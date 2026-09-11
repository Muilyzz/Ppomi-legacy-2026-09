package com.ppomi.androidbridge;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.util.Arrays;
import java.util.Base64;

/** No device, real endpoint, persistent app state, or private signing key is used. */
public final class FamilyWebUpdatesTest {
    private static KeyPair key;
    private static FamilyWebPackage.Config config;
    interface Checked { void run() throws Exception; }
    public static void main(String[] args) throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1")); key = generator.generateKeyPair();
        config = config(rawKey((ECPublicKey) key.getPublic()), "preview", "https://example.invalid/preview.json");
        if (args.length == 1) {
            Path fixtures = new File(args[0]).toPath();
            String publicKey = new String(Files.readAllBytes(fixtures.resolve("public-key.txt")), StandardCharsets.UTF_8).trim();
            FamilyWebPackage.Config fixtureConfig = config(publicKey, "preview", "https://example.invalid/preview.json");
            equal(42, FamilyWebPackage.verify(Files.readAllBytes(fixtures.resolve("valid-android.json")), fixtureConfig).sequence);
            reject(() -> FamilyWebPackage.verify(Files.readAllBytes(fixtures.resolve("tampered.json")), fixtureConfig));
        }
        verifyAndReject();
        lifecycle();
        System.out.println("Family web update signature, bounds, path and cold-launch rollback tests passed");
    }
    private static void verifyAndReject() throws Exception {
        byte[] valid = signed(payload(1, ""));
        equal("release-1", FamilyWebPackage.verify(valid, config).release);
        byte[] changed = valid.clone(); changed[changed.length / 3] ^= 1;
        reject(() -> FamilyWebPackage.verify(changed, config));
        reject(() -> FamilyWebPackage.verify(valid, config(rawKey((ECPublicKey) key.getPublic()), "family", "https://example.invalid/preview.json")));
        for (String endpoint : Arrays.asList("http://example.invalid/a", "https://user:password@example.invalid/a", "https://example.invalid/a?key=x", "https://example.invalid/a#x"))
            reject(() -> config(rawKey((ECPublicKey) key.getPublic()), "preview", endpoint));
        for (String path : Arrays.asList("../bad.js", "/bad.js", "Agent/../bad.js", "Agent/%2e%2e/a.js", "Agent/./a.js", "Agent//a.js", "Agent/한글.js", "Agent/a.exe", "Agent/a\\b.js"))
            reject(() -> FamilyWebPackage.verify(signed(payload(2, "," + file(path, new byte[0]))), config));
        for (String path : Arrays.asList("agent/APP.JS", "Agent/app.js/child.json"))
            reject(() -> FamilyWebPackage.verify(signed(payload(2, "," + file(path, new byte[0]))), config));
        for (String bad : Arrays.asList(
            payload(2, "").replace("\"platform\":\"android\"", "\"platform\":\"ipad\""),
            payload(2, "").replace("\"bridgeVersion\":1", "\"bridgeVersion\":2"),
            payload(2, "").replace("\"minNativeBuild\":1", "\"minNativeBuild\":2"),
            payload(2, "").replace("\"sequence\":2", "\"sequence\":2147483648"),
            payload(2, "").replace("\"sequence\":2", "\"sequence\":2.0"),
            payload(2, "").replace("\"formatVersion\":1", "\"formatVersion\":1,\"formatVersion\":1"),
            payload(2, "").replace("\"formatVersion\":1", "\"formatVersion\":1,\"extra\":true"),
            payload(2, "").replace("\"agent.v1\"", "\"agent.v2\""),
            payload(2, "").replace("Agent/index.html", "Agent/other.html"),
            payload(2, "").replace("\"sha256\":\"", "\"sha256\":\"a")))
            reject(() -> FamilyWebPackage.verify(signed(bad), config));
        reject(() -> FamilyWebPackage.verify(signed(payload(2, "," + file("large.js", new byte[FamilyWebPackage.MAX_FILE + 1]))), config));
        StringBuilder tooMany = new StringBuilder();
        for (int index = 0; index < 509; index++) tooMany.append(',').append(file("extra" + index + ".js", new byte[0]));
        reject(() -> FamilyWebPackage.verify(signed(payload(2, tooMany.toString())), config));
        reject(() -> FamilyWebPackage.decode("YQ", 10));
        reject(() -> FamilyWebPackage.decode("YR==", 10));
    }
    private static void lifecycle() throws Exception {
        Path temporary = Files.createTempDirectory("ppomi-family-update-test-");
        try {
            File storage = temporary.toFile();
            FamilyWebStore first = new FamilyWebStore(storage, config);
            equal("bundled", first.beginLaunch().release);
            yes(first.stage(signed(payload(1, ""))));
            no(first.stage(signed(payload(1, ""))));
            FamilyWebStore second = new FamilyWebStore(storage, config);
            FamilyWebStore.Selection one = second.beginLaunch();
            equal("release-1", one.release); yes(one.trial);
            yes(second.stage(signed(payload(2, ""))));
            yes(new File(one.root, "Agent/app.js").isFile()); // Staging cannot change or delete the process-pinned root.
            second.ready();
            FamilyWebStore third = new FamilyWebStore(storage, config);
            equal("release-2", third.beginLaunch().release);
            third.failedStartup(); reject(third::ready);
            FamilyWebStore fourth = new FamilyWebStore(storage, config);
            equal("release-1", fourth.beginLaunch().release);
            no(fourth.stage(signed(payload(2, "")))); // Failed candidates remain below the accepted sequence floor.
            yes(fourth.stage(signed(payload(3, ""))));
            FamilyWebStore fifth = new FamilyWebStore(storage, config);
            FamilyWebStore.Selection three = fifth.beginLaunch(); equal("release-3", three.release); fifth.ready();
            Files.write(new File(three.root, "Agent/app.js").toPath(), new byte[]{0});
            FamilyWebStore sixth = new FamilyWebStore(storage, config);
            equal("release-1", sixth.beginLaunch().release); // Corruption rolls back the entire release.
            no(sixth.stage(signed(payload(3, ""))));
            FamilyWebPackage.Config otherChannel = config(rawKey((ECPublicKey) key.getPublic()), "family", "https://example.invalid/preview.json");
            FamilyWebStore other = new FamilyWebStore(storage, otherChannel);
            equal("bundled", other.beginLaunch().release);
            yes(other.stage(signed(payload(1, "").replace("\"preview\"", "\"family\""))));
            Path state = temporary.resolve(config.namespace).resolve("state.properties");
            Files.write(state, "corrupt".getBytes(StandardCharsets.UTF_8));
            reject(() -> new FamilyWebStore(storage, config).beginLaunch());
        } finally { remove(temporary); }
        Path unconfirmed = Files.createTempDirectory("ppomi-family-unconfirmed-test-");
        try {
            FamilyWebStore first = new FamilyWebStore(unconfirmed.toFile(), config); first.beginLaunch(); first.stage(signed(payload(1, "")));
            FamilyWebStore trial = new FamilyWebStore(unconfirmed.toFile(), config); equal("release-1", trial.beginLaunch().release);
            FamilyWebStore rollback = new FamilyWebStore(unconfirmed.toFile(), config); equal("bundled", rollback.beginLaunch().release);
            no(rollback.stage(signed(payload(1, ""))));
        } finally { remove(unconfirmed); }
    }
    private static String payload(int sequence, String extra) throws Exception {
        return "{\"formatVersion\":1,\"release\":\"release-" + sequence + "\",\"sequence\":" + sequence
            + ",\"channel\":\"preview\",\"platform\":\"android\",\"bridgeVersion\":1,\"minNativeBuild\":1,\"capabilities\":[\"agent.v1\"],\"files\":["
            + file("Agent/index.html", "<html>test</html>".getBytes(StandardCharsets.UTF_8)) + ","
            + file("Agent/app.js", "/* synthetic */".getBytes(StandardCharsets.UTF_8)) + ","
            + file("Agent/app.css", new byte[0]) + "," + file("playbooks.json", "{}".getBytes(StandardCharsets.UTF_8)) + extra + "]}";
    }
    private static String file(String path, byte[] bytes) throws Exception {
        return "{\"path\":\"" + path.replace("\\", "\\\\") + "\",\"sha256\":\"" + FamilyWebPackage.sha256(bytes) + "\",\"data\":\"" + Base64.getEncoder().encodeToString(bytes) + "\"}";
    }
    private static byte[] signed(String payload) throws Exception {
        byte[] bytes = payload.getBytes(StandardCharsets.UTF_8);
        Signature signer = Signature.getInstance("SHA256withECDSA"); signer.initSign(key.getPrivate()); signer.update(bytes);
        return ("{\"payload\":\"" + Base64.getEncoder().encodeToString(bytes) + "\",\"signature\":\"" + Base64.getEncoder().encodeToString(signer.sign()) + "\"}").getBytes(StandardCharsets.UTF_8);
    }
    private static FamilyWebPackage.Config config(String key, String channel, String endpoint) throws Exception {
        return new FamilyWebPackage.Config(("{\"formatVersion\":1,\"endpoint\":\"" + endpoint + "\",\"publicKey\":\"" + key + "\",\"channel\":\"" + channel + "\"}").getBytes(StandardCharsets.UTF_8));
    }
    private static String rawKey(ECPublicKey key) {
        byte[] raw = new byte[65]; raw[0] = 4;
        byte[] x = key.getW().getAffineX().toByteArray(), y = key.getW().getAffineY().toByteArray();
        System.arraycopy(x, Math.max(0, x.length - 32), raw, 1 + Math.max(0, 32 - x.length), Math.min(x.length, 32));
        System.arraycopy(y, Math.max(0, y.length - 32), raw, 33 + Math.max(0, 32 - y.length), Math.min(y.length, 32));
        return Base64.getEncoder().encodeToString(raw);
    }
    private static void remove(Path path) throws Exception {
        if (Files.isDirectory(path)) try (java.nio.file.DirectoryStream<Path> children = Files.newDirectoryStream(path)) { for (Path child : children) remove(child); }
        Files.delete(path);
    }
    private static void equal(Object expected, Object actual) { if (!expected.equals(actual)) throw new AssertionError(expected + " != " + actual); }
    private static void yes(boolean value) { if (!value) throw new AssertionError("Expected true"); }
    private static void no(boolean value) { if (value) throw new AssertionError("Expected false"); }
    private static void reject(Checked operation) throws Exception {
        try { operation.run(); } catch (Exception expected) { return; }
        throw new AssertionError("Expected rejection");
    }
}
