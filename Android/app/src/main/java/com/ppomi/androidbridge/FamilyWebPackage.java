package com.ppomi.androidbridge;

import java.math.BigInteger;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.AlgorithmParameters;
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** Signed, bounded data-only transport. No network or Android dependencies, so validation runs off-device. */
final class FamilyWebPackage {
    static final int MAX_ENVELOPE = 32 * 1024 * 1024;
    static final int MAX_TOTAL = 16 * 1024 * 1024;
    static final int MAX_FILE = 8 * 1024 * 1024;
    static final int BRIDGE_VERSION = 1;
    static final int NATIVE_BUILD = 1;
    static final Set<String> REQUIRED = new HashSet<>(Arrays.asList(
        "Agent/index.html", "Agent/app.js", "Agent/app.css", "playbooks.json"));
    private static final Set<String> EXTENSIONS = new HashSet<>(Arrays.asList(
        "html", "js", "css", "json", "woff2", "png", "jpg", "jpeg", "svg", "webp"));

    static final class Config {
        final URI endpoint;
        final PublicKey key;
        final String channel;
        final String namespace;
        Config(byte[] bytes) throws Exception {
            require(bytes.length <= 8192);
            Map<String, Object> data = object(Json.parse(bytes));
            keys(data, "formatVersion", "endpoint", "publicKey", "channel");
            require(integer(data, "formatVersion") == 1);
            endpoint = new URI(string(data, "endpoint"));
            require("https".equals(endpoint.getScheme()) && endpoint.getHost() != null
                && endpoint.getUserInfo() == null && endpoint.getRawQuery() == null && endpoint.getRawFragment() == null
                && (endpoint.getPort() == -1 || (endpoint.getPort() > 0 && endpoint.getPort() <= 65535)));
            channel = string(data, "channel");
            require(channel.equals("preview") || channel.equals("family"));
            byte[] raw = decode(string(data, "publicKey"), 65);
            require(raw.length == 65 && raw[0] == 4);
            AlgorithmParameters parameters = AlgorithmParameters.getInstance("EC");
            parameters.init(new ECGenParameterSpec("secp256r1"));
            ECParameterSpec spec = parameters.getParameterSpec(ECParameterSpec.class);
            key = KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(new ECPoint(
                new BigInteger(1, Arrays.copyOfRange(raw, 1, 33)),
                new BigInteger(1, Arrays.copyOfRange(raw, 33, 65))), spec));
            namespace = sha256((string(data, "publicKey") + "\n" + channel + "\n" + endpoint).getBytes(StandardCharsets.UTF_8));
        }
    }

    final String release;
    final int sequence;
    final Map<String, byte[]> files;
    final byte[] envelope;
    final String directory;

    private FamilyWebPackage(String release, int sequence, Map<String, byte[]> files, byte[] envelope) throws Exception {
        this.release = release;
        this.sequence = sequence;
        this.files = files;
        this.envelope = envelope;
        directory = sequence + "-" + sha256(envelope);
    }

    static FamilyWebPackage verify(byte[] bytes, Config config) throws Exception {
        require(bytes.length <= MAX_ENVELOPE);
        Map<String, Object> wrapper = object(Json.parse(bytes));
        keys(wrapper, "payload", "signature");
        byte[] payload = decode(string(wrapper, "payload"), MAX_ENVELOPE);
        byte[] signature = decode(string(wrapper, "signature"), 80);
        Signature verifier = Signature.getInstance("SHA256withECDSA");
        verifier.initVerify(config.key);
        verifier.update(payload);
        require(verifier.verify(signature));
        Map<String, Object> data = object(Json.parse(payload));
        keys(data, "formatVersion", "release", "sequence", "channel", "platform", "bridgeVersion", "minNativeBuild", "capabilities", "files");
        require(integer(data, "formatVersion") == 1 && integer(data, "bridgeVersion") == BRIDGE_VERSION);
        require(integer(data, "minNativeBuild") > 0 && integer(data, "minNativeBuild") <= NATIVE_BUILD);
        require(string(data, "platform").equals("android") && string(data, "channel").equals(config.channel));
        String release = string(data, "release");
        require(release.matches("[a-z0-9][a-z0-9._-]{0,63}"));
        int sequence = integer(data, "sequence");
        require(sequence > 0);
        require(list(data.get("capabilities")).equals(Arrays.asList("agent.v1")));
        List<?> entries = list(data.get("files"));
        require(entries.size() >= REQUIRED.size() && entries.size() <= 512);
        Map<String, byte[]> files = new LinkedHashMap<>();
        Set<String> names = new HashSet<>();
        int total = 0;
        for (Object entry : entries) {
            Map<String, Object> file = object(entry);
            keys(file, "path", "sha256", "data");
            String path = string(file, "path");
            safePath(path);
            String lower = path.toLowerCase(Locale.ROOT);
            require(names.add(lower));
            String hash = string(file, "sha256");
            require(hash.matches("[a-f0-9]{64}"));
            byte[] contents = decode(string(file, "data"), MAX_FILE);
            total += contents.length;
            require(total <= MAX_TOTAL && sha256(contents).equals(hash));
            files.put(path, contents);
        }
        require(files.keySet().containsAll(REQUIRED));
        for (String path : names) {
            for (int slash = path.indexOf('/'); slash >= 0; slash = path.indexOf('/', slash + 1))
                require(!names.contains(path.substring(0, slash)));
        }
        return new FamilyWebPackage(release, sequence, files, bytes.clone());
    }

    static void safePath(String path) {
        require(!path.isEmpty() && path.length() <= 240);
        for (String part : path.split("/", -1)) require(part.matches("[A-Za-z0-9_-][A-Za-z0-9._-]*"));
        int dot = path.lastIndexOf('.');
        require(dot > path.lastIndexOf('/') && EXTENSIONS.contains(path.substring(dot + 1).toLowerCase(Locale.ROOT)));
    }
    static byte[] decode(String text, int maximum) {
        require(text.length() <= ((maximum + 2L) / 3) * 4 && text.length() % 4 == 0);
        byte[] bytes = Base64.getDecoder().decode(text);
        require(bytes.length <= maximum && Base64.getEncoder().encodeToString(bytes).equals(text));
        return bytes;
    }
    static String sha256(byte[] data) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(data);
        StringBuilder value = new StringBuilder(64);
        for (byte b : digest) value.append(String.format(Locale.ROOT, "%02x", b & 255));
        return value.toString();
    }
    static void require(boolean value) { if (!value) throw new IllegalArgumentException("Invalid family update"); }
    @SuppressWarnings("unchecked") static Map<String, Object> object(Object value) {
        require(value instanceof Map); return (Map<String, Object>) value;
    }
    static List<?> list(Object value) { require(value instanceof List); return (List<?>) value; }
    static String string(Map<String, Object> map, String key) {
        require(map.get(key) instanceof String); return (String) map.get(key);
    }
    static int integer(Map<String, Object> map, String key) {
        Object value = map.get(key);
        require(value instanceof Long && (Long) value >= 0 && (Long) value <= Integer.MAX_VALUE);
        return ((Long) value).intValue();
    }
    static void keys(Map<String, Object> map, String... keys) { require(map.keySet().equals(new HashSet<>(Arrays.asList(keys)))); }

    /** Strict JSON: duplicate keys, malformed UTF-8, excessive depth, and fractional numbers are rejected. */
    static final class Json {
        private final String text;
        private int at;
        private Json(String text) { this.text = text; }
        static Object parse(byte[] bytes) throws Exception {
            String text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
            Json parser = new Json(text);
            Object result = parser.value(0);
            parser.space(); require(parser.at == text.length()); return result;
        }
        private void space() { while (at < text.length() && " \t\r\n".indexOf(text.charAt(at)) >= 0) at++; }
        private boolean take(char c) { space(); if (at < text.length() && text.charAt(at) == c) { at++; return true; } return false; }
        private Object value(int depth) {
            require(depth < 24); space(); require(at < text.length());
            if (take('{')) {
                Map<String, Object> result = new LinkedHashMap<>();
                if (take('}')) return result;
                do { String key = quoted(); require(take(':') && !result.containsKey(key)); result.put(key, value(depth + 1)); } while (take(','));
                require(take('}')); return result;
            }
            if (take('[')) {
                List<Object> result = new ArrayList<>();
                if (take(']')) return result;
                do { require(result.size() < 1024); result.add(value(depth + 1)); } while (take(','));
                require(take(']')); return result;
            }
            if (text.charAt(at) == '"') return quoted();
            if (text.startsWith("true", at)) { at += 4; return true; }
            if (text.startsWith("false", at)) { at += 5; return false; }
            if (text.startsWith("null", at)) { at += 4; return null; }
            int start = at;
            if (text.charAt(at) == '-') at++;
            require(at < text.length());
            if (text.charAt(at) == '0') at++;
            else { require(text.charAt(at) >= '1' && text.charAt(at) <= '9'); while (at < text.length() && text.charAt(at) >= '0' && text.charAt(at) <= '9') at++; }
            return Long.parseLong(text.substring(start, at));
        }
        private String quoted() {
            require(take('"')); StringBuilder result = new StringBuilder();
            while (at < text.length()) {
                char c = text.charAt(at++);
                if (c == '"') return result.toString();
                require(c >= 32);
                if (c == '\\') {
                    require(at < text.length()); c = text.charAt(at++);
                    switch (c) {
                        case '"': case '\\': case '/': result.append(c); break;
                        case 'b': result.append('\b'); break;
                        case 'f': result.append('\f'); break;
                        case 'n': result.append('\n'); break;
                        case 'r': result.append('\r'); break;
                        case 't': result.append('\t'); break;
                        case 'u':
                            require(at + 4 <= text.length());
                            String digits = text.substring(at, at + 4); require(digits.matches("[a-fA-F0-9]{4}"));
                            result.append((char) Integer.parseInt(digits, 16)); at += 4; break;
                        default: throw new IllegalArgumentException("Invalid JSON escape");
                    }
                } else result.append(c);
            }
            throw new IllegalArgumentException("Unclosed JSON string");
        }
    }
}
