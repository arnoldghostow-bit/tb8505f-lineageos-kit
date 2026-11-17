<#
.SYNOPSIS
    Общие функции комплекта прошивки Lenovo TB-8505F: adb/fastboot, драйвер,
    ожидание состояний устройства, прошивка разделов, пост-настройка GSI.
.NOTES
    PowerShell 5.1+. Файл в UTF-8 с BOM.
    fastboot пишет всё в stderr, поэтому служебные вызовы идут через cmd /s /c ... 2>&1,
    чтобы PowerShell 5.1 не превращал строки stderr в ErrorRecord.
#>

$script:_KitRoot = $null
$script:_Adb = $null
$script:_Fastboot = $null
$script:_LogFile = $null

#region Инициализация и лог

function Install-KitAsset {
    <#
        Если в комплекте нет fastboot/образов (свежая копия из GitHub) - запускает
        Get-KitAssets.ps1 отдельным процессом и ждёт его. Возвращает $true, если всё готово.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$KitRoot,

        [Parameter(Mandatory = $true)]
        [ValidateSet('LineageOS', 'Stock')]
        [string]$Target
    )
    $config = Get-Content -Path (Join-Path $KitRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $required = New-Object System.Collections.Generic.List[string]
    $required.Add((Join-Path $KitRoot (Join-Path $config.Tools.PlatformTools 'fastboot.exe')))
    $required.Add((Join-Path $KitRoot $config.Tools.DriverInf))
    foreach ($item in $config.$Target.Flash) { $required.Add((Join-Path $KitRoot $item.File)) }
    $missing = @($required | Where-Object { -not (Test-Path $_) })

    $ready = $true
    if ($missing.Count -gt 0) {
        Write-Host ''
        Write-Host "В комплекте не хватает файлов ($($missing.Count)) - запускаю подготовку (Get-KitAssets.ps1)..." -ForegroundColor Cyan
        $assetsScript = Join-Path $KitRoot 'scripts\Get-KitAssets.ps1'
        $psExe = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path $psExe)) { $psExe = Join-Path $PSHOME 'pwsh.exe' }
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $assetsScript
        $stillMissing = @($required | Where-Object { -not (Test-Path $_) })
        if ($stillMissing.Count -gt 0) {
            Write-Host 'Подготовка не завершена, не хватает:' -ForegroundColor Yellow
            foreach ($m in $stillMissing) { Write-Host "  - $m" -ForegroundColor Yellow }
            $ready = $false
        }
    }
    $ready
}

function Initialize-Kit {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$KitRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogName
    )
    $script:_KitRoot = (Resolve-Path $KitRoot).Path
    $configPath = Join-Path $script:_KitRoot 'config.json'
    $config = Get-Content -Path $configPath -Raw -Encoding UTF8 -ErrorAction Stop |
        ConvertFrom-Json

    $toolsDir = Join-Path $script:_KitRoot $config.Tools.PlatformTools
    $script:_Adb = Join-Path $toolsDir 'adb.exe'
    $script:_Fastboot = Join-Path $toolsDir 'fastboot.exe'
    foreach ($exe in $script:_Adb, $script:_Fastboot) {
        if (-not (Test-Path $exe)) { throw "Не найден инструмент: $exe. Сначала запустите GET_ASSETS.cmd." }
    }

    $logDir = Join-Path $script:_KitRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:_LogFile = Join-Path $logDir "$LogName`_$stamp.log"

    $config
}

function Write-KitLog {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Step', 'Action')]
        [string]$Level = 'Info'
    )
    $colors = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red'; Step = 'Cyan'; Action = 'Magenta' }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Message
    if ($Level -eq 'Step') { Write-Host '' }
    Write-Host $line -ForegroundColor $colors[$Level]
    if ($script:_LogFile) {
        Add-Content -Path $script:_LogFile -Value $line -Encoding UTF8 -WhatIf:$false
    }
}

