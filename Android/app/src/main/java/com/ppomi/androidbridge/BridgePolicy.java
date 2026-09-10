package com.ppomi.androidbridge;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/** Pure Java policy so transport and authorization boundaries can be tested off-device. */
final class BridgePolicy {
    static final int PORT = 8765;
    static final Set<String> ALLOWED_PACKAGES = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
        "com.android.settings", "com.ppomi.androidtarget", "com.ppomi.androidbridge")));

    static boolean isEmulator(String hardware, String fingerprint, String model) {
        return ("ranchu".equals(hardware) || "goldfish".equals(hardware))
            && (fingerprint.contains("generic") || fingerprint.contains("emulator")
                || model.contains("sdk_gphone") || model.contains("Android SDK"));
    }

    static boolean validToken(String token) {
        return token != null && token.matches("[A-Za-z0-9_-]{32,128}");
    }

    static boolean authorized(String token, String authorization) {
        if (!validToken(token) || authorization == null) return false;
        return MessageDigest.isEqual(("Bearer " + token).getBytes(StandardCharsets.UTF_8),
            authorization.getBytes(StandardCharsets.UTF_8));
    }

    static void requireAllowedPackage(String packageName) {
        if (!ALLOWED_PACKAGES.contains(packageName))
            throw new IllegalArgumentException("Prototype permits only Settings and Ppomi test apps; foreground: " + packageName);
    }
}
