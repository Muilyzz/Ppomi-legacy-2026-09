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
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Explicitly configured provider only. Provider secrets never leave Android app-private storage. */
public final class AgentSettings {
    private static final String KEY_ALIAS = "ppomi.android.agent.provider.v1";
    private static AgentSettings instance;
    private final SharedPreferences preferences;

    private AgentSettings(Context context) { preferences = context.getSharedPreferences("agent_settings", Context.MODE_PRIVATE); }
    public static synchronized AgentSettings get(Context context) {
        if (instance == null) instance = new AgentSettings(context.getApplicationContext());
        return instance;
    }

    public synchronized JSONObject snapshot() {
        return TaskStore.object("endpoint", preferences.getString("endpoint", ""), "model", preferences.getString("model", ""),
            "hasApiKey", preferences.contains("encrypted_key"), "configured", configured());
    }

    public synchronized boolean configured() {
        return !preferences.getString("endpoint", "").isEmpty() && !preferences.getString("model", "").isEmpty()
            && preferences.contains("encrypted_key");
    }

    public synchronized void save(String endpoint, String model, String apiKey) {
        String normalized = normalizeEndpoint(endpoint);
        String modelName = model == null ? "" : model.trim();
        if (modelName.isEmpty() || modelName.length() > 200) throw new IllegalArgumentException("모델 이름을 입력해 주세요.");
        SharedPreferences.Editor editor = preferences.edit().putString("endpoint", normalized).putString("model", modelName);
        if (apiKey != null && !apiKey.trim().isEmpty()) {
            String secret = apiKey.trim();
            if (secret.length() > 4096 || secret.contains("\n") || secret.contains("\r")) throw new IllegalArgumentException("API 키 형식이 올바르지 않습니다.");
            editor.putString("encrypted_key", encrypt(secret));
        } else if (!preferences.contains("encrypted_key")) throw new IllegalArgumentException("API 키를 입력해 주세요.");
        else if (!normalized.equals(preferences.getString("endpoint", "")))
            throw new IllegalArgumentException("API 주소를 바꿀 때는 해당 제공자의 API 키를 다시 입력해 주세요.");
        if (!editor.commit()) throw new IllegalStateException("모델 설정을 저장하지 못했습니다.");
    }

    public synchronized void clear() {
        if (!preferences.edit().clear().commit()) throw new IllegalStateException("모델 설정을 지우지 못했습니다.");
    }

    synchronized String apiKey() {
        if (!configured()) throw new IllegalStateException("AI 모델을 먼저 연결해 주세요.");
        try {
            String[] parts = preferences.getString("encrypted_key", "").split("\\.");
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)));
            return new String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), StandardCharsets.UTF_8);
        } catch (Exception error) { throw new IllegalStateException("저장된 API 키를 복원하지 못했습니다. 다시 입력해 주세요."); }
    }

    static String normalizeEndpoint(String value) {
        try {
            URI uri = new URI(value == null ? "" : value.trim());
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null || uri.getUserInfo() != null
                || uri.getFragment() != null || uri.getQuery() != null) throw new IllegalArgumentException();
            String endpoint = uri.toString().replaceAll("/+$", "");
            return endpoint.endsWith("/chat/completions") ? endpoint : endpoint + "/chat/completions";
        } catch (Exception error) { throw new IllegalArgumentException("HTTPS 모델 API 주소를 입력해 주세요. 예: https://provider.example/v1"); }
    }

    private String encrypt(String value) {
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key());
            return Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP) + "."
                + Base64.encodeToString(cipher.doFinal(value.getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
        } catch (Exception error) { throw new IllegalStateException("Android 보안 저장소에 API 키를 저장하지 못했습니다."); }
    }

    private SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if (store.containsAlias(KEY_ALIAS)) return ((KeyStore.SecretKeyEntry) store.getEntry(KEY_ALIAS, null)).getSecretKey();
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
}
