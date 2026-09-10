package com.ppomi.androidbridge;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/** Deliberately bounded, one-request HTTP/1 parser. No chunked bodies or keep-alive. */
final class HttpRequest {
    static final int MAX_HEADER = 16 * 1024;
    static final int MAX_BODY = 64 * 1024;
    final String method;
    final String path;
    final Map<String, String> headers;
    final String body;

    private HttpRequest(String method, String path, Map<String, String> headers, String body) {
        this.method = method; this.path = path; this.headers = headers; this.body = body;
    }

    static HttpRequest read(InputStream input) throws IOException {
        ByteArrayOutputStream head = new ByteArrayOutputStream();
        int match = 0;
        int[] ending = {13, 10, 13, 10};
        while (match < 4) {
            int next = input.read();
            if (next < 0) throw new IOException("Truncated HTTP headers");
            head.write(next);
            if (head.size() > MAX_HEADER) throw new IOException("HTTP headers too large");
            match = next == ending[match] ? match + 1 : next == 13 ? 1 : 0;
        }
        String[] lines = head.toString(StandardCharsets.US_ASCII.name()).split("\r\n");
        String[] request = lines[0].split(" ", -1);
        if (request.length != 3 || !request[2].equals("HTTP/1.1")) throw new IOException("Invalid HTTP request line");
        Map<String, String> headers = new HashMap<>();
        for (int i = 1; i < lines.length; i++) {
            int colon = lines[i].indexOf(':');
            if (colon < 1) throw new IOException("Invalid HTTP header");
            String key = lines[i].substring(0, colon).toLowerCase(Locale.ROOT);
            if (headers.put(key, lines[i].substring(colon + 1).trim()) != null)
                throw new IOException("Duplicate HTTP header");
        }
        if (headers.containsKey("transfer-encoding")) throw new IOException("Chunked requests are unsupported");
        int length;
        try { length = Integer.parseInt(headers.getOrDefault("content-length", "0")); }
        catch (NumberFormatException invalid) { throw new IOException("Invalid content length"); }
        if (length < 0 || length > MAX_BODY) throw new IOException("HTTP body too large");
        byte[] body = new byte[length];
        int read = 0;
        while (read < length) {
            int count = input.read(body, read, length - read);
            if (count < 0) throw new IOException("Truncated HTTP body");
            read += count;
        }
        return new HttpRequest(request[0], request[1], headers, new String(body, StandardCharsets.UTF_8));
    }
}
