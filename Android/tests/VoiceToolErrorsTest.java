package com.ppomi.androidbridge;

import java.util.concurrent.ExecutionException;

/** Pure Java checks; no Android framework, credentials, device or network needed. */
public final class VoiceToolErrorsTest {
    private static int checks;

    public static void main(String[] args) {
        for (String code : new String[] {"accessibility_required", "app_not_allowed", "app_not_found", "app_ambiguous",
                "stale_screen", "no_active_screen", "protected_action", "tool_failed"}) {
            VoiceToolErrors.Failure failure = new VoiceToolErrors.Failure(code);
            equal(code, failure.code);
            equal(code, VoiceToolErrors.code(new ExecutionException(new RuntimeException(failure))));
            equal("Voice tool failed", failure.getMessage());
        }
        equal("tool_failed", VoiceToolErrors.code(null));
        equal("tool_failed", VoiceToolErrors.code(new IllegalStateException()));
        equal("tool_failed", new VoiceToolErrors.Failure(null).code);
        equal("tool_failed", new VoiceToolErrors.Failure("password: synthetic-secret").code);
        equal("Voice tool failed", new VoiceToolErrors.Failure("password: synthetic-secret").getMessage());
        equal("tool_failed", VoiceToolErrors.code(new IllegalArgumentException("arbitrary app_not_found private content")));
        equal("tool_failed", VoiceToolErrors.code(new IllegalStateException("password field in unrelated exception")));
        mapped("accessibility_required", "접근성 서비스가 연결되지 않았습니다.");
        mapped("accessibility_required", "Android 접근성 설정에서 뽀미 서비스를 먼저 켜 주세요.");
        mapped("app_not_found", "Package has no launcher activity or is not installed");
        mapped("app_not_allowed", "Prototype permits only Settings, Ppomi test apps and the selected Home app; foreground: private.synthetic.package");
        mapped("app_not_allowed", "Prototype permits only Settings and Ppomi test apps; foreground: private.synthetic.package");
        mapped("stale_screen", "Stale nodeId; fetch ui_tree and use an id from its latest snapshot");
        mapped("stale_screen", "Read the current screen before acting");
        mapped("stale_screen", "Display or active window changed before gesture; inspect a fresh screen");
        mapped("stale_screen", "Node is not visible and enabled");
        mapped("no_active_screen", "No active accessibility window; unlock the device and open an allowed app");
        mapped("no_active_screen", "Cannot verify the active window display");
        mapped("protected_action", "Ppomi approvals and settings are controlled by the user only");
        mapped("protected_action", "Password fields are excluded from this prototype");
        mapped("protected_action", "This action requires a separate explicit workflow");
        mapped("protected_action", "A local task owns control or is waiting for user approval");
        // An uncertain gesture result is not a stale, safely retryable precondition.
        mapped("tool_failed", "Display geometry changed during gesture");
        mapped("tool_failed", "Foreground changed");
        mapped("tool_failed", "Android rejected gesture dispatch; gestureId=synthetic-id");
        // Prefer the deliberate typed category over a wrapper's recognized message.
        equal("app_ambiguous", VoiceToolErrors.code(new IllegalArgumentException(
            "This action requires a separate explicit workflow", new VoiceToolErrors.Failure("app_ambiguous"))));
        Throwable cyclic = new IllegalStateException() {
            @Override public synchronized Throwable getCause() { return this; }
        };
        equal("tool_failed", VoiceToolErrors.code(cyclic));
        Throwable deep = new VoiceToolErrors.Failure("protected_action");
        for (int index = 0; index < 40; index++) deep = new RuntimeException(deep);
        equal("tool_failed", VoiceToolErrors.code(deep));
        System.out.println("Voice tool error tests passed: " + checks);
    }

    private static void mapped(String expected, String message) {
        equal(expected, VoiceToolErrors.code(new ExecutionException(new IllegalStateException(message))));
    }

    private static void equal(Object expected, Object actual) {
        checks++;
        if (!expected.equals(actual)) throw new AssertionError("Unexpected safe error category");
    }
}
