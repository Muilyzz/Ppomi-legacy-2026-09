package com.ppomi.androidbridge;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;

/** Stable voice-tool error categories. Exception messages never cross the bridge. */
public final class VoiceToolErrors {
    private VoiceToolErrors() {}

    public static final class Failure extends IllegalArgumentException {
        public final String code;

        public Failure(String code) {
            super("Voice tool failed");
            this.code = allowed(code) ? code : "tool_failed";
        }
    }

    /** Wrapped worker failures retain a typed category; arbitrary messages stay generic. */
    public static String code(Throwable failure) {
        Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<Throwable, Boolean>());
        String fallback = "tool_failed";
        for (int depth = 0; failure != null && depth < 32 && seen.add(failure); depth++) {
            if (failure instanceof Failure) return ((Failure) failure).code;
            if ("tool_failed".equals(fallback)) fallback = knownMessage(failure.getMessage());
            failure = failure.getCause();
        }
        return fallback;
    }

    private static boolean allowed(String code) {
        if (code == null) return false;
        switch (code) {
            case "accessibility_required":
            case "app_not_allowed":
            case "app_not_found":
            case "app_ambiguous":
            case "stale_screen":
            case "no_active_screen":
            case "protected_action":
            case "tool_failed": return true;
            default: return false;
        }
    }

    private static String knownMessage(String message) {
        if (message == null) return "tool_failed";
        switch (message) {
            case "Android 접근성 설정에서 뽀미 서비스를 먼저 켜 주세요.":
            case "접근성 서비스를 먼저 켜 주세요.":
            case "접근성 서비스가 연결되지 않았습니다.":
                return "accessibility_required";
            case "Package has no launcher activity or is not installed":
                return "app_not_found";
            case "Stale nodeId; fetch ui_tree and use an id from its latest snapshot":
            case "Read the current screen before acting":
            case "Display or active window changed before gesture; inspect a fresh screen":
            case "Node is not visible and enabled":
            case "Node has no visible screen area":
                return "stale_screen";
            case "No active accessibility window; unlock the device and open an allowed app":
            case "Cannot verify the active window display":
                return "no_active_screen";
            case "Ppomi approvals and settings are controlled by the user only":
            case "Password fields are excluded from this prototype":
            case "This action requires a separate explicit workflow":
            case "A local task owns control or is waiting for user approval":
                return "protected_action";
            default:
                // The suffix contains a package name. Recognize the fixed native
                // prefix, but never return the package name or any other message.
                if (message.startsWith("Prototype permits only Settings, Ppomi test apps and the selected Home app; foreground: ")
                    || message.startsWith("Prototype permits only Settings and Ppomi test apps; foreground: ")) {
                    return "app_not_allowed";
                }
                return "tool_failed";
        }
    }
}
