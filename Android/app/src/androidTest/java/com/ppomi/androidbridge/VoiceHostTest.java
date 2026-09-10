package com.ppomi.androidbridge;

import android.Manifest;
import android.app.ActivityManager;
import android.app.NotificationManager;
import android.app.UiAutomation;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.service.notification.StatusBarNotification;
import android.test.InstrumentationTestCase;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.webkit.WebView;
import androidx.webkit.WebViewCompat;
import org.json.JSONObject;
import org.json.JSONArray;
import org.json.JSONTokener;
import java.io.File;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.Collections;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Emulator-only runtime proof. The network test replaces getUserMedia with a synthetic stream in test JS. */
public final class VoiceHostTest extends InstrumentationTestCase {
    private Context context;
    private MainActivity activity;
    private VoiceSessionHost host;
    private WebView view;
    private File testFile;
    private Map<String, String> recordsBefore;
    private final CopyOnWriteArrayList<String> networkStages = new CopyOnWriteArrayList<>();

    @Override protected void setUp() throws Exception {
        super.setUp();
        assertTrue("Voice runtime tests are restricted to emulators", BridgeSession.isEmulator());
        context = getInstrumentation().getTargetContext();
        UiAutomation user = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        if (!getName().startsWith("testText")) {
            user.grantRuntimePermission(context.getPackageName(), Manifest.permission.RECORD_AUDIO);
            if (Build.VERSION.SDK_INT >= 33) user.grantRuntimePermission(context.getPackageName(), Manifest.permission.POST_NOTIFICATIONS);
        }
        host = VoiceSessionHost.Companion.get(context);
        assertFalse("Do not interrupt an existing voice session", host.getActive());
        assertNull("Do not interrupt an existing legacy task", LocalTaskRunner.actionOwner());
        // Instrumentation prepares its own target app's private preferences. The
        // public launcher no longer accepts endpoint/credential setup extras.
        assertTrue(context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE).edit()
            .putString("endpoint", "https://ppomi-agent.vercel.app").commit());
        activity = (MainActivity) getInstrumentation().startActivitySync(new Intent(context, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK));
        awaitPage();
        recordsBefore = taskFiles();
        probe();
    }

    @Override protected void tearDown() throws Exception {
        if (host != null) getInstrumentation().runOnMainSync(() -> host.stopVoice());
        if (testFile != null) Files.deleteIfExists(testFile.toPath());
        if (recordsBefore != null) assertEquals("Ephemeral voice must not create or modify task records", recordsBefore, taskFiles());
        if (activity != null) getInstrumentation().runOnMainSync(() -> activity.finish());
        // Finish the previous Activity and its delayed WebView disposal before the
        // next test creates a new Activity against the process-wide voice host.
        getInstrumentation().waitForIdleSync();
        SystemClock.sleep(150);
        super.tearDown();
    }

    public void testPublicLauncherCannotReplaceProvisioning() throws Exception {
        String endpoint = context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE).getString("endpoint", "");
        String credential = context.getSharedPreferences("ssot_settings", Context.MODE_PRIVATE).getString("encrypted_config", null);
        String token = BridgeSession.token(context);
        Intent untrusted = new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("configure_agent_endpoint", "https://attacker.invalid")
            .putExtra("ssot_config", "{}")
            .putExtra("bridge_token", "synthetic-untrusted-token-0000000000000000");
        getInstrumentation().runOnMainSync(() -> context.startActivity(untrusted));
        getInstrumentation().waitForIdleSync();
        assertTrue("Public launcher must not redirect authenticated requests", endpoint.equals(
            context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE).getString("endpoint", "")));
        assertTrue("Public launcher must not replace encrypted device credentials", java.util.Objects.equals(credential,
            context.getSharedPreferences("ssot_settings", Context.MODE_PRIVATE).getString("encrypted_config", null)));
        assertTrue("Public launcher must not replace the MCP bearer token", token.equals(BridgeSession.token(context)));
    }

    public void testDebugProvisioningRequiresPrivilegedPermission() throws Exception {
        android.content.pm.PackageManager manager = context.getPackageManager();
        android.content.pm.ActivityInfo setup = manager.getActivityInfo(new android.content.ComponentName(
            context.getPackageName(), context.getPackageName() + ".DebugProvisioningActivity"), 0);
        assertTrue("Debug setup must be guarded by the platform DUMP permission",
            Manifest.permission.DUMP.equals(setup.permission));
        assertTrue("ADB setup component must be reachable with its required permission", setup.exported);
        assertEquals("An ordinary installed test app must not hold the setup permission",
            android.content.pm.PackageManager.PERMISSION_DENIED,
            manager.checkPermission(Manifest.permission.DUMP, getInstrumentation().getContext().getPackageName()));
    }

    public void testNativeFilesAndNotificationStopAcrossAppSwitch() throws Exception {
        JSONObject bootstrap = call("bootstrap", new JSONObject()).getJSONObject("result");
        assertEquals("android", bootstrap.getString("platform"));
        assertEquals("https://ppomi-agent.vercel.app", bootstrap.getString("endpoint"));
        assertTrue(call("executeTool", tool("file_list", new JSONObject())).has("error"));
        assertTrue(call("sessionState", new JSONObject().put("active", true)).getJSONObject("result").getBoolean("active"));
        waitFor(() -> host.getActive() && serviceRunning(), 10000, "Foreground voice service did not start");
        JSONObject status = call("executeTool", tool("device_status", new JSONObject())).getJSONObject("result");
        assertTrue(status.has("accessibility"));
        String path = "instrumentation-" + UUID.randomUUID() + ".txt";
        testFile = new File(context.getFilesDir(), "AgentWorkspace/" + path);
        JSONObject written = call("executeTool", tool("file_write", new JSONObject().put("path", path)
            .put("content", "Synthetic tool result · 합성 도구 결과"))).getJSONObject("result");
        assertTrue(written.getBoolean("verified"));
        JSONObject read = call("executeTool", tool("file_read", new JSONObject().put("path", path))).getJSONObject("result");
        assertEquals(written.getString("sha256"), read.getString("sha256"));
        assertTrue(call("executeTool", tool("file_read", new JSONObject().put("path", "../tasks/private.json"))).has("error"));
        int generation = host.getViewGeneration();
        openFixture();
        SystemClock.sleep(1200);
        assertTrue("Voice survives another foreground app", host.getActive());
        assertTrue("Microphone foreground service survives another app", serviceRunning());
        boolean sentStop = false;
        for (StatusBarNotification item : context.getSystemService(NotificationManager.class).getActiveNotifications()) {
            if (!"ppomi_active_voice".equals(item.getNotification().getChannelId())) continue;
            assertTrue(item.getNotification().actions.length > 0);
            item.getNotification().actions[0].actionIntent.send();
            sentStop = true;
        }
        assertTrue("Ongoing notification exposes stop", sentStop);
        waitFor(() -> !host.getActive() && !serviceRunning() && host.getViewGeneration() > generation,
            10000, "Notification stop did not release service and old page");
        returnToVoice();
        probe();
        assertTrue(call("executeTool", tool("file_list", new JSONObject())).has("error"));
        int idleGeneration = host.getViewGeneration();
        getInstrumentation().runOnMainSync(() -> { host.stopVoice(); host.stopVoice(); });
        SystemClock.sleep(250);
        assertEquals("Repeated stop must not destroy a new idle page", idleGeneration, host.getViewGeneration());
        assertEquals(recordsBefore, taskFiles());
        proof("native_voice_lifetime", "active_only_tools,verified_file_write,foreground_app_switch,notification_stop,page_disposal,idempotent_stop,no_task_records");
    }

    public void testSyntheticRealtimeConnectMuteAndTeardown() throws Exception {
        JSONObject bootstrap = call("bootstrap", new JSONObject()).getJSONObject("result");
        assertTrue("Emulator needs its existing device-only Supabase configuration", bootstrap.getBoolean("configured"));
        clickNativeText("음성");
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('button.primary')?.disabled === false")),
            5000, "Voice start button remained disabled");
        getInstrumentation().runOnMainSync(() -> WebViewCompat.addWebMessageListener(view, "ppomiVoiceTest",
            Collections.singleton(VoiceBridgePolicy.ORIGIN), (webView, message, origin, mainFrame, reply) -> {
                String stage = message.getData();
                if (mainFrame && stage != null && stage.matches("[a-z0-9_:-]{1,80}")) {
                    networkStages.add(stage); proof("synthetic_stage", stage);
                }
            }));
        // WebMessageListener appears on the next navigation; the native production bridge has no testing hooks.
        getInstrumentation().runOnMainSync(() -> view.reload());
        waitFor(() -> Boolean.TRUE.equals(evaluate("!!window.ppomiVoiceTest && !!document.querySelector('#chat-input')")),
            10000, "Synthetic probe did not initialize");
        clickNativeText("음성");
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('button.primary')?.disabled === false")), 5000, "Voice mode not ready");
        probe();
        evaluate("(() => { const report=s=>window.ppomiVoiceTest.postMessage(s); const fetch=window.fetch;"
            + "const send=window.ppomiAgentNative.postMessage.bind(window.ppomiAgentNative);window.ppomiAgentNative.postMessage=raw=>{"
            + "const request=JSON.parse(raw);if(request.method==='sessionState')report(request.args.active?'native_start_sent':'native_stop_sent');send(raw);};"
            + "window.addEventListener('unhandledrejection',event=>{report('unhandled_rejection');"
            + "if(event.reason instanceof TypeError)report('type_error');if(String(event.reason?.message).includes('splice'))report('splice_error');});"
            + "window.fetch=async(...args)=>{report('fetch_start');try{const response=await fetch(...args);report('fetch_status_'+response.status);return response;}"
            + "catch(error){report('fetch_failed');throw error;}}; const Peer=window.RTCPeerConnection;"
            + "window.RTCPeerConnection=class extends Peer{constructor(...args){super(...args);report('peer_created');"
            + "window.__voiceProbe.peer=this;"
            + "this.addEventListener('connectionstatechange',()=>report('peer_'+this.connectionState));}};"
            + "const receive=window.ppomiAgentReceive;window.ppomiAgentReceive=r=>{if(r.error)report('native_error');"
            + "else if(r.result?.clientSecret)report('ephemeral_received');receive(r);};return true;})()");
        evaluate("(() => { window.__voiceProbe.syntheticCalls = 0; "
            + "Object.defineProperty(navigator.mediaDevices, 'getUserMedia', {configurable:true, value:async () => {"
            + "window.__voiceProbe.syntheticCalls++;"
            + "window.ppomiVoiceTest.postMessage('synthetic_audio_created');"
            + "const audio = new AudioContext(); const destination = audio.createMediaStreamDestination();"
            + "window.__voiceProbe.syntheticContext = audio; window.__voiceProbe.syntheticStream = destination.stream;"
            + "return destination.stream; }}); document.querySelector('button.primary').click(); return true; })()");
        try {
            waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('.chat-status')?.textContent === '듣고 있어요'")),
                45000, "Synthetic Realtime connection did not reach listening state");
        } catch (AssertionError failure) {
            throw new AssertionError("Synthetic Realtime failed; safe stages=" + networkStages + "; active=" + host.getActive(), failure);
        }
        assertTrue(host.getActive());
        assertTrue(serviceRunning());
        assertEquals(1, ((Number) evaluate("window.__voiceProbe.syntheticCalls")).intValue());
        assertEquals("live", evaluate("window.__voiceProbe.syntheticStream.getAudioTracks()[0].readyState"));
        evaluate("document.querySelector('button.mute').click(); true");
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('button.mute')?.getAttribute('aria-pressed') === 'true'")),
            5000, "Mute button state not updated");
        evaluate("document.querySelector('button.mute').click(); true");
        openFixture();
        SystemClock.sleep(1500);
        assertTrue("Realtime host remains active behind another app", host.getActive());
        assertEquals("live", evaluate("window.__voiceProbe.syntheticStream.getAudioTracks()[0].readyState"));
        int generation = host.getViewGeneration();
        Object stopped = evaluate("(() => { window.ppomiVoiceStop(); const stopped = window.__voiceProbe.syntheticStream"
            + ".getAudioTracks().every(track => track.readyState === 'ended') && window.__voiceProbe.peer.connectionState === 'closed'"
            + "&& document.querySelectorAll('audio').length === 0; window.__voiceProbe.syntheticContext.close(); return stopped; })()");
        assertEquals(Boolean.TRUE, stopped);
        try {
            waitFor(() -> !host.getActive() && !serviceRunning() && host.getViewGeneration() > generation,
                10000, "Realtime stop did not release service and page");
        } catch (AssertionError failure) {
            throw new AssertionError("Stop failure; safe stages=" + networkStages + "; active=" + host.getActive()
                + "; service=" + serviceRunning() + "; generation=" + generation + "->" + host.getViewGeneration(), failure);
        }
        assertTrue(context.getSystemService(AudioManager.class).getMode() != AudioManager.MODE_IN_COMMUNICATION);
        assertEquals(recordsBefore, taskFiles());
        proof("synthetic_realtime", "trusted_bundled_ui,live_realtime_connection,synthetic_audio_only,mute,background_continuity,tracks_ended,service_stopped,page_disposed,no_task_records");
    }

    public void testStoreSearchRejectsInactiveAndCompetingControlOwners() throws Exception {
        reconnectEmulatorAccessibility();
        waitFor(() -> BridgeAccessibilityService.getInstance() != null, 10000, "Emulator accessibility service is required");
        JSONArray tools = call("bootstrap", new JSONObject()).getJSONObject("result").getJSONArray("tools");
        boolean advertised = false;
        for (int index = 0; index < tools.length(); index++) if ("store_search".equals(tools.getString(index))) advertised = true;
        assertTrue(advertised);
        JSONObject query = new JSONObject().put("query", "테스트 앱");
        assertEquals("protected_action", call("executeTool", tool("store_search", query)).getJSONObject("error").getString("code"));
        BridgeAccessibilityService bridge = BridgeAccessibilityService.getInstance();
        try { bridge.executeLocal("store_search", query, null); fail("Inactive direct store control was accepted"); }
        catch (Exception expected) { assertEquals("protected_action", VoiceToolErrors.code(expected)); }
        assertTrue(call("sessionState", new JSONObject().put("active", true).put("mode", "text")).getJSONObject("result").getBoolean("active"));
        try { bridge.executeLocal("store_search", query, null); fail("Competing external store control was accepted"); }
        catch (Exception expected) { /* Existing common owner gate rejects external execution. */ }
        try { bridge.executeLocal("store_search", query, "voice:expired-session"); fail("Stale session owner was accepted"); }
        catch (Exception expected) { /* A different session cannot borrow the current control owner. */ }
        assertEquals("tool_failed", call("executeTool", tool("store_search", new JSONObject().put("query", "https://example.test")))
            .getJSONObject("error").getString("code"));
        proof("store_search_boundary", "advertised,active_only,external_owner_denied,stale_owner_denied,url_rejected,no_store_launch");
    }

    public void testAppDiscoveryErrorsAndProtectedParentAction() throws Exception {
        reconnectEmulatorAccessibility();
        waitFor(() -> BridgeAccessibilityService.getInstance() != null, 10000, "Emulator accessibility service is required");
        JSONObject bootstrap = call("bootstrap", new JSONObject()).getJSONObject("result");
        assertTrue(bootstrap.getBoolean("accessibility"));
        JSONArray controls = bootstrap.getJSONArray("controlApps");
        for (int index = 0; index < controls.length(); index++)
            assertFalse(context.getPackageName().equals(controls.getJSONObject(index).getString("packageName")));
        assertTrue(call("executeTool", tool("app_list", new JSONObject().put("query", ""))).has("error"));
        call("sessionState", new JSONObject().put("active", true));
        JSONObject listed = call("executeTool", tool("app_list", new JSONObject().put("query", "com.ppomi.androidtarget"))).getJSONObject("result");
        assertEquals(1, listed.getJSONArray("apps").length());
        JSONObject fixture = listed.getJSONArray("apps").getJSONObject(0);
        assertTrue(fixture.getBoolean("allowed"));
        assertEquals("app_not_found", call("executeTool", tool("app_open", new JSONObject().put("target", "missing.uninstalled.app")))
            .getJSONObject("error").getString("code"));
        assertEquals("protected_action", call("executeTool", tool("app_open", new JSONObject().put("target", context.getPackageName())))
            .getJSONObject("error").getString("code"));
        for (BridgeAccessPolicy.App app : BridgeAccessPolicy.launchableApps(context)) {
            if (BridgeAccessPolicy.allowedPackages(context).contains(app.packageName)) continue;
            assertEquals("app_not_allowed", call("executeTool", tool("app_open", new JSONObject().put("target", app.packageName)))
                .getJSONObject("error").getString("code"));
            break;
        }
        assertTrue(call("setControlApps", new JSONObject()).has("error"));
        try { BridgeAccessPolicy.saveUserPackages(context, java.util.Collections.emptySet()); fail("Active voice changed app authorization"); }
        catch (IllegalStateException expected) {}
        JSONObject opened = call("executeTool", tool("app_open", new JSONObject().put("target", fixture.getString("label")))).getJSONObject("result");
        assertEquals("com.ppomi.androidtarget", opened.getString("opened"));
        assertEquals("App-open returns after the target becomes stable", "com.ppomi.androidtarget",
            call("executeTool", tool("device_status", new JSONObject())).getJSONObject("result").optString("foregroundPackage"));
        JSONArray nodes = call("executeTool", tool("screen_read", new JSONObject())).getJSONObject("result").getJSONArray("nodes");
        JSONObject label = nodeWithText(nodes, "송금");
        assertNotNull("Protected child fixture is visible", label);
        String parentId = label.getString("parentId");
        JSONObject parent = null;
        for (int index = 0; index < nodes.length(); index++) if (parentId.equals(nodes.getJSONObject(index).getString("id"))) parent = nodes.getJSONObject(index);
        assertNotNull(parent);
        assertTrue(parent.getBoolean("clickable"));
        assertEquals("", parent.getString("text"));
        assertEquals("protected_action", call("executeTool", tool("ui_tap", new JSONObject().put("nodeId", parentId)))
            .getJSONObject("error").getString("code"));
        nodes = call("executeTool", tool("screen_read", new JSONObject())).getJSONObject("result").getJSONArray("nodes");
        assertNotNull(nodeWithText(nodes, "Protected fixture count: 0"));
        JSONObject publisher = nodeWithText(nodes, "Publisher card");
        assertNotNull("Synthetic publisher card is visible", publisher);
        assertTrue(publisher.getString("contentDescription").contains("금융결제원"));
        assertTrue(call("executeTool", tool("ui_tap", new JSONObject().put("nodeId", publisher.getString("parentId"))))
            .getJSONObject("result").getBoolean("performed"));
        nodes = call("executeTool", tool("screen_read", new JSONObject())).getJSONObject("result").getJSONArray("nodes");
        assertNotNull(nodeWithText(nodes, "Publisher fixture count: 1"));
        assertNotNull(nodeWithText(nodes, "Protected fixture count: 0"));
        JSONObject increment = nodeWithText(nodes, "Increment");
        assertNotNull(increment);
        assertTrue(call("executeTool", tool("ui_tap", new JSONObject().put("nodeId", increment.getString("id"))))
            .getJSONObject("result").getBoolean("performed"));
        assertEquals("stale_screen", call("executeTool", tool("ui_tap", new JSONObject().put("nodeId", increment.getString("id"))))
            .getJSONObject("error").getString("code"));
        proof("app_control", "native_app_catalog,exact_label_open,denied_unselected_app,protected_own_app,no_tool_permission_changes,protected_child_parent_denied,publisher_parent_allowed,safe_click,stale_screen_code");
    }

    public void testNativeAppPickerPersistsSelectionAndRefreshesBootstrap() throws Exception {
        BridgeAccessPolicy.App candidate = null;
        for (BridgeAccessPolicy.App app : BridgeAccessPolicy.launchableApps(context))
            if (!BridgeAccessPolicy.defaultPackages(context).contains(app.packageName)) { candidate = app; break; }
        assertNotNull(candidate);
        final String selectedPackage = candidate.packageName;
        Set<String> before = BridgeAccessPolicy.userPackages(context);
        boolean originallySelected = before.contains(selectedPackage);
        int generation = host.getViewGeneration();
        try {
            clickNativeText("제어 앱");
            waitFor(() -> hasNativeNode(node -> node.isEditable()), 5000, "Native app picker did not open");
            AccessibilityNodeInfo search = nativeNode(node -> node.isEditable());
            Bundle arguments = new Bundle(); arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, selectedPackage);
            assertTrue(search.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)); search.recycle();
            waitFor(() -> hasNativeNode(node -> node.isCheckable() && node.isEnabled()), 5000, "Selectable app checkbox did not appear");
            AccessibilityNodeInfo checkbox = nativeNode(node -> node.isCheckable() && node.isEnabled());
            assertEquals(originallySelected, checkbox.isChecked());
            android.graphics.Bitmap capture = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).takeScreenshot();
            assertNotNull(capture);
            try (java.io.FileOutputStream output = new java.io.FileOutputStream(new File(context.getCacheDir(), "voice-app-picker.png"))) {
                assertTrue(capture.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output));
            } finally { capture.recycle(); }
            assertTrue(checkbox.performAction(AccessibilityNodeInfo.ACTION_CLICK)); checkbox.recycle();
            clickNativeText("저장");
            waitFor(() -> BridgeAccessPolicy.userPackages(context).contains(selectedPackage) != originallySelected,
                5000, "Native app selection did not persist");
            waitFor(() -> host.getViewGeneration() > generation, 5000, "Picker did not refresh the idle voice page");
            awaitPage(); probe();
            JSONArray controls = call("bootstrap", new JSONObject()).getJSONObject("result").getJSONArray("controlApps");
            boolean present = false;
            for (int index = 0; index < controls.length(); index++) if (selectedPackage.equals(controls.getJSONObject(index).getString("packageName"))) present = true;
            assertEquals(!originallySelected, present);
            proof("native_app_picker", "user_ui_selection,persisted_choice,fresh_bootstrap,no_model_permission_tool");
        } finally {
            assertTrue(context.getSharedPreferences("control_app_access", Context.MODE_PRIVATE).edit().putStringSet("user_packages", before).commit());
        }
    }

    /** Actual bundled chat UI -> live model -> accessibility fixture action -> visible chat answer. */
    public void testTextChatUiControlsFixtureWithoutMicrophonePermission() throws Exception {
        assertEquals("Run this emulator test after revoking microphone permission", android.content.pm.PackageManager.PERMISSION_DENIED,
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO));
        if (Build.VERSION.SDK_INT >= 33) assertEquals("Text must also start with notifications denied",
            android.content.pm.PackageManager.PERMISSION_DENIED, context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS));
        reconnectEmulatorAccessibility();
        waitFor(() -> BridgeAccessibilityService.getInstance() != null, 10000, "Emulator accessibility did not reconnect");
        Intent fixture = context.getPackageManager().getLaunchIntentForPackage("com.ppomi.androidtarget");
        assertNotNull(fixture);
        context.startActivity(fixture.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK));
        waitFor(() -> hasNativeNode(node -> "Count: 0".contentEquals(node.getText() == null ? "" : node.getText())), 5000, "Fixture counter did not reset");
        returnToVoice();
        int audioMode = context.getSystemService(AudioManager.class).getMode();
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('#chat-input')?.disabled === false")), 5000, "Chat input is not ready");
        waitFor(() -> hasNativeNode(node -> node.isEditable() && context.getPackageName().contentEquals(
            node.getPackageName() == null ? "" : node.getPackageName())), 5000, "Ppomi chat did not become the foreground input surface");
        AccessibilityNodeInfo input = nativeNode(node -> node.isEditable() && context.getPackageName().contentEquals(
            node.getPackageName() == null ? "" : node.getPackageName()));
        assertNotNull("Actual chat input must be accessible", input);
        String prompt = "이 테스트는 기억에 저장하지 마. app_list로 Ppomi control target 앱을 찾아 열고, 화면을 읽어서 Increment 버튼을 정확히 한 번 눌러 줘. 다시 화면을 읽고 Count가 1인지 확인한 뒤 한국어로 알려 줘. 송금 버튼은 누르지 마.";
        Bundle arguments = new Bundle(); arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, prompt);
        assertTrue(input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)); input.recycle();
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('#chat-input')?.value.length > 0")), 5000, "Native text input did not reach the actual chat field");
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('button[aria-label=\\"메시지 보내기\\"]')?.disabled === false")), 5000, "UI send button did not enable");
        clickNativeText("메시지 보내기");
        waitFor(() -> host.getActive() && "text".equals(host.getMode()) && serviceRunning(), 15000, "Text foreground session did not start");
        assertEquals(audioMode, context.getSystemService(AudioManager.class).getMode());
        assertEquals(android.content.pm.PackageManager.PERMISSION_DENIED, context.checkSelfPermission(Manifest.permission.RECORD_AUDIO));
        if (Build.VERSION.SDK_INT >= 33) assertEquals(android.content.pm.PackageManager.PERMISSION_DENIED, context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS));
        waitFor(() -> hasNativeNode(node -> "Count: 1".contentEquals(node.getText() == null ? "" : node.getText())),
            90000, "Live text model did not perform the requested single fixture action");
        assertTrue("Text agent continues while the fixture is foreground", host.getActive() && serviceRunning());
        waitFor(() -> Boolean.TRUE.equals(evaluate("document.querySelector('.chat-status')?.textContent === '메시지를 보내 주세요' && "
            + "!!document.querySelector('.message.assistant p')?.textContent?.trim()")), 45000, "Model did not finish with a chat response");
        assertEquals(Boolean.TRUE, evaluate("document.querySelectorAll('audio,video').length === 0"));
        assertEquals(Boolean.TRUE, evaluate("[...document.querySelectorAll('.tool-progress li.success')].some(item=>item.textContent.includes('화면'))"));
        returnToVoice();
        assertEquals(Boolean.TRUE, evaluate("!!document.querySelector('.message.assistant p')?.textContent?.trim()"));
        android.graphics.Bitmap capture = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).takeScreenshot();
        assertNotNull(capture);
        try (java.io.FileOutputStream output = new java.io.FileOutputStream(new File(context.getCacheDir(), "text-agent-ui-proof.png"))) {
            assertTrue(capture.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output));
        } finally { capture.recycle(); }
        int generation = host.getViewGeneration();
        clickNativeText("대화 종료");
        waitFor(() -> !host.getActive() && !serviceRunning() && host.getViewGeneration() > generation, 10000, "Text stop did not release its service/page");
        awaitPage();
        assertEquals(Boolean.TRUE, evaluate("document.querySelectorAll('.message').length === 0 && document.querySelectorAll('audio,video').length === 0"));
        assertEquals(audioMode, context.getSystemService(AudioManager.class).getMode());
        assertEquals(recordsBefore, taskFiles());
        proof("text_chat_ui", "actual_accessible_input_and_send,live_text_model,app_discovery,fixture_open,single_verified_click,chat_response,background_continuity,no_mic_or_notification_permission,no_audio,service_stop,ephemeral_chat_cleared,no_task_records");
    }

    private interface NodeMatch { boolean matches(AccessibilityNodeInfo node); }
    private boolean hasNativeNode(NodeMatch match) {
        AccessibilityNodeInfo node = nativeNode(match);
        if (node == null) return false;
        node.recycle(); return true;
    }
    private AccessibilityNodeInfo nativeNode(NodeMatch match) {
        AccessibilityNodeInfo root = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).getRootInActiveWindow();
        if (root == null) return null;
        try { return matchingNode(root, match, 0); } finally { root.recycle(); }
    }
    private AccessibilityNodeInfo matchingNode(AccessibilityNodeInfo node, NodeMatch match, int depth) {
        if (depth > 30) return null;
        if (match.matches(node)) return AccessibilityNodeInfo.obtain(node);
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo child = node.getChild(index); if (child == null) continue;
            try { AccessibilityNodeInfo found = matchingNode(child, match, depth + 1); if (found != null) return found; }
            finally { child.recycle(); }
        }
        return null;
    }
    private void clickNativeText(String text) throws Exception {
        AtomicReference<AccessibilityNodeInfo> match = new AtomicReference<>();
        waitFor(() -> { match.set(nativeNode(node -> text.contentEquals(node.getText() == null ? "" : node.getText())
            || text.contentEquals(node.getContentDescription() == null ? "" : node.getContentDescription()))); return match.get() != null; },
            5000, "Native action not visible");
        AccessibilityNodeInfo node = match.get();
        while (!node.isClickable()) {
            AccessibilityNodeInfo parent = node.getParent(); node.recycle(); node = parent;
            assertNotNull("Native action must have a clickable parent", node);
        }
        assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK)); node.recycle();
    }

    private JSONObject nodeWithText(JSONArray nodes, String text) throws Exception {
        for (int index = 0; index < nodes.length(); index++) if (text.equalsIgnoreCase(nodes.getJSONObject(index).optString("text"))) return nodes.getJSONObject(index);
        return null;
    }

    private void reconnectEmulatorAccessibility() throws Exception {
        assertTrue(BridgeSession.isEmulator());
        if (BridgeAccessibilityService.getInstance() != null) return;
        // Starting instrumentation kills the previously bound target process. Reset
        // only this emulator service's binding; no production setup hook is needed.
        UiAutomation automation = getInstrumentation().getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        automation.adoptShellPermissionIdentity(Manifest.permission.WRITE_SECURE_SETTINGS);
        try {
            String key = android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES;
            String previous = android.provider.Settings.Secure.getString(context.getContentResolver(), key);
            java.util.ArrayList<String> services = new java.util.ArrayList<>();
            if (previous != null) for (String service : previous.split(":"))
                if (!service.isEmpty() && !service.startsWith(context.getPackageName() + "/")) services.add(service);
            assertTrue(android.provider.Settings.Secure.putString(context.getContentResolver(), key, String.join(":", services)));
            SystemClock.sleep(300);
            services.add(context.getPackageName() + "/.BridgeAccessibilityService");
            assertTrue(android.provider.Settings.Secure.putString(context.getContentResolver(), key, String.join(":", services)));
            assertTrue(android.provider.Settings.Secure.putInt(context.getContentResolver(), android.provider.Settings.Secure.ACCESSIBILITY_ENABLED, 1));
        } finally { automation.dropShellPermissionIdentity(); }
    }

    private JSONObject tool(String name, JSONObject args) throws Exception { return new JSONObject().put("name", name).put("args", args); }
    private void awaitPage() throws Exception {
        waitFor(() -> {
            getInstrumentation().runOnMainSync(() -> view = findWebView(activity.getWindow().getDecorView()));
            return view != null && Boolean.TRUE.equals(evaluate("!!window.ppomiAgentReceive && !!document.querySelector('button.primary, #chat-input')"));
        }, 15000, "Trusted bundled voice UI did not load");
    }
    private WebView findWebView(View candidate) {
        if (candidate instanceof WebView) return (WebView) candidate;
        if (candidate instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) candidate;
            for (int i = 0; i < group.getChildCount(); i++) { WebView found = findWebView(group.getChildAt(i)); if (found != null) return found; }
        }
        return null;
    }
    private void probe() throws Exception {
        evaluate("(() => { window.__voiceProbe={replies:{}}; const receive=window.ppomiAgentReceive; window.ppomiAgentReceive=r=>"
            + "{window.__voiceProbe.replies[r.id]=r;receive?.(r)}; return true; })()");
    }
    private JSONObject call(String method, JSONObject args) throws Exception {
        String id = UUID.randomUUID().toString();
        JSONObject request = new JSONObject().put("id", id).put("method", method).put("args", args);
        evaluate("window.ppomiAgentNative.postMessage(" + JSONObject.quote(request.toString()) + "); true");
        AtomicReference<JSONObject> answer = new AtomicReference<>();
        waitFor(() -> {
            Object result = evaluate("JSON.stringify(window.__voiceProbe?.replies[" + JSONObject.quote(id) + "] ?? null)");
            if (!(result instanceof String) || "null".equals(result)) return false;
            answer.set(new JSONObject((String) result)); return true;
        }, 15000, "Native bridge reply timed out");
        evaluate("delete window.__voiceProbe.replies[" + JSONObject.quote(id) + "]; true");
        return answer.get();
    }
    private Object evaluate(String script) throws Exception {
        CountDownLatch ready = new CountDownLatch(1); AtomicReference<String> answer = new AtomicReference<>();
        getInstrumentation().runOnMainSync(() -> view.evaluateJavascript(script, value -> { answer.set(value); ready.countDown(); }));
        if (!ready.await(4, TimeUnit.SECONDS)) throw new AssertionError("Voice page JavaScript did not respond");
        return new JSONTokener(answer.get()).nextValue();
    }
    private boolean serviceRunning() {
        for (ActivityManager.RunningServiceInfo info : context.getSystemService(ActivityManager.class).getRunningServices(30))
            if (VoiceForegroundService.class.getName().equals(info.service.getClassName())) return info.foreground;
        return false;
    }
    private void openFixture() {
        Intent fixture = context.getPackageManager().getLaunchIntentForPackage("com.ppomi.androidtarget");
        assertNotNull("Safe fixture app must be installed", fixture);
        context.startActivity(fixture.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }
    private void returnToVoice() throws Exception {
        // This is an explicit user/ADB return, not a background activity launch by the agent.
        // Modern Android correctly blocks context.startActivity while the fixture is foreground.
        try (android.os.ParcelFileDescriptor result = getInstrumentation()
                .getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
                .executeShellCommand("am start -n com.ppomi.androidbridge/.MainActivity --ez show_voice true");
             java.io.FileInputStream input = new java.io.FileInputStream(result.getFileDescriptor())) {
            byte[] buffer = new byte[1024]; while (input.read(buffer) != -1) {}
        }
        waitFor(() -> hasNativeNode(node -> context.getPackageName().contentEquals(
            node.getPackageName() == null ? "" : node.getPackageName())), 8000, "ADB return did not foreground Ppomi");
        awaitPage();
    }
    private Map<String, String> taskFiles() {
        Map<String, String> result = new HashMap<>();
        File[] files = new File(context.getFilesDir(), "tasks").listFiles((dir, name) -> name.endsWith(".json"));
        if (files != null) for (File file : files) result.put(file.getName(), file.length() + ":" + file.lastModified());
        return result;
    }
    private interface Check { boolean ready() throws Exception; }
    private void waitFor(Check check, long timeout, String failure) throws Exception {
        long deadline = SystemClock.uptimeMillis() + timeout;
        while (SystemClock.uptimeMillis() < deadline) { if (check.ready()) return; SystemClock.sleep(80); }
        fail(failure);
    }
    private void proof(String name, String checks) {
        Bundle proof = new Bundle(); proof.putString("voiceProof", name + ": " + checks);
        getInstrumentation().sendStatus(0, proof);
    }
}