function Show-UserAction {
    <# Крупное заметное сообщение о том, что нужно сделать руками. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines
    )
    $bar = '=' * 70
    Write-Host ''
    Write-Host $bar -ForegroundColor Magenta
    foreach ($l in $Lines) { Write-Host "  $l" -ForegroundColor White -BackgroundColor DarkMagenta }
    Write-Host $bar -ForegroundColor Magenta
    Write-Host ''
    foreach ($l in $Lines) { Write-KitLog -Message "ДЕЙСТВИЕ ПОЛЬЗОВАТЕЛЯ: $l" -Level Action 6>$null }
}

#endregion

#region Вызов adb / fastboot

function Invoke-KitTool {
    <# Запускает adb/fastboot и возвращает объект с ExitCode и Output (stdout+stderr). #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('adb', 'fastboot')]
        [string]$Tool,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )
    $exe = if ($Tool -eq 'adb') { $script:_Adb } else { $script:_Fastboot }
    $quotedArgs = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
    $cmdLine = '""{0}" {1} 2>&1"' -f $exe, $quotedArgs
    $output = & cmd.exe /s /c $cmdLine
    $result = [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = (@($output) | ForEach-Object { "$_".TrimEnd() }) -join "`n"
    }
    Write-Verbose "$Tool $quotedArgs -> $($result.ExitCode): $($result.Output)"
    $result
}

function Invoke-KitToolLive {
    <# Запуск с выводом прямо в консоль (для долгих операций, где важен прогресс). #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('adb', 'fastboot')]
        [string]$Tool,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailMessage
    )
    $exe = if ($Tool -eq 'adb') { $script:_Adb } else { $script:_Fastboot }
    Write-KitLog -Message "$Tool $($Arguments -join ' ')"
    & $exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FailMessage (код $LASTEXITCODE)" }
}

function Get-FastbootVar {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )
    $r = Invoke-KitTool -Tool fastboot -Arguments @('getvar', $Name)
    $value = $null
    $m = [regex]::Match($r.Output, "(?m)^(?:\(bootloader\)\s*)?$([regex]::Escape($Name)):\s*(.*)$")
    if ($m.Success) { $value = $m.Groups[1].Value.Trim() }
    $value
}

function Get-AdbProp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )
    $r = Invoke-KitTool -Tool adb -Arguments @('shell', 'getprop', $Name)
    $value = $r.Output.Trim()
    $value
}

#endregion

#region Драйвер

function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $isAdmin
}

function Install-KitDriver {
    <# Ставит драйвер MediaTek ADB/fastboot (WinUSB). Повторный запуск безопасен. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InfPath
    )
    if (-not (Test-Path $InfPath)) { throw "Не найден драйвер: $InfPath" }
    if (-not (Test-IsAdministrator)) {
        Write-KitLog -Message 'Нет прав администратора: установка драйвера пропущена (запускайте через .cmd).' -Level Warn
        return
    }
    Write-KitLog -Message "Установка драйвера: $InfPath"
    $out = & pnputil.exe /add-driver $InfPath /install 2>&1
    Write-Verbose ($out -join "`n")
    # 0 = установлен, 259 = уже актуален / нет подходящих устройств сейчас - оба варианта нормальны.
    if ($LASTEXITCODE -notin 0, 259, 3010) {
        Write-KitLog -Message "pnputil вернул код $LASTEXITCODE. Вывод: $($out -join ' ')" -Level Warn
    }
    else {
        Write-KitLog -Message 'Драйвер MediaTek ADB/fastboot установлен.' -Level Ok
    }
}

#endregion

#region Состояние устройства

function Get-DeviceState {
    <# Возвращает: Adb, AdbUnauthorized, AdbOffline, Fastboot, None, Multiple. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $fb = Invoke-KitTool -Tool fastboot -Arguments @('devices')
    $fbLines = @($fb.Output -split "`n" | Where-Object { $_ -match '^\S+\s+fastboot\s*$' })
    $adb = Invoke-KitTool -Tool adb -Arguments @('devices')
    $adbLines = @($adb.Output -split "`n" | Where-Object { $_ -match '^\S+\t(device|unauthorized|offline|recovery|sideload)' })

    $total = $fbLines.Count + $adbLines.Count
    $state = 'None'
    if ($total -gt 1) { $state = 'Multiple' }
    elseif ($fbLines.Count -eq 1) { $state = 'Fastboot' }
    elseif ($adbLines.Count -eq 1) {
        $state = switch -Regex ($adbLines[0]) {
            '\tdevice' { 'Adb' }
            '\tunauthorized' { 'AdbUnauthorized' }
            default { 'AdbOffline' }
        }
    }
    $state
}

