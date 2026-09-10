package com.ppomi.androidbridge;

import java.nio.charset.StandardCharsets;

/** JSON transport into the same Swift accounting sources used by the Mac app. No Java arithmetic. */
public final class SharedAccounting {
    static { System.loadLibrary("ppomi_accounting"); }
    private SharedAccounting() {}
    private static native byte[] nativeReport(byte[] archiveJSON);

    /** Returns validation errors as {ok:false, code, error}; amounts stay signed integer minor units. */
    public static String report(String archiveJSON) {
        if (archiveJSON == null) throw new IllegalArgumentException("Archive JSON is required.");
        byte[] input = archiveJSON.getBytes(StandardCharsets.UTF_8);
        if (input.length > 4 * 1024 * 1024) throw new IllegalArgumentException("Archive exceeds 4 MiB.");
        byte[] output = nativeReport(input);
        if (output == null) throw new IllegalStateException("Swift accounting bridge returned no result.");
        return new String(output, StandardCharsets.UTF_8);
    }
}
