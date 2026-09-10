package com.ppomi.androidbridge;

import java.net.URI;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/** Pure validation shared by the native voice host and off-device boundary tests. */
final class VoiceBridgePolicy {
    static final String ORIGIN = "https://appassets.androidplatform.net";
    static final String ENTRY = ORIGIN + "/assets/agent/index.html";
    static final Set<String> PATHS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
        "/v1/session", "/v1/memories/list", "/v1/memories/save", "/v1/memories/delete")));
    static String endpoint(String raw) {
        try {
            URI uri = new URI(raw == null ? "" : raw.trim());
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                || uri.getUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null
                || uri.getHost().equalsIgnoreCase("appassets.androidplatform.net")
                || (uri.getPort() != -1 && (uri.getPort() < 1 || uri.getPort() > 65535))) throw new Exception();
            String path = uri.getRawPath();
            if (path != null && (path.contains("%") || path.contains("..") || path.contains("\\"))) throw new Exception();
            return uri.toASCIIString().replaceAll("/+$", "");
        } catch (Exception failure) { throw new IllegalArgumentException("HTTPS 음성 서버 주소를 입력해 주세요."); }
    }
    static boolean trustedEntry(String raw) { return ENTRY.equals(raw); }
    static boolean bundledAsset(String raw) {
        try {
            URI uri = new URI(raw);
            String path = uri.getRawPath();
            return "https".equals(uri.getScheme()) && "appassets.androidplatform.net".equals(uri.getHost())
                && uri.getPort() == -1 && uri.getUserInfo() == null && uri.getRawQuery() == null
                && uri.getRawFragment() == null && path != null && path.startsWith("/assets/agent/")
                && !path.contains("%") && !path.contains("..") && !path.contains("\\");
        } catch (Exception failure) { return false; }
    }
    static boolean realtimeSignaling(String raw, String method) {
        return ("POST".equals(method) || "OPTIONS".equals(method))
            && "https://api.openai.com/v1/realtime/calls".equals(raw);
    }
    static boolean realtimeWebSocket(String raw, String method) {
        if (!"GET".equals(method)) return false;
        try {
            URI uri = new URI(raw);
            return "wss".equals(uri.getScheme()) && "api.openai.com".equals(uri.getHost())
                && uri.getPort() == -1 && uri.getUserInfo() == null && uri.getRawFragment() == null
                && "/v1/realtime".equals(uri.getRawPath()) && uri.getRawQuery() != null
                && uri.getRawQuery().matches("model=[A-Za-z0-9._-]{1,120}");
        } catch (Exception failure) { return false; }
    }
    static String storeQuery(String raw) {
        String query = raw == null ? "" : raw.trim();
        if (query.isEmpty() || query.length() > 160 || query.startsWith("//")
            || query.matches("(?is).*[a-z][a-z0-9+.-]*://.*")
            || query.matches("(?is)^(https?|market|intent|javascript|file|content|data):.*"))
            throw new IllegalArgumentException("Invalid store search");
        for (int index = 0; index < query.length(); index++)
            if (Character.isISOControl(query.charAt(index))) throw new IllegalArgumentException("Invalid store search");
        return query;
    }
    static String relativePath(String raw, boolean rootAllowed) {
        if (raw == null || raw.isEmpty()) {
            if (rootAllowed) return "";
            throw new IllegalArgumentException("파일 경로가 필요합니다.");
        }
        if (raw.length() > 240 || raw.startsWith("/") || raw.contains("\\") || raw.contains("\u0000")
            || raw.contains(":")) throw new IllegalArgumentException("작업 폴더 안의 상대 경로만 사용할 수 있습니다.");
        for (String part : raw.split("/", -1))
            if (part.isEmpty() || part.equals(".") || part.equals(".."))
                throw new IllegalArgumentException("잘못된 작업 파일 경로입니다.");
        return raw;
    }
}
