<#
.SYNOPSIS
    Оптимизация уже установленной LineageOS на TB-8505F и тест на тормоза.

.DESCRIPTION
    Запускать ПОСЛЕ прошивки, когда мастер настройки пройден и Google Play закончил
    первые обновления приложений (обычно через 20-40 минут после входа в аккаунт).
    Именно в это время появляются окна "Приложение не отвечает": Play обновил Chrome,
    сервисы Google и т. д., а их код ещё не скомпилирован под планшет.

    Что делает (без стирания данных и без перезагрузки):
      1. Проверяет исправления пост-настройки (Bluetooth, GL backpressure, анимации)
         и применяет заново, если что-то сбилось.
      2. Отключает ненужные на Wi-Fi-планшете службы (список в config.json:
         LineageOS.Optimize.DisablePackages) - меньше занятой памяти.
      3. Компилирует обновлённые приложения (cmd package bg-dexopt-job) -
         то, что Android иначе сделал бы сам ночью на зарядке.
      4. Тест на тормоза: время холодного/тёплого запуска приложений, плавность
         прокрутки (доля "рваных" кадров), ANR, задержка и сигнал Wi-Fi.

.PARAMETER SkipDexopt
    Не компилировать приложения (только проверка, отключение служб и тест).

.PARAMETER BenchmarkOnly
    Только тест на тормоза, ничего не менять.

.PARAMETER Revert
    Включить обратно службы, отключённые этим скриптом.

.EXAMPLE
    .\Optimize-LineageOS.ps1
    Полная оптимизация и тест (лучше через OPTIMIZE_LINEAGEOS.cmd).

.EXAMPLE
    .\Optimize-LineageOS.ps1 -BenchmarkOnly
    Только замерить тормоза.

.NOTES
    PowerShell 5.1+. Комплект: TB8505F_LineageOS_Kit. Лог: logs\optimize_*.log
#>
[CmdletBinding(DefaultParameterSetName = 'Optimize')]
[OutputType([void])]
param(
    [Parameter(Mandatory = $false, ParameterSetName = 'Optimize')]
    [switch]$SkipDexopt,

    [Parameter(Mandatory = $true, ParameterSetName = 'Benchmark')]
    [switch]$BenchmarkOnly,

    [Parameter(Mandatory = $true, ParameterSetName = 'Revert')]
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$kitRoot = Split-Path -Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'TB8505F.Flash.psm1') -Force -DisableNameChecking

function Invoke-AdbShell {
    <# adb shell <команда>, возвращает текст вывода. #>
    param([Parameter(Mandatory = $true)][string]$Command)
    (Invoke-KitTool -Tool adb -Arguments @('shell', $Command)).Output
}

function Get-AnrCount {
    $n = Invoke-AdbShell -Command 'logcat -d -b events | grep -c am_anr'
    [int]($n -replace '\D', '0')
}

function Test-PostConfig {
    <# Возвращает $true, если все исправления пост-настройки на месте. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$PostConfig)
    $ok = $true
    foreach ($prop in $PostConfig.Props.PSObject.Properties) {
        $v = Get-AdbProp -Name $prop.Name
        if ($v -ne $prop.Value) {
            Write-KitLog -Message "  $($prop.Name) = '$v' (нужно '$($prop.Value)')" -Level Warn
            $ok = $false
        }
        else { Write-KitLog -Message "  $($prop.Name) = $v" -Level Ok }
    }
    foreach ($key in 'window_animation_scale', 'transition_animation_scale', 'animator_duration_scale') {
        $v = Invoke-AdbShell -Command "settings get global $key"
        if ($v.Trim() -ne $PostConfig.AnimationScale) {
            Write-KitLog -Message "  $key = '$v' (нужно '$($PostConfig.AnimationScale)')" -Level Warn
            $ok = $false
        }
    }
    if ($ok) { Write-KitLog -Message "  анимации = $($PostConfig.AnimationScale)" -Level Ok }
    $ok
}

function Set-PackageState {
    <# Отключает (или включает обратно) пакеты для пользователя 0. Отсутствующие пропускает. #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Packages,
        [Parameter(Mandatory = $true)][ValidateSet('Disable', 'Enable')][string]$Action
    )
    $installed = Invoke-AdbShell -Command 'pm list packages -u'
    $disabled = Invoke-AdbShell -Command 'pm list packages -d'
    foreach ($p in $Packages) {
        if ($installed -notmatch "(?m)^package:$([regex]::Escape($p))\s*$") {
            Write-KitLog -Message "  $p - не установлен, пропуск"
            continue
        }
        $isDisabled = $disabled -match "(?m)^package:$([regex]::Escape($p))\s*$"
        if ($Action -eq 'Disable' -and $isDisabled) { Write-KitLog -Message "  $p - уже отключён" -Level Ok; continue }
        if ($Action -eq 'Enable' -and -not $isDisabled) { Write-KitLog -Message "  $p - уже включён" -Level Ok; continue }
        $cmd = if ($Action -eq 'Disable') { "pm disable-user --user 0 $p" } else { "pm enable --user 0 $p" }
        $r = Invoke-AdbShell -Command $cmd
        if ($r -match 'new state') { Write-KitLog -Message "  $p - $($r.Trim())" -Level Ok }
        else { Write-KitLog -Message "  $p - не удалось: $r" -Level Warn }
    }
}

