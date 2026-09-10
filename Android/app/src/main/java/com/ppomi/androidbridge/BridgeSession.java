package com.ppomi.androidbridge;

import android.content.Context;
import android.os.Build;
import java.security.SecureRandom;
import java.util.Base64;

final class BridgeSession {
    private BridgeSession() {}
    static boolean supported() {
        // Installing the development build and enabling its accessibility service are
        // explicit device setup steps. Release builds remain disabled.
        return BuildConfig.DEBUG;
    }
    static boolean isEmulator() {
        return BridgePolicy.isEmulator(Build.HARDWARE, Build.FINGERPRINT, Build.MODEL);
    }
    static String token(Context context) {
        return context.getSharedPreferences("bridge", Context.MODE_PRIVATE).getString("token", "");
    }
    static void configure(Context context, String supplied) {
        if (!supported()) return;
        if (supplied != null && !BridgePolicy.validToken(supplied))
            throw new IllegalArgumentException("Session token must be 32–128 URL-safe characters.");
        if (supplied == null && BridgePolicy.validToken(token(context))) return;
        byte[] bytes = new byte[32];
        new SecureRandom().nextBytes(bytes);
        String next = supplied == null ? Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) : supplied;
        context.getSharedPreferences("bridge", Context.MODE_PRIVATE).edit().putString("token", next).commit();
    }
}
