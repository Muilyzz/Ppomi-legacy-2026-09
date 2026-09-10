package com.ppomi.androidbridge;

import android.app.UiAutomation;
import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;
import android.test.InstrumentationTestCase;
import android.test.InstrumentationTestRunner;
import android.view.accessibility.AccessibilityNodeInfo;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayDeque;
import java.util.UUID;

/** Uses a pre-provisioned device and an explicit synthetic fixture run UUID. Never grants permissions. */
public final class SharedWorkflowTest extends InstrumentationTestCase {
    private UiAutomation user;
    private Context context;
    private SharedTaskController shared;
    private LocalTaskRunner runner;

    public void testWorkbenchReturnClearsSettingsFromPpomiTask() throws Exception {
        context = getInstrumentation().getTargetContext();
        user = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        long deadline = SystemClock.uptimeMillis() + 45000;
        while (!BridgeAccessibilityService.connected() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(200);
        assertTrue("Already enabled accessibility service must be connected", BridgeAccessibilityService.connected());
        assertNull("Do not interrupt an existing task", LocalTaskRunner.get(context).activeTask());
        Intent intent = new Intent(context, MainActivity.class).setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        android.app.Activity activity = getInstrumentation().startActivitySync(intent);
        // Recreate the previous task stack: Settings was launched as a child of Ppomi.
        getInstrumentation().runOnMainSync(() -> activity.startActivity(new Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        awaitPackage("com.android.settings", 12000);
        BridgeAccessibilityService.getInstance().openWorkbench();
        awaitPackage("com.ppomi.androidbridge", 12000);
        AccessibilityNodeInfo workbench = find("tab_tasks");
        assertNotNull("The actual Ppomi workbench must be visible", workbench); workbench.recycle();
    }

    public void testExplicitSharedFixtureRunAndServerCompletion() throws Exception {
        String id = ((InstrumentationTestRunner) getInstrumentation()).getArguments().getString("shared_run_id");
        assertNotNull("Pass a newly created synthetic fixture task via -e shared_run_id UUID", id);
        UUID.fromString(id);
        context = getInstrumentation().getTargetContext();
        user = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        runner = LocalTaskRunner.get(context); shared = SharedTaskController.get(context);
        assertNull("Do not interrupt an existing local task", runner.activeTask());
        long deadline = SystemClock.uptimeMillis() + 45000;
        while (!BridgeAccessibilityService.connected() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(200);
        assertTrue("User-enabled accessibility service must already be connected", BridgeAccessibilityService.connected());
        launch(); shared.refresh();
        JSONObject queued = awaitServer(id, "queued", 45000);
        assertEquals("builtin", queued.getString("mode"));
        assertEquals(shared.snapshot().getString("deviceId"), queued.getString("executor_device_id"));
        click("tab_shared"); scrollTo("start_shared_" + id); click("start_shared_" + id);
        JSONObject waiting = awaitLocal(id, "waiting_approval", 30000);
        assertEquals("The local execution id must equal the server run id", id, waiting.getString("id"));
        assertFalse("No fixture text action before approval", waiting.getJSONArray("events").toString().contains("type_text"));
        awaitServer(id, "waiting_approval", 30000);
        click("approve_task");
        JSONObject completed = awaitLocal(id, "completed", 45000);
        assertTrue("Observe the actual fixture output", completed.toString().contains("Applied: " + queued.getString("request")));
        JSONObject server = awaitServer(id, "completed", 45000);
        assertTrue("Server versions must advance through claim and execution", server.getLong("version") >= 6);
        assertEquals(0, runner.store().get(id).getJSONObject("shared").getJSONArray("outbox").length());
        assertNotNull("Evidence remains on device", completed.optString("screenshotPath", null));
        launch(); click("tab_shared"); scrollTo("shared_state_" + id);
        android.graphics.Bitmap bitmap = user.takeScreenshot();
        if (bitmap != null) try (java.io.FileOutputStream output = new java.io.FileOutputStream(new File(context.getFilesDir(), "shared-workflow-screen.png"))) {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output);
        } finally { if (bitmap != null) bitmap.recycle(); }
        JSONObject proof = TaskStore.object("runId", id, "serverState", server.getString("state"), "serverVersion", server.getLong("version"),
            "localState", completed.getString("state"), "remainingOutbox", 0, "source", "android_user_ui_and_device_supabase_https",
            "checks", new JSONArray().put("explicit_shared_run_ui").put("server_claim_before_execution").put("same_server_and_local_uuid")
                .put("device_local_approval").put("observed_fixture_result").put("durable_status_outbox_drained").put("server_confirmed_completed")
                .put("native_evidence_kept_local"));
        Files.write(new File(context.getFilesDir(), "shared-workflow-proof.json").toPath(), proof.toString(2).getBytes(StandardCharsets.UTF_8));
    }
    private JSONObject awaitServer(String id, String expected, long timeout) throws Exception {
        long deadline = SystemClock.uptimeMillis() + timeout;
        while (SystemClock.uptimeMillis() < deadline) {
            JSONObject snapshot = shared.snapshot();
            JSONArray runs = snapshot.optJSONArray("runs");
            if (snapshot.optBoolean("online") && runs != null) for (int i = 0; i < runs.length(); i++) {
                JSONObject run = runs.getJSONObject(i);
                if (id.equals(run.optString("id")) && expected.equals(run.optString("state"))) return run;
            }
            shared.refresh(); SystemClock.sleep(2000);
        }
        fail("Shared server did not confirm " + expected + "; " + shared.snapshot().optString("connectionError")); return null;
    }
    private JSONObject awaitLocal(String id, String expected, long timeout) throws Exception {
        long deadline = SystemClock.uptimeMillis() + timeout;
        while (SystemClock.uptimeMillis() < deadline) {
            try {
                JSONObject task = runner.store().get(id);
                if (expected.equals(task.optString("state"))) return task;
                if ("failed".equals(task.optString("state"))) fail("Local fixture task failed");
            } catch (IllegalArgumentException notCreated) { }
            SystemClock.sleep(150);
        }
        fail("Local fixture did not reach " + expected); return null;
    }
    private void launch() {
        context.startActivity(new Intent(context, MainActivity.class).setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP));
        SystemClock.sleep(800);
    }
    private void awaitPackage(String name, long timeout) {
        long deadline = SystemClock.uptimeMillis() + timeout;
        while (SystemClock.uptimeMillis() < deadline) {
            AccessibilityNodeInfo root = user.getRootInActiveWindow();
            if (root != null) { boolean match = name.equals(String.valueOf(root.getPackageName())); root.recycle(); if (match) return; }
            SystemClock.sleep(150);
        }
        fail("Expected foreground app " + name);
    }
    private void click(String tag) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 12000;
        while (SystemClock.uptimeMillis() < deadline) {
            AccessibilityNodeInfo node = find(tag);
            if (node != null) try {
                if (node.isVisibleToUser() && node.isEnabled() && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) { SystemClock.sleep(250); return; }
            } finally { node.recycle(); }
            SystemClock.sleep(150);
        }
        fail("Missing enabled user action " + tag);
    }
    private void scrollTo(String tag) {
        for (int attempt = 0; attempt < 18; attempt++) {
            AccessibilityNodeInfo node = find(tag);
            if (node != null) { boolean visible = node.isVisibleToUser(); node.recycle(); if (visible) return; }
            AccessibilityNodeInfo root = user.getRootInActiveWindow();
            if (root == null) { SystemClock.sleep(200); continue; }
            ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>(); queue.add(root); boolean moved = false;
            while (!queue.isEmpty()) {
                AccessibilityNodeInfo item = queue.remove();
                if (!moved && item.isScrollable()) moved = item.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD);
                for (int i = 0; i < item.getChildCount(); i++) { AccessibilityNodeInfo child = item.getChild(i); if (child != null) queue.add(child); }
                item.recycle();
            }
            SystemClock.sleep(250);
        }
        fail("Could not reveal shared UI " + tag);
    }
    private AccessibilityNodeInfo find(String tag) {
        AccessibilityNodeInfo root = user.getRootInActiveWindow(); if (root == null) return null;
        ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>(); queue.add(root); AccessibilityNodeInfo found = null;
        while (!queue.isEmpty()) {
            AccessibilityNodeInfo node = queue.remove(); String viewId = node.getViewIdResourceName();
            if (tag.equals(viewId) || (viewId != null && viewId.endsWith("/" + tag))) { if (found != null) found.recycle(); found = AccessibilityNodeInfo.obtain(node); }
            for (int i = 0; i < node.getChildCount(); i++) { AccessibilityNodeInfo child = node.getChild(i); if (child != null) queue.add(child); }
            node.recycle();
        }
        return found;
    }
}
