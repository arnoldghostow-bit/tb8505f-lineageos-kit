<#
.SYNOPSIS
    Возврат Lenovo Tab M8 HD (TB-8505F) на заводской Android 10 (S301106_230914).

.DESCRIPTION
    Прошивает через fastboot стоковые boot, dtbo, recovery, logo, lenovocust,
    vendor, system и оригинальный vbmeta, стирает данные и перезагружает.
    Низкоуровневые разделы (preloader, lk, tee, scp, sspm, md1img) не трогаются:
    прошивка LineageOS их не меняет, они и так стоковые.

    С -LockBootloader после прошивки загрузчик блокируется обратно
    (нужно нажать Громкость ВВЕРХ; данные стираются ещё раз).

.PARAMETER Force
    Не спрашивать подтверждение стирания данных в консоли.

.PARAMETER SkipHashCheck
    Не проверять SHA256 образов.

.PARAMETER LockBootloader
    Заблокировать загрузчик после возврата на сток.

.EXAMPLE
    .\Restore-Stock.ps1
    Вернуть заводскую систему, загрузчик остаётся разблокированным.

.EXAMPLE
    .\Restore-Stock.ps1 -LockBootloader
    Полный возврат к заводскому состоянию, включая блокировку загрузчика.

.NOTES
    PowerShell 5.1+. Если планшет не входит даже в fastboot - используйте
    Lenovo Rescue and Smart Assistant (полная прошивка через preloader).
#>
[CmdletBinding()]
[OutputType([void])]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$SkipHashCheck,

    [Parameter(Mandatory = $false)]
    [switch]$LockBootloader
)

$ErrorActionPreference = 'Stop'
$kitRoot = Split-Path -Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'TB8505F.Flash.psm1') -Force -DisableNameChecking

try {
    if (-not (Install-KitAsset -KitRoot $kitRoot -Target Stock)) {
        throw 'Комплект не готов к возврату на сток - см. сообщения подготовки выше.'
    }
    $config = Initialize-Kit -KitRoot $kitRoot -LogName 'restore'
    $host.UI.RawUI.WindowTitle = 'TB-8505F -> Stock'
    Write-KitLog -Message "Возврат на сток: $($config.Stock.Description)" -Level Step

    Write-KitLog -Message '1/5 Драйвер' -Level Step
    Install-KitDriver -InfPath (Join-Path $kitRoot $config.Tools.DriverInf)

    Write-KitLog -Message '2/5 Проверка образов' -Level Step
    Test-KitImage -FlashList $config.Stock.Flash -SkipHash:$SkipHashCheck

    Write-KitLog -Message '3/5 Подключение планшета' -Level Step
    $state = Connect-Device
    Assert-DeviceModel -State $state -DeviceConfig $config.Device
    if ($state -eq 'Adb') { Assert-BatteryLevel -MinPercent $config.Device.MinBatteryPercent }

    if (-not $Force) {
        Write-Host ''
        Write-Host 'ВНИМАНИЕ: все данные на планшете будут стёрты.' -ForegroundColor Yellow
        $answer = Read-Host 'Введите Y и нажмите Enter, чтобы продолжить'
        if ($answer -notmatch '^[YyДд]') { throw 'Отменено пользователем.' }
    }

    Write-KitLog -Message '4/5 Прошивка стока' -Level Step
    Enter-Fastboot -State $state
    if ((Get-FastbootVar -Name 'unlocked') -ne 'yes') {
        throw 'Загрузчик заблокирован - fastboot не может писать разделы. Используйте Lenovo Rescue and Smart Assistant.'
    }
    Invoke-PartitionFlash -FlashList $config.Stock.Flash -EraseList $config.Stock.Erase
    if ($LockBootloader) { Lock-Bootloader }

    Write-KitLog -Message '5/5 Загрузка' -Level Step
    Invoke-KitTool -Tool fastboot -Arguments @('reboot') | Out-Null
    Write-KitLog -Message 'Первая загрузка стока занимает 3-5 минут. ADB после стирания выключен - это нормально.'

    Show-UserAction -Lines @(
        'ГОТОВО. Заводской Android 10 прошит.',
        'Дождитесь мастера настройки Lenovo на экране планшета.'
    )
}
catch {
    Write-KitLog -Message "ОШИБКА: $($_.Exception.Message)" -Level Error
    Write-KitLog -Message 'Скрипт можно запустить повторно. Лог в папке logs.' -Level Warn
    exit 1
}
