#!/usr/bin/env bash
# ==============================================================================
# Enable 5G Standalone (SA) on MediaTek Devices (Xiaomi MT6895 / Xaga & others)
# ==============================================================================
#
# Reverse-engineered from MediaTek EngineerMode and MTK RIL stack.
# Fixes the issue where 5G Standalone (SA) is disabled on SIM Slot 2 without
# requiring vulnerable Engineering Mode APKs or private permissions on AOSP/LineageOS.
#
# Usage:
#   ./enable_5g_sa.sh [OPTIONS]
#
# Options:
#   -s, --slot <1|2|both>    Target SIM Slot (default: 2)
#   -m, --mode <mode>        NR Mode (default: 7 = SA + NSA)
#                            7 = Both SA and NSA enabled (Full 5G)
#                            3 = SA Only
#                            5 = NSA Only
#                            1 = NR Disabled
#   -r, --reboot             Automatically reboot device after applying
#   -d, --device <serial>    Target specific ADB device
#   -h, --help               Show this help message
# ==============================================================================

RED="$(printf "\033[0;31m")"
GREEN="$(printf "\033[0;32m")"
YELLOW="$(printf "\033[1;33m")"
BLUE="$(printf "\033[0;34m")"
CYAN="$(printf "\033[0;36m")"
BOLD="$(printf "\033[1m")"
NC="$(printf "\033[0m")"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

TARGET_SLOT="2"
NR_MODE="7"
AUTO_REBOOT=false
SPECIFIC_DEVICE=""
INTERACTIVE=true

prompt_input() {
    local prompt_msg="$1"
    local default_val="$2"
    local user_val=""

    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        echo -ne "$prompt_msg" > /dev/tty
        read -r user_val < /dev/tty || true
    elif [ -t 0 ]; then
        read -r -p "$prompt_msg" user_val || true
    else
        user_val="$default_val"
    fi

    echo "${user_val:-$default_val}"
}

show_help() {
    cat << EOF
${BOLD}MediaTek 5G Standalone (SA) Enabler via ADB${NC}

${BOLD}Usage:${NC}
  $0 [OPTIONS]

${BOLD}Options:${NC}
  -s, --slot <1|2|both>    Target SIM slot to configure (default: 2)
  -m, --mode <7|3|5|1>     NR configuration mode (default: 7)
                             7 = SA + NSA (Standard 5G, recommended)
                             3 = SA Only
                             5 = NSA Only
                             1 = Disabled
  -r, --reboot             Automatically reboot device after applying
  -d, --device <serial>    Specify ADB device serial number
  -h, --help               Display this help message

${BOLD}Examples:${NC}
  $0                      # Enable SA on SIM Slot 2 (default)
  $0 --both               # Enable SA on both SIM Slot 1 and Slot 2
  $0 --slot 2 --reboot    # Enable SA on Slot 2 and reboot device
EOF
}

if [[ $# -gt 0 ]]; then
    INTERACTIVE=false
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--slot)
            TARGET_SLOT="$2"
            shift 2
            ;;
        --both|--all)
            TARGET_SLOT="both"
            shift
            ;;
        -m|--mode)
            NR_MODE="$2"
            shift 2
            ;;
        -r|--reboot)
            AUTO_REBOOT=true
            shift
            ;;
        -d|--device)
            SPECIFIC_DEVICE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

if ! command -v adb &>/dev/null; then
    log_error "adb command not found. Please install Android Platform Tools and add adb to your PATH."
    exit 1
fi

ADB_CMD="adb"
if [[ -n "$SPECIFIC_DEVICE" ]]; then
    ADB_CMD="adb -s $SPECIFIC_DEVICE"
fi

adb_cmd() {
    "$ADB_CMD" "$@" < /dev/null
}

adb_shell() {
    "$ADB_CMD" shell -n "$@" < /dev/null
}

echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}   Xiaomi MT6895 5G Standalone (SA) Enabler via ADB      ${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"

log_info "Checking connected device..."
RAW_DEVICES=$(adb_cmd devices 2>/dev/null || true)
DEVICE_COUNT=$(echo "$RAW_DEVICES" | awk 'NR>1 && $2 ~ /^(device|recovery|sideload)$/ {print $1}' | grep -c . || true)
UNAUTH_COUNT=$(echo "$RAW_DEVICES" | awk 'NR>1 && $2=="unauthorized" {print $1}' | grep -c . || true)

if [[ "$UNAUTH_COUNT" -gt 0 ]]; then
    log_error "Device detected but unauthorized."
    echo -e "Please check your phone's screen and tap ${BOLD}'Allow USB debugging'${NC}."
    exit 1
fi

if [[ "$DEVICE_COUNT" -eq 0 ]]; then
    log_error "No authorized Android device connected via ADB."
    echo -e "Please ensure:"
    echo -e "  1. USB Debugging is enabled in Settings -> Developer Options."
    echo -e "  2. The device is connected to this computer with a reliable cable."
    echo -e "  3. You accepted the 'Allow USB debugging' prompt on the device screen."
    exit 1
fi

if [[ "$DEVICE_COUNT" -gt 1 && -z "$SPECIFIC_DEVICE" ]]; then
    log_error "Multiple ADB devices detected. Please specify target device with -d <serial>."
    adb_cmd devices
    exit 1
fi

DEVICE_MODEL=$(adb_shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)
DEVICE_DEVICE=$(adb_shell getprop ro.product.device 2>/dev/null | tr -d '\r' || true)
DEVICE_PLATFORM=$(adb_shell getprop ro.board.platform 2>/dev/null | tr -d '\r' || true)
log_info "Connected device: ${DEVICE_MODEL:-Unknown} (Codename: ${DEVICE_DEVICE:-Unknown}, Platform: ${DEVICE_PLATFORM:-Unknown})"

log_info "Verifying root access for telephony HIDL execution..."
HAS_ROOT=false
IS_ADB_ROOT=false

CURRENT_UID=$(adb_shell id -u 2>/dev/null | tr -d '\r' || true)
if [[ "$CURRENT_UID" == "0" ]]; then
    HAS_ROOT=true
    IS_ADB_ROOT=true
else
    adb_cmd root &>/dev/null || true
    sleep 1
    CURRENT_UID=$(adb_shell id -u 2>/dev/null | tr -d '\r' || true)
    if [[ "$CURRENT_UID" == "0" ]]; then
        HAS_ROOT=true
        IS_ADB_ROOT=true
    else
        SU_TEST=$(adb_shell "su -c id -u" 2>/dev/null | tr -d '\r' || true)
        if [[ "$SU_TEST" == "0" ]]; then
            HAS_ROOT=true
            IS_ADB_ROOT=false
            log_info "Root access confirmed via su binary (Magisk/KernelSU/APatch)."
        fi
    fi
fi

if [[ "$HAS_ROOT" != "true" ]]; then
    log_error "Root access is required to execute telephony HAL / HIDL commands."
    echo -e "Please either:"
    echo -e "  - In LineageOS / AOSP userdebug: Enable 'Rooted debugging' in Developer Options and re-run."
    echo -e "  - On rooted devices: Grant Root access when prompted."
    exit 1
fi

run_device_cmd() {
    if [[ "$IS_ADB_ROOT" == "true" ]]; then
        "$ADB_CMD" shell -n "$@" < /dev/null
    else
        "$ADB_CMD" shell -n su -c "$*" < /dev/null
    fi
}

if [[ "$INTERACTIVE" == "true" ]]; then
    echo ""
    echo -e "${CYAN}${BOLD}------------------------------------------------------------${NC}"
    echo -e "${BOLD}[?] Which SIM slot would you like to configure?${NC}"
    echo -e "  ${CYAN}1)${NC} SIM Slot 2 only ${YELLOW}(default - fixes Slot 2 5G SA drop)${NC}"
    echo -e "  ${CYAN}2)${NC} BOTH SIM Slot 1 & Slot 2 ${GREEN}(recommended)${NC}"
    echo -e "  ${CYAN}3)${NC} SIM Slot 1 only"
    SLOT_CHOICE=$(prompt_input "Enter choice [1-3] (default: 1): " "1")

    case "$SLOT_CHOICE" in
        2) TARGET_SLOT="both" ;;
        3) TARGET_SLOT="1" ;;
        *) TARGET_SLOT="2" ;;
    esac

    echo ""
    echo -e "${BOLD}[?] Select 5G Mode:${NC}"
    echo -e "  ${CYAN}1)${NC} 5G SA + NSA (Full 5G) ${GREEN}(default, recommended)${NC}"
    echo -e "  ${CYAN}2)${NC} 5G SA Only"
    echo -e "  ${CYAN}3)${NC} 5G NSA Only"
    MODE_CHOICE=$(prompt_input "Enter choice [1-3] (default: 1): " "1")

    case "$MODE_CHOICE" in
        2) NR_MODE="3" ;;
        3) NR_MODE="5" ;;
        *) NR_MODE="7" ;;
    esac
    echo -e "${CYAN}${BOLD}------------------------------------------------------------${NC}"
    echo ""
