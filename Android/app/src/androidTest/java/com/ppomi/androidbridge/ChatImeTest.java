package com.ppomi.androidbridge;

import android.app.UiAutomation;
import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;
import android.os.Bundle;
import android.test.InstrumentationTestCase;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebView;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.webkit.WebViewCompat;
import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;
import java.util.Collections;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Real soft-keyboard/layout proof; the bridge supplies only synthetic bootstrap/empty records.
 * Emulator preparation: save/restore secure show_ime_with_hard_keyboard=1 and
 * stylus_handwriting_enabled=0 so Gboard uses a docked software keyboard.
 */
public final class ChatImeTest extends InstrumentationTestCase {
    private Context context;
    private MainActivity activity;
    private VoiceSessionHost host;
    private WebView view;
    private String previousEndpoint;
    private final AtomicInteger unexpectedRequests = new AtomicInteger();

    @Override protected void setUp() throws Exception {
        super.setUp();
        assertTrue("IME tests run only on an emulator", BridgeSession.isEmulator());
        UiAutomation automation = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        android.accessibilityservice.AccessibilityServiceInfo serviceInfo = automation.getServiceInfo();
        serviceInfo.flags |= android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
        automation.setServiceInfo(serviceInfo);
        context = getInstrumentation().getTargetContext();
        host = VoiceSessionHost.Companion.get(context);
        assertFalse("Preserve an existing agent session", host.getActive());
        assertNull("Preserve an existing local task", LocalTaskRunner.actionOwner());
        previousEndpoint = context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE).getString("endpoint", "");
        // Disable native server requests before the first page load; credentials are never read or changed.
        assertTrue(context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE).edit().putString("endpoint", "").commit());
        getInstrumentation().runOnMainSync(() -> host.destroyHost());
        SystemClock.sleep(150);
        activity = (MainActivity) getInstrumentation().startActivitySync(new Intent(context, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK));
        waitFor(() -> {
            getInstrumentation().runOnMainSync(() -> view = findWebView(activity.getWindow().getDecorView()));
            return view != null && Boolean.TRUE.equals(evaluate("!!document.querySelector('#chat-input')"));
        }, 15000, "Bundled chat page did not load");
        getInstrumentation().runOnMainSync(() -> {
            WebViewCompat.removeWebMessageListener(view, "ppomiAgentNative");
            WebViewCompat.addWebMessageListener(view, "ppomiAgentNative", Collections.singleton(VoiceBridgePolicy.ORIGIN),
                (source, message, origin, mainFrame, proxy) -> {
                    if (source != view || !mainFrame || !VoiceBridgePolicy.ORIGIN.equals(origin.toString().replaceAll("/+$", ""))) return;
                    try {
                        JSONObject request = new JSONObject(message.getData());
                        JSONObject result;
                        if ("bootstrap".equals(request.optString("method"))) {
                            result = TaskStore.object("platform", "android", "deviceLabel", "뽀미 Android", "configured", true,
                                "endpoint", "", "accessibility", true, "controlApps", new JSONArray(), "tools", new JSONArray());
                        } else if ("request".equals(request.optString("method"))
                            && "/v1/memories/list".equals(request.getJSONObject("args").optString("path"))) {
                            result = TaskStore.object("records", new JSONArray());
                        } else { unexpectedRequests.incrementAndGet(); return; }
                        JSONObject reply = TaskStore.object("id", request.getString("id"), "result", result);
                        source.evaluateJavascript("window.ppomiAgentReceive?.(" + reply + ")", null);
                    } catch (Exception failure) { unexpectedRequests.incrementAndGet(); }
                });
            view.reload();
        });
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('#chat-input')?.disabled === false")),
            10000, "Synthetic bootstrap did not enable chat input");
    }

    @Override protected void tearDown() throws Exception {
        if (activity != null) getInstrumentation().runOnMainSync(() -> activity.finish());
        if (host != null) getInstrumentation().runOnMainSync(() -> host.destroyHost());
        if (context != null && previousEndpoint != null)
            assertTrue(context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE).edit().putString("endpoint", previousEndpoint).commit());
        getInstrumentation().waitForIdleSync();
        SystemClock.sleep(150);
        super.tearDown();
    }

    public void testRealKeyboardKeepsComposerVisibleAndPreservesDraft() throws Exception {
        AtomicInteger lastHeight = new AtomicInteger(-1), stableMeasures = new AtomicInteger();
        waitFor(() -> {
            JSONObject state = geometry();
            int height = state.getInt("viewHeight");
            boolean settled = !state.getBoolean("imeVisible") && height > 0 && state.getDouble("innerHeight") > 0
                && Math.abs(state.getJSONObject("main").getDouble("height") - state.getDouble("innerHeight")) <= 2
                && lastHeight.getAndSet(height) == height;
            if (!settled) { stableMeasures.set(0); return false; }
            return stableMeasures.incrementAndGet() >= 3;
        }, 5000, "Keyboard must begin hidden with a stable, nonzero CSS/native viewport");
        JSONObject baseline = geometry();
        assertEquals("CSS viewport must fill the WebView", baseline.getDouble("innerHeight"), baseline.getJSONObject("main").getDouble("height"), 2);
        tapInput();
        AtomicInteger keyboardModeStep = new AtomicInteger();
        try { waitFor(() -> {
            JSONObject state = geometry();
            if (state.getBoolean("imeVisible") && state.getInt("imeBottom") > state.getInt("navigationBottom") + 100) return true;
            // The emulator's Gboard may retain stylus mode. Select its normal
            // keyboard through visible system UI before testing resize behavior.
            if (keyboardModeStep.get() == 0 && clickKeyboardLabel("More stylus options")) keyboardModeStep.set(1);
            else if (keyboardModeStep.get() == 1 && clickKeyboardLabel("Show on-screen keyboard")) keyboardModeStep.set(2);
            return false;
        }, 10000, "Actual software keyboard did not open"); }
        catch (AssertionError failure) {
            saveScreenshot();
            throw new AssertionError("IME did not open; geometry=" + geometry() + "; focusedInput="
                + evaluate("document.activeElement?.id === 'chat-input'"), failure);
        }
        // Physical key injection makes Gboard replace its software keyboard with
        // a hardware-keyboard toolbar. Accessibility input preserves the real IME.
        AccessibilityNodeInfo input = editableNode();
        assertNotNull("Native textarea must remain accessible", input);
        Bundle text = new Bundle(); text.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "keyboard draft survives");
        assertTrue(input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, text)); input.recycle();
        waitFor(() -> "keyboard draft survives".equals(evaluate("document.querySelector('#chat-input').value")),
            5000, "Keyboard typing did not update the draft");
        waitFor(() -> composerAboveIme(geometry()), 5000, "Input or send button is obscured by the keyboard");
        SystemClock.sleep(350); // Finish the platform IME animation before measuring consumed insets.
        JSONObject open = geometry();
        assertTrue(composerAboveIme(open));
        saveScreenshot();
        assertTrue("IME must reduce the actual WebView height; baseline=" + baseline + "; open=" + open,
            open.getInt("viewHeight") < baseline.getInt("viewHeight"));
        int expectedReduction = open.getInt("imeBottom") - baseline.getInt("navigationBottom");
        int actualReduction = baseline.getInt("viewHeight") - open.getInt("viewHeight");
        assertTrue("IME/navigation insets must be consumed once", Math.abs(expectedReduction - actualReduction) <= 12);
        assertFalse("Typing must not start an agent/media session", host.getActive());
        assertEquals(Boolean.TRUE, evaluate("document.querySelector('button[aria-label=\\"메시지 보내기\\"]').disabled === false"));
        assertEquals(0, unexpectedRequests.get());
        assertEquals(Boolean.TRUE, evaluate("document.querySelectorAll('audio,video').length === 0"));
        getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);
        waitFor(() -> !geometry().getBoolean("imeVisible") && Math.abs(geometry().getInt("viewHeight") - baseline.getInt("viewHeight")) <= 12,
            5000, "Closing the keyboard did not restore the viewport");
        assertEquals("keyboard draft survives", evaluate("document.querySelector('#chat-input').value"));
        android.os.Bundle proof = new android.os.Bundle();
        proof.putString("imeProof", "real_keyboard,input_and_send_above_ime,draft_preserved,no_duplicate_insets,no_agent_or_media,viewport_restored");
        proof.putInt("viewportWidthPx", open.getInt("viewWidth"));
        proof.putInt("viewportHeightWithImePx", open.getInt("viewHeight"));
        proof.putInt("imeHeightPx", open.getInt("imeBottom"));
        getInstrumentation().sendStatus(0, proof);
    }

    private boolean composerAboveIme(JSONObject metrics) throws Exception {
        if (!metrics.getBoolean("imeVisible")) return false;
        double scale = metrics.getDouble("viewWidth") / metrics.getDouble("innerWidth");
        if (metrics.getInt("viewTop") + metrics.getInt("viewHeight") > metrics.getInt("imeTop") + 2) return false;
        for (String key : new String[] {"input", "send"}) {
            JSONObject box = metrics.getJSONObject(key);
            if (box.getDouble("width") <= 0 || box.getDouble("height") <= 0 || box.getDouble("top") < -1
                || box.getDouble("left") < -1 || box.getDouble("right") > metrics.getDouble("innerWidth") + 1
                || box.getDouble("bottom") > metrics.getDouble("innerHeight") + 1
                || metrics.getInt("viewTop") + box.getDouble("bottom") * scale > metrics.getInt("imeTop") + 2) return false;
        }
        return true;
    }

    private JSONObject geometry() throws Exception {
        String json = (String) evaluate("JSON.stringify((()=>{const box=s=>{const r=document.querySelector(s).getBoundingClientRect();return {top:r.top,bottom:r.bottom,left:r.left,right:r.right,width:r.width,height:r.height}};return {innerWidth,innerHeight,visualHeight:visualViewport?.height,documentHeight:document.documentElement.clientHeight,mainHeight:getComputedStyle(document.querySelector('main')).height,dvhSupported:CSS.supports('height','100dvh'),shortViewport:matchMedia('(max-height:600px)').matches,main:box('main'),root:box('#root'),body:box('body'),input:box('#chat-input'),send:box('button.send')}})())");
        JSONObject metrics = new JSONObject(json);
        getInstrumentation().runOnMainSync(() -> {
            View decor = activity.getWindow().getDecorView();
            WindowInsetsCompat insets = ViewCompat.getRootWindowInsets(decor);
            int[] origin = new int[2], windowOrigin = new int[2];
            view.getLocationOnScreen(origin); decor.getLocationOnScreen(windowOrigin);
            int ime = insets == null ? 0 : insets.getInsets(WindowInsetsCompat.Type.ime()).bottom;
            TaskStore.put(metrics, "imeVisible", insets != null && insets.isVisible(WindowInsetsCompat.Type.ime()));
            TaskStore.put(metrics, "imeBottom", ime);
            TaskStore.put(metrics, "navigationBottom", insets == null ? 0 : insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom);
            TaskStore.put(metrics, "imeTop", windowOrigin[1] + decor.getHeight() - ime);
            TaskStore.put(metrics, "viewTop", origin[1]); TaskStore.put(metrics, "viewHeight", view.getHeight());
            TaskStore.put(metrics, "viewWidth", view.getWidth());
        });
        return metrics;
    }

    private void saveScreenshot() throws Exception {
        android.graphics.Bitmap bitmap = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).takeScreenshot();
        if (bitmap == null) return;
        try (java.io.FileOutputStream output = new java.io.FileOutputStream(new java.io.File(context.getCacheDir(), "chat-ime-proof.png"))) {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output);
        } finally { bitmap.recycle(); }
    }

    private void tapInput() throws Exception {
        JSONObject metrics = geometry();
        JSONObject box = metrics.getJSONObject("input");
        float scale = (float) (metrics.getDouble("viewWidth") / metrics.getDouble("innerWidth"));
        int[] origin = new int[2]; getInstrumentation().runOnMainSync(() -> view.getLocationOnScreen(origin));
        float x = origin[0] + (float) ((box.getDouble("left") + box.getDouble("right")) / 2) * scale;
        float y = origin[1] + (float) ((box.getDouble("top") + box.getDouble("bottom")) / 2) * scale;
        long now = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties pointer = new MotionEvent.PointerProperties();
        pointer.id = 0; pointer.toolType = MotionEvent.TOOL_TYPE_FINGER;
        MotionEvent.PointerCoords coordinate = new MotionEvent.PointerCoords();
        coordinate.x = x; coordinate.y = y; coordinate.pressure = 1; coordinate.size = 1;
        MotionEvent down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, 1,
            new MotionEvent.PointerProperties[] {pointer}, new MotionEvent.PointerCoords[] {coordinate},
            0, 0, 1, 1, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0);
        MotionEvent up = MotionEvent.obtain(now, now + 70, MotionEvent.ACTION_UP, 1,
            new MotionEvent.PointerProperties[] {pointer}, new MotionEvent.PointerCoords[] {coordinate},
            0, 0, 1, 1, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0);
        try { getInstrumentation().sendPointerSync(down); getInstrumentation().sendPointerSync(up); }
        finally { down.recycle(); up.recycle(); }
    }
    private AccessibilityNodeInfo editableNode() {
        AccessibilityNodeInfo root = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).getRootInActiveWindow();
        if (root == null) return null;
        try { return editableNode(root, 0); } finally { root.recycle(); }
    }
    private boolean clickKeyboardLabel(String label) {
        boolean clicked = false;
        for (android.view.accessibility.AccessibilityWindowInfo window : getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).getWindows()) {
            AccessibilityNodeInfo node = window.getRoot();
            if (node != null) { try { if (!clicked) clicked = clickKeyboardLabel(node, label, 0); } finally { node.recycle(); } }
            window.recycle();
        }
        return clicked;
    }
    private boolean clickKeyboardLabel(AccessibilityNodeInfo node, String label, int depth) {
        if (depth > 20) return false;
        if ("com.google.android.inputmethod.latin".contentEquals(node.getPackageName() == null ? "" : node.getPackageName())
            && (label.contentEquals(node.getText() == null ? "" : node.getText())
                || label.contentEquals(node.getContentDescription() == null ? "" : node.getContentDescription()))) {
            return node.performAction(AccessibilityNodeInfo.ACTION_CLICK);
        }
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo child = node.getChild(index); if (child == null) continue;
            try { if (clickKeyboardLabel(child, label, depth + 1)) return true; } finally { child.recycle(); }
        }
        return false;
    }
    private AccessibilityNodeInfo editableNode(AccessibilityNodeInfo node, int depth) {
        if (depth > 30) return null;
        if (node.isEditable() && context.getPackageName().contentEquals(node.getPackageName() == null ? "" : node.getPackageName()))
            return AccessibilityNodeInfo.obtain(node);
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo child = node.getChild(index); if (child == null) continue;
            try { AccessibilityNodeInfo found = editableNode(child, depth + 1); if (found != null) return found; }
            finally { child.recycle(); }
        }
        return null;
    }
    private WebView findWebView(View candidate) {
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
