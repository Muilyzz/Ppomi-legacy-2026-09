package com.ppomi.androidbridge;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.IOException;
import java.io.OutputStream;
import java.io.File;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import android.util.Base64;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** MCP HTTP subset, isolated to the device's loopback interface. */
final class LocalMcpServer implements AutoCloseable {
    private final BridgeAccessibilityService service;
    private final ThreadPoolExecutor workers = new ThreadPoolExecutor(2, 2, 0, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(4), new ThreadPoolExecutor.AbortPolicy());
    private volatile boolean open;
    private volatile boolean closed;
    private volatile ServerSocket listener;

    LocalMcpServer(BridgeAccessibilityService service) { this.service = service; }
    boolean running() { return open; }

    void start() {
        new Thread(() -> {
            try {
                listener = new ServerSocket(BridgePolicy.PORT, 8, InetAddress.getByName("127.0.0.1"));
                if (closed) { listener.close(); return; }
                open = true;
                while (open) {
                    Socket client = listener.accept();
                    try { workers.execute(() -> handle(client)); }
                    catch (RuntimeException full) { client.close(); }
                }
            } catch (IOException failure) {
                android.util.Log.w("PpomiBridge", "MCP listener stopped: " + failure.getClass().getSimpleName());
            } finally { open = false; }
        }, "ppomi-mcp-listener").start();
    }