fi

REMOTE_TMP="/data/local/tmp/mtk_nr_config.dex"

log_info "Deploying standalone MTK NR configuration DEX to $REMOTE_TMP..."

DEX_B64="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AAJMTAADTExMAAJMWgAZTGNvbS94YWdhL3NhL010a05yQ29uZmlnOwAVTGphdmEvaW8vUHJpbnRTdHJlYW07ABNMamF2YS9sYW5nL0Jvb2xlYW47ABFMamF2YS9sYW5nL0NsYXNzOwAVTGphdmEvbGFuZy9FeGNlcHRpb247ABNMamF2YS9sYW5nL0ludGVnZXI7ABBMamF2YS9sYW5nL0xvbmc7ABJMamF2YS9sYW5nL09iamVjdDsAEkxqYXZhL2xhbmcvU3RyaW5nOwAZTGphdmEvbGFuZy9TdHJpbmdCdWlsZGVyOwASTGphdmEvbGFuZy9TeXN0ZW07AB9MamF2YS9sYW5nL3JlZmxlY3QvQ29uc3RydWN0b3I7ABpMamF2YS9sYW5nL3JlZmxlY3QvTWV0aG9kOwAVTGphdmEvdXRpbC9BcnJheUxpc3Q7ABBNdGtOckNvbmZpZy5qYXZhAAtOUiBEaXNhYmxlZAAITlNBIE9ubHkAFlNBICsgTlNBIChSZWNvbW1lbmRlZCkAB1NBIE9ubHkAA1RBRwAEVFlQRQABVgACVkkAAlZMAAFaAANaSUkABFpJSUwABFpJSkwAAlpMAAVaTExJTAAnWypdIEFwcGx5aW5nIHRvIEJPVEggU0lNIDEgYW5kIFNJTSAyLi4uABFbKl0gVGFyZ2V0IE1vZGU6IAASW0xqYXZhL2xhbmcvQ2xhc3M7ABNbTGphdmEvbGFuZy9PYmplY3Q7ABNbTGphdmEvbGFuZy9TdHJpbmc7AA1bTXRrTnJDb25maWddACdbTXRrTnJDb25maWddIFsqXSBDb25maWd1cmluZyBTSU0gU2xvdCAAIVtNdGtOckNvbmZpZ10gWytdIFNlbnQgdmlhIEFJREwgKAAgW010a05yQ29uZmlnXSBbK10gU2VudCB2aWEgSElETCAAKVtNdGtOckNvbmZpZ10gWytdIFNlbnQgdmlhIHBob25lRXggKHNsb3QgAFFbTXRrTnJDb25maWddIFstXSBGYWlsZWQgdG8gc2VuZCBBVCBjb21tYW5kIHZpYSBhbnkgc3VwcG9ydGVkIGludGVyZmFjZSBmb3IgU2xvdCAAN1tNdGtOckNvbmZpZ10gW0VSUk9SXSBDb3VsZCBub3QgYXBwbHkgNUcgY29uZmlndXJhdGlvbi4AYltNdGtOckNvbmZpZ10gW0lNUE9SVEFOVF0gQSBkZXZpY2UgcmVib290IG9yIG1vZGVtIHJlc3RhcnQgaXMgcmVxdWlyZWQgZm9yIGNoYW5nZXMgdG8gdGFrZSBlZmZlY3QuAEFbTXRrTnJDb25maWddIFtTVUNDRVNTXSA1RyBTQSBjb25maWd1cmF0aW9uIGFwcGxpZWQgc3VjY2Vzc2Z1bGx5IQADYWRkAANhbGwAE2FuZHJvaWQub3MuSHdCaW5kZXIAE2FuZHJvaWQub3MuSHdQYXJjZWwAEmFuZHJvaWQub3MuSUJpbmRlcgAUYW5kcm9pZC5vcy5JSHdCaW5kZXIAEWFuZHJvaWQub3MuUGFyY2VsABlhbmRyb2lkLm9zLlNlcnZpY2VNYW5hZ2VyAAZhcHBlbmQABGJvdGgAL2NvbS5tZWRpYXRlay5pbnRlcm5hbC50ZWxlcGhvbnkuSU10a1RlbGVwaG9ueUV4AA1jb25maWd1cmVTbG90AAZlcXVhbHMAA2VycgAEZXhpdAAHZm9yTmFtZQAOZ2V0Q29uc3RydWN0b3IACWdldE1ldGhvZAAKZ2V0U2VydmljZQAGaW52b2tlAARtYWluAAVtdGtFbQALbmV3SW5zdGFuY2UABm9idGFpbgADb3V0AAhwYXJzZUludAAHcGhvbmVFeAAHcHJpbnRsbgAHcmVjeWNsZQAHcmVsZWFzZQAXcmVsZWFzZVRlbXBvcmFyeVN0b3JhZ2UAC3NlbmRWaWFBaWRsAAtzZW5kVmlhSGlkbAAOc2VuZFZpYVBob25lRXgAC3RvTG93ZXJDYXNlAAh0b1N0cmluZwAIdHJhbnNhY3QABHRyaW0AB3ZhbHVlT2YAOnZlbmRvci5tZWRpYXRlay5oYXJkd2FyZS5tdGtyYWRpb2V4Lm1vZGVtLklNdGtSYWRpb0V4TW9kZW0AP3ZlbmRvci5tZWRpYXRlay5oYXJkd2FyZS5tdGtyYWRpb2V4Lm1vZGVtLklNdGtSYWRpb0V4TW9kZW0vc2xvdAAkdmVuZG9yLm1lZGlhdGVrLmhhcmR3YXJlLm10a3JhZGlvZXhAAAh3cml0ZUludAAKd3JpdGVJbnQzMgATd3JpdGVJbnRlcmZhY2VUb2tlbgAJd3JpdGVMb25nAAt3cml0ZVN0cmluZwAQd3JpdGVTdHJpbmdBcnJheQARd3JpdGVTdHJpbmdWZWN0b3IAEXdyaXRlU3Ryb25nQmluZGVyAJsBfn5EOHsiYmFja2VuZCI6ImRleCIsImNvbXBpbGF0aW9uLW1vZGUiOiJkZWJ1ZyIsImhhcy1jaGVja3N1bXMiOmZhbHNlLCJtaW4tYXBpIjoxLCJzaGEtMSI6IjA4NGE4OTEyNmFlMDU5NmM1OTkxNDNkZjU3YTY1NDY0NmFmMjgzMTMiLCJ2ZXJzaW9uIjoiOS4yLjQtZGV2In0AAQAGAAAaAIGABIwaAQnICQEJpBoBCqAMAQrAEAEKwBUBFzwAAAAAAAAADwAAAAAAAAABAAAAAAAAAAEAAAB4AAAAcAAAAAIAAAAVAAAAUAIAAAMAAAAVAAAApAIAAAQAAAAGAAAAoAMAAAUAAAAbAAAA0AMAAAYAAAABAAAAqAQAAAEgAAAGAAAAyAQAAAMgAAAGAAAATw8AAAEQAAAOAAAALBAAAAIgAAB4AAAAqBAAAAAgAAABAAAAYhkAAAUgAAABAAAAghkAAAMQAAABAAAAiBkAAAAQAAABAAAAjBkAAA=="

