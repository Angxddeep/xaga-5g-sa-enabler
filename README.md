# MediaTek 5G Standalone (SA) Enabler

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: MediaTek MT6895](https://img.shields.io/badge/Platform-MediaTek%20Dimensity%208100%2FMT6895-blue.svg)](https://www.mediatek.com/)
[![Target: Xaga](https://img.shields.io/badge/Device-Xaga%20%7C%20Poco%20X4%20GT%20%7C%20Redmi%20K50i-green.svg)]()

A standalone, headless ADB utility that permanently enables **5G Standalone (SA)** on Dimensity 8100 / MT6895 devices tested on `xaga` (Redmi K50i / Poco X4 GT / Redmi Note 11T Pro). Supports **Linux, macOS, and Windows**.

**No EngineerMode APK or proprietary engineering blobs required.** It works directly on clean AOSP, LineageOS, PixelOS, and any custom ROM.

---

## Usage

1. Connect your device with USB Debugging enabled.
2. Clone the repository:

```bash
git clone https://github.com/Angxddeep/xaga-5g-sa-enabler.git
cd xaga-5g-sa-enabler
```

### On Linux / macOS:
```bash
chmod +x enable_5g_sa.sh
./enable_5g_sa.sh
```

### On Windows:
- **Batch**:
  Simply double-click `enable_5g_sa.bat` in Windows Explorer, or run from Command Prompt:
  ```cmd
  enable_5g_sa.bat
  ```
- **PowerShell**:
  ```powershell
  .\enable_5g_sa.ps1
  ```

---

## The Problem

On MediaTek Dimensity devices, SIM Slot 2 frequently drops or has 5G Standalone (SA) disabled by default. 

### Why Not Just Use EngineerMode?
The conventional workaround involves dialing `*#*#3646633#*#*`, opening MediaTek EngineerMode, navigating to *Nr Configure*, selecting *Slot 1 (SIM 2)*, and toggling *SA* on.

However:
* Shipping `EngineerMode.apk` and its vendor daemon `em_hidl` depends highly on the ROM maintainer.
* Exposes dangerous low-level factory test interfaces which users can mess up easily.
* Prohibited on official custom ROM builds (such as LineageOS).

---

## Reverse Engineering the Baseband Logic

By reverse-engineering `EngineerMode.apk` (`com.mediatek.engineermode.nrconfigure.NrConfigActivity`) and the MediaTek vendor RIL daemon (`libmtk-ril.so` / `mtkfusionrild`):

### 1. The AT Command & Bitmask
`NrConfigActivity` controls 5G modes using the proprietary MediaTek AT command:
```
AT+E5GOPT=<mode>
```
The `<mode>` value is a 3-bit bitmask:
| Mode | Bitmask (`binary`) | SA | NSA | Description |
| :---: | :---: | :---: | :---: | :--- |
| **1** | `001` | ❌ Off | ❌ Off | NR (5G) Disabled |
| **3** | `011` | ✔️ **On** | ❌ Off | 5G Standalone (SA) Only |
| **5** | `101` | ❌ Off | ✔️ **On** | 5G Non-Standalone (NSA) Only *(Common default on Slot 2)* |
| **7** | `111` | ✔️ **On** | ✔️ **On** | **5G SA + NSA (Full 5G)** |

When toggled, `AT+E5GOPT=7` is sent to the baseband modem and stored permanently in the modem's **NVRAM / NVDATA** partitions.

### 2. The Radio HAL Channel
`NrConfigActivity` communicates with the modem via the MediaTek Radio HAL:
```
NrConfigActivity.set5G()
  └── EmUtils.invokeOemRilRequestStringsEm()
        └── EmRadioHidl3_0.invokeOemRilRequestStringsEm()
              └── vendor.mediatek.hardware.mtkradioex@3.0::IMtkRadioEx
                    ├── mtkEm1 (Slot 0 / SIM 1)
                    └── mtkEm2 (Slot 1 / SIM 2)
```
* **HIDL Service**: `vendor.mediatek.hardware.mtkradioex@3.0::IMtkRadioEx` (`mtkEm1` / `mtkEm2`)
* **Transaction Code**: `101` (`sendRequestStrings`), one-way flag `1`
* **Daemon**: `/vendor/bin/hw/mtkfusionrild` (`libmtk-ril.so` and `librilfusion.so`)

---

## How This Tool Works

[`enable_5g_sa.sh`](enable_5g_sa.sh) (and its Windows counterparts [`enable_5g_sa.bat`](enable_5g_sa.bat) / [`enable_5g_sa.ps1`](enable_5g_sa.ps1)) packages this logic into an automated workflow:

1. Connects to your device over ADB.
2. Deploys the lightweight (6.7 KB) headless DEX (`MtkNrConfig.dex`) to `/data/local/tmp/`.
3. Runs the DEX directly inside Android's native runtime using `app_process`.
4. Connects straight to the active `IMtkRadioEx` HIDL service (`mtkEm2` and/or `mtkEm1`) and dispatches `AT+E5GOPT=7`.
5. Cleans up all temporary files on the device.
6. Prompts or automatically performs a device reboot (`adb reboot`) to reload modem NVRAM.

---

## Requirements

* **Computer**: Windows, macOS, or Linux with `adb` installed.
* **Device**:
  * USB Debugging enabled (`Settings > Developer Options > USB debugging`).
  * Root access:
    * **LineageOS / AOSP userdebug**: Enable *Rooted debugging* in Developer Options (`Settings > System > Developer options > Rooted debugging`).
    * **User builds**: Standard `su` (Magisk, KernelSU, or APatch).

---

## Verification

After running the script, verify that the modem processed the command via radio logcat:

```bash
adb shell "logcat -b radio -d | grep -i 'E5GOPT'"
```

Expected log output:
```text
D RpOemCtlr: onHandleOemHookString, data[0] = AT+E5GOPT=7
```

Once rebooted, the modem will latch onto 5G Standalone networks.

---

## Advanced Options (Command-line Flags)

You can also pass arguments directly to bypass interactive prompts:

```bash
# Linux/macOS
./enable_5g_sa.sh --both --reboot

# Windows (Batch)
enable_5g_sa.bat --both --reboot

# Windows (PowerShell)
.\enable_5g_sa.ps1 -Slot both -Reboot
```

```
Options:
  -s, --slot <1|2|both>    Target SIM slot to configure (default: 2)
  -m, --mode <7|3|5|1>     NR configuration mode (default: 7)
                             7 = SA + NSA (Standard 5G, recommended)
                             3 = SA Only
                             5 = NSA Only
                             1 = Disabled
  -r, --reboot             Automatically reboot device after applying
  -d, --device <serial>    Specify ADB device serial number
  -h, --help               Display help message
```

---

## Rebuilding the Java DEX (Optional)

If you modify `tools/src/com/xaga/sa/MtkNrConfig.java`, you can recompile the DEX using:

```bash
cd tools
./build.sh
```

Prerequisites for rebuilding:
* JDK 8+ (`javac`)
* Android SDK Build-Tools (`d8`)

---

## License

This project is licensed under the [MIT License](LICENSE).