function Wait-DeviceState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Adb', 'Fastboot', 'AnyUsable')]
        [string]$State,

        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 3600)]
        [int]$TimeoutSec = 120
    )
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $current = Get-DeviceState
    $reached = $false
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $current = Get-DeviceState
        $reached = switch ($State) {
            'AnyUsable' { $current -in 'Adb', 'Fastboot' }
            default { $current -eq $State }
        }
        if ($reached) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $reached) {
        throw "За $TimeoutSec с устройство не перешло в состояние '$State' (сейчас: $current)."
    }
    $current
}

function Connect-Device {
    <#
        Доводит устройство до рабочего состояния adb или fastboot,
        подсказывая пользователю, что сделать, если оно не видно или не авторизовано.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateRange(30, 3600)]
        [int]$TimeoutSec = 600
    )
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $lastShown = ''
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $state = Get-DeviceState
        if ($state -in 'Adb', 'Fastboot') { break }
        if ($state -ne $lastShown) {
            switch ($state) {
                'None' {
                    Show-UserAction -Lines @(
                        'Планшет не виден. Подключите его USB-кабелем к этому ПК.',
                        'Если он включён в Android: Настройки > О планшете > 7 раз по "Номер сборки",',
                        'затем Настройки > Система > Для разработчиков > "Отладка по USB" = ВКЛ.',
                        'Если планшет выключен/не грузится: зажмите Громкость ВНИЗ + Питание (вход в fastboot).'
                    )
                }
                'AdbUnauthorized' {
                    Show-UserAction -Lines @(
                        'На экране планшета появился запрос "Разрешить отладку по USB?".',
                        'Поставьте галочку "Всегда разрешать" и нажмите OK.'
                    )
                }
                'AdbOffline' { Write-KitLog -Message 'Устройство в состоянии offline, жду...' -Level Warn }
                'Multiple' {
                    Show-UserAction -Lines @('Подключено больше одного Android-устройства. Оставьте только планшет TB-8505F.')
                }
            }
            $lastShown = $state
        }
        Start-Sleep -Seconds 2
    }
    if ($state -notin 'Adb', 'Fastboot') { throw "Планшет так и не подключился за $TimeoutSec с." }
    Write-KitLog -Message "Планшет подключён, режим: $state" -Level Ok
    $state
}

function Assert-DeviceModel {
    <# Проверяет, что подключён именно TB-8505F (в любом из режимов). #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Adb', 'Fastboot')]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$DeviceConfig
    )
    if ($State -eq 'Adb') {
        $actual = Get-AdbProp -Name 'ro.product.board'
        if ($actual -ne $DeviceConfig.AdbBoard) {
            # В GSI ro.product.board может быть другим - проверяем vendor-свойство.
            $actual = Get-AdbProp -Name 'ro.product.vendor.device'
            $model = Get-AdbProp -Name 'ro.product.vendor.model'
            if ($model -notmatch '8505F') {
                throw "Подключено не то устройство (board/model: '$actual' / '$model'). Нужен $($DeviceConfig.Name)."
            }
        }
    }
    else {
        $actual = Get-FastbootVar -Name 'product'
        if ($actual -ne $DeviceConfig.FastbootProduct) {
            throw "Подключено не то устройство (fastboot product: '$actual'). Нужен $($DeviceConfig.FastbootProduct)."
        }
    }
    Write-KitLog -Message "Модель подтверждена: $($DeviceConfig.Name)" -Level Ok
}