if [[ "$IS_ADB_ROOT" == "true" ]]; then
    echo "$DEX_B64" | "$ADB_CMD" shell "base64 -d > $REMOTE_TMP && chmod 644 $REMOTE_TMP"
else
    echo "$DEX_B64" | "$ADB_CMD" shell su -c "base64 -d > $REMOTE_TMP && chmod 644 $REMOTE_TMP"
fi

REMOTE_SIZE=$(run_device_cmd "ls -l $REMOTE_TMP" 2>/dev/null | awk '{print $5}' || true)
if [[ -z "$REMOTE_SIZE" || "$REMOTE_SIZE" -eq 0 ]]; then
    log_error "Failed to write DEX file on device."
    exit 1
fi

log_info "Executing MTK 5G NR configuration via app_process..."
log_info "Target Slot: $TARGET_SLOT | Mode: $NR_MODE"

CMD_OUTPUT=$(run_device_cmd "CLASSPATH=$REMOTE_TMP app_process /system/bin com.xaga.sa.MtkNrConfig $TARGET_SLOT $NR_MODE" 2>&1 || true)
echo "$CMD_OUTPUT"

run_device_cmd "rm -f $REMOTE_TMP" &>/dev/null || true

if echo "$CMD_OUTPUT" | grep -q "\[SUCCESS\]"; then
    log_success "5G Standalone (SA) configuration successfully applied to the modem NVRAM!"
    echo ""
    echo -e "${YELLOW}${BOLD}NOTE:${NC} A device reboot is REQUIRED for the modem baseband to reload NVRAM and activate 5G SA."
    
    if [[ "$AUTO_REBOOT" == "true" ]]; then
        log_info "Rebooting device now as requested by --reboot flag..."
        adb_cmd reboot
        log_success "Device is rebooting. Once booted, 5G SA will be active on the target SIM slot."
    else
        REBOOT_CHOICE=$(prompt_input "$(echo -e "${BOLD}[?] Would you like to reboot the device now? [Y/n]: ${NC}")" "Y")
        if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
            log_info "Rebooting device..."
            adb_cmd reboot
            log_success "Device is rebooting. Once booted, 5G SA will be active on the target SIM slot."
        else
            log_warn "Please manually reboot your phone at your convenience to finish activating 5G SA."
        fi
    fi
else
    log_error "The configuration tool encountered an error. See output above for details."
    exit 1
fi
