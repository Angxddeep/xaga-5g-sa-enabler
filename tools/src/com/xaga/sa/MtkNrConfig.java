package com.xaga.sa;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.ArrayList;

/**
 * MtkNrConfig - Standalone MediaTek 5G NR / SA Configuration Utility for Android.
 *
 * Reverse-engineered from MediaTek EngineerMode (com.mediatek.engineermode.nrconfigure.NrConfigActivity)
 * and MediaTek RIL (libmtk-ril.so / vendor.mediatek.hardware.mtkradioex@3.0).
 *
 * Background:
 * On MediaTek Dimensity platforms (such as MT6895 / Dimensity 8100 on Redmi K50i / Poco X4 GT - "xaga"),
 * 5G Standalone (SA) capability on SIM Slot 2 often defaults to disabled (Mode 5: NSA only) or drops SA
 * during DSDS negotiation.
 *
 * In MTK EngineerMode (*#*#3646633#*#* or *#*#723366#*#*), navigating to "Nr Configure" and toggling "SA"
 * sends the AT command:
 *     AT+E5GOPT=<mode>
 * where <mode> is a bitmask:
 *     Bit 0 (1): Base NR flag
 *     Bit 1 (2): Standalone (SA) enabled
 *     Bit 2 (4): Non-Standalone (NSA) enabled
 *
 * Resulting mode values:
 *     1 = SA disabled, NSA disabled (NR Off)
 *     3 = SA enabled, NSA disabled
 *     5 = SA disabled, NSA enabled (NSA Only - common default on Slot 2)
 *     7 = SA enabled, NSA enabled   (SA + NSA - FULL 5G)
 *
 * EngineerMode transmits this command via HIDL/AIDL to the MediaTek RIL daemon (mtkfusionrild):
 *     - Slot 0 (SIM 1): vendor.mediatek.hardware.mtkradioex@3.0::IMtkRadioEx / mtkEm1
 *     - Slot 1 (SIM 2): vendor.mediatek.hardware.mtkradioex@3.0::IMtkRadioEx / mtkEm2
 *
 * This utility invokes the exact same HIDL/AIDL/PhoneEx IPC mechanism via app_process,
 * eliminating any need to include vulnerable or prohibited EngineerMode blobs in custom ROMs like LineageOS.
 */
public class MtkNrConfig {
    private static final String TAG = "[MtkNrConfig]";