function Assert-BatteryLevel {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 100)]
        [int]$MinPercent
    )
    $r = Invoke-KitTool -Tool adb -Arguments @('shell', 'dumpsys', 'battery')
    $m = [regex]::Match($r.Output, '(?m)^\s*level:\s*(\d+)')
    if (-not $m.Success) {
        Write-KitLog -Message 'Не удалось прочитать заряд батареи, продолжаю.' -Level Warn
        return
    }
    $level = [int]$m.Groups[1].Value
    if ($level -lt $MinPercent) {
        throw "Заряд $level% - меньше $MinPercent%. Зарядите планшет и запустите снова."
    }
    Write-KitLog -Message "Заряд батареи: $level%" -Level Ok
}

#endregion

#region Прошивка

function Test-KitImage {
    <# Проверяет наличие и SHA256 образов из списка Flash. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$FlashList,

        [Parameter(Mandatory = $false)]
        [switch]$SkipHash
    )
    foreach ($item in $FlashList) {
        $path = Join-Path $script:_KitRoot $item.File
        if (-not (Test-Path $path)) { throw "Нет файла образа: $path. Сначала запустите GET_ASSETS.cmd." }
        if ($SkipHash) { continue }
        Write-KitLog -Message "Проверка SHA256: $($item.File)"
        $hash = (Get-FileHash -Path $path -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($hash -ne $item.Sha256) { throw "Файл повреждён (SHA256 не совпадает): $path" }
    }
    Write-KitLog -Message 'Все образы на месте и целы.' -Level Ok
}

function Enter-Fastboot {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Adb', 'Fastboot')]
        [string]$State
    )
    if ($State -eq 'Fastboot') { return }
    Write-KitLog -Message 'Перезагрузка в fastboot...'
    Invoke-KitTool -Tool adb -Arguments @('reboot', 'bootloader') | Out-Null
    Wait-DeviceState -State Fastboot -TimeoutSec 120 | Out-Null
    Write-KitLog -Message 'Планшет в режиме fastboot.' -Level Ok
}

function Unlock-Bootloader {
    <# Разблокирует загрузчик, если он ещё заблокирован. Требует нажатия Громкость ВВЕРХ. #>
    [CmdletBinding()]
    [OutputType([void])]
    param()
    $unlocked = Get-FastbootVar -Name 'unlocked'
    if ($unlocked -eq 'yes') {
        Write-KitLog -Message 'Загрузчик уже разблокирован.' -Level Ok
        return
    }
    Show-UserAction -Lines @(
        'СЕЙЧАС на экране планшета появится предупреждение о разблокировке загрузчика.',
        'Нажмите кнопку ГРОМКОСТЬ ВВЕРХ, чтобы подтвердить.',
        '(Громкость вниз = отмена. Все данные на планшете будут стёрты.)'
    )
    $r = Invoke-KitTool -Tool fastboot -Arguments @('flashing', 'unlock')
    Write-KitLog -Message $r.Output
    Start-Sleep -Seconds 3
    $unlocked = Get-FastbootVar -Name 'unlocked'
    if ($unlocked -ne 'yes') {
        throw 'Загрузчик не разблокирован (не подтвердили кнопкой громкости или нажали "вниз"). Запустите скрипт снова.'
    }
    Write-KitLog -Message 'Загрузчик разблокирован.' -Level Ok
}

function Lock-Bootloader {
    [CmdletBinding()]
    [OutputType([void])]
    param()
    Show-UserAction -Lines @(
        'СЕЙЧАС на экране планшета появится запрос на БЛОКИРОВКУ загрузчика.',
        'Нажмите кнопку ГРОМКОСТЬ ВВЕРХ, чтобы подтвердить.'
    )
    $r = Invoke-KitTool -Tool fastboot -Arguments @('flashing', 'lock')
    Write-KitLog -Message $r.Output
    Start-Sleep -Seconds 3
    $unlocked = Get-FastbootVar -Name 'unlocked'
    if ($unlocked -ne 'no') { throw 'Загрузчик не заблокирован.' }
    Write-KitLog -Message 'Загрузчик заблокирован.' -Level Ok
}

