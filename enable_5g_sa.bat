@echo off
setlocal EnableDelayedExpansion
title MediaTek 5G Standalone (SA) Enabler

echo ============================================================
echo    Xiaomi MT6895 5G Standalone (SA) Enabler via ADB
echo ============================================================
echo.

:: Check if adb is installed
where adb >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] adb command not found.
    echo Please install Android Platform Tools and add adb to your system PATH.
    echo Download: https://developer.android.com/tools/releases/platform-tools
    goto :end_pause
)

:: Parse optional command-line arguments
set "TARGET_SLOT="
set "NR_MODE="
set "AUTO_REBOOT=0"
set "SPECIFIC_DEVICE="

:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="-s" (set "TARGET_SLOT=%~2" & shift & shift & goto :parse_args)
if /i "%~1"=="--slot" (set "TARGET_SLOT=%~2" & shift & shift & goto :parse_args)
if /i "%~1"=="--both" (set "TARGET_SLOT=both" & shift & goto :parse_args)
if /i "%~1"=="-m" (set "NR_MODE=%~2" & shift & shift & goto :parse_args)
if /i "%~1"=="--mode" (set "NR_MODE=%~2" & shift & shift & goto :parse_args)
if /i "%~1"=="-r" (set "AUTO_REBOOT=1" & shift & goto :parse_args)
if /i "%~1"=="--reboot" (set "AUTO_REBOOT=1" & shift & goto :parse_args)
if /i "%~1"=="-d" (set "SPECIFIC_DEVICE=%~2" & shift & shift & goto :parse_args)
if /i "%~1"=="--device" (set "SPECIFIC_DEVICE=%~2" & shift & shift & goto :parse_args)
if /i "%~1"=="-h" goto :show_help
if /i "%~1"=="--help" goto :show_help
echo [WARN] Unknown option: %~1
shift
goto :parse_args

:show_help
echo Usage: %~nx0 [OPTIONS]
echo.
echo Options:
echo   -s, --slot ^<1^|2^|both^>    Target SIM slot to configure (default: 2)
echo   -m, --mode ^<7^|3^|5^|1^>     NR configuration mode (default: 7 = SA + NSA)
echo   -r, --reboot             Automatically reboot device after applying
echo   -d, --device ^<serial^>    Specify ADB device serial number
echo   -h, --help               Display this help message
goto :end_pause

:args_done
set "ADB_CMD=adb"
if defined SPECIFIC_DEVICE (
    set "ADB_CMD=adb -s %SPECIFIC_DEVICE%"
)

echo [INFO] Checking connected device...
set "DEVICE_COUNT=0"
set "UNAUTH_COUNT=0"

for /f "tokens=1,2" %%A in ('%ADB_CMD% devices ^| findstr /v "List"') do (
    if "%%B"=="device" (
        set /a DEVICE_COUNT+=1
    ) else if "%%B"=="recovery" (
        set /a DEVICE_COUNT+=1
    ) else if "%%B"=="sideload" (
        set /a DEVICE_COUNT+=1
    ) else if "%%B"=="unauthorized" (
        set /a UNAUTH_COUNT+=1
    )
)

if %UNAUTH_COUNT% gtr 0 (
    echo [ERROR] Device detected but unauthorized.
    echo Please check your phone's screen and tap 'Allow USB debugging'.
    goto :end_pause
)

if %DEVICE_COUNT% equ 0 (
    echo [ERROR] No authorized Android device connected via ADB.
    echo Please ensure:
    echo   1. USB Debugging is enabled in Settings -^> Developer Options.
    echo   2. The device is connected with a reliable USB cable.
    echo   3. You accepted the 'Allow USB debugging' prompt on the device screen.
    goto :end_pause
)

if %DEVICE_COUNT% gtr 1 if not defined SPECIFIC_DEVICE (
    echo [ERROR] Multiple ADB devices detected. Please specify target device with -d ^<serial^>.
    %ADB_CMD% devices
    goto :end_pause
)

for /f "delims=" %%i in ('%ADB_CMD% shell getprop ro.product.model 2^>nul') do set "DEVICE_MODEL=%%i"
for /f "delims=" %%i in ('%ADB_CMD% shell getprop ro.product.device 2^>nul') do set "DEVICE_CODENAME=%%i"
for /f "delims=" %%i in ('%ADB_CMD% shell getprop ro.board.platform 2^>nul') do set "DEVICE_PLATFORM=%%i"

echo [INFO] Connected device: %DEVICE_MODEL% (Codename: %DEVICE_CODENAME%, Platform: %DEVICE_PLATFORM%)

echo [INFO] Verifying root access for telephony HIDL execution...
set "IS_ADB_ROOT=0"
set "CURRENT_UID="

