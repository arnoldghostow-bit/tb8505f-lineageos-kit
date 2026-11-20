<#
.SYNOPSIS
    Автономная прошивка Lenovo Tab M8 HD (TB-8505F) на LineageOS 21 (GSI с GApps).

.DESCRIPTION
    Делает всё сам: ставит драйвер, проверяет образы и модель планшета,
    перезагружает в fastboot, разблокирует загрузчик, прошивает vbmeta (проверка
    отключена) и system, стирает данные, ждёт первой загрузки и применяет
    исправления для этого планшета (Bluetooth MediaTek, плавность, анимации).

    От пользователя нужно только:
      - подключить планшет (и разрешить отладку по USB, если просят);
      - один раз подтвердить стирание данных в консоли (если не указан -Force);
      - нажать Громкость ВВЕРХ при разблокировке загрузчика (только первый раз).

    Скрипт можно безопасно запустить повторно с любого этапа.

.PARAMETER Force
    Не спрашивать подтверждение стирания данных в консоли.

.PARAMETER SkipHashCheck
    Не проверять SHA256 образов (экономит ~20 с).

.PARAMETER SkipPostConfig
    Не применять исправления после прошивки.

.PARAMETER PostConfigOnly
    Ничего не прошивать, только применить исправления к уже установленной LineageOS.

.EXAMPLE
    .\Flash-LineageOS.ps1
    Обычный запуск (лучше через START_FLASH_LINEAGEOS.cmd - он сам поднимет права для драйвера).

.EXAMPLE
    .\Flash-LineageOS.ps1 -Force -SkipHashCheck
    Повторная прошивка без вопросов и без проверки контрольных сумм.

.NOTES
    PowerShell 5.1+. Комплект: TB8505F_LineageOS_Kit. Лог: logs\flash_*.log
#>
[CmdletBinding()]
[OutputType([void])]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$SkipHashCheck,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPostConfig,

    [Parameter(Mandatory = $false)]
    [switch]$PostConfigOnly
)

$ErrorActionPreference = 'Stop'
$kitRoot = Split-Path -Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'TB8505F.Flash.psm1') -Force -DisableNameChecking

try {
    # Свежая копия из GitHub: сначала докачать fastboot/образы/драйвер.
    if (-not $PostConfigOnly -and -not (Install-KitAsset -KitRoot $kitRoot -Target LineageOS)) {
        throw 'Комплект не готов к прошивке - см. сообщения подготовки выше.'
    }
    $config = Initialize-Kit -KitRoot $kitRoot -LogName 'flash'
    $host.UI.RawUI.WindowTitle = 'TB-8505F -> LineageOS'
    Write-KitLog -Message "Комплект прошивки: $($config.Device.Name) -> $($config.LineageOS.Description)" -Level Step

    if ($PostConfigOnly) {
        # Только исправления на уже прошитой LineageOS, без перепрошивки.
        $state = Connect-Device
        if ($state -ne 'Adb') { throw 'Для пост-настройки планшет должен быть загружен в LineageOS.' }
        Assert-DeviceModel -State $state -DeviceConfig $config.Device
        Set-GsiPostConfig -PostConfig $config.LineageOS.PostConfig
        Invoke-KitTool -Tool adb -Arguments @('reboot') | Out-Null
        Start-Sleep -Seconds 15
        Wait-AndroidBoot -TimeoutSec 300 | Out-Null
        Show-UserAction -Lines @('ГОТОВО. Исправления применены, планшет перезагружен.')
        exit 0
    }

    Write-KitLog -Message '1/7 Драйвер' -Level Step
    Install-KitDriver -InfPath (Join-Path $kitRoot $config.Tools.DriverInf)

    Write-KitLog -Message '2/7 Проверка образов' -Level Step
    Test-KitImage -FlashList $config.LineageOS.Flash -SkipHash:$SkipHashCheck

    Write-KitLog -Message '3/7 Подключение планшета' -Level Step
    # Напоминание всегда, на всякий случай: без OEM unlocking разблокировка загрузчика не пройдёт.
    Show-OemUnlockAlert
    $state = Connect-Device
    Assert-DeviceModel -State $state -DeviceConfig $config.Device
    if ($state -eq 'Adb') {
        Assert-BatteryLevel -MinPercent $config.Device.MinBatteryPercent
        Assert-OemUnlockAllowed
    }
    else {
        Write-KitLog -Message 'Планшет уже в fastboot - заряд проверить нельзя, убедитесь что он > 30%.' -Level Warn
    }

    if (-not $Force) {
        Write-Host ''
        Write-Host 'ВНИМАНИЕ: все данные на планшете будут стёрты.' -ForegroundColor Yellow
        $answer = Read-Host 'Введите Y и нажмите Enter, чтобы продолжить'
        if ($answer -notmatch '^[YyДд]') { throw 'Отменено пользователем.' }
    }

    Write-KitLog -Message '4/7 Fastboot и разблокировка загрузчика' -Level Step
    Enter-Fastboot -State $state
    Unlock-Bootloader

    Write-KitLog -Message '5/7 Прошивка LineageOS' -Level Step
    Invoke-PartitionFlash -FlashList $config.LineageOS.Flash -EraseList $config.LineageOS.Erase

    Write-KitLog -Message '6/7 Первая загрузка' -Level Step
    Show-UserAction -Lines @(
        'Планшет загружается. НЕ проходите мастер настройки до надписи ГОТОВО:',
        'после пост-настройки скрипт ещё раз перезагрузит планшет.'
    )
    Invoke-KitTool -Tool fastboot -Arguments @('reboot') | Out-Null
    Start-Sleep -Seconds 15
    $booted = Wait-AndroidBoot -TimeoutSec $config.LineageOS.BootTimeoutSec

    Write-KitLog -Message '7/7 Пост-настройка' -Level Step
    if ($SkipPostConfig) {
        Write-KitLog -Message 'Пропущено (-SkipPostConfig).' -Level Warn
    }
    elseif (-not $booted) {
        Write-KitLog -Message 'Система не ответила по ADB - пост-настройку можно применить позже: POSTCONFIG_ONLY.cmd' -Level Warn
    }
    else {
        Set-GsiPostConfig -PostConfig $config.LineageOS.PostConfig
        Write-KitLog -Message 'Перезагрузка для применения настроек...'
        Invoke-KitTool -Tool adb -Arguments @('reboot') | Out-Null
        Start-Sleep -Seconds 15
        Wait-AndroidBoot -TimeoutSec 300 | Out-Null
    }

    Show-UserAction -Lines @(
        'ГОТОВО. LineageOS установлена.',
        'Пройдите мастер настройки на планшете (на экране бэкапов - "Don''t restore").'
    )
}
catch {
    Write-KitLog -Message "ОШИБКА: $($_.Exception.Message)" -Level Error
    Write-KitLog -Message 'Скрипт можно запустить повторно - он продолжит с нужного этапа. Лог в папке logs.' -Level Warn
    exit 1
}