    private void handle(Socket client) {
        try (client) {
            client.setSoTimeout(5000);
            try {
                HttpRequest request = HttpRequest.read(client.getInputStream());
                if (request.headers.containsKey("origin")) { respond(client, 403, "{\"error\":\"Browser origins are unsupported\"}"); return; }
                if (!BridgePolicy.authorized(BridgeSession.token(service), request.headers.get("authorization"))) {
                    respond(client, 401, "{\"error\":\"Valid bearer token required\"}"); return;
                }
                if (!request.path.equals("/mcp")) { respond(client, 404, "{\"error\":\"Use /mcp\"}"); return; }
                if (!request.method.equals("POST")) { respond(client, 405, "{\"error\":\"Use POST\"}"); return; }
                if (!request.headers.getOrDefault("content-type", "").startsWith("application/json")) {
                    respond(client, 415, "{\"error\":\"Use application/json\"}"); return;
                }
                JSONObject rpc;
                try { rpc = new JSONObject(request.body); }
                catch (JSONException malformed) { respond(client, 200, error(JSONObject.NULL, -32700, "Parse error").toString()); return; }
                if (!"2.0".equals(rpc.optString("jsonrpc")) || !(rpc.opt("method") instanceof String)) {
                    respond(client, 200, error(rpc.opt("id"), -32600, "Invalid JSON-RPC request").toString()); return;
                }
                if (!rpc.has("id")) {
                    // Notifications carry no result and must never trigger a control action.
                    respond(client, 202, ""); return;
                }
                Object id = rpc.get("id");
                String method = rpc.getString("method");
                JSONObject result;
                switch (method) {
                    case "initialize":
                        result = new JSONObject().put("protocolVersion", "2024-11-05")
                            .put("capabilities", new JSONObject().put("tools", new JSONObject()))
                            .put("serverInfo", new JSONObject().put("name", "ppomi-android").put("version", "0.1.0"));
                        break;
                    case "ping": result = new JSONObject(); break;
                    case "tools/list": result = new JSONObject().put("tools", tools()); break;
                    case "tools/call": {
                        JSONObject params = rpc.optJSONObject("params");
                        if (params == null || !params.has("name")) {
                            respond(client, 200, error(id, -32602, "Tool name required").toString()); return;
                        }
                        try {
                            JSONObject args = params.optJSONObject("arguments");
                            String name = params.getString("name");
                            if ("screen".equals(name)) result = screenResult();
                            else {
                                JSONObject value = service.execute(name, args == null ? new JSONObject() : args);
                                result = toolResult(value, false);
                            }
                        } catch (Exception failure) {
                            Throwable cause = failure.getCause() == null ? failure : failure.getCause();
                            String message = cause.getMessage() == null ? cause.getClass().getSimpleName() : cause.getMessage();
                            result = toolResult(new JSONObject().put("error", message), true);
                        }
                        break;
                    }
                    default: respond(client, 200, error(id, -32601, "Method not found").toString()); return;
                }
                respond(client, 200, new JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", result).toString());
            } catch (Exception malformed) { respond(client, 400, "{\"error\":\"Invalid HTTP request\"}"); }
        } catch (IOException ignored) { /* disconnected clients have no effect on server lifetime */ }
    }

    private static JSONObject toolResult(JSONObject value, boolean failed) throws JSONException {
        return new JSONObject().put("content", new JSONArray().put(new JSONObject().put("type", "text").put("text", value.toString())))
            .put("structuredContent", value).put("isError", failed);
    }

    /** Image bytes appear once, as MCP image content; private capture files are transient. */
    private JSONObject screenResult() throws Exception {
        String id = UUID.randomUUID().toString();
        File capture = new File(service.getFilesDir(), "mcp-screens/" + id + ".png");
        try {
            JSONObject metadata = service.captureLocal(capture.getAbsolutePath(), null);
            if (capture.length() > 12 * 1024 * 1024) throw new IOException("Screenshot exceeds 12 MB response limit");
            String data = Base64.encodeToString(Files.readAllBytes(capture.toPath()), Base64.NO_WRAP);
            metadata.remove("path");
            metadata.put("screenshotId", id);
            return new JSONObject().put("isError", false).put("structuredContent", metadata)
                .put("content", new JSONArray()
                    .put(new JSONObject().put("type", "text").put("text", metadata.toString()))
                    .put(new JSONObject().put("type", "image").put("mimeType", "image/png").put("data", data)));
        } finally { capture.delete(); }
    }

    private static JSONObject error(Object id, int code, String message) throws JSONException {
        return new JSONObject().put("jsonrpc", "2.0").put("id", id == null ? JSONObject.NULL : id)
            .put("error", new JSONObject().put("code", code).put("message", message));
    }

    private static JSONArray tools() throws JSONException {
        JSONArray output = new JSONArray();
        add(output, "status", "Connection, allowed packages and last gesture completion. Gesture completion must be verified against a fresh screen.", new JSONObject());
        add(output, "ui_tree", "Read current allowed app UI. Node IDs expire on UI change, new snapshot, or after 30 seconds.", new JSONObject());
        add(output, "screen", "Capture the currently allowed foreground app through Android accessibility. Returns PNG image content and dimensions; requires Android 11 or later.", new JSONObject());
        add(output, "tap", "Tap screen pixel coordinates via Android AccessibilityService.", props("x", "number", "y", "number"), "x", "y");
        add(output, "swipe", "Swipe screen pixel coordinates via Android AccessibilityService.", props("x1", "number", "y1", "number", "x2", "number", "y2", "number", "durationMs", "integer"), "x1", "y1", "x2", "y2");
        add(output, "long_press", "Hold the visible center of a node from the latest ui_tree. holdMs: 400..1500, default 700. Poll gesture_status and verify the resulting screen.", props("nodeId", "string", "holdMs", "integer"), "nodeId");
        add(output, "long_press_drag", "Hold a fresh node and drag the same pointer to screen pixels, then hover and release. holdMs 400..1500 (700), dragMs 200..2000 (600), hoverMs 0..1500 (400). Poll gesture_status, then verify placement. Never blindly repeat a cancelled/uncertain move.", props("nodeId", "string", "x2", "number", "y2", "number", "holdMs", "integer", "dragMs", "integer", "hoverMs", "integer"), "nodeId", "x2", "y2");
        add(output, "gesture_status", "Read a retained gesture by ID, or the latest gesture. completed describes input delivery, not successful UI rearrangement.", props("gestureId", "string"));
        add(output, "cancel_gesture", "Request cancellation by gestureId. Held drags release at the next continuation boundary; an in-flight short gesture may finish. Inspect the screen before any retry.", props("gestureId", "string"), "gestureId");
        add(output, "click", "Click an enabled clickable node from latest ui_tree.", props("nodeId", "string"), "nodeId");
        add(output, "type_text", "Replace editable non-password node text, including Unicode.", props("nodeId", "string", "text", "string"), "nodeId", "text");
        add(output, "back", "Android system Back.", new JSONObject());
        add(output, "home", "Android system Home.", new JSONObject());
        add(output, "recents", "Android recent apps overview.", new JSONObject());
        add(output, "open_app", "Launch an installed allowlisted package. status lists the configured packages, including the default launcher when available.", props("packageName", "string"), "packageName");
        return output;
    }

    private static JSONObject props(String... fields) throws JSONException {
        JSONObject output = new JSONObject();
        for (int i = 0; i < fields.length; i += 2) output.put(fields[i], new JSONObject().put("type", fields[i + 1]));
        return output;
    }

    private static void add(JSONArray output, String name, String description, JSONObject properties, String... required) throws JSONException {
        JSONObject schema = new JSONObject().put("type", "object").put("properties", properties).put("additionalProperties", false);
        if (required.length > 0) schema.put("required", new JSONArray(required));
        output.put(new JSONObject().put("name", name).put("description", description).put("inputSchema", schema));
    }

    private static void respond(Socket client, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        String phrase = switch (status) { case 200 -> "OK"; case 202 -> "Accepted"; case 401 -> "Unauthorized";
            case 403 -> "Forbidden"; case 404 -> "Not Found"; case 405 -> "Method Not Allowed";
            case 415 -> "Unsupported Media Type"; default -> "Bad Request"; };
        OutputStream output = client.getOutputStream();
        output.write(("HTTP/1.1 " + status + " " + phrase + "\r\nContent-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: " + bytes.length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
        output.write(bytes); output.flush();
    }

    @Override public void close() {
        closed = true;
        open = false;
        if (listener != null) try { listener.close(); } catch (IOException ignored) {}
        workers.shutdownNow();
    }
}
