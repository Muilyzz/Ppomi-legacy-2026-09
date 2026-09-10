package com.ppomi.androidbridge;

import android.test.AndroidTestCase;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.UUID;

public final class AgentWorkspaceTest extends AndroidTestCase {
    private Path root;
    private AgentWorkspace workspace;
    @Override protected void setUp() throws Exception {
        super.setUp();
        root = getContext().getCacheDir().toPath().resolve("voice-workspace-test-" + UUID.randomUUID());
        workspace = new AgentWorkspace(root);
    }
    @Override protected void tearDown() throws Exception {
        if (Files.exists(root)) try (var paths = Files.walk(root)) {
            for (Path path : (Iterable<Path>) paths.sorted(Comparator.reverseOrder())::iterator) Files.delete(path);
        }
        super.tearDown();
    }
    public void testUnicodeWriteReadbackAndReplacement() throws Exception {
        var saved = workspace.write("notes/result.txt", "검증된 결과 🍑\n");
        assertTrue(saved.getBoolean("verified"));
        assertEquals("검증된 결과 🍑\n", workspace.read("notes/result.txt").getString("content"));
        assertEquals(saved.getString("sha256"), workspace.read("notes/result.txt").getString("sha256"));
        workspace.write("notes/result.txt", "수정 결과");
        assertEquals("수정 결과", workspace.read("notes/result.txt").getString("content"));
        assertEquals(1, workspace.list("notes").getJSONArray("entries").length());
    }
    public void testTraversalSizeAndSymlinkRejection() throws Exception {
        reject(() -> workspace.write("../outside.txt", "no"));
        reject(() -> workspace.read("/etc/passwd"));
        reject(() -> workspace.write("too-large.txt", "a".repeat(AgentWorkspace.LIMIT + 1)));
        workspace.write("safe.txt", "inside");
        Files.createSymbolicLink(root.resolve("escape"), getContext().getFilesDir().toPath());
        reject(() -> workspace.write("escape/outside.txt", "no"));
        reject(() -> workspace.list("escape"));
        assertEquals(1, workspace.list("").getJSONArray("entries").length());
    }
    private interface Operation { void run() throws Exception; }
    private void reject(Operation operation) throws Exception {
        try { operation.run(); } catch (IllegalArgumentException expected) { return; }
        fail("Expected boundary rejection");
    }
}