for /f "delims=" %%i in ('%ADB_CMD% shell id -u 2^>nul') do set "CURRENT_UID=%%i"
if "%CURRENT_UID%"=="0" (
    set "IS_ADB_ROOT=1"
) else (
    %ADB_CMD% root >nul 2>&1
    timeout /t 1 /nobreak >nul
    for /f "delims=" %%i in ('%ADB_CMD% shell id -u 2^>nul') do set "CURRENT_UID=%%i"
    if "!CURRENT_UID!"=="0" (
        set "IS_ADB_ROOT=1"
    ) else (
        set "SU_UID="
        for /f "delims=" %%i in ('%ADB_CMD% shell "su -c id -u" 2^>nul') do set "SU_UID=%%i"
        if "!SU_UID!"=="0" (
            set "IS_ADB_ROOT=0"
            echo [INFO] Root access confirmed via su binary (Magisk/KernelSU/APatch).
        ) else (
            echo [ERROR] Root access is required to execute telephony HAL / HIDL commands.
            echo Please either:
            echo   - In LineageOS / AOSP userdebug: Enable 'Rooted debugging' in Developer Options and re-run.
            echo   - On rooted devices: Grant Root access when prompted.
            goto :end_pause
        )
    )
)

:: If TARGET_SLOT was not provided via arguments, prompt interactively
if not defined TARGET_SLOT (
    echo.
    echo ------------------------------------------------------------
    echo [?] Which SIM slot would you like to configure?
    echo   1) SIM Slot 2 only (default - fixes Slot 2 5G SA drop)
    echo   2) BOTH SIM Slot 1 ^& Slot 2 (recommended)
    echo   3) SIM Slot 1 only
    set "SLOT_INPUT=1"
    set /p "SLOT_INPUT=Enter choice [1-3] (default: 1): "
    if "!SLOT_INPUT!"=="2" (
        set "TARGET_SLOT=both"
    ) else if "!SLOT_INPUT!"=="3" (
        set "TARGET_SLOT=1"
    ) else (
        set "TARGET_SLOT=2"
    )
)

:: If NR_MODE was not provided via arguments, prompt interactively
if not defined NR_MODE (
    echo.
    echo [?] Select 5G Mode:
    echo   1) 5G SA + NSA (Full 5G) (default, recommended)
    echo   2) 5G SA Only
    echo   3) 5G NSA Only
    set "MODE_INPUT=1"
    set /p "MODE_INPUT=Enter choice [1-3] (default: 1): "
    if "!MODE_INPUT!"=="2" (
        set "NR_MODE=3"
    ) else if "!MODE_INPUT!"=="3" (
        set "NR_MODE=5"
    ) else (
        set "NR_MODE=7"
    )
    echo ------------------------------------------------------------
    echo.
)

set "REMOTE_TMP=/data/local/tmp/mtk_nr_config.dex"
set "LOCAL_DEX=%~dp0tools\mtk_nr_config.dex"

echo [INFO] Deploying standalone MTK NR configuration DEX to %REMOTE_TMP%...

if exist "%LOCAL_DEX%" (
    %ADB_CMD% push "%LOCAL_DEX%" %REMOTE_TMP% >nul 2>&1
) else (
    echo [ERROR] Cannot find tools\mtk_nr_config.dex!
    echo Please make sure you cloned the full repository.
    goto :end_pause
)

if "%IS_ADB_ROOT%"=="1" (
    %ADB_CMD% shell chmod 644 %REMOTE_TMP% >nul 2>&1
) else (
    %ADB_CMD% shell su -c "chmod 644 %REMOTE_TMP%" >nul 2>&1
)

echo [INFO] Executing MTK 5G NR configuration via app_process...
echo [INFO] Target Slot: %TARGET_SLOT% ^| Mode: %NR_MODE%
echo.

if "%IS_ADB_ROOT%"=="1" (
    %ADB_CMD% shell "CLASSPATH=%REMOTE_TMP% app_process /system/bin com.xaga.sa.MtkNrConfig %TARGET_SLOT% %NR_MODE%"
    %ADB_CMD% shell rm -f %REMOTE_TMP% >nul 2>&1
) else (
    %ADB_CMD% shell su -c "CLASSPATH=%REMOTE_TMP% app_process /system/bin com.xaga.sa.MtkNrConfig %TARGET_SLOT% %NR_MODE%"
    %ADB_CMD% shell su -c "rm -f %REMOTE_TMP%" >nul 2>&1
)

echo.
echo [SUCCESS] 5G Standalone (SA) configuration applied to modem NVRAM!
echo.
echo NOTE: A device reboot is REQUIRED for the modem baseband to reload NVRAM and activate 5G SA.
echo.

if "%AUTO_REBOOT%"=="1" (
    echo [INFO] Rebooting device now as requested by --reboot flag...
    %ADB_CMD% reboot
    echo [SUCCESS] Device is rebooting. Once booted, 5G SA will be active on the target SIM slot.
) else (
    set "REBOOT_CHOICE=Y"
    set /p "REBOOT_CHOICE=[?] Would you like to reboot the device now? [Y/n]: "
    if /i "!REBOOT_CHOICE!"=="Y" (
        echo [INFO] Rebooting device...
        %ADB_CMD% reboot
        echo [SUCCESS] Device is rebooting. Once booted, 5G SA will be active on the target SIM slot.
    ) else (
        echo [WARN] Please manually reboot your phone at your convenience to finish activating 5G SA.
    )
)

:end_pause
echo.
echo Press any key to exit...
pause >nul
exit /b 0
