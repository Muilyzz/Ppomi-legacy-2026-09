package com.ppomi.androidbridge;

import android.content.Context;
import org.json.JSONObject;
import org.json.JSONTokener;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.function.BooleanSupplier;
import javax.net.ssl.HttpsURLConnection;

/** Authenticated native HTTPS proxy. No content logging, caching, redirects or JS credentials. */
final class VoiceServerClient {
    private final SupabaseSettings settings;
    private final SupabaseClient auth;
    private volatile HttpsURLConnection inFlight;
    VoiceServerClient(Context context) {
        settings = new SupabaseSettings(context);
        auth = new SupabaseClient(settings);
    }
    boolean configured() { return settings.configured(); }
    void cancel() {
        HttpsURLConnection connection = inFlight;
        if (connection != null) connection.disconnect();
    }
    Object request(String endpoint, String path, JSONObject body, BooleanSupplier stillValid) throws Exception {
        if (!VoiceBridgePolicy.PATHS.contains(path)) throw new IllegalArgumentException("허용하지 않은 서버 요청입니다.");
        String base = VoiceBridgePolicy.endpoint(endpoint);
        boolean modelTurn = path.equals("/v1/responses");   // a chat turn carries instructions, tools and history, and the model takes its time
        byte[] bytes = body.toString().getBytes(StandardCharsets.UTF_8);
        if (bytes.length > (modelTurn ? 1_000_000 : 16000)) throw new IllegalArgumentException("요청이 너무 큽니다.");
        String token = auth.agentAccessToken();
        if (!stillValid.getAsBoolean()) throw new IllegalStateException("음성 세션이 종료되었습니다.");
        HttpsURLConnection connection = (HttpsURLConnection) new URL(base + path).openConnection();
        inFlight = connection;
        connection.setInstanceFollowRedirects(false);
        connection.setUseCaches(false);
        connection.setRequestMethod("POST"); connection.setConnectTimeout(12000); connection.setReadTimeout(modelTurn ? 120000 : 20000);
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("Cache-Control", "no-store");
        connection.setRequestProperty("Authorization", "Bearer " + token);
        connection.setDoOutput(true); connection.setFixedLengthStreamingMode(bytes.length);
        try {
            if (!stillValid.getAsBoolean()) throw new IllegalStateException("음성 세션이 종료되었습니다.");
            try (java.io.OutputStream output = connection.getOutputStream()) { output.write(bytes); }
            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) {
                if (status == 401) auth.reset();
                throw new IllegalStateException("음성 서버 요청을 완료하지 못했습니다. HTTP " + status);
            }
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            try (InputStream input = connection.getInputStream()) {
                byte[] buffer = new byte[8192]; int read;
                while ((read = input.read(buffer)) != -1) {
                    if (!stillValid.getAsBoolean()) throw new IllegalStateException("음성 세션이 종료되었습니다.");
                    if (output.size() + read > (modelTurn ? 2 * 1024 * 1024 : 512 * 1024)) throw new IllegalStateException("음성 서버 응답이 너무 큽니다.");
                    output.write(buffer, 0, read);
                }
            }
            Object result = new JSONTokener(output.toString(StandardCharsets.UTF_8.name())).nextValue();
            if (!(result instanceof JSONObject)) throw new IllegalStateException("음성 서버 응답 형식을 확인해 주세요.");
            return result;
        } finally { connection.disconnect(); if (inFlight == connection) inFlight = null; }
    }
}
