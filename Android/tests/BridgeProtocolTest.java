package com.ppomi.androidbridge;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** No Android/JUnit dependency: checks auth, base scope, device classification and HTTP framing. */
public final class BridgeProtocolTest {
    private static int assertions;
    public static void main(String[] args) throws Exception {
        String token = "A".repeat(43);
        check(BridgePolicy.authorized(token, "Bearer " + token), "valid bearer token");
        check(!BridgePolicy.authorized(token, "Bearer " + "B".repeat(43)), "wrong bearer token");
        check(!BridgePolicy.authorized("", "Bearer "), "empty token denied");
        check(!BridgePolicy.authorized(token, null), "missing token denied");
        check(!BridgePolicy.validToken("A".repeat(31)), "short provisioning token denied");
        check(!BridgePolicy.validToken("A".repeat(33) + "\n"), "newline token denied");
        check(BridgePolicy.isEmulator("ranchu", "google/sdk_gphone64_arm64/emulator", "sdk_gphone64_arm64"), "emulator accepted");
        check(!BridgePolicy.isEmulator("tensor", "google/husky", "Pixel 8 Pro"), "physical device is not classified as emulator");
        BridgePolicy.requireAllowedPackage("com.ppomi.androidtarget");
        try { BridgePolicy.requireAllowedPackage("com.example.bank"); throw new AssertionError("Other package allowed"); }
        catch (IllegalArgumentException expected) { assertions++; }
        String body = "{\"text\":\"안드로이드 🤖\"}";
        HttpRequest parsed = parse("POST /mcp HTTP/1.1\r\nContent-Length: " + body.getBytes(StandardCharsets.UTF_8).length
            + "\r\nAuthorization: Bearer " + token + "\r\n\r\n" + body);
        check(parsed.body.equals(body), "UTF-8 byte length framing");
        check(parsed.headers.get("authorization").equals("Bearer " + token), "case-insensitive header names");
        check(parsed.method.equals("POST") && parsed.path.equals("/mcp"), "request line");
        reject("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 3\r\n\r\n{}");
        reject("POST /mcp HTTP/1.1\r\nContent-Length: 65537\r\n\r\n");
        reject("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n");
        reject("POST /mcp HTTP/1.1\r\nContent-Length: NaN\r\n\r\n");
        reject("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}");
        reject("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n");
        reject("POST /mcp HTTP/1.1\r\nX-Large: " + "x".repeat(17000) + "\r\n\r\n");
        reject("POST /mcp HTTP/1.1\r\nIncomplete: yes");
        System.out.println("PASS: " + assertions + " bridge protocol/policy assertions");
    }

    private static HttpRequest parse(String request) throws IOException {
        return HttpRequest.read(new ByteArrayInputStream(request.getBytes(StandardCharsets.UTF_8)));
    }
    private static void reject(String request) throws Exception {
        try { parse(request); throw new AssertionError("Malformed request was accepted"); }
        catch (IOException expected) { assertions++; }
    }
    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
        assertions++;
    }
}
