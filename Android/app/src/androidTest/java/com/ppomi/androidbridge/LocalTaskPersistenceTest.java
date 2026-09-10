package com.ppomi.androidbridge;

import android.test.InstrumentationTestCase;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.util.UUID;

/** Persistence and selection invariants; no model traffic and no app-control permissions. */
public final class LocalTaskPersistenceTest extends InstrumentationTestCase {
    public void testRestartRetainsUncertainActionAndRequiresExplicitResume() throws Exception {
        File directory = new File(getInstrumentation().getTargetContext().getCacheDir(), "task-store-test-" + UUID.randomUUID());
        TaskStore first = new TaskStore(directory);
        JSONObject task = first.create("한글 결과", "builtin", new JSONArray().put(TaskStore.object("op", "click")));
        String id = task.getString("id");
        TaskStore.put(task, "inFlight", TaskStore.object("tool", "click", "mutation", true, "returned", true));
        first.event(task, "action_returned", "Android accepted, checkpoint not yet advanced", new JSONObject());
        TaskStore reopened = new TaskStore(directory);
        reopened.recoverInterrupted();
        JSONObject recovered = reopened.get(id);
        assertEquals("interrupted", recovered.getString("state"));
        assertEquals(0, recovered.getInt("stepIndex"));
        assertTrue(recovered.getJSONObject("inFlight").getBoolean("mutation"));
        assertTrue(recovered.getJSONObject("inFlight").getBoolean("returned"));
        assertEquals(2, recovered.getJSONArray("events").length());
        reopened.recoverInterrupted();
        assertEquals("Recovery must not repeatedly mutate history", 2, reopened.get(id).getJSONArray("events").length());
        delete(directory);
    }

    public void testSnapshotCopiesAndEvidenceConfinement() throws Exception {
        File directory = new File(getInstrumentation().getTargetContext().getCacheDir(), "task-store-test-" + UUID.randomUUID());
        TaskStore store = new TaskStore(directory);
        JSONObject task = store.create("private", "builtin", new JSONArray());
        String id = task.getString("id");
        JSONObject copy = store.get(id); copy.put("request", "modified copy");
        assertEquals("private", store.get(id).getString("request"));
        assertTrue(store.evidenceFile(id, "proof.png").getCanonicalPath().startsWith(directory.getCanonicalPath() + "/"));
        try { store.evidenceFile(id, "../outside.png"); fail("Traversal accepted"); }
        catch (IllegalArgumentException expected) {}
        try { store.get("../../outside"); fail("Invalid task ID accepted"); }
        catch (IllegalArgumentException expected) {}
        delete(directory);
    }

    public void testSelectorRejectsAmbiguousAndPasswordNodes() throws Exception {
        JSONObject node = TaskStore.object("id", "one", "text", "Apply", "visible", true,
            "enabled", true, "clickable", true, "password", false);
        JSONObject tree = TaskStore.object("nodes", new JSONArray().put(node));
        JSONObject selector = TaskStore.object("text", "Apply", "clickable", true);
        assertEquals("one", LocalTaskRunner.uniqueNode(tree, selector).getString("id"));
        node.put("password", true);
        assertNull(LocalTaskRunner.uniqueNode(tree, selector));
        node.put("password", false);
        tree.getJSONArray("nodes").put(TaskStore.copy(node).put("id", "two"));
        try { LocalTaskRunner.uniqueNode(tree, selector); fail("Ambiguous selector accepted"); }
        catch (IllegalStateException expected) {}
        JSONObject notes = TaskStore.object("id", "before:1", "className", "android.widget.TextView",
            "resourceId", "launcher:id/icon", "text", "Notes", "contentDescription", "Personal notes",
            "visible", true, "enabled", true, "longClickable", true, "password", false);
        JSONObject camera = TaskStore.copy(notes).put("id", "before:2").put("text", "Camera")
            .put("contentDescription", "Camera app");
        JSONObject screen = TaskStore.object("packageName", "launcher", "displayWidth", 1080, "displayHeight", 2400,
            "nodes", new JSONArray().put(notes).put(camera));
        JSONObject iconSelector = LocalTaskRunner.modelSelector(screen, notes, "long_press_drag");
        assertEquals("launcher:id/icon", iconSelector.getString("resourceId"));
        assertEquals("Notes", iconSelector.getString("text"));
        assertEquals("Personal notes", iconSelector.getString("contentDescription"));

        // Approval returns with new snapshot IDs; match the same semantic icon.
        JSONObject next = TaskStore.object("packageName", "launcher", "displayWidth", 1080, "displayHeight", 2400,
            "nodes", new JSONArray().put(TaskStore.copy(notes).put("id", "after:1"))
            .put(TaskStore.copy(camera).put("id", "after:2")));
        assertEquals("after:1", LocalTaskRunner.uniqueNode(next, iconSelector).getString("id"));
        assertEquals("New snapshot IDs must not invalidate unchanged screen approval",
            LocalTaskRunner.fingerprint(screen), LocalTaskRunner.fingerprint(next));
        next.getJSONArray("nodes").getJSONObject(0).put("contentDescription", "Different shortcut");
        assertNull("A reused view ID must not approve a different shortcut", LocalTaskRunner.uniqueNode(next, iconSelector));
        assertFalse("Changed shortcut descriptions must invalidate coordinate approval",
            LocalTaskRunner.fingerprint(screen).equals(LocalTaskRunner.fingerprint(next)));
        assertFalse("A fold display resize must invalidate old drop coordinates",
            LocalTaskRunner.fingerprint(screen).equals(LocalTaskRunner.fingerprint(TaskStore.copy(screen).put("displayWidth", 1800))));
        try {
            LocalTaskRunner.modelSelector(screen, TaskStore.copy(notes).put("id", "missing:1"), "long_press_drag");
            fail("A node absent from the observed screen was accepted");
        } catch (IllegalStateException expected) {}
    }

    public void testProviderAddressValidationWithoutAnyNetworkRequest() {
        assertEquals("https://provider.example/v1/chat/completions", AgentSettings.normalizeEndpoint("https://provider.example/v1/"));
        assertEquals("https://provider.example/v1/chat/completions", AgentSettings.normalizeEndpoint("https://provider.example/v1/chat/completions"));
        for (String invalid : new String[]{"http://provider.example/v1", "https://secret@provider.example/v1", "https://provider.example/v1?key=secret"}) {
            try { AgentSettings.normalizeEndpoint(invalid); fail("Unsafe provider address accepted"); }
            catch (IllegalArgumentException expected) {}
        }
    }

    private static void delete(File file) {
        File[] children = file.listFiles(); if (children != null) for (File child : children) delete(child);
        file.delete();
    }
}
