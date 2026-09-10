package com.ppomi.androidbridge;

import android.test.InstrumentationTestCase;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

/** Auth destination boundaries and durable SSOT bookkeeping, without network or screen control. */
public final class SharedStateTest extends InstrumentationTestCase {
    public void testConfigurationRejectsRedirectDestinationsAndPrivilegedKeys() throws Exception {
        JSONObject valid = TaskStore.object("url", "https://abcdefghijklmnopqrst.supabase.co/",
            "publishableKey", "sb_publishable_test_only_123456789012345", "email", "device@example.invalid",
            "password", "test-only-secret-123456789", "deviceId", UUID.randomUUID().toString());
        assertEquals("https://abcdefghijklmnopqrst.supabase.co", SupabaseSettings.validate(valid.toString()).getString("url"));
        for (String url : new String[]{"http://abcdefghijklmnopqrst.supabase.co", "https://abcdefghijklmnopqrst.supabase.co.evil.example",
            "https://secret@abcdefghijklmnopqrst.supabase.co", "https://abcdefghijklmnopqrst.supabase.co:444",
            "https://abcdefghijklmnopqrst.supabase.co/path", "https://abcdefghijklmnopqrst.supabase.co?key=secret"}) {
            rejected(TaskStore.copy(valid).put("url", url));
        }
        String servicePayload = Base64.encodeToString("{\"role\":\"service_role\"}".getBytes(StandardCharsets.UTF_8), Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
        rejected(TaskStore.copy(valid).put("publishableKey", "header." + servicePayload + ".signature"));
        rejected(TaskStore.copy(valid).put("publishableKey", "sb_secret_do_not_accept_any_privileged_key"));
        assertTrue("A PostgreSQL CAS rejection remains a conflict even with HTTP 500", new SupabaseClient.HttpFailure(500, "40001").conflict);
        assertTrue("Terminal state rejection must pause the outbox", new SupabaseClient.HttpFailure(500, "55000").conflict);
        assertFalse("Transient server errors may retry only the persisted event", new SupabaseClient.HttpFailure(503, "").conflict);
    }
    public void testOutboxSurvivesRestartWithStableIdsAndExcludesPrivateEvidence() throws Exception {
        File directory = directory(); TaskStore store = new TaskStore(directory);
        String id = UUID.randomUUID().toString();
        JSONObject task = store.create(id, "shared synthetic test", "builtin", new JSONArray(), shared());
        task.put("state", "running");
        store.event(task, "started", "private local text", TaskStore.object("password", "never-upload", "path", "/private/screen.png"));
        task.put("state", "waiting_approval");
        store.event(task, "approval_requested", "private approval payload", TaskStore.object("text", "never-upload"));
        JSONObject first = store.firstSharedEvent(id);
        assertEquals(2, first.getLong("p_expected_version"));
        assertFalse(first.toString().contains("never-upload")); assertFalse(first.toString().contains("/private/"));
        assertEquals(id, first.getJSONObject("p_data").getString("local_task_id"));
        TaskStore reopened = new TaskStore(directory);
        assertEquals("Retry must preserve the entire RPC body", first.toString(), reopened.firstSharedEvent(id).toString());
        try { reopened.acknowledgeSharedEvent(id, UUID.randomUUID().toString(), 3); fail("Out-of-order ACK accepted"); }
        catch (IllegalStateException expected) { }
        reopened.acknowledgeSharedEvent(id, first.getString("p_event_id"), 3);
        JSONObject second = reopened.firstSharedEvent(id);
        assertEquals(3, second.getLong("p_expected_version"));
        assertEquals("waiting_approval", second.getString("p_state"));
        reopened.acknowledgeSharedEvent(id, second.getString("p_event_id"), 4);
        assertNull(reopened.firstSharedEvent(id));
        assertEquals(4, reopened.get(id).getJSONObject("shared").getLong("serverVersion"));
        delete(directory);
    }
    public void testRecoveryQueuesOneInterruptionAndApprovalHasExplicitUserAction() throws Exception {
        File directory = directory(); TaskStore store = new TaskStore(directory);
        String id = UUID.randomUUID().toString();
        JSONObject task = store.create(id, "synthetic test", "builtin", new JSONArray(), shared());
        task.put("state", "running"); store.event(task, "approved", "approved", new JSONObject());
        JSONObject approval = store.firstSharedEvent(id);
        assertEquals("approval", approval.getString("p_kind"));
        assertTrue(approval.getJSONObject("p_data").getBoolean("user_action"));
        task.put("inFlight", TaskStore.object("mutation", true, "tool", "click")); store.save(task);
        TaskStore reopened = new TaskStore(directory); reopened.recoverInterrupted(); reopened.recoverInterrupted();
        JSONObject recovered = reopened.get(id);
        assertEquals("interrupted", recovered.getString("state"));
        assertTrue(recovered.getJSONObject("inFlight").getBoolean("mutation"));
        assertEquals(2, recovered.getJSONObject("shared").getJSONArray("outbox").length());
        assertEquals("interrupted", recovered.getJSONObject("shared").getJSONArray("outbox").getJSONObject(1).getString("p_state"));
        delete(directory);
    }
    public void testExistingLocalRecordsNeverEnterSharedOutboxAndDuplicateIdsCannotReplay() throws Exception {
        File directory = directory(); TaskStore store = new TaskStore(directory);
        JSONObject local = store.create("private local history", "builtin", new JSONArray());
        store.event(local, "completed", "private screenshot", TaskStore.object("path", "/private/file.png"));
        assertFalse(store.get(local.getString("id")).has("shared")); assertNull(store.firstSharedEvent(local.getString("id")));
        String id = UUID.randomUUID().toString(); store.create(id, "once", "builtin", new JSONArray(), shared());
        try { store.create(id, "twice", "builtin", new JSONArray(), shared()); fail("Duplicate run replay accepted"); }
        catch (IllegalStateException expected) { }
        assertEquals("once", store.get(id).getString("request")); delete(directory);
    }
    private void rejected(JSONObject value) {
        try { SupabaseSettings.validate(value.toString()); fail("Unsafe config accepted"); }
        catch (IllegalArgumentException expected) {
            assertFalse(expected.getMessage().contains("test-only-secret")); assertFalse(expected.getMessage().contains("sb_secret"));
        }
    }
    private JSONObject shared() { return TaskStore.object("phase", "active", "serverVersion", 2, "nextVersion", 2, "outbox", new JSONArray()); }
    private File directory() { return new File(getInstrumentation().getTargetContext().getCacheDir(), "shared-test-" + UUID.randomUUID()); }
    private void delete(File file) { File[] children = file.listFiles(); if (children != null) for (File child : children) delete(child); file.delete(); }
}