function Invoke-PartitionFlash {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$FlashList,

        [Parameter(Mandatory = $false)]
        [string[]]$EraseList = @()
    )
    foreach ($item in $FlashList) {
        $path = Join-Path $script:_KitRoot $item.File
        if ($PSCmdlet.ShouldProcess($item.Partition, "fastboot flash $($item.File)")) {
            Write-KitLog -Message "Прошивка раздела '$($item.Partition)' <- $($item.File)" -Level Step
            $flashParams = @{
                Tool        = 'fastboot'
                Arguments   = @('flash', $item.Partition, $path)
                FailMessage = "Ошибка прошивки раздела $($item.Partition)"
            }
            Invoke-KitToolLive @flashParams
        }
    }
    foreach ($part in $EraseList) {
        if ($PSCmdlet.ShouldProcess($part, 'fastboot erase')) {
            Write-KitLog -Message "Очистка раздела '$part'"
            $r = Invoke-KitTool -Tool fastboot -Arguments @('erase', $part)
            if ($r.ExitCode -ne 0) { throw "Ошибка очистки $part : $($r.Output)" }
        }
    }
    Write-KitLog -Message 'Все разделы записаны.' -Level Ok
}

function Wait-AndroidBoot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateRange(60, 3600)]
        [int]$TimeoutSec = 600
    )
    Write-KitLog -Message "Ожидание загрузки Android (первая загрузка до $([int]($TimeoutSec/60)) мин)..."
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $booted = $false
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $state = Get-DeviceState
        if ($state -eq 'Fastboot' -and $timer.Elapsed.TotalSeconds -gt 30) {
            throw 'Планшет вернулся в fastboot вместо загрузки системы (бутлуп).'
        }
        if ($state -eq 'Adb' -and (Get-AdbProp -Name 'sys.boot_completed') -eq '1') {
            $booted = $true
            break
        }
        Start-Sleep -Seconds 5
    }
    if ($booted) {
        Write-KitLog -Message ("Android загрузился за {0:N0} с." -f $timer.Elapsed.TotalSeconds) -Level Ok
    }
    else {
        Write-KitLog -Message 'ADB не появился (на этой системе отладка может быть выключена) - проверьте экран планшета.' -Level Warn
    }
    $booted
}

#endregion

#region Пост-настройка LineageOS GSI

