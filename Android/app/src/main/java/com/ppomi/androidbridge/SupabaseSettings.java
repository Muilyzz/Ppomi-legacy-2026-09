package com.ppomi.androidbridge;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import org.json.JSONObject;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Device credentials are encrypted together; public snapshots never contain auth material. */
public final class SupabaseSettings {
    private static final String ALIAS = "ppomi.android.ssot.device.v1";
    private final SharedPreferences preferences;
    SupabaseSettings(Context context) { preferences = context.getSharedPreferences("ssot_settings", Context.MODE_PRIVATE); }
    synchronized boolean configured() { return preferences.contains("encrypted_config"); }
    synchronized void save(String raw) {
        JSONObject config = validate(raw);
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key());
            String encrypted = Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP) + "."
                + Base64.encodeToString(cipher.doFinal(config.toString().getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
            if (!preferences.edit().putString("encrypted_config", encrypted).commit()) throw new Exception();
        } catch (Exception failure) { throw new IllegalStateException("공유 연결 정보를 기기 보안 저장소에 저장하지 못했습니다."); }
    }
    synchronized JSONObject credentials() {
        if (!configured()) throw new IllegalStateException("공유 서버가 연결되지 않았습니다.");
        try {
            String[] parts = preferences.getString("encrypted_config", "").split("\\.");
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)));
            return new JSONObject(new String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), StandardCharsets.UTF_8));
        } catch (Exception failure) { throw new IllegalStateException("공유 연결 정보를 복원하지 못했습니다. 다시 연결해 주세요."); }
    }
    static JSONObject validate(String raw) {
        try {
            if (raw == null || raw.length() > 16000) throw new Exception();
            JSONObject input = new JSONObject(raw);
            URI url = new URI(input.getString("url"));
            if (!"https".equals(url.getScheme()) || url.getHost() == null
                || !url.getHost().matches("[a-z0-9]{20}\\.supabase\\.co") || url.getUserInfo() != null
                || url.getPort() != -1 || url.getQuery() != null || url.getFragment() != null
                || !(url.getPath().isEmpty() || url.getPath().equals("/"))) throw new Exception();
            String key = input.getString("publishableKey");
            boolean accepted = key.startsWith("sb_publishable_") && key.length() >= 30;
            if (!accepted && key.split("\\.").length == 3) {
                JSONObject payload = new JSONObject(new String(Base64.decode(key.split("\\.")[1], Base64.URL_SAFE | Base64.NO_WRAP), StandardCharsets.UTF_8));
                accepted = "anon".equals(payload.optString("role"));
            }
            String email = input.getString("email"), password = input.getString("password");
            String device = UUID.fromString(input.getString("deviceId")).toString();
            if (!accepted || key.length() > 4096 || key.matches("(?s).*\\s.*") || !email.contains("@")
                || email.length() > 320 || password.length() < 16 || password.length() > 1024) throw new Exception();
            return TaskStore.object("url", "https://" + url.getHost(), "publishableKey", key,
                "email", email, "password", password, "deviceId", device);
        } catch (Exception failure) { throw new IllegalArgumentException("공유 연결 정보 형식이 올바르지 않습니다. Supabase 프로젝트 주소와 기기 전용 연결 정보가 필요합니다."); }
    }
    private SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if (store.containsAlias(ALIAS)) return ((KeyStore.SecretKeyEntry) store.getEntry(ALIAS, null)).getSecretKey();
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
}