function Get-CompileStatus {
    <#
        Статус компиляции основного кода приложений (pm art dump): хэш-таблица пакет -> статус.
        speed / speed-profile = скомпилировано; verify / quicken / run-from-apk = нет.
    #>
    param([Parameter(Mandatory = $true)][object[]]$Apps)
    $installed = Invoke-AdbShell -Command 'pm list packages'
    $result = [ordered]@{}
    foreach ($app in $Apps) {
        if ($installed -notmatch "(?m)^package:$([regex]::Escape($app.Package))\s*$") { continue }
        $dump = Invoke-AdbShell -Command "pm art dump $($app.Package)"
        $result[$app.Package] = if ($dump -match '\[status=([a-z-]+)\]') { $Matches[1] } else { '?' }
    }
    $result
}

function Write-CompileReport {
    <# Таблица "было -> стало" по ключевым приложениям. #>
    param(
        [Parameter(Mandatory = $true)][object[]]$Apps,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Before,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$After
    )
    Write-KitLog -Message 'Статус компиляции (speed / speed-profile = скомпилировано):'
    foreach ($app in $Apps) {
        if (-not $After.Contains($app.Package)) { continue }
        $b = if ($Before.Contains($app.Package)) { $Before[$app.Package] } else { 'нет' }
        $a = $After[$app.Package]
        $ok = $a -match '^speed'
        Write-KitLog -Message ('  {0,-22} {1,-14} -> {2}' -f $app.Name, $b, $a) -Level $(if ($ok) { 'Ok' } else { 'Warn' })
    }
}

function Measure-WifiLatency {
    <# 50 пингов до шлюза Wi-Fi: среднее, максимум, число медленных (>30 мс). #>
    $r = Invoke-AdbShell -Command 'gw=$(ip route get 1.1.1.1 | grep -oE "via [0-9.]+" | cut -d" " -f2); [ -z "$gw" ] && exit 0; ping -c 50 -i 0.2 -W 2 $gw > /data/local/tmp/tb_ping.txt; tail -1 /data/local/tmp/tb_ping.txt; echo slow=$(grep -v DUP /data/local/tmp/tb_ping.txt | grep -cE "time=([3-9][0-9]|[0-9]{3})"); rm -f /data/local/tmp/tb_ping.txt'
    if ($r -match '= [\d.]+/([\d.]+)/([\d.]+)/' ) {
        $avg = $Matches[1]; $max = $Matches[2]
        $slow = if ($r -match 'slow=(\d+)') { $Matches[1] } else { '?' }
        "среднее $avg мс, максимум $max мс, медленных (>30 мс) $slow из 50"
    }
    else { 'нет данных (Wi-Fi не подключён?)' }
}

function Measure-AppLaunch {
    <# Холодный и тёплый запуск приложения, мс (TotalTime из am start -W). #>
    param([Parameter(Mandatory = $true)][pscustomobject]$App)
    Invoke-AdbShell -Command "am force-stop $($App.Package)" | Out-Null
    Start-Sleep -Seconds 2
    $cold = Invoke-AdbShell -Command "am start -W -n $($App.Activity)"
    Invoke-AdbShell -Command 'input keyevent KEYCODE_HOME' | Out-Null
    Start-Sleep -Seconds 2
    $warm = Invoke-AdbShell -Command "am start -W -n $($App.Activity)"
    Invoke-AdbShell -Command 'input keyevent KEYCODE_HOME' | Out-Null
    Start-Sleep -Seconds 3
    $parse = { param($t) if ($t -match 'TotalTime:\s*(\d+)') { [int]$Matches[1] } else { $null } }
    [pscustomobject]@{
        Name   = $App.Name
        ColdMs = & $parse $cold
        WarmMs = & $parse $warm
    }
}

