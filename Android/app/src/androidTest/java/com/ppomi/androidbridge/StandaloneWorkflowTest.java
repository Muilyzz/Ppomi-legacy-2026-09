package com.ppomi.androidbridge;

import android.app.UiAutomation;
import android.content.Context;
import android.content.Intent;
import android.graphics.BitmapFactory;
import android.os.Bundle;
import android.os.SystemClock;
import android.test.InstrumentationTestCase;
import android.view.accessibility.AccessibilityNodeInfo;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayDeque;

/** UI automation represents only the user: requests and approvals. Target actions run inside Ppomi. */
public final class StandaloneWorkflowTest extends InstrumentationTestCase {
    private UiAutomation user;
    private Context context;
    private LocalTaskRunner runner;

    @Override protected void setUp() throws Exception {
        super.setUp();
        context = getInstrumentation().getTargetContext();
        // Keep the real Ppomi AccessibilityService connected while the test observes UI.
        user = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        rebindTestService();
        runner = LocalTaskRunner.get(context);
        launchWorkbench();
        long end = SystemClock.uptimeMillis() + 15000;
        while (!BridgeAccessibilityService.connected() && SystemClock.uptimeMillis() < end) SystemClock.sleep(100);
        assertTrue("Real AccessibilityService must be enabled", BridgeAccessibilityService.connected());
    }

    public void testStandaloneApprovalEvidenceAndCancel() throws Exception {
        assertNull("No existing active user task may be interrupted by this test", runner.activeTask());
        String message = "맥 없이 실행한 뽀미 · 한글 " + System.currentTimeMillis();
        String id = startThroughUi(message);
        JSONObject pending = awaitState(id, "waiting_approval", 20000);
        BridgeAccessibilityService service = BridgeAccessibilityService.getInstance();
        assertRejected(() -> service.execute("ui_tree", new JSONObject()));
        assertRejected(() -> service.execute("open_app", new JSONObject().put("packageName", "com.ppomi.androidtarget")));
        assertRejected(() -> service.executeLocal("tap", new JSONObject().put("x", 100).put("y", 100), id));
        assertTrue("Approval must describe the requested text", pending.toString().contains(message));
        clickTag("approve_task");
        JSONObject completed = awaitState(id, "completed", 30000);
        assertEquals("builtin", completed.getString("mode"));
        assertTrue("Result must be observed, not inferred", completed.toString().contains("Applied: " + message));
        JSONArray evidence = completed.getJSONArray("evidence");
        assertTrue("Must persist evidence", evidence.length() >= 1);
        File screenshot = new File(completed.getString("screenshotPath"));
        assertTrue("Device captured PNG must be private", screenshot.getCanonicalPath().startsWith(context.getFilesDir().getCanonicalPath() + "/"));
        assertTrue("Screenshot must have actual pixels", screenshot.length() > 1000);
        BitmapFactory.Options dimensions = new BitmapFactory.Options();
        dimensions.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(screenshot.getPath(), dimensions);
        assertTrue(dimensions.outWidth > 500 && dimensions.outHeight > 500);
        assertTrue(completed.toString().contains("android_accessibility"));
        // Cross-app verification through a read-only production tool after local ownership is released.
        service.execute("open_app", new JSONObject().put("packageName", "com.ppomi.androidtarget"));
        SystemClock.sleep(600);
        assertTrue(service.execute("ui_tree", new JSONObject()).toString().contains("Applied: " + message));

        launchWorkbench();
        String cancelledId = startThroughUi("승인하지 않은 입력 " + System.currentTimeMillis());
        awaitState(cancelledId, "waiting_approval", 20000);
        clickTag("cancel_task");
        JSONObject cancelled = awaitState(cancelledId, "cancelled", 10000);
        assertFalse(cancelled.has("screenshotPath"));
        assertFalse(cancelled.getJSONArray("events").toString().contains("type_text"));
        assertFalse(cancelled.getJSONArray("events").toString().contains("\"tool\":\"click\""));
        assertNull(runner.activeTask());
        service.execute("open_app", new JSONObject().put("packageName", "com.ppomi.androidtarget"));
        SystemClock.sleep(500);
        assertFalse(service.execute("ui_tree", new JSONObject()).toString().contains(cancelled.getString("request")));
        JSONObject proof = new JSONObject().put("completedTaskId", id).put("cancelledTaskId", cancelledId)
            .put("source", "android_instrumentation_user_ui").put("hostControlRequired", false)
            .put("checks", new JSONArray().put("native_request_ui").put("approval_gate")
                .put("external_control_exclusion").put("owner_cannot_self_approve")
                .put("cross_app_unicode_apply").put("observed_result")
                .put("private_native_screenshot").put("cancel_before_write"))
            .put("completed", completed).put("cancelled", cancelled);
        Files.write(new File(context.getFilesDir(), "standalone-e2e.json").toPath(), proof.toString(2).getBytes(StandardCharsets.UTF_8));
        launchWorkbench();
    }

