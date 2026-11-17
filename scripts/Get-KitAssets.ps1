<#
.SYNOPSIS
    Подготовка комплекта: скачивает и собирает всё, чего нет в git-репозитории.

.DESCRIPTION
    Большие и чужие файлы (образы, прошивка Lenovo, fastboot, драйвер) не хранятся в git.
    Этот скрипт приводит свежий клон репозитория в рабочее состояние:

      1. tools\platform-tools  - adb/fastboot 34.0.5 с dl.google.com (SHA256 проверяется).
      2. stock\                - заводская прошивка TB-8505F: копируется из папки загрузок
                                 Lenovo Rescue and Smart Assistant (RSA), если она там есть.
      3. images\vbmeta_disabled.img - собирается из стокового vbmeta.img (флаги 0x3).
      4. images\<LineageOS>.img - скачивается .img.gz с SourceForge, проверяется и распаковывается.
      5. drivers\mtk_android_winusb - драйвер MediaTek ADB/fastboot копируется из хранилища
                                 драйверов Windows (его ставит Lenovo RSA).

    Каждый шаг пропускается, если результат уже на месте и контрольная сумма совпадает,
    поэтому скрипт можно запускать повторно.

.PARAMETER KeepDownloads
    Не удалять скачанные архивы (.zip, .img.gz) из папки downloads\.

.EXAMPLE
    .\Get-KitAssets.ps1
    Подготовить комплект после git clone (лучше через GET_ASSETS.cmd).

.NOTES
    PowerShell 5.1+. Нужен интернет (~1,5 ГБ) и ~10 ГБ свободного места.
    Стоковую прошивку скачивает только Lenovo RSA (нужен вход в Lenovo ID):
    RSA > Rescue > Tablet > TB-8505F > "Скачать" (НЕ "Восстановить").
#>
[CmdletBinding()]
[OutputType([void])]
param(
    [Parameter(Mandatory = $false)]
    [switch]$KeepDownloads
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$kitRoot = Split-Path -Path $PSScriptRoot -Parent

#region Функции

function Write-Step {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('Info', 'Ok', 'Warn', 'Step')][string]$Level = 'Info'
    )
    $colors = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Step = 'Cyan' }
    if ($Level -eq 'Step') { Write-Host '' }
    Write-Host ('{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Message) -ForegroundColor $colors[$Level]
}

function Test-FileHash {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Sha256
    )
    $match = $false
    if (Test-Path $Path) {
        $match = (Get-FileHash -Path $Path -Algorithm SHA256).Hash -eq $Sha256
    }
    $match
}

function Save-WebFile {
    <# Скачивание через curl.exe (есть в Windows 10 1803+): быстрее Invoke-WebRequest в 5.1 и умеет редиректы SourceForge. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string[]]$Urls,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Sha256
    )
    if (Test-FileHash -Path $Destination -Sha256 $Sha256) {
        Write-Step "Уже скачано: $(Split-Path $Destination -Leaf)" -Level Ok
        return
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { throw 'Не найден curl.exe (нужна Windows 10 1803 или новее).' }
    <# Зеркала SourceForge иногда «зависают» посреди файла: --speed-limit/--speed-time
       обрывают соединение, если скорость < 10 КБ/с дольше 60 с, а -C - докачивает
       с места обрыва (каждая попытка может попасть на другое зеркало). #>
    $curlArgs = @('-L', '--fail', '--connect-timeout', '30', '--speed-limit', '10240', '--speed-time', '60',
        '-C', '-', '--progress-bar', '-o', $Destination)
    foreach ($url in $Urls) {
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            Write-Step "Скачивание (попытка $attempt/5): $url"
            & $curl @curlArgs $url
            $code = $LASTEXITCODE
            if ($code -eq 0 -and (Test-FileHash -Path $Destination -Sha256 $Sha256)) {
                Write-Step "Скачано и проверено: $(Split-Path $Destination -Leaf)" -Level Ok
                return
            }
            if ($code -eq 0) {
                # Скачалось целиком, но хеш не тот - файл битый, начинаем заново.
                Remove-Item -Path $Destination -Force
            }
            # 22 = HTTP-ошибка (например 404): с этим адресом дальше пробовать бессмысленно.
            if ($code -eq 22) { break }
            Write-Step "Обрыв (curl код $code), повтор с докачкой..." -Level Warn
            Start-Sleep -Seconds 5
        }
        Write-Step 'Не получилось с этого адреса, пробую следующий.' -Level Warn
    }
    throw "Не удалось скачать $(Split-Path $Destination -Leaf). Проверьте интернет или обновите ссылки в config.json."
}