    /**
     * Send AT command via MediaTek Radio HIDL (IMtkRadioEx@3.0 or @2.0).
     */
    private static boolean sendViaHidl(String hidlVersion, String serviceName, int serial, String atCmd) {
        try {
            Class<?> hwBinderCls = Class.forName("android.os.HwBinder");
            Method getServiceMethod = hwBinderCls.getMethod("getService", String.class, String.class, boolean.class);

            String ifaceName = "vendor.mediatek.hardware.mtkradioex@" + hidlVersion + "::IMtkRadioEx";
            Object binder = getServiceMethod.invoke(null, ifaceName, serviceName, false);
            if (binder == null) {
                return false;
            }

            Class<?> hwParcelCls = Class.forName("android.os.HwParcel");
            Constructor<?> ctor = hwParcelCls.getConstructor();
            Object request = ctor.newInstance();
            Object reply = ctor.newInstance();

            Method writeInterfaceToken = hwParcelCls.getMethod("writeInterfaceToken", String.class);
            Method writeInt32 = hwParcelCls.getMethod("writeInt32", int.class);
            Method writeStringVector = hwParcelCls.getMethod("writeStringVector", ArrayList.class);
            Method releaseTemp = hwParcelCls.getMethod("releaseTemporaryStorage");
            Method release = hwParcelCls.getMethod("release");

            writeInterfaceToken.invoke(request, ifaceName);
            writeInt32.invoke(request, serial);

            ArrayList<String> cmdList = new ArrayList<String>();
            cmdList.add(atCmd);
            cmdList.add("");
            writeStringVector.invoke(request, cmdList);

            Class<?> iHwBinderCls = Class.forName("android.os.IHwBinder");
            Method transact = iHwBinderCls.getMethod("transact", int.class, hwParcelCls, hwParcelCls, int.class);

            // Transaction code 101 is sendRequestStrings; flag 1 is FLAG_ONEWAY
            transact.invoke(binder, 101, request, reply, 1);
            releaseTemp.invoke(request);
            release.invoke(reply);

            System.out.println(TAG + " [+] Sent via HIDL " + hidlVersion + " (" + serviceName + "): " + atCmd);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * Send AT command via MediaTek Radio AIDL (IMtkRadioExModem).
     */
    private static boolean sendViaAidl(int slotId, int serial, String atCmd) {
        try {
            Class<?> smCls = Class.forName("android.os.ServiceManager");
            Method getServiceMethod = smCls.getMethod("getService", String.class);

            String serviceName = "vendor.mediatek.hardware.mtkradioex.modem.IMtkRadioExModem/slot" + (slotId + 1);
            Object binder = getServiceMethod.invoke(null, serviceName);
            if (binder == null) {
                return false;
            }

            Class<?> parcelCls = Class.forName("android.os.Parcel");
            Method obtain = parcelCls.getMethod("obtain");
            Object data = obtain.invoke(null);

            Method writeInterfaceToken = parcelCls.getMethod("writeInterfaceToken", String.class);
            Method writeInt = parcelCls.getMethod("writeInt", int.class);
            Method writeStringArray = parcelCls.getMethod("writeStringArray", String[].class);
            Method recycle = parcelCls.getMethod("recycle");

            String descriptor = "vendor.mediatek.hardware.mtkradioex.modem.IMtkRadioExModem";
            writeInterfaceToken.invoke(data, descriptor);
            writeInt.invoke(data, serial);
            writeStringArray.invoke(data, (Object) new String[]{atCmd, ""});
            writeInt.invoke(data, 3); // CLIENT_EM = 3

            Class<?> iBinderCls = Class.forName("android.os.IBinder");
            Method transact = iBinderCls.getMethod("transact", int.class, parcelCls, parcelCls, int.class);

            // Transaction code 11 is sendRequestStrings; flag 1 is FLAG_ONEWAY
            transact.invoke(binder, 11, data, null, 1);
            recycle.invoke(data);

            System.out.println(TAG + " [+] Sent via AIDL (" + serviceName + "): " + atCmd);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * Send AT command via MediaTek Telephony AIDL (IMtkTelephonyEx on phoneEx).
     */
    private static boolean sendViaPhoneEx(int slotId, long token, String atCmd) {
        try {
            Class<?> smCls = Class.forName("android.os.ServiceManager");
            Method getServiceMethod = smCls.getMethod("getService", String.class);
            Object binder = getServiceMethod.invoke(null, "phoneEx");
            if (binder == null) {
                return false;
            }

            Class<?> parcelCls = Class.forName("android.os.Parcel");
            Method obtain = parcelCls.getMethod("obtain");
            Object data = obtain.invoke(null);
            Object reply = obtain.invoke(null);

            Method writeInterfaceToken = parcelCls.getMethod("writeInterfaceToken", String.class);
            Method writeInt = parcelCls.getMethod("writeInt", int.class);
            Method writeLong = parcelCls.getMethod("writeLong", long.class);
            Method writeString = parcelCls.getMethod("writeString", String.class);
            Method writeStrongBinder = parcelCls.getMethod("writeStrongBinder", Class.forName("android.os.IBinder"));
            Method recycle = parcelCls.getMethod("recycle");

            String descriptor = "com.mediatek.internal.telephony.IMtkTelephonyEx";
            writeInterfaceToken.invoke(data, descriptor);
            writeInt.invoke(data, slotId);
            writeLong.invoke(data, token);
            writeString.invoke(data, atCmd);
            writeStrongBinder.invoke(data, new Object[]{null});

            Class<?> iBinderCls = Class.forName("android.os.IBinder");
            Method transact = iBinderCls.getMethod("transact", int.class, parcelCls, parcelCls, int.class);

            // TRANSACTION_sendAtCmd = 39
            transact.invoke(binder, 39, data, reply, 0);
            recycle.invoke(data);
            recycle.invoke(reply);

            System.out.println(TAG + " [+] Sent via phoneEx (slot " + slotId + "): " + atCmd);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    public static boolean configureSlot(int slotId, int mode) {
        String atCmd = "AT+E5GOPT=" + mode;
        String emService = "mtkEm" + (slotId + 1);

        System.out.println(TAG + " [*] Configuring SIM Slot " + (slotId + 1) + " (slot index: " + slotId + ") with mode=" + mode + " (" + atCmd + ")...");

        // 1. Try HIDL 3.0 (standard on MT6895 / Dimensity 8100)
        if (sendViaHidl("3.0", emService, 101, atCmd)) {
            return true;
        }

        // 2. Try HIDL 2.0
        if (sendViaHidl("2.0", emService, 101, atCmd)) {
            return true;
        }

        // 3. Try AIDL Modem
        if (sendViaAidl(slotId, 101, atCmd)) {
            return true;
        }

        // 4. Try PhoneEx
        if (sendViaPhoneEx(slotId, 101L, atCmd)) {
            return true;
        }

        System.err.println(TAG + " [-] Failed to send AT command via any supported interface for Slot " + (slotId + 1));
        return false;
    }

    public static void main(String[] args) {
        System.out.println("=================================================");
        System.out.println("  MTK 5G Standalone (SA) Enabler for Xaga/MT6895 ");
        System.out.println("=================================================");

        int targetSlot = 1; // 0 for SIM 1, 1 for SIM 2, -1 for BOTH
        int mode = 7;       // 7 = SA + NSA enabled

        if (args.length > 0) {
            String arg0 = args[0].trim().toLowerCase();
            if (arg0.equals("all") || arg0.equals("both") || arg0.equals("-1")) {
                targetSlot = -1;
            } else {
                try {
                    int s = Integer.parseInt(arg0);
                    if (s == 2) targetSlot = 1;
                    else if (s == 1) targetSlot = 0;
                    else targetSlot = s;
                } catch (Exception e) {
                    targetSlot = 1;
                }
            }
        }

        if (args.length > 1) {
            try {
                mode = Integer.parseInt(args[1].trim());
            } catch (Exception e) {
                mode = 7;
            }
        }

        String modeDesc;
        switch (mode) {
            case 7: modeDesc = "SA + NSA (Recommended)"; break;
            case 3: modeDesc = "SA Only"; break;
            case 5: modeDesc = "NSA Only"; break;
            case 1: modeDesc = "NR Disabled"; break;
            default: modeDesc = "Custom Mode (" + mode + ")"; break;
        }
        System.out.println("[*] Target Mode: " + mode + " (" + modeDesc + ")");

        boolean ok;
        if (targetSlot == -1) {
            System.out.println("[*] Applying to BOTH SIM 1 and SIM 2...");
            boolean r1 = configureSlot(0, mode);
            boolean r2 = configureSlot(1, mode);
            ok = r1 || r2;
        } else {
            ok = configureSlot(targetSlot, mode);
        }

        if (ok) {
            System.out.println(TAG + " [SUCCESS] 5G SA configuration applied successfully!");
            System.out.println(TAG + " [IMPORTANT] A device reboot or modem restart is required for changes to take effect.");
            System.exit(0);
        } else {
            System.err.println(TAG + " [ERROR] Could not apply 5G configuration.");
            System.exit(1);
        }
    }
}