    /** First phase of an actual force-stop/relaunch test; the host stops the process after this returns. */
    public void testPrepareProcessInterruption() throws Exception {
        assertNull(runner.activeTask());
        String id = startThroughUi("재실행 시 자동 적용 금지 " + System.currentTimeMillis());
        awaitState(id, "waiting_approval", 20000);
        Files.write(new File(context.getFilesDir(), "interrupted-test-id").toPath(), id.getBytes(StandardCharsets.UTF_8));
    }

    public void testVerifyProcessRecovery() throws Exception {
        File marker = new File(context.getFilesDir(), "interrupted-test-id");
        assertTrue(marker.isFile());
        String id = new String(Files.readAllBytes(marker.toPath()), StandardCharsets.UTF_8);
        JSONObject recovered = runner.store().get(id);
        assertEquals("interrupted", recovered.getString("state"));
        assertNull(runner.activeTask());
        assertFalse(recovered.has("screenshotPath"));
        assertFalse(recovered.getJSONArray("events").toString().contains("type_text"));
        assertTrue(recovered.getJSONArray("events").toString().contains("interrupted"));
        BridgeAccessibilityService service = BridgeAccessibilityService.getInstance();
        service.execute("open_app", new JSONObject().put("packageName", "com.ppomi.androidtarget"));
        SystemClock.sleep(700);
        assertFalse("Restart must not apply the pending request", service.execute("ui_tree", new JSONObject()).toString().contains(recovered.getString("request")));
        Files.write(new File(context.getFilesDir(), "standalone-recovery.json").toPath(), recovered.toString(2).getBytes(StandardCharsets.UTF_8));
    }

    public void testHistoryEvidenceAndPackagedCore() throws Exception {
        JSONObject proof = new JSONObject(new String(Files.readAllBytes(new File(context.getFilesDir(), "standalone-e2e.json").toPath()), StandardCharsets.UTF_8));
        clickTag("tab_history");
        scrollToTag("history_item_" + proof.getString("completedTaskId"));
        clickTag("history_item_" + proof.getString("completedTaskId"));
        awaitTag("task_detail", 10000).recycle();
        assertTrue(describeUi().contains("완료"));
        assertTrue(describeUi().contains("화면 증빙"));
        SystemClock.sleep(400);
        saveUiScreenshot("workbench-record.png");
        clickTag("tab_history");
        scrollToTag("accounting_demo");
        clickTag("accounting_demo");
        scrollToTag("accounting_report");
        awaitTag("accounting_report", 15000).recycle();
        assertTrue("APK must load its bundled Swift JNI report", describeUi().contains("평가 포함"));
        saveUiScreenshot("workbench-accounting.png");
        try (java.io.InputStream input = context.getAssets().open("accounting-example.json")) {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[4096]; int count;
            while ((count = input.read(buffer)) >= 0) bytes.write(buffer, 0, count);
            JSONObject report = new JSONObject(SharedAccounting.report(bytes.toString("UTF-8")));
            assertTrue(report.getBoolean("ok"));
            assertEquals(3, report.getJSONArray("books").length());
            Files.write(new File(context.getFilesDir(), "packaged-core-report.json").toPath(), report.toString(2).getBytes(StandardCharsets.UTF_8));
        }
    }

