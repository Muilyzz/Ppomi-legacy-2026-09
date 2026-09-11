package com.ppomi.androidbridge;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.test.InstrumentationTestCase;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inspector.WindowInspector;
import android.webkit.WebView;
import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;
import java.util.HashSet;
import java.util.Arrays;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Real Compose/WebView lifetime proof on an unprovisioned emulator, using only synthetic text replies. */
public final class WorkbenchFrameTest extends InstrumentationTestCase {
    private Context context;
    private UiAutomation user;
    private MainActivity activity;
    private Instrumentation.ActivityMonitor activities;
    private VoiceSessionHost host;
    private WebView view;
    private int generation;
    private boolean compactLayout;
    private int requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
    private String previousEndpoint;
    private String documentMarker;
    private final AtomicInteger unexpected = new AtomicInteger();
    private final ChatImeTest.SyntheticReplies replies = new ChatImeTest.SyntheticReplies(true, unexpected);

    @Override protected void setUp() throws Exception {
        super.setUp();
        assertTrue("Workbench UI tests run only on an emulator", BridgeSession.isEmulator());
        context = getInstrumentation().getTargetContext();
        ChatImeTest.assertOfflineEnvironment(context);
        user = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        android.accessibilityservice.AccessibilityServiceInfo serviceInfo = user.getServiceInfo();
        serviceInfo.flags |= android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
        user.setServiceInfo(serviceInfo);
        host = VoiceSessionHost.Companion.get(context);
        assertFalse("Preserve an existing agent session", host.getActive());
        assertNull("Preserve an existing local task", LocalTaskRunner.actionOwner());
        previousEndpoint = context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE).getString("endpoint", "");
        assertTrue(context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE).edit().putString("endpoint", "").commit());
        getInstrumentation().runOnMainSync(() -> host.destroyHost());
        SystemClock.sleep(150);
        activities = getInstrumentation().addMonitor(MainActivity.class.getName(), null, false);
        activity = (MainActivity) getInstrumentation().startActivitySync(new Intent(context, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK));
        getInstrumentation().runOnMainSync(() -> requestedOrientation = activity.getRequestedOrientation());
        waitFor(() -> {
            getInstrumentation().runOnMainSync(() -> view = findWebView(activity.getWindow().getDecorView()));
            return view != null && Boolean.TRUE.equals(evaluate("!!document.querySelector('#chat-input')"));
        }, 15000, "Bundled chat did not attach to the workbench");
        getInstrumentation().runOnMainSync(() -> {
            ChatImeTest.installSyntheticBridge(view, replies);
            view.reload();
        });
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('#chat-input')?.disabled === false")),
            10000, "Synthetic bootstrap did not enable the composer");
        generation = host.getViewGeneration();
        documentMarker = UUID.randomUUID().toString();
        assertEquals(Boolean.TRUE, evaluate("(()=>{window.__workbenchProbe={document,marker:" + JSONObject.quote(documentMarker)
            + ",media:0,network:0};const denyNetwork=()=>{window.__workbenchProbe.network++;throw new Error('Offline test');};"
            + "window.fetch=async()=>denyNetwork();window.WebSocket=class{constructor(){denyNetwork();}};"
            + "window.RTCPeerConnection=class{constructor(){window.__workbenchProbe.media++;throw new Error('Offline test');}};"
            + "if(navigator.mediaDevices)Object.defineProperty(navigator.mediaDevices,'getUserMedia',{configurable:true,value:async()=>{"
            + "window.__workbenchProbe.media++;throw new Error('Offline test');}});return true;})()"));
        awaitTag("workbench_frame");
        compactLayout = bounds("workbench_frame").width() / activity.getResources().getDisplayMetrics().density < 600;
        awaitTag(compactLayout ? "open_content" : "show_control");
    }

    @Override protected void tearDown() throws Exception {
        try {
            followActivity();
            if (activity != null) getInstrumentation().runOnMainSync(() -> {
                activity.setRequestedOrientation(requestedOrientation);
                activity.finish();
            });
            if (host != null) getInstrumentation().runOnMainSync(() -> host.destroyHost());
            if (context != null && previousEndpoint != null)
                assertTrue(context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE).edit().putString("endpoint", previousEndpoint).commit());
            getInstrumentation().waitForIdleSync();
            SystemClock.sleep(150);
        } finally {
            if (activities != null) getInstrumentation().removeMonitor(activities);
            super.tearDown();
        }
    }

    public void testThreeRegionsRetainTheLiveConversationAcrossNavigationAndRotation() throws Exception {
        assertFrameGeometry();
        String first = "첫 번째 합성 대화";
        String draft = "화면을 바꿔도 남는 초안";
        send(first, 1);
        setDraft(draft);
        assertSession(draft, 1);

        openContentIfCompact();
        for (String tab : new String[] {"tab_tasks", "tab_history", "tab_shared"}) {
            clickTag(tab);
            if (!compactLayout) assertFrameGeometry();
            assertSession(draft, 1);
        }
        clickTag("show_control");
        awaitTag("show_records");
        if (!compactLayout) assertFrameGeometry();
        assertSession(draft, 1);
        clickTag("show_records");
        awaitTag("show_control");
        assertSession(draft, 1);
        closeContentIfCompact();

        clickTag("tab_settings");
        awaitTag("close_settings");
        waitFor(this::hasSecureWindow, 5000, "Settings must be presented in a secure native window");
        assertSession(draft, 1);
        clickTag("close_settings");
        waitFor(() -> !hasSecureWindow(), 5000, "Closing settings must release its secure dialog");
        assertFrameGeometry();
        assertSession(draft, 1);

        Rect before = bounds("workbench_frame");
        boolean compactBefore = compactLayout;
        // A compact content dialog must release on expansion while the chat document remains attached.
        openContentIfCompact();
        int initialOrientation = activity.getResources().getConfiguration().orientation;
        int targetOrientation = initialOrientation == Configuration.ORIENTATION_LANDSCAPE
            ? ActivityInfo.SCREEN_ORIENTATION_PORTRAIT : ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE;
        rotateActivity(targetOrientation, before);
        boolean compactAfter = bounds("workbench_frame").width() / activity.getResources().getDisplayMetrics().density < 600;
        if (compactBefore && compactAfter && tagIsVisible("workbench_content_sheet")) {
            // A rotation that stays compact may retain the explicitly opened dialog.
            clickTag("close_content");
        }
        waitFor(() -> !tagIsVisible("workbench_content_sheet"), 5000, "A breakpoint change must close the compact content dialog");
        assertFrameGeometry();
        assertSession(draft, 1);
        openContentIfCompact();
        clickTag("show_control");
        assertSession(draft, 1);
        clickTag("show_records");
        closeContentIfCompact();

        Rect afterRotation = bounds("workbench_frame");
        int returnOrientation = initialOrientation == Configuration.ORIENTATION_LANDSCAPE
            ? ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE : ActivityInfo.SCREEN_ORIENTATION_PORTRAIT;
        rotateActivity(returnOrientation, afterRotation);
        waitFor(() -> !tagIsVisible("workbench_content_sheet"), 5000, "Returning to the cover must not reopen a previously hidden content dialog");
        assertFrameGeometry();
        assertSession(draft, 1);

        String second = "앞선 대화를 기억하는 두 번째 합성 요청";
        send(second, 2);
        assertSession("", 2);
        assertEquals("A retained conversation must not reconnect on layout/navigation changes", 1, replies.starts.get());
        assertEquals(2, replies.responses.size());
        JSONArray input = replies.responses.get(1).getJSONArray("input");
        assertTrue("The second request must include the first user turn", containsMessage(input, "user", first));
        assertTrue("The second request must include the prior assistant turn", containsMessage(input, "assistant", ChatImeTest.SyntheticReplies.ANSWER));
        assertTrue("The second request must include the new user turn", containsMessage(input, "user", second));
        Bundle proof = new Bundle();
        proof.putString("workbenchFrameProof", "three_regions,expanded_content_left_chat_right,compact_chat_and_content_dialog,record_control_settings,secure_dialog,same_webview_generation_document,draft_and_messages,rotation,second_turn_history,no_network_tools_or_media");
        proof.putBoolean("compactBefore", compactBefore);
        proof.putBoolean("compactAfter", compactAfter);
        proof.putInt("frameWidthBeforePx", before.width());
        proof.putInt("frameWidthAfterRotationPx", afterRotation.width());
        proof.putInt("frameWidthAfterReturnPx", bounds("workbench_frame").width());
        getInstrumentation().sendStatus(0, proof);
    }

    private void rotateActivity(int orientation, Rect before) throws Exception {
        int targetConfiguration = orientation == ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            ? Configuration.ORIENTATION_PORTRAIT : Configuration.ORIENTATION_LANDSCAPE;
        getInstrumentation().runOnMainSync(() -> activity.setRequestedOrientation(orientation));
        waitFor(() -> {
            followActivity();
            AtomicReference<WebView> attached = new AtomicReference<>();
            getInstrumentation().runOnMainSync(() -> attached.set(findWebView(activity.getWindow().getDecorView())));
            if (attached.get() == null || activity.getResources().getConfiguration().orientation != targetConfiguration) return false;
            AccessibilityNodeInfo frame = ChatImeTest.findTag(user, context.getPackageName(), "workbench_frame");
            if (frame == null) return false;
            try { Rect next = new Rect(); frame.getBoundsInScreen(next); return next.width() > 0 && Math.abs(next.width() - before.width()) > 4; }
            finally { frame.recycle(); }
        }, 15000, "The resized/recreated activity did not publish its workbench frame");
        getInstrumentation().waitForIdleSync();
    }

    private void assertFrameGeometry() throws Exception {
        awaitTag("workbench_frame");
        Rect frame = bounds("workbench_frame"), bar = bounds("workbench_top_bar"), chat = bounds("workbench_chat");
        float density = activity.getResources().getDisplayMetrics().density;
        compactLayout = frame.width() / density < 600;
        assertTrue("The top bar and persistent chat must have area", bar.width() > 0 && bar.height() > 0 && chat.width() > 0 && chat.height() > 0);
        assertNear("Top bar spans the frame", frame.left, bar.left); assertNear("Top bar spans the frame", frame.right, bar.right);
        assertNear("Top bar starts below the consumed status inset", frame.top, bar.top);
        assertNear("Top bar height is 48dp", 48 * density, bar.height());
        assertTrue("Chat stays within its owner", frame.contains(chat));
        assertNear("Chat sits below the top bar", bar.bottom, chat.top);
        assertNear("Chat reaches the bottom", frame.bottom, chat.bottom);
        if (!compactLayout) {
            Rect content = bounds("workbench_content");
            assertTrue("Expanded content must have area inside its owner", content.width() > 0 && content.height() > 0 && frame.contains(content));
            assertNear("Content sits below the top bar", bar.bottom, content.top);
            assertNear("Content owns the left", frame.left, content.left);
            assertNear("Chat follows content on the right", content.right, chat.left);
            assertNear("Chat reaches the trailing edge", frame.right, chat.right);
            assertNear("Content reaches the bottom", frame.bottom, content.bottom);
            assertNear("Chat width is capped at 412dp and 45 percent", Math.min(412 * density, frame.width() * 0.45), chat.width());
        } else {
            assertNear("Compact chat spans the frame", frame.left, chat.left);
            assertNear("Compact chat spans the frame", frame.right, chat.right);
            awaitTag("open_content");
            AccessibilityNodeInfo content = ChatImeTest.findTag(user, context.getPackageName(), "workbench_content");
            if (content != null) {
                try { Rect rect = new Rect(); content.getBoundsInScreen(rect);
                    assertTrue("Compact content must not take space from chat", rect.isEmpty() || !content.isVisibleToUser());
                } finally { content.recycle(); }
            }
        }
        AccessibilityNodeInfo node = ChatImeTest.findTag(user, context.getPackageName(), "workbench_frame");
        assertNotNull(node);
        try {
            Set<String> roots = new HashSet<>();
            for (int index = 0; index < node.getChildCount(); index++) {
                AccessibilityNodeInfo child = node.getChild(index);
                assertNotNull(child);
                try { String id = child.getViewIdResourceName(); roots.add(id == null ? "<untagged>" : id.substring(id.lastIndexOf('/') + 1)); }
                finally { child.recycle(); }
            }
            Set<String> expected = new HashSet<>(Arrays.asList("workbench_top_bar", "workbench_chat", "workbench_content"));
            if (compactLayout) {
                assertTrue("Compact accessibility roots stay within the three ownership slots", expected.containsAll(roots));
                assertTrue(roots.contains("workbench_top_bar") && roots.contains("workbench_chat"));
            } else {
                assertEquals("Only the three ownership roots are direct frame children", expected, roots);
                assertEquals(3, node.getChildCount());
            }
        } finally { node.recycle(); }
    }

    private void openContentIfCompact() throws Exception {
        if (compactLayout) {
            clickTag("open_content");
            awaitTag("workbench_content_sheet");
            awaitTag("close_content");
        }
    }
    private void closeContentIfCompact() throws Exception {
        if (compactLayout) {
            clickTag("close_content");
            waitFor(() -> !tagIsVisible("workbench_content_sheet"), 5000, "Content dialog did not close");
            assertFrameGeometry();
        }
    }
    private boolean tagIsVisible(String tag) {
        AccessibilityNodeInfo node = ChatImeTest.findTag(user, context.getPackageName(), tag);
        if (node == null) return false;
        try { return node.isVisibleToUser(); } finally { node.recycle(); }
    }

    private void assertSession(String draft, int turns) throws Exception {
        followActivity();
        AtomicReference<WebView> attached = new AtomicReference<>();
        getInstrumentation().runOnMainSync(() -> attached.set(findWebView(activity.getWindow().getDecorView())));
        assertSame("Navigation and configuration changes must retain the actual WebView", view, attached.get());
        assertEquals("A display change must not rotate the host generation", generation, host.getViewGeneration());
        assertEquals(documentMarker, evaluate("window.__workbenchProbe?.marker"));
        assertEquals(Boolean.TRUE, evaluate("window.__workbenchProbe?.document === document"));
        assertEquals(draft, evaluate("document.querySelector('#chat-input').value"));
        assertEquals(turns, ((Number) evaluate("document.querySelectorAll('[role=article][aria-label=\"나\"]').length")).intValue());
        assertEquals(turns, ((Number) evaluate("document.querySelectorAll('[role=article][aria-label=\"뽀미\"]').length")).intValue());
        assertFalse("No production agent session may start", host.getActive());
        assertNull(LocalTaskRunner.actionOwner());
        assertEquals(0, unexpected.get());
        assertEquals(0, ((Number) evaluate("window.__workbenchProbe.network")).intValue());
        assertEquals(0, ((Number) evaluate("window.__workbenchProbe.media")).intValue());
        assertEquals(Boolean.TRUE, evaluate("document.querySelectorAll('audio,video').length === 0"));
    }

    private void setDraft(String text) throws Exception {
        evaluate("(()=>{const input=document.querySelector('#chat-input');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,"
            + JSONObject.quote(text) + ");input.dispatchEvent(new Event('input',{bubbles:true}));return true;})()");
        waitFor(() -> text.equals(evaluate("document.querySelector('#chat-input').value")), 5000, "Composer did not retain the draft");
    }

    private void send(String text, int turn) throws Exception {
        setDraft(text);
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('button[aria-label=\"메시지 보내기\"]')?.disabled === false")),
            5000, "The shared send control did not become ready");
        evaluate("document.querySelector('button[aria-label=\"메시지 보내기\"]').click();true");
        waitFor(() -> replies.responses.size() == turn && Boolean.TRUE.equals(evaluate("(()=>{const messages=[...document.querySelectorAll('[role=article][aria-label=\"뽀미\"]')];"
            + "return messages.length===" + turn + " && messages.at(-1).textContent.includes(" + JSONObject.quote(ChatImeTest.SyntheticReplies.ANSWER)
            + ") && !document.querySelector('button[aria-label=\"진행 정지\"]');})()")), 15000, "Synthetic assistant reply did not complete");
    }

    private static boolean containsMessage(JSONArray input, String role, String text) {
        for (int index = 0; index < input.length(); index++) {
            JSONObject message = input.optJSONObject(index);
            if (message != null && role.equals(message.optString("role")) && message.optJSONArray("content") != null
                && message.optJSONArray("content").toString().contains(text)) return true;
        }
        return false;
    }

    private boolean hasSecureWindow() {
        if (Build.VERSION.SDK_INT < 29) throw new AssertionError("Secure-window proof requires Android 10 or later");
        AtomicReference<Boolean> secure = new AtomicReference<>(false);
        getInstrumentation().runOnMainSync(() -> {
            for (View root : WindowInspector.getGlobalWindowViews()) {
                if (root.isShown() && root.getLayoutParams() instanceof WindowManager.LayoutParams
                    && ((((WindowManager.LayoutParams) root.getLayoutParams()).flags & WindowManager.LayoutParams.FLAG_SECURE) != 0)) secure.set(true);
            }
        });
        return secure.get();
    }

    private void followActivity() {
        if (activities == null) return;
        Activity latest = activities.getLastActivity();
        if (latest instanceof MainActivity && !latest.isDestroyed()) activity = (MainActivity) latest;
    }
    private Rect bounds(String tag) { return ChatImeTest.taggedBounds(user, context.getPackageName(), tag); }
    private void assertNear(String message, double expected, double actual) { assertEquals(message, expected, actual, 2); }
    private void awaitTag(String tag) throws Exception {
        waitFor(() -> { AccessibilityNodeInfo node = ChatImeTest.findTag(user, context.getPackageName(), tag);
            if (node == null) return false; try { return node.isVisibleToUser(); } finally { node.recycle(); }
        }, 10000, "Missing native control: " + tag);
    }
    private void clickTag(String tag) throws Exception {
        awaitTag(tag);
        AccessibilityNodeInfo node = ChatImeTest.findTag(user, context.getPackageName(), tag);
        assertNotNull(node);
        try { assertTrue("Native click was rejected: " + tag, node.performAction(AccessibilityNodeInfo.ACTION_CLICK)); }
        finally { node.recycle(); }
        getInstrumentation().waitForIdleSync();
    }
    private static WebView findWebView(View candidate) {
        if (candidate instanceof WebView) return (WebView) candidate;
        if (candidate instanceof ViewGroup) for (int index = 0; index < ((ViewGroup) candidate).getChildCount(); index++) {
            WebView found = findWebView(((ViewGroup) candidate).getChildAt(index)); if (found != null) return found;
        }
        return null;
    }
    private Object evaluate(String script) throws Exception {
        CountDownLatch ready = new CountDownLatch(1); AtomicReference<String> answer = new AtomicReference<>();
        getInstrumentation().runOnMainSync(() -> view.evaluateJavascript(script, result -> { answer.set(result); ready.countDown(); }));
        assertTrue("Page JavaScript did not respond", ready.await(4, TimeUnit.SECONDS));
        return new JSONTokener(answer.get()).nextValue();
    }
    private interface Check { boolean ready() throws Exception; }
    private void waitFor(Check check, long timeout, String message) throws Exception {
        long deadline = SystemClock.uptimeMillis() + timeout;
        while (SystemClock.uptimeMillis() < deadline) { if (check.ready()) return; SystemClock.sleep(80); }
        fail(message);
    }
}