function Measure-ScrollJank {
    <# Прокрутка Настроек 12 раз, доля рваных кадров и 90-й перцентиль времени кадра. #>
    Invoke-AdbShell -Command 'am start -W -n com.android.settings/.Settings' | Out-Null
    Start-Sleep -Seconds 2
    Invoke-AdbShell -Command 'dumpsys gfxinfo com.android.settings reset' | Out-Null
    Invoke-AdbShell -Command 'for i in 1 2 3 4 5 6; do input swipe 400 1000 400 300 250; sleep 0.6; input swipe 400 300 400 1000 250; sleep 0.6; done' | Out-Null
    $g = Invoke-AdbShell -Command 'dumpsys gfxinfo com.android.settings'
    Invoke-AdbShell -Command 'input keyevent KEYCODE_HOME' | Out-Null
    $frames = if ($g -match 'Total frames rendered:\s*(\d+)') { [int]$Matches[1] } else { 0 }
    $jank = if ($g -match 'Janky frames:\s*\d+\s*\(([\d.]+)%\)') { [double]$Matches[1] } else { $null }
    $p90 = if ($g -match '90th percentile:\s*(\d+)ms') { [int]$Matches[1] } else { $null }
    [pscustomobject]@{ Frames = $frames; JankPercent = $jank; P90Ms = $p90 }
}

function Invoke-LagBenchmark {
    <# Тест на тормоза. Возвращает $true, если всё в пределах нормы. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Optimize)
    Invoke-AdbShell -Command 'input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard' | Out-Null
    Start-Sleep -Seconds 2
    if ((Invoke-AdbShell -Command 'dumpsys window') -match 'isKeyguardShowing=true') {
        Write-KitLog -Message 'Экран заблокирован (PIN/графический ключ) - разблокируйте планшет и запустите тест ещё раз.' -Level Warn
        return $false
    }
    Show-UserAction -Lines @('Идёт тест: скрипт сам открывает приложения и листает Настройки.', 'Не трогайте планшет ~1 минуту.')
    $anrBefore = Get-AnrCount
    $good = $true
    $installed = Invoke-AdbShell -Command 'pm list packages'
    foreach ($app in $Optimize.BenchmarkApps) {
        if ($installed -notmatch "(?m)^package:$([regex]::Escape($app.Package))\s*$") {
            Write-KitLog -Message ('  Запуск {0,-12} не установлен - пропуск (поставится из Play позже)' -f $app.Name)
            continue
        }
        $m = Measure-AppLaunch -App $app
        $slow = ($null -eq $m.ColdMs) -or ($m.ColdMs -gt $Optimize.MaxColdStartMs)
        if ($slow) { $good = $false }
        Write-KitLog -Message ('  Запуск {0,-12} холодный {1,6} мс, тёплый {2,5} мс' -f $m.Name, $m.ColdMs, $m.WarmMs) -Level $(if ($slow) { 'Warn' } else { 'Ok' })
    }
    $s = Measure-ScrollJank
    $janky = ($null -eq $s.JankPercent) -or ($s.JankPercent -gt $Optimize.MaxJankPercent)
    if ($janky) { $good = $false }
    Write-KitLog -Message ('  Прокрутка: {0} кадров, рваных {1}%, 90% кадров быстрее {2} мс' -f $s.Frames, $s.JankPercent, $s.P90Ms) -Level $(if ($janky) { 'Warn' } else { 'Ok' })
    $anrAfter = Get-AnrCount
    $newAnr = $anrAfter - $anrBefore
    if ($newAnr -gt 0) { $good = $false }
    Write-KitLog -Message "  ANR во время теста: $newAnr (всего с момента включения: $anrAfter)" -Level $(if ($newAnr -gt 0) { 'Warn' } else { 'Ok' })
    Write-KitLog -Message "  Задержка Wi-Fi до роутера: $(Measure-WifiLatency)"
    $rssi = Invoke-AdbShell -Command 'dumpsys wifi | grep -m1 "^mWifiInfo"'
    if ($rssi -match 'RSSI: (-?\d+), Link speed: (\d+)') {
        $weak = [int]$Matches[1] -lt -75
        Write-KitLog -Message ('  Сигнал Wi-Fi: {0} dBm, скорость связи {1} Мбит/с{2}' -f $Matches[1], $Matches[2], $(if ($weak) { ' - СЛАБЫЙ (нужно лучше -65 dBm): страницы и видео будут грузиться медленно' } else { '' })) -Level $(if ($weak) { 'Warn' } else { 'Ok' })
    }
    $mem = Invoke-AdbShell -Command 'grep MemAvailable /proc/meminfo'
    if ($mem -match '(\d+)\s*kB') { Write-KitLog -Message ('  Свободно памяти: {0} МБ' -f [math]::Round([int]$Matches[1] / 1024)) }
    $good
}