    private void saveUiScreenshot(String name) throws Exception {
        android.graphics.Bitmap bitmap = user.takeScreenshot();
        assertNotNull(bitmap);
        try (java.io.FileOutputStream stream = new java.io.FileOutputStream(new File(context.getFilesDir(), name))) {
            assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream));
        } finally { bitmap.recycle(); }
    }

    private void scrollToTag(String tag) throws Exception {
        for (int attempt=0; attempt<16; attempt++) {
            AccessibilityNodeInfo found=findTag(tag);
            if(found!=null) {
                android.graphics.Rect bounds=new android.graphics.Rect();found.getBoundsInScreen(bounds);
                boolean visible=found.isVisibleToUser() && bounds.height()>10;
                found.recycle();if(visible)return;
            }
            AccessibilityNodeInfo root=user.getRootInActiveWindow();
            if(root==null){SystemClock.sleep(200);continue;}
            ArrayDeque<AccessibilityNodeInfo> queue=new ArrayDeque<>();queue.add(root);
            boolean scrolled=false;
            while(!queue.isEmpty()) { AccessibilityNodeInfo n=queue.remove();
                if(!scrolled&&n.isScrollable())scrolled=n.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD);
                for(int i=0;i<n.getChildCount();i++){AccessibilityNodeInfo child=n.getChild(i);if(child!=null)queue.add(child);}n.recycle();
            }
            SystemClock.sleep(250);
        }
        fail("Could not scroll to " + tag + "; " + describeUi());
    }

    private void rebindTestService() throws Exception {
        // Instrumentation starts by killing the target process. Android marks its old service
        // crashed, so re-enable this same test service after UiAutomation is registered.
        String component = "com.ppomi.androidbridge/.BridgeAccessibilityService";
        String full = "com.ppomi.androidbridge/com.ppomi.androidbridge.BridgeAccessibilityService";
        String existing = shell("settings get secure enabled_accessibility_services").trim();
        java.util.ArrayList<String> others = new java.util.ArrayList<>();
        for (String entry : existing.split(":"))
            if (!entry.isEmpty() && !entry.equals("null") && !entry.equals(component) && !entry.equals(full)) others.add(entry);
        shell("settings put secure enabled_accessibility_services " + (others.isEmpty() ? "null" : String.join(":", others)));
        SystemClock.sleep(300);
        others.add(component);
        shell("settings put secure enabled_accessibility_services " + String.join(":", others));
        shell("settings put secure accessibility_enabled 1");
        assertTrue("Test service setting was not applied", shell("settings get secure enabled_accessibility_services").contains("com.ppomi.androidbridge"));
    }

    private String shell(String command) throws Exception {
        try (java.io.InputStream input = new android.os.ParcelFileDescriptor.AutoCloseInputStream(user.executeShellCommand(command))) {
            java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[2048]; int count;
            while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
            return output.toString("UTF-8");
        }
    }

    private String startThroughUi(String message) throws Exception {
        AccessibilityNodeInfo close = findTag("close_detail");
        if (close != null) { close.performAction(AccessibilityNodeInfo.ACTION_CLICK); close.recycle(); SystemClock.sleep(200); }
        clickTag("tab_tasks");
        AccessibilityNodeInfo input = awaitTag("task_request", 10000);
        Bundle text = new Bundle();
        text.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, message);
        assertTrue("Request field must accept user text", input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, text));
        input.recycle();
        clickTag("start_builtin");
        long end = SystemClock.uptimeMillis() + 15000;
        while (SystemClock.uptimeMillis() < end) {
            JSONArray list = runner.store().list();
            for (int i=0; i<list.length(); i++) if (message.equals(list.getJSONObject(i).optString("request")))
                return list.getJSONObject(i).getString("id");
            SystemClock.sleep(100);
        }
        fail("UI did not create requested task");
        return null;
    }

    private JSONObject awaitState(String id, String state, long timeout) throws Exception {
        long end = SystemClock.uptimeMillis() + timeout;
        JSONObject last = null;
        while (SystemClock.uptimeMillis() < end) {
            last = runner.store().get(id);
            if (state.equals(last.optString("state"))) return last;
            if ("failed".equals(last.optString("state"))) fail("Task failed: " + last);
            SystemClock.sleep(100);
        }
        fail("Expected " + state + "; got " + last);
        return null;
    }

    private void launchWorkbench() {
        Intent launch = new Intent(context, MainActivity.class).setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        context.startActivity(launch);
        SystemClock.sleep(700);
    }

    private void clickTag(String tag) throws Exception {
        AccessibilityNodeInfo node = awaitTag(tag, 12000);
        try { assertTrue("User click rejected: " + tag, node.performAction(AccessibilityNodeInfo.ACTION_CLICK)); }
        finally { node.recycle(); }
        SystemClock.sleep(200);
    }

    private AccessibilityNodeInfo awaitTag(String tag, long timeout) throws Exception {
        long end = SystemClock.uptimeMillis() + timeout;
        while (SystemClock.uptimeMillis() < end) {
            AccessibilityNodeInfo node = findTag(tag);
            if (node != null && node.isVisibleToUser()) return node;
            if (node != null) node.recycle();
            SystemClock.sleep(150);
        }
        fail("Missing user UI tag: " + tag + "; UI=" + describeUi());
        return null;
    }

    private AccessibilityNodeInfo findTag(String tag) {
        AccessibilityNodeInfo root = user.getRootInActiveWindow();
        if (root == null) return null;
        ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>();
        queue.add(root);
        AccessibilityNodeInfo found = null;
        while (!queue.isEmpty()) {
            AccessibilityNodeInfo node = queue.remove();
            String id = node.getViewIdResourceName();
            if (tag.equals(id) || (id != null && id.endsWith("/" + tag))) found = AccessibilityNodeInfo.obtain(node);
            for (int i=0;i<node.getChildCount();i++) { AccessibilityNodeInfo child=node.getChild(i); if(child!=null)queue.add(child); }
            node.recycle();
        }
        return found;
    }

    private String describeUi() {
        AccessibilityNodeInfo root=user.getRootInActiveWindow();
        if(root==null)return "no root";
        StringBuilder out=new StringBuilder();
        ArrayDeque<AccessibilityNodeInfo> queue=new ArrayDeque<>();queue.add(root);
        while(!queue.isEmpty()) { AccessibilityNodeInfo n=queue.remove();out.append(n.getViewIdResourceName()).append(':').append(n.getText()).append(';');
            for(int i=0;i<n.getChildCount();i++){AccessibilityNodeInfo child=n.getChild(i);if(child!=null)queue.add(child);}n.recycle(); }
        return out.toString();
    }

    interface ThrowingCall { void run() throws Exception; }
    private void assertRejected(ThrowingCall call) throws Exception {
        boolean rejected=false;
        try { call.run(); } catch(Exception expected) { rejected=true; }
        assertTrue("A task must exclusively own control and cannot act while waiting approval",rejected);
    }
}
