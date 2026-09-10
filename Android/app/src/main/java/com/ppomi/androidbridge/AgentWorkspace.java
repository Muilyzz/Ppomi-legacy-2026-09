package com.ppomi.androidbridge;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.Comparator;
import java.util.stream.Stream;

/** Only explicit file tools write here; no dialogue or automatic session checkpoint files. */
final class AgentWorkspace {
    static final int LIMIT = 128 * 1024;
    private final Path root;
    AgentWorkspace(Context context) { this(new File(context.getFilesDir(), "AgentWorkspace").toPath()); }
    AgentWorkspace(Path path) {
        root = path.toAbsolutePath().normalize();
    }
    private Path resolve(String raw, boolean rootAllowed) throws Exception {
        String relative = VoiceBridgePolicy.relativePath(raw, rootAllowed);
        if (Files.isSymbolicLink(root)) throw new IllegalArgumentException("심볼릭 링크는 사용할 수 없습니다.");
        Files.createDirectories(root);
        Path result = relative.isEmpty() ? root : root.resolve(relative).normalize();
        if (!result.startsWith(root)) throw new IllegalArgumentException("작업 폴더 밖에는 접근할 수 없습니다.");
        Path current = root;
        for (Path part : root.relativize(result)) {
            current = current.resolve(part);
            if (Files.isSymbolicLink(current)) throw new IllegalArgumentException("심볼릭 링크는 사용할 수 없습니다.");
        }
        return result;
    }
    synchronized JSONObject list(String path) throws Exception {
        Path directory = resolve(path, true);
        if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) throw new IllegalArgumentException("작업 폴더를 찾을 수 없습니다.");
        JSONArray entries = new JSONArray();
        try (Stream<Path> children = Files.list(directory)) {
            for (Path child : (Iterable<Path>) children.sorted(Comparator.comparing(p -> p.getFileName().toString())).limit(201)::iterator) {
                if (entries.length() >= 200) return TaskStore.object("entries", entries, "truncated", true);
                if (Files.isSymbolicLink(child)) continue;
                entries.put(TaskStore.object("path", root.relativize(child).toString(),
                    "type", Files.isDirectory(child, LinkOption.NOFOLLOW_LINKS) ? "directory" : "file",
                    "bytes", Files.isRegularFile(child, LinkOption.NOFOLLOW_LINKS) ? Files.size(child) : 0));
            }
        }
        return TaskStore.object("entries", entries, "truncated", false);
    }
    synchronized JSONObject read(String path) throws Exception {
        Path file = resolve(path, false);
        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) || Files.size(file) > LIMIT)
            throw new IllegalArgumentException("128 KiB 이하의 UTF-8 작업 파일만 읽을 수 있습니다.");
        byte[] bytes = Files.readAllBytes(file);
        if (bytes.length > LIMIT) throw new IllegalArgumentException("작업 파일이 너무 큽니다.");
        String content = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
        return TaskStore.object("path", path, "content", content, "sha256", hash(bytes));
    }
    synchronized JSONObject write(String path, String content) throws Exception {
        byte[] bytes = content.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > LIMIT) throw new IllegalArgumentException("128 KiB 이하만 저장할 수 있습니다.");
        Path destination = resolve(path, false);
        Files.createDirectories(destination.getParent());
        resolve(path, false);
        Path temporary = Files.createTempFile(destination.getParent(), ".write-", ".tmp");
        try {
            Files.write(temporary, bytes);
            Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            JSONObject observed = read(path);
            if (!hash(bytes).equals(observed.getString("sha256"))) throw new IllegalStateException("저장 결과를 확인하지 못했습니다.");
            return TaskStore.object("path", path, "bytes", bytes.length, "sha256", observed.getString("sha256"), "verified", true);
        } finally { Files.deleteIfExists(temporary); }
    }
    private static String hash(byte[] bytes) throws Exception {
        StringBuilder text = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(bytes)) text.append(String.format("%02x", value & 255));
        return text.toString();
    }
}