function Set-GsiPostConfig {
    <#
        Применяет исправления для TB-8505F через adb root (userdebug-сборка GSI):
        Bluetooth-обход MediaTek, отключение GL backpressure, анимации.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$PostConfig
    )
    Write-KitLog -Message 'Пост-настройка LineageOS...' -Level Step
    Invoke-KitTool -Tool adb -Arguments @('root') | Out-Null
    Start-Sleep -Seconds 3
    Wait-DeviceState -State Adb -TimeoutSec 60 | Out-Null
    $id = (Invoke-KitTool -Tool adb -Arguments @('shell', 'id', '-u')).Output.Trim()
    if ($id -ne '0') {
        Write-KitLog -Message 'adb root недоступен - свойства Bluetooth/SurfaceFlinger выставьте в TrebleDroid Settings вручную.' -Level Warn
    }
    else {
        <# Скрипт для планшета собирается целиком и выполняется через push + sh,
           чтобы не бороться с тройным экранированием cmd -> adb -> shell. #>
        $prefsFile = '/data/data/me.phh.treble.app/shared_prefs/me.phh.treble.app_preferences.xml'
        $sh = New-Object System.Collections.Generic.List[string]
        $sh.Add('#!/system/bin/sh')
        foreach ($prop in $PostConfig.Props.PSObject.Properties) {
            $sh.Add(("setprop '{0}' '{1}' && echo 'prop {0}={1}'" -f $prop.Name, $prop.Value))
        }
        <# Настройки приложения TrebleDroid: при загрузке оно выставляет свойства из своих
           настроек (по умолчанию Bluetooth = none) и затирает наш setprop. На свежей
           прошивке файла настроек ещё нет: запускаем приложение один раз, а если файл
           так и не появился - создаём его сами с правами и SELinux-контекстом приложения. #>
        $sh.Add("P='$prefsFile'")
        $sh.Add(@'
D=/data/data/me.phh.treble.app
am force-stop me.phh.treble.app
if [ ! -f "$P" ]; then
  monkey -p me.phh.treble.app -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 6
  am force-stop me.phh.treble.app
fi
if [ ! -f "$P" ]; then
  mkdir -p "$D/shared_prefs"
  printf "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>\n" > "$P"
  echo "prefs-created"
fi
U=$(stat -c %u "$D")
chown -R "$U:$U" "$D/shared_prefs"
chmod 771 "$D/shared_prefs"
chmod 660 "$P"
restorecon -R "$D/shared_prefs"
set_bool() {
  if grep -q "name=\"$1\"" "$P"; then
    sed -i "s|<boolean name=\"$1\" value=\"[a-z]*\" />|<boolean name=\"$1\" value=\"$2\" />|" "$P"
  else
    sed -i "/<\/map>/i \    <boolean name=\"$1\" value=\"$2\" />" "$P"
  fi
  grep -q "<boolean name=\"$1\" value=\"$2\" />" "$P" && echo "pref $1=$2" || echo "pref-failed $1"
}
set_str() {
  if grep -q "name=\"$1\"" "$P"; then
    sed -i "s|<string name=\"$1\">[^<]*</string>|<string name=\"$1\">$2</string>|" "$P"
  else
    sed -i "/<\/map>/i \    <string name=\"$1\">$2</string>" "$P"
  fi
  grep -q "<string name=\"$1\">$2</string>" "$P" && echo "pref $1=$2" || echo "pref-failed $1"
}
'@)
        foreach ($pref in $PostConfig.TrebleAppPrefs.PSObject.Properties) {
            $fn = if ($pref.Value -in 'true', 'false') { 'set_bool' } else { 'set_str' }
            $sh.Add(("{0} '{1}' '{2}'" -f $fn, $pref.Name, $pref.Value))
        }

        $localSh = Join-Path $env:TEMP ("tb8505f_post_{0}.sh" -f (New-Guid))
        [System.IO.File]::WriteAllText($localSh, (($sh -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
        try {
            Invoke-KitTool -Tool adb -Arguments @('push', $localSh, '/data/local/tmp/tb8505f_post.sh') | Out-Null
            $r = Invoke-KitTool -Tool adb -Arguments @('shell', 'sh', '/data/local/tmp/tb8505f_post.sh')
            foreach ($l in ($r.Output -split "`n")) { if ($l) { Write-KitLog -Message "  $l" } }
            if ($r.Output -match 'pref-failed') {
                Write-KitLog -Message 'Часть настроек TrebleDroid не записалась - проверьте их в TrebleDroid Settings вручную.' -Level Warn
            }
            Invoke-KitTool -Tool adb -Arguments @('shell', 'rm', '-f', '/data/local/tmp/tb8505f_post.sh') | Out-Null
        }
        finally {
            Remove-Item -Path $localSh -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($key in 'window_animation_scale', 'transition_animation_scale', 'animator_duration_scale') {
        Invoke-KitTool -Tool adb -Arguments @('shell', 'settings', 'put', 'global', $key, $PostConfig.AnimationScale) | Out-Null
    }
    Write-KitLog -Message "Анимации: $($PostConfig.AnimationScale)" -Level Ok
    Invoke-KitTool -Tool adb -Arguments @('unroot') | Out-Null
}

#endregion

Export-ModuleMember -Function Install-KitAsset, Initialize-Kit,Write-KitLog, Show-UserAction, Invoke-KitTool,
Get-FastbootVar, Get-AdbProp, Test-IsAdministrator, Install-KitDriver, Get-DeviceState,
Wait-DeviceState, Connect-Device, Assert-DeviceModel, Assert-BatteryLevel, Test-KitImage,
Enter-Fastboot, Unlock-Bootloader, Lock-Bootloader, Invoke-PartitionFlash, Wait-AndroidBoot,
Set-GsiPostConfig