function Expand-GzipFile {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Write-Step "Распаковка: $(Split-Path $Source -Leaf)"
    $in = [System.IO.File]::OpenRead($Source)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
        $out = [System.IO.File]::Create($Destination)
        try { $gz.CopyTo($out, 4MB) }
        finally { $out.Dispose(); $gz.Dispose() }
    }
    finally { $in.Dispose() }
}

#endregion

try {
    $config = Get-Content -Path (Join-Path $kitRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $assets = $config.Assets
    $downloadDir = Join-Path $kitRoot 'downloads'
    foreach ($dir in 'tools', 'images', 'stock', 'drivers', 'downloads', 'logs') {
        $p = Join-Path $kitRoot $dir
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
    }
    $problems = New-Object System.Collections.Generic.List[string]

    #region 1. platform-tools
    Write-Step '1/5 adb/fastboot 34.0.5' -Level Step
    $fastboot = Join-Path $kitRoot (Join-Path $config.Tools.PlatformTools 'fastboot.exe')
    if (Test-Path $fastboot) {
        Write-Step 'Уже на месте.' -Level Ok
    }
    else {
        $zip = Join-Path $downloadDir 'platform-tools_r34.0.5-windows.zip'
        Save-WebFile -Urls @($assets.PlatformTools.Url) -Destination $zip -Sha256 $assets.PlatformTools.Sha256
        Expand-Archive -Path $zip -DestinationPath (Join-Path $kitRoot 'tools') -Force
        Write-Step 'Распаковано в tools\platform-tools' -Level Ok
    }
    #endregion

    #region 2. Стоковая прошивка
    Write-Step '2/5 Стоковая прошивка Lenovo' -Level Step
    $stockMissing = @($config.Stock.Flash | Where-Object { -not (Test-FileHash -Path (Join-Path $kitRoot $_.File) -Sha256 $_.Sha256) })
    if ($stockMissing.Count -eq 0) {
        Write-Step 'Уже на месте и цела.' -Level Ok
    }
    else {
        $source = $assets.StockSourceDirs | Where-Object { Test-Path (Join-Path $_ 'system.img') } | Select-Object -First 1
        if ($null -eq $source) {
            $problems.Add('Стоковая прошивка: установите Lenovo Rescue and Smart Assistant, войдите в Lenovo ID, Rescue > Tablet > TB-8505F > "Скачать" (НЕ "Восстановить"), затем запустите GET_ASSETS.cmd снова.')
            Write-Step 'Не найдена в папке загрузок Lenovo RSA.' -Level Warn
        }
        else {
            Write-Step "Копирование из $source"
            Copy-Item -Path (Join-Path $source '*') -Destination (Join-Path $kitRoot 'stock') -Recurse -Force
            $stillBad = @($config.Stock.Flash | Where-Object { -not (Test-FileHash -Path (Join-Path $kitRoot $_.File) -Sha256 $_.Sha256) })
            if ($stillBad.Count -gt 0) {
                $problems.Add("Стоковая прошивка в RSA другой версии или повреждена: $($stillBad.File -join ', '). Нужна TB-8505F_S301106_230914_BMP.")
            }
            else { Write-Step 'Скопирована и проверена.' -Level Ok }
        }
    }
    #endregion

    #region 3. vbmeta_disabled.img
    Write-Step '3/5 vbmeta с отключённой проверкой' -Level Step
    $vbItem = $config.LineageOS.Flash | Where-Object { $_.Partition -eq 'vbmeta' }
    $vbTarget = Join-Path $kitRoot $vbItem.File
    $vbStock = Join-Path $kitRoot $assets.StockVbmeta
    if (Test-FileHash -Path $vbTarget -Sha256 $vbItem.Sha256) {
        Write-Step 'Уже на месте.' -Level Ok
    }
    elseif (-not (Test-Path $vbStock)) {
        $problems.Add('vbmeta_disabled.img не собран: нет стокового stock\vbmeta.img (см. пункт 2).')
        Write-Step 'Пропущено: нет стокового vbmeta.img.' -Level Warn
    }
    else {
        # Флаги AVB в заголовке vbmeta: big-endian uint32 по смещению 120.
        # 0x3 = HASHTREE_DISABLED | VERIFICATION_DISABLED (то же, что fastboot --disable-verity --disable-verification).
        $bytes = [System.IO.File]::ReadAllBytes($vbStock)
        $bytes[120] = 0; $bytes[121] = 0; $bytes[122] = 0; $bytes[123] = 3
        [System.IO.File]::WriteAllBytes($vbTarget, $bytes)
        if (Test-FileHash -Path $vbTarget -Sha256 $vbItem.Sha256) { Write-Step 'Собран и проверен.' -Level Ok }
        else { $problems.Add('vbmeta_disabled.img собран, но SHA256 не совпадает - стоковый vbmeta другой версии.') }
    }
    #endregion

    #region 4. LineageOS
    Write-Step '4/5 Образ LineageOS (~1,4 ГБ скачивание, 3,2 ГБ после распаковки)' -Level Step
    $sysItem = $config.LineageOS.Flash | Where-Object { $_.Partition -eq 'system' }
    $sysTarget = Join-Path $kitRoot $sysItem.File
    if (Test-FileHash -Path $sysTarget -Sha256 $sysItem.Sha256) {
        Write-Step 'Уже на месте и цел.' -Level Ok
    }
    else {
        $gzName = Split-Path ($assets.LineageOSGz.Urls[0] -replace '/download$', '') -Leaf
        $gz = Join-Path $downloadDir $gzName
        Save-WebFile -Urls $assets.LineageOSGz.Urls -Destination $gz -Sha256 $assets.LineageOSGz.Sha256
        Expand-GzipFile -Source $gz -Destination $sysTarget
        if (-not (Test-FileHash -Path $sysTarget -Sha256 $sysItem.Sha256)) { throw 'Распакованный образ LineageOS не совпал по SHA256.' }
        Write-Step 'Распакован и проверен.' -Level Ok
    }
    #endregion

    #region 5. Драйвер
    Write-Step '5/5 Драйвер MediaTek ADB/fastboot' -Level Step
    $infTarget = Join-Path $kitRoot $config.Tools.DriverInf
    if (Test-Path $infTarget) {
        Write-Step 'Уже на месте.' -Level Ok
    }
    else {
        $repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
        $found = Get-ChildItem -Path $repo -Directory -Filter 'android_winusb.inf_amd64_*' -ErrorAction SilentlyContinue |
            Where-Object { Select-String -Path (Join-Path $_.FullName 'android_winusb.inf') -Pattern 'VID_0E8D&PID_201C' -Quiet } |
            Select-Object -First 1
        if ($null -eq $found) {
            $problems.Add('Драйвер MediaTek не найден в системе: установите Lenovo Rescue and Smart Assistant (он ставит драйвер) и запустите GET_ASSETS.cmd снова.')
            Write-Step 'Не найден в хранилище драйверов Windows.' -Level Warn
        }
        else {
            $driverDir = Split-Path $infTarget -Parent
            New-Item -ItemType Directory -Path $driverDir -Force | Out-Null
            Copy-Item -Path (Join-Path $found.FullName '*') -Destination $driverDir -Recurse -Force
            Write-Step "Скопирован из $($found.Name)" -Level Ok
        }
    }
    #endregion

    if (-not $KeepDownloads) {
        Get-ChildItem -Path $downloadDir -File | Remove-Item -Force
    }

    Write-Host ''
    if ($problems.Count -eq 0) {
        Write-Step 'Комплект готов. Можно запускать START_FLASH_LINEAGEOS.cmd' -Level Ok
    }
    else {
        Write-Step 'Комплект подготовлен не полностью:' -Level Warn
        foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Yellow }
        exit 2
    }
}
catch {
    Write-Step "ОШИБКА: $($_.Exception.Message)" -Level Warn
    exit 1
}
