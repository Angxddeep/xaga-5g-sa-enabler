<#
.SYNOPSIS
    Enable 5G Standalone (SA) on MediaTek MT6895 (Xaga) via ADB
.DESCRIPTION
    Interactive PowerShell script to configure MTK modem 5G SA mode via HIDL/AIDL HAL.
#>

[CmdletBinding()]
param(
    [Parameter()][ValidateSet('1', '2', 'both')][string]$Slot,
    [Parameter()][ValidateSet('7', '3', '5', '1')][string]$Mode,
    [Parameter()][switch]$Reboot,
    [Parameter()][string]$Device
)

$ErrorActionPreference = 'Stop'

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   Xiaomi MT6895 5G Standalone (SA) Enabler via ADB         " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Check if adb is available
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] adb command not found. Please install Android Platform Tools and add adb to your PATH." -ForegroundColor Red
    exit 1
}

$AdbArgs = @()
if ($Device) {
    $AdbArgs += @('-s', $Device)
}

function Invoke-Adb {
    param([string[]]$CommandArgs)
    & adb @AdbArgs @CommandArgs
}

Write-Host "[INFO] Checking connected device..." -ForegroundColor Blue
$DevicesRaw = Invoke-Adb @('devices')
$DeviceLines = $DevicesRaw | Where-Object { $_ -match '\t(device|recovery|sideload|unauthorized)$' }

$Unauthorized = $DeviceLines | Where-Object { $_ -match '\tunauthorized$' }
if ($Unauthorized) {
    Write-Host "[ERROR] Device detected but unauthorized." -ForegroundColor Red
    Write-Host "Please check your phone screen and tap 'Allow USB debugging'." -ForegroundColor Yellow
    exit 1
}

$ActiveDevices = $DeviceLines | Where-Object { $_ -match '\t(device|recovery|sideload)$' }
if (-not $ActiveDevices) {
    Write-Host "[ERROR] No authorized Android device connected via ADB." -ForegroundColor Red
    Write-Host "Please ensure:"
    Write-Host "  1. USB Debugging is enabled in Settings -> Developer Options."
    Write-Host "  2. The device is connected with a reliable USB cable."
    Write-Host "  3. You accepted the 'Allow USB debugging' prompt on screen."
    exit 1
}

if ($ActiveDevices.Count -gt 1 -and -not $Device) {
    Write-Host "[ERROR] Multiple ADB devices detected. Please specify target device with -Device <serial>." -ForegroundColor Red
    Invoke-Adb @('devices')
    exit 1
}

$DeviceModel = (Invoke-Adb @('shell', 'getprop', 'ro.product.model')).Trim()
$DeviceCode = (Invoke-Adb @('shell', 'getprop', 'ro.product.device')).Trim()
$DevicePlat = (Invoke-Adb @('shell', 'getprop', 'ro.board.platform')).Trim()
Write-Host "[INFO] Connected device: $DeviceModel (Codename: $DeviceCode, Platform: $DevicePlat)" -ForegroundColor Blue

Write-Host "[INFO] Verifying root access for telephony HIDL execution..." -ForegroundColor Blue
$IsAdbRoot = $false
$CurrentUid = (Invoke-Adb @('shell', 'id', '-u')).Trim()

if ($CurrentUid -eq '0') {
    $IsAdbRoot = $true
} else {
    Invoke-Adb @('root') | Out-Null
    Start-Sleep -Seconds 1
    $CurrentUid = (Invoke-Adb @('shell', 'id', '-u')).Trim()
    if ($CurrentUid -eq '0') {
        $IsAdbRoot = $true
    } else {
        $SuUid = (Invoke-Adb @('shell', 'su', '-c', 'id -u')).Trim()
        if ($SuUid -eq '0') {
            $IsAdbRoot = $false
            Write-Host "[INFO] Root access confirmed via su binary (Magisk/KernelSU/APatch)." -ForegroundColor Blue
        } else {
            Write-Host "[ERROR] Root access is required to execute telephony HAL / HIDL commands." -ForegroundColor Red
            exit 1
        }
    }
}

