package com.ppomi.androidbridge;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Runs the exact app JNI wrapper in Android's Java runtime without launching or changing UI. */
public final class JniProbe {
    public static void main(String[] args) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        InputStream input = args.length == 1 ? new FileInputStream(args[0]) : System.in;
        for (int count; (count = input.read(buffer)) >= 0;) bytes.write(buffer, 0, count);
        if (input != System.in) input.close();
        System.out.println(SharedAccounting.report(new String(bytes.toByteArray(), StandardCharsets.UTF_8)));
    }
}
