package com.ppomi.androidbridge;

/** Off-device assertions for the voice host's trust and file boundaries. */
public final class VoiceBridgePolicyTest {
    public static void main(String[] args) {
        equal("https://agent.example/api", VoiceBridgePolicy.endpoint(" https://agent.example/api/ "));
        for (String input : new String[] {"http://agent.example", "https://user:secret@agent.example", "https://agent.example?key=x",
            "https://agent.example/#secret", "https://appassets.androidplatform.net", "https://agent.example/a/../b",
            "https://agent.example/%2e%2e", "javascript:alert(1)"}) reject(() -> VoiceBridgePolicy.endpoint(input));
        yes(VoiceBridgePolicy.trustedEntry(VoiceBridgePolicy.ENTRY));
        no(VoiceBridgePolicy.trustedEntry(VoiceBridgePolicy.ENTRY + "#frame"));
        yes(VoiceBridgePolicy.bundledAsset(VoiceBridgePolicy.ORIGIN + "/assets/agent/app.js"));
        for (String url : new String[] {"https://appassets.androidplatform.net.evil.test/assets/agent/app.js",
            "https://appassets.androidplatform.net/assets/agent/../secret", "https://appassets.androidplatform.net/assets/agent/%2e%2e/secret",
            "https://appassets.androidplatform.net:443/assets/agent/app.js", "file:///android_asset/agent/index.html",
            "https://appassets.androidplatform.net/assets/agent/app.js?redirect=other"}) no(VoiceBridgePolicy.bundledAsset(url));
        yes(VoiceBridgePolicy.realtimeSignaling("https://api.openai.com/v1/realtime/calls", "POST"));
        yes(VoiceBridgePolicy.realtimeSignaling("https://api.openai.com/v1/realtime/calls", "OPTIONS"));
        no(VoiceBridgePolicy.realtimeSignaling("https://api.openai.com/v1/realtime/calls", "GET"));
        no(VoiceBridgePolicy.realtimeSignaling("https://api.openai.com/v1/realtime/calls/evil", "POST"));
        yes(VoiceBridgePolicy.realtimeWebSocket("wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1", "GET"));
        for (String url : new String[] {"ws://api.openai.com/v1/realtime?model=gpt-realtime", "wss://api.openai.com.evil.test/v1/realtime?model=x",
            "wss://api.openai.com/v1/realtime?model=x&key=y", "wss://api.openai.com/v1/realtime?model=x#fragment", "wss://api.openai.com/other?model=x"})
            no(VoiceBridgePolicy.realtimeWebSocket(url, "GET"));
        no(VoiceBridgePolicy.realtimeWebSocket("wss://api.openai.com/v1/realtime?model=gpt-realtime", "POST"));
        equal("어카운트인포", VoiceBridgePolicy.storeQuery("  어카운트인포  "));
        equal("com.example.confirmed.app", VoiceBridgePolicy.storeQuery("com.example.confirmed.app"));
        equal("앱 &c=books # ? + %", VoiceBridgePolicy.storeQuery("앱 &c=books # ? + %"));
        equal(new String(new char[160]).replace('\0', 'a'), VoiceBridgePolicy.storeQuery(new String(new char[160]).replace('\0', 'a')));
        for (String query : new String[] {null, "", "   ", "https://example.test", "market://details?id=other",
            "intent:other", "javascript:alert(1)", "//example.test", "name https://example.test", "앱\n이름", "a\u0000b",
            new String(new char[161]).replace('\0', 'a')}) reject(() -> VoiceBridgePolicy.storeQuery(query));
        equal("", VoiceBridgePolicy.relativePath("", true));
        equal("notes/할 일.txt", VoiceBridgePolicy.relativePath("notes/할 일.txt", false));
        for (String path : new String[] {"", "/tmp/secrets", "../secret", "notes/../../secret", "notes//x", ".", "notes/./x", "C:\\secret", "a\u0000b"})
            reject(() -> VoiceBridgePolicy.relativePath(path, false));
        System.out.println("Voice bridge boundary tests passed");
    }
    private static void equal(Object expected, Object actual) { if (!expected.equals(actual)) throw new AssertionError("Mismatch"); }
    private static void yes(boolean value) { if (!value) throw new AssertionError("Expected true"); }
    private static void no(boolean value) { if (value) throw new AssertionError("Expected false"); }
    private static void reject(Runnable operation) {
        try { operation.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Expected rejection");
    }
}