function Invoke-DeviceShell {
    param([string]$Cmd)
    if ($IsAdbRoot) {
        Invoke-Adb @('shell', $Cmd)
    } else {
        Invoke-Adb @('shell', 'su', '-c', $Cmd)
    }
}

# Interactive selection if not supplied as parameters
if (-not $Slot) {
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "[?] Which SIM slot would you like to configure?" -ForegroundColor White
    Write-Host "  1) SIM Slot 2 only (default - fixes Slot 2 5G SA drop)" -ForegroundColor Yellow
    Write-Host "  2) BOTH SIM Slot 1 & Slot 2 (recommended)" -ForegroundColor Green
    Write-Host "  3) SIM Slot 1 only" -ForegroundColor Cyan
    $SlotChoice = Read-Host "Enter choice [1-3] (default: 1)"
    switch ($SlotChoice) {
        '2' { $Slot = 'both' }
        '3' { $Slot = '1' }
        default { $Slot = '2' }
    }
}

if (-not $Mode) {
    Write-Host ""
    Write-Host "[?] Select 5G Mode:" -ForegroundColor White
    Write-Host "  1) 5G SA + NSA (Full 5G) (default, recommended)" -ForegroundColor Green
    Write-Host "  2) 5G SA Only" -ForegroundColor Cyan
    Write-Host "  3) 5G NSA Only" -ForegroundColor Cyan
    $ModeChoice = Read-Host "Enter choice [1-3] (default: 1)"
    switch ($ModeChoice) {
        '2' { $Mode = '3' }
        '3' { $Mode = '5' }
        default { $Mode = '7' }
    }
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
}

$RemoteTmp = "/data/local/tmp/mtk_nr_config.dex"
$LocalDex = Join-Path $PSScriptRoot "tools\mtk_nr_config.dex"

if (-not (Test-Path $LocalDex)) {
    Write-Host "[ERROR] Cannot find tools\mtk_nr_config.dex. Make sure you cloned the repository completely." -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Deploying standalone MTK NR configuration DEX to $RemoteTmp..." -ForegroundColor Blue
Invoke-Adb @('push', $LocalDex, $RemoteTmp) | Out-Null
Invoke-DeviceShell "chmod 644 $RemoteTmp" | Out-Null

Write-Host "[INFO] Executing MTK 5G NR configuration via app_process..." -ForegroundColor Blue
Write-Host "[INFO] Target Slot: $Slot | Mode: $Mode" -ForegroundColor Blue

$Output = Invoke-DeviceShell "CLASSPATH=$RemoteTmp app_process /system/bin com.xaga.sa.MtkNrConfig $Slot $Mode"
$Output | ForEach-Object { Write-Host $_ }

Invoke-DeviceShell "rm -f $RemoteTmp" | Out-Null

if ($Output -match '\[SUCCESS\]') {
    Write-Host ""
    Write-Host "[SUCCESS] 5G Standalone (SA) configuration applied to modem NVRAM!" -ForegroundColor Green
    Write-Host "NOTE: A device reboot is REQUIRED for the modem baseband to reload NVRAM and activate 5G SA." -ForegroundColor Yellow
    Write-Host ""
    
    if ($Reboot) {
        Write-Host "[INFO] Rebooting device..." -ForegroundColor Blue
        Invoke-Adb @('reboot')
        Write-Host "[SUCCESS] Device is rebooting." -ForegroundColor Green
    } else {
        $RebootChoice = Read-Host "[?] Would you like to reboot the device now? [Y/n] (default: Y)"
        if (-not $RebootChoice -or $RebootChoice -match '^[Yy]$') {
            Write-Host "[INFO] Rebooting device..." -ForegroundColor Blue
            Invoke-Adb @('reboot')
            Write-Host "[SUCCESS] Device is rebooting." -ForegroundColor Green
        } else {
            Write-Host "[WARN] Please manually reboot your phone at your convenience to finish activating 5G SA." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "[ERROR] Configuration failed. See output above." -ForegroundColor Red
    exit 1
}
