package com.ppomi.androidbridge;

import org.json.JSONObject;
import org.json.JSONTokener;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import javax.net.ssl.HttpsURLConnection;

/** HTTPS RPC transport. Credentials are never forwarded through redirects or included in errors. */
final class SupabaseClient {
    private final SupabaseSettings settings;
    private String accessToken;
    private long expiresAt;
    SupabaseClient(SupabaseSettings settings) { this.settings = settings; }
    synchronized void reset() { accessToken = null; expiresAt = 0; }
    /** Native-only token access for the trusted agent HTTPS proxy; never sent to JavaScript. */
    synchronized String agentAccessToken() throws Exception {
        ensureAuth(settings.credentials());
        return accessToken;
    }
    synchronized Object rpc(String name, JSONObject arguments) throws Exception {
        if (!name.matches("ppomi_[a-z_]+")) throw new IllegalArgumentException("잘못된 공유 작업 요청입니다.");
        JSONObject config = settings.credentials();
        ensureAuth(config);
        try { return request(config, "/rest/v1/rpc/" + name, arguments, accessToken); }
        catch (HttpFailure failure) {
            if (failure.status != 401) throw failure;
            reset(); ensureAuth(config);
            return request(config, "/rest/v1/rpc/" + name, arguments, accessToken);
        }
    }
    private void ensureAuth(JSONObject config) throws Exception {
        if (accessToken != null && System.currentTimeMillis() < expiresAt) return;
        JSONObject result = (JSONObject) request(config, "/auth/v1/token?grant_type=password",
            TaskStore.object("email", config.getString("email"), "password", config.getString("password")), null);
        accessToken = result.getString("access_token");
        expiresAt = System.currentTimeMillis() + Math.max(1, result.optLong("expires_in", 3600) - 60) * 1000;
    }
    private Object request(JSONObject config, String path, JSONObject body, String token) throws Exception {
        HttpsURLConnection connection = (HttpsURLConnection) new URL(config.getString("url") + path).openConnection();
        connection.setInstanceFollowRedirects(false);
        connection.setRequestMethod("POST"); connection.setConnectTimeout(12000); connection.setReadTimeout(15000);
        connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("apikey", config.getString("publishableKey"));
        if (token != null) connection.setRequestProperty("Authorization", "Bearer " + token);
        try {
            byte[] bytes = body.toString().getBytes(StandardCharsets.UTF_8);
            connection.setFixedLengthStreamingMode(bytes.length);
            try (java.io.OutputStream output = connection.getOutputStream()) { output.write(bytes); }
            int status = connection.getResponseCode();
            String response;
            try (InputStream input = status >= 400 ? connection.getErrorStream() : connection.getInputStream()) { response = read(input); }
            if (status < 200 || status >= 300) {
                String code = "";
                try { code = new JSONObject(response).optString("code"); } catch (Exception ignored) { }
                throw new HttpFailure(status, code);
            }
            return new JSONTokener(response).nextValue();
        } catch (HttpFailure failure) { throw failure; }
        catch (Exception failure) { throw new IllegalStateException("공유 서버 응답을 확인하지 못했습니다. 저장된 기록은 유지되며 앱 동작을 다시 실행하지 않습니다."); }
        finally { connection.disconnect(); }
    }
    private static String read(InputStream input) throws Exception {
        if (input == null) return "";
        ByteArrayOutputStream output = new ByteArrayOutputStream(); byte[] buffer = new byte[8192]; int length;
        while ((length = input.read(buffer)) != -1) {
            if (output.size() + length > 2_000_000) throw new IllegalArgumentException("response limit");
            output.write(buffer, 0, length);
        }
        return output.toString(StandardCharsets.UTF_8.name());
    }
    static final class HttpFailure extends Exception {
        final int status;
        final boolean conflict;
        HttpFailure(int status, String code) {
            super(status == 401 || status == 403 ? "공유 서버 인증 또는 기기 권한을 확인해 주세요. (HTTP " + status + ")"
                : status == 409 || "40001".equals(code) || "55000".equals(code)
                ? "공유 작업의 서버 버전 또는 상태가 변경됐습니다. 충돌을 확인해야 합니다. (HTTP " + status + ")"
                : "공유 서버가 요청을 확정하지 못했습니다. (HTTP " + status + ")");
            this.status = status;
            this.conflict = status == 409 || "40001".equals(code) || "55000".equals(code);
        }
    }
}