try {
    $config = Initialize-Kit -KitRoot $kitRoot -LogName 'optimize'
    $host.UI.RawUI.WindowTitle = 'TB-8505F - оптимизация LineageOS'
    $opt = $config.LineageOS.Optimize

    Write-KitLog -Message '1/4 Подключение планшета' -Level Step
    $state = Connect-Device
    if ($state -ne 'Adb') { throw 'Планшет должен быть загружен в LineageOS (не в fastboot).' }
    Assert-DeviceModel -State $state -DeviceConfig $config.Device

    if ($Revert) {
        Write-KitLog -Message 'Включение отключённых служб' -Level Step
        Set-PackageState -Packages $opt.DisablePackages -Action Enable
        Show-UserAction -Lines @('ГОТОВО. Службы включены обратно.')
        exit 0
    }

    # Мастер настройки ещё не пройден: компиляция всего (dex2oat) конкурирует с ним за CPU/диск,
    # и мастер надолго зависает на "Проверка..." - запускать оптимизацию нужно ПОСЛЕ мастера.
    # Проверяем ВСЕ задачи, а не только окно на экране: мастер Google живёт в отдельной задаче
    # и может быть на заднем плане (сверху - рабочий стол), но всё ещё не завершён.
    $wiz = Invoke-AdbShell -Command 'dumpsys activity activities | grep -cE "u0 (com.google.android.setupwizard|org.lineageos.setupwizard|com.android.provision)/"'
    $wizCount = 0
    [void][int]::TryParse((($wiz -split "`n")[0]).Trim(), [ref]$wizCount)
    if ($wizCount -gt 0) {
        Show-KitAlert -Lines @(
            'СНАЧАЛА ЗАВЕРШИТЕ МАСТЕР НАСТРОЙКИ НА ПЛАНШЕТЕ!',
            '',
            'Оптимизация во время мастера тормозит его ("Проверка..." висит долго).',
            'Пройдите мастер до конца, подождите 20-40 мин, пока Google Play обновит',
            'приложения, затем запустите OPTIMIZE_LINEAGEOS.cmd снова.',
            '',
            'FINISH THE SETUP WIZARD FIRST, then run OPTIMIZE_LINEAGEOS.cmd again.'
        )
        exit 2
    }

    if (-not $BenchmarkOnly) {
        Write-KitLog -Message '2/4 Проверка исправлений пост-настройки' -Level Step
        if (-not (Test-PostConfig -PostConfig $config.LineageOS.PostConfig)) {
            Write-KitLog -Message 'Часть исправлений сбилась - применяю заново.' -Level Warn
            Set-GsiPostConfig -PostConfig $config.LineageOS.PostConfig
        }

        Write-KitLog -Message '3/4 Отключение ненужных служб и компиляция приложений' -Level Step
        Set-PackageState -Packages $opt.DisablePackages -Action Disable
        if ($SkipDexopt) {
            Write-KitLog -Message 'Компиляция пропущена (-SkipDexopt).' -Level Warn
        }
        else {
            $statusBefore = Get-CompileStatus -Apps $opt.CompileReportApps
            Write-KitLog -Message 'Компиляция приложений: стандартная задача Android bg-dexopt-job (2-10 мин, планшет может подтормаживать)...'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-AdbShell -Command 'cmd package bg-dexopt-job'
            $sw.Stop()
            if ($r -match 'cancel') {
                Write-KitLog -Message 'Компиляция была прервана - запустите скрипт ещё раз позже.' -Level Warn
            }
            elseif ($r -match 'finished') {
                Write-KitLog -Message ('Компиляция завершена за {0:N0} с.' -f $sw.Elapsed.TotalSeconds) -Level Ok
            }
            else {
                Write-KitLog -Message "Компиляция: $r" -Level Warn
            }
            $statusAfter = Get-CompileStatus -Apps $opt.CompileReportApps
            Write-CompileReport -Apps $opt.CompileReportApps -Before $statusBefore -After $statusAfter
        }
    }

    Write-KitLog -Message '4/4 Тест на тормоза' -Level Step
    $good = Invoke-LagBenchmark -Optimize $opt
    if ($good) {
        Show-UserAction -Lines @('ГОТОВО. Тест пройден - тормозов и зависаний нет.')
    }
    else {
        Show-UserAction -Lines @(
            'ГОТОВО, но тест показал отклонения (жёлтые строки выше).',
            'Если Google Play ещё обновляет приложения - подождите и запустите скрипт ещё раз.'
        )
    }
}
catch {
    Write-KitLog -Message "ОШИБКА: $($_.Exception.Message)" -Level Error
    Write-KitLog -Message 'Скрипт можно запустить повторно. Лог в папке logs.' -Level Warn
    exit 1
}
