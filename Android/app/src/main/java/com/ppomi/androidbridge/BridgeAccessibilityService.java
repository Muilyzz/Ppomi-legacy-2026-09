package com.ppomi.androidbridge;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Typeface;
import android.net.Uri;
import android.graphics.Path;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.hardware.HardwareBuffer;
import android.os.Build;
import android.view.Display;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Button;
import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.CompletableFuture;
import android.graphics.Rect;
import android.graphics.Point;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

public final class BridgeAccessibilityService extends AccessibilityService {
    private static volatile BridgeAccessibilityService instance;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, AccessibilityNodeInfo> nodes = new LinkedHashMap<>();
    private String snapshotId;
    private long snapshotTime;
    private LocalMcpServer server;
    private String lastGesture = "none";
    private final Map<String, GestureRun> gestures = new LinkedHashMap<>();
    private GestureRun activeGesture;

    /** Each continuation retains the same pointer; we never repeat an uncertain gesture. */
    private static final class GestureRun {
        final String id = UUID.randomUUID().toString();
        final String type, ownerId, packageName;
        final int displayWidth, displayHeight, windowId, displayId, displayRotation;
        final long startedAt = System.currentTimeMillis();
        String state = "pending", phase = "dispatch", detail = "";
        long finishedAt;
        boolean cancelRequested;
        float x, y;
        GestureDescription.StrokeDescription stroke;
        GestureDescription.StrokeDescription confirmedStroke;
        float confirmedX, confirmedY;
        boolean pointerHeld;
        GestureRun(String type, String ownerId, String packageName, float x, float y,
                   int displayWidth, int displayHeight, int windowId, int displayId, int displayRotation) {
            this.type = type; this.ownerId = ownerId; this.packageName = packageName;
            this.x = x; this.y = y;
            this.displayWidth = displayWidth; this.displayHeight = displayHeight;
            this.windowId = windowId; this.displayId = displayId;
            this.displayRotation = displayRotation;
        }
        JSONObject json() throws Exception {
            JSONObject value = new JSONObject().put("id", id).put("type", type).put("state", state)
                .put("phase", phase).put("startedAt", startedAt).put("cancelRequested", cancelRequested)
                .put("displayWidth", displayWidth).put("displayHeight", displayHeight)
                .put("windowId", windowId).put("displayId", displayId)
                .put("displayRotation", displayRotation)
                .put("controlBlocked", "pending".equals(state) || "release_unconfirmed".equals(state))
                .put("pointerReleaseConfirmed", !"pending".equals(state) && !"release_unconfirmed".equals(state))
                .put("outcomeNeedsVerification", true);
            if (finishedAt != 0) value.put("finishedAt", finishedAt);
            if (!detail.isEmpty()) value.put("detail", detail);
            return value;
        }
    }

    private LinearLayout overlay;
    private TextView overlayStatus;
    private TextView overlayRequest;
    private Button overlayStop;
    private volatile boolean capturing;
    private Object captureOwner;
    private final Runnable refreshOverlay = new Runnable() {
        @Override public void run() {
            if (instance != BridgeAccessibilityService.this) return;
            updateControlWindow();
            updateOverlay();
            main.postDelayed(this, 700);
        }
    };

    // ---- Control slot (docs/android-control.md): the target app's window, for the workbench to reserve and follow.
    static volatile String lastOpenedPackage;
    static volatile String popupStatus = "";
    private static volatile JSONObject controlWindow;

    /** {packageName,label,left,top,right,bottom} in screen pixels, or null while no allowed app window is on screen. */
    static JSONObject controlWindow() { return controlWindow; }

    private void updateControlWindow() {
        JSONObject found = null;
        try {
            java.util.Set<String> allowed = BridgeAccessPolicy.allowedPackages(this);
            String launcher = BridgeAccessPolicy.launcherPackage(this);
            for (AccessibilityWindowInfo window : getWindows()) {
                if (window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) continue;
                AccessibilityNodeInfo root = window.getRoot();
                if (root == null) continue;
                String name = string(root.getPackageName());
                root.recycle();
                if (name.isEmpty() || name.equals(getPackageName()) || name.equals(launcher) || !allowed.contains(name)) continue;
                Rect bounds = new Rect();
                window.getBoundsInScreen(bounds);
                if (bounds.isEmpty()) continue;
                // The app the agent opened last wins; otherwise the first allowed window.
                if (found != null && !name.equals(lastOpenedPackage)) continue;
                found = new JSONObject().put("packageName", name).put("label", labelOf(name))
                    .put("left", bounds.left).put("top", bounds.top).put("right", bounds.right).put("bottom", bounds.bottom);
            }
        } catch (Exception ignored) { found = null; }
        controlWindow = found;
        // After a service restart the app the slot follows is the one to restore later.
        if (found != null && lastOpenedPackage == null) lastOpenedPackage = found.optString("packageName");
    }

    String labelOf(String packageName) {
        try { return getPackageManager().getApplicationLabel(getPackageManager().getApplicationInfo(packageName, 0)).toString(); }
        catch (Exception failure) { return packageName; }
    }

    /**
     * Opens the target as a floating pop-up window through the launcher's recents menu (Samsung: 최근 앱 → 앱 아이콘 →
     * 팝업 화면으로 열기), then brings the workbench back behind it. Started only from Ppomi's own native UI.
     */
    public void openAsPopup(String packageName) {
        String label = labelOf(packageName);
        popupStatus = label + " 팝업 여는 중";
        if (!performGlobalAction(GLOBAL_ACTION_RECENTS)) { popupStatus = "최근 앱 화면을 열지 못했습니다"; return; }
        main.postDelayed(() -> {
            if (!tapLauncherNode(node -> {
                String description = string(node.getContentDescription());
                return description.startsWith("고급 옵션, " + label) || (description.contains(label) && description.endsWith("버튼"));
            })) {
                performGlobalAction(GLOBAL_ACTION_BACK);
                popupStatus = "최근 앱에서 " + label + " 카드를 찾지 못했습니다";
                return;
            }
            main.postDelayed(() -> {
                if (!tapLauncherNode(node -> {
                    String text = string(node.getText());
                    return text.equals("팝업 화면으로 열기") || text.equals("Open in pop-up view");
                })) {
                    performGlobalAction(GLOBAL_ACTION_BACK);
                    popupStatus = "팝업 화면 메뉴를 찾지 못했습니다";
                    return;
                }
                main.postDelayed(() -> { openWorkbench(); popupStatus = ""; }, 1200);
            }, 700);
        }, 900);
    }

    /**
     * Records focus (same rule as the Mac workbench): data views that need the whole screen hide the target pop-up
     * by minimizing it through its own caption (handle tap → 최소화), and restore it by tapping the minimized icon.
     */
    public void setControlWindowHidden(boolean hidden) {
        if (hidden) {
            JSONObject window = controlWindow;
            if (window == null) return;
            String packageName = window.optString("packageName");
            float grab = 6 * getResources().getDisplayMetrics().density;
            tapPoint((window.optInt("left") + window.optInt("right")) / 2f, window.optInt("top") + grab);
            main.postDelayed(() -> {
                if (!tapAnyNode(node -> {
                    String label = string(node.getContentDescription()) + string(node.getText());
                    return label.contains("최소화") || label.toLowerCase(java.util.Locale.ROOT).contains("minimize");
                })) { popupStatus = packageName + " 팝업을 최소화하지 못했습니다"; performGlobalAction(GLOBAL_ACTION_BACK); }
                else popupStatus = "";
            }, 700);
        } else {
            String packageName = lastOpenedPackage;
            if (packageName == null) return;
            // The minimized icon is not an accessibility window, but bringing the target's task forward restores the
            // pop-up in place (its task stays in freeform mode); the workbench then returns behind it.
            Intent launch = getPackageManager().getLaunchIntentForPackage(packageName);
            if (launch == null) return;
            startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            main.postDelayed(this::openWorkbench, 700);
        }
    }

    private void tapPoint(float x, float y) {
        Path path = new Path();
        path.moveTo(x, y);
        dispatchGesture(new GestureDescription.Builder()
            .addStroke(new GestureDescription.StrokeDescription(path, 0, 60)).build(), null, null);
    }

    private boolean tapAnyNode(NodeTest test) {
        for (AccessibilityWindowInfo window : getWindows()) {
            AccessibilityNodeInfo root = window.getRoot();
            if (root == null) continue;
            AccessibilityNodeInfo match = find(root, test);
            root.recycle();
            if (match == null) continue;
            Rect bounds = new Rect();
            match.getBoundsInScreen(bounds);
            match.recycle();
            if (bounds.isEmpty()) return false;
            tapPoint(bounds.exactCenterX(), bounds.exactCenterY());
            return true;
        }
        return false;
    }

    /** One drag from the pop-up's top handle to the slot's top-left corner; the window keeps its own size. */
    public void dockControlWindow(int targetLeft, int targetTop) {
        JSONObject window = controlWindow;
        if (window == null) return;
        float grab = 6 * getResources().getDisplayMetrics().density;
        int left = window.optInt("left"), top = window.optInt("top"), right = window.optInt("right");
        Path path = new Path();
        path.moveTo((left + right) / 2f, top + grab);
        path.lineTo(targetLeft + (right - left) / 2f, targetTop + grab);
        dispatchGesture(new GestureDescription.Builder()
            .addStroke(new GestureDescription.StrokeDescription(path, 0, 600)).build(), null, null);
    }

    private interface NodeTest { boolean test(AccessibilityNodeInfo node); }

    private boolean tapLauncherNode(NodeTest test) {
        String launcher = BridgeAccessPolicy.launcherPackage(this);
        for (AccessibilityWindowInfo window : getWindows()) {
            AccessibilityNodeInfo root = window.getRoot();
            if (root == null) continue;
            String name = string(root.getPackageName());
            boolean systemSurface = (launcher != null && launcher.equals(name)) || "com.android.systemui".equals(name);
            AccessibilityNodeInfo match = systemSurface ? find(root, test) : null;
            root.recycle();
            if (match == null) continue;
            Rect bounds = new Rect();
            match.getBoundsInScreen(bounds);
            match.recycle();
            if (bounds.isEmpty()) return false;
            Path path = new Path();
            path.moveTo(bounds.exactCenterX(), bounds.exactCenterY());
            dispatchGesture(new GestureDescription.Builder()
                .addStroke(new GestureDescription.StrokeDescription(path, 0, 60)).build(), null, null);
            return true;
        }
        return false;
    }

    private AccessibilityNodeInfo find(AccessibilityNodeInfo node, NodeTest test) {
        if (test.test(node)) return AccessibilityNodeInfo.obtain(node);
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            AccessibilityNodeInfo found = find(child, test);
            child.recycle();
            if (found != null) return found;
        }
        return null;
    }

    public static BridgeAccessibilityService getInstance() { return instance; }

    static boolean connected() { return instance != null && instance.server != null && instance.server.running(); }

    @Override protected void onServiceConnected() {
        instance = this;
        if (!BridgeSession.supported()) { disableSelf(); return; }
        BridgeSession.configure(this, null);
        if (server != null) server.close();
        server = new LocalMcpServer(this);
        server.start();
        main.removeCallbacks(refreshOverlay);
        main.post(refreshOverlay);
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent event) {
        // Our non-focusable task overlay does not change the target application's nodes.
        if (!getPackageName().contentEquals(event.getPackageName() == null ? "" : event.getPackageName()))
            invalidateSnapshot();
    }
    @Override public void onInterrupt() { invalidateSnapshot(); }
    @Override public void onDestroy() {
        main.removeCallbacks(refreshOverlay);
        removeOverlay();
        LocalTaskRunner.get(this).serviceDisconnected();
        if (server != null) server.close();
        server = null;
        if (activeGesture != null) finishGesture(activeGesture, "cancelled", "Accessibility service disconnected; inspect the screen before further action");
        invalidateSnapshot();
        if (instance == this) instance = null;
        super.onDestroy();
    }

    JSONObject execute(String name, JSONObject arguments) throws Exception {
        return executeLocal(name, arguments, null);
    }

    public JSONObject executeLocal(String name, JSONObject arguments, String ownerId) throws Exception {
        if (Looper.myLooper() == Looper.getMainLooper())
            throw new IllegalStateException("Control calls must run on a worker thread");
        FutureTask<JSONObject> task = new FutureTask<>(() -> {
            if (!"status".equals(name) && !"gesture_status".equals(name)) requireOwner(ownerId);
            if (!"status".equals(name) && !"gesture_status".equals(name) && !"cancel_gesture".equals(name)) requireIdle();
            return executeOnMain(name, arguments, ownerId);
        });
        main.post(task);
        try { return task.get(5, TimeUnit.SECONDS); }
        finally { main.removeCallbacks(task); task.cancel(false); }
    }

    private JSONObject executeOnMain(String name, JSONObject args, String ownerId) throws Exception {
        if (name.equals("status")) {
            JSONObject status = new JSONObject().put("connected", true).put("accessibilityEnabled", true)
                .put("emulator", BridgeSession.isEmulator()).put("packageName", getPackageName())
                .put("port", BridgePolicy.PORT).put("lastGesture", lastGesture)
                .put("allowedPackages", new JSONArray(BridgeAccessPolicy.allowedPackages(this)));
            String launcherPackage = BridgeAccessPolicy.launcherPackage(this);
            status.put("launcherPackage", launcherPackage == null ? JSONObject.NULL : launcherPackage);
            if (!gestures.isEmpty()) {
                GestureRun latest = null;
                for (GestureRun value : gestures.values()) latest = value;
                status.put("gesture", latest.json());
            }
            AccessibilityNodeInfo root = getRootInActiveWindow();
            if (root != null) { status.put("foregroundPackage", string(root.getPackageName())); root.recycle(); }
            return status;
        }
        if (!BridgeSession.supported()) throw new IllegalStateException("A supported Ppomi debug install is required");
        switch (name) {
            case "ui_tree": return tree();
            case "tap": return gesture(args, false, ownerId);
            case "swipe": return gesture(args, true, ownerId);
            case "long_press": return longGesture(args, false, ownerId);
            case "long_press_drag": return longGesture(args, true, ownerId);
            case "gesture_status": return gestureStatus(args);
            case "cancel_gesture": return cancelGesture(args, ownerId);
            case "click": return nodeAction(args, false, ownerId);
            case "type_text": return nodeAction(args, true, ownerId);
            case "back": return global(GLOBAL_ACTION_BACK);
            case "home": return global(GLOBAL_ACTION_HOME);
            case "recents": return global(GLOBAL_ACTION_RECENTS);
            case "store_search": {
                // This operation belongs only to an active in-app conversation. The common
                // executeLocal gate also rejects competing MCP/local-task owners and gestures.
                if (!VoiceSessionHost.isControlOwner(ownerId)) throw new VoiceToolErrors.Failure("protected_action");
                Object raw = args.opt("query");
                if (!(raw instanceof String)) throw new IllegalArgumentException("Invalid store search");
                Intent search = storeSearchIntent((String) raw);
                try { getPackageManager().getApplicationInfo("com.android.vending", 0); }
                catch (android.content.pm.PackageManager.NameNotFoundException missing) {
                    throw new VoiceToolErrors.Failure("app_not_found");
                }
                BridgeAccessPolicy.requireAllowedPackage(this, "com.android.vending");
                if (search.resolveActivity(getPackageManager()) == null) throw new VoiceToolErrors.Failure("app_not_found");
                invalidateSnapshot();
                startActivity(search);
                return new JSONObject().put("opened", "com.android.vending");
            }
            case "open_app": {
                String packageName = args.getString("packageName");
                BridgeAccessPolicy.requireAllowedPackage(this, packageName);
                Intent launch;
                if (packageName.equals(BridgeAccessPolicy.launcherPackage(this))) {
                    launch = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).setPackage(packageName);
                    if (launch.resolveActivity(getPackageManager()) == null) launch = null;
                } else launch = getPackageManager().getLaunchIntentForPackage(packageName);
                if (launch == null) throw new IllegalArgumentException("Package has no launcher activity or is not installed");
                invalidateSnapshot();
                // When the workbench already sits in one half of a split, the target lands in the other half; otherwise no effect.
                startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT));
                lastOpenedPackage = packageName;
                return new JSONObject().put("opened", packageName);
            }
            default: throw new IllegalArgumentException("Unknown tool: " + name);
        }
    }

    static Intent storeSearchIntent(String raw) {
        String query = VoiceBridgePolicy.storeQuery(raw);
        return new Intent(Intent.ACTION_VIEW, Uri.parse("market://search?q=" + Uri.encode(query) + "&c=apps"))
            .setPackage("com.android.vending").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
    }

    private AccessibilityNodeInfo allowedRoot() {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        // Split screen or pop-up: when the focused window is the workbench itself, the target is the allowed app window
        // the slot follows (the app the agent opened last), never an arbitrary window that happens to be on top.
        if (root != null && getPackageName().equals(string(root.getPackageName()))) {
            java.util.Set<String> allowed = BridgeAccessPolicy.allowedPackages(this);
            String launcher = BridgeAccessPolicy.launcherPackage(this);
            JSONObject slot = controlWindow;
            String preferred = slot == null ? lastOpenedPackage : slot.optString("packageName");
            AccessibilityNodeInfo chosen = null;
            for (AccessibilityWindowInfo window : getWindows()) {
                if (window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) continue;
                AccessibilityNodeInfo other = window.getRoot();
                if (other == null) continue;
                String name = string(other.getPackageName());
                boolean candidate = !name.equals(getPackageName()) && !name.equals(launcher) && allowed.contains(name);
                if (candidate && (chosen == null || name.equals(preferred))) {
                    if (chosen != null) chosen.recycle();
                    chosen = other;
                    if (name.equals(preferred)) break;
                } else other.recycle();
            }
            if (chosen != null) { root.recycle(); root = chosen; }
        }
        if (root == null) throw new IllegalStateException("No active accessibility window; unlock the device and open an allowed app");
        try {
            BridgeAccessPolicy.requireAllowedPackage(this, string(root.getPackageName()));
            if (getPackageName().equals(string(root.getPackageName())))
                throw new IllegalStateException("Ppomi approvals and settings are controlled by the user only");
        }
        catch (RuntimeException failure) { root.recycle(); throw failure; }
        return root;
    }

    private JSONObject tree() throws Exception {
        invalidateSnapshot();
        AccessibilityNodeInfo root = allowedRoot();
        snapshotId = UUID.randomUUID().toString();
        snapshotTime = SystemClock.uptimeMillis();
        JSONArray output = new JSONArray();
        String packageName = string(root.getPackageName());
        try { collect(root, null, 0, output); }
        finally { root.recycle(); }
        JSONObject result = new JSONObject().put("snapshotId", snapshotId).put("packageName", packageName)
            .put("nodes", output).put("truncated", output.length() >= 300)
            .put("displayWidth", screenSize().x)
            .put("displayHeight", screenSize().y);
        Rect target = targetBounds(packageName);
        if (target != null) result.put("targetWindow", new JSONObject().put("left", target.left).put("top", target.top)
            .put("right", target.right).put("bottom", target.bottom));
        return result;
    }

    private void collect(AccessibilityNodeInfo node, String parent, int depth, JSONArray output) throws Exception {
        if (depth > 32 || output.length() >= 300) return;
        String id = snapshotId + ":" + output.length();
        nodes.put(id, AccessibilityNodeInfo.obtain(node));
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        JSONObject item = new JSONObject().put("id", id).put("parentId", parent == null ? JSONObject.NULL : parent)
            .put("className", string(node.getClassName())).put("resourceId", string(node.getViewIdResourceName()))
            .put("text", node.isPassword() ? "[redacted]" : string(node.getText()))
            .put("contentDescription", node.isPassword() ? "[redacted]" : string(node.getContentDescription()))
            .put("clickable", node.isClickable()).put("longClickable", node.isLongClickable()).put("editable", node.isEditable())
            .put("enabled", node.isEnabled()).put("visible", node.isVisibleToUser()).put("password", node.isPassword())
            .put("bounds", new JSONObject().put("left", bounds.left).put("top", bounds.top)
                .put("right", bounds.right).put("bottom", bounds.bottom));
        JSONArray actions = new JSONArray();
        if (!node.isPassword()) for (AccessibilityNodeInfo.AccessibilityAction action : node.getActionList())
            actions.put(new JSONObject().put("id", action.getId()).put("label", string(action.getLabel())));
        item.put("actions", actions);
        output.put(item);
        for (int i = 0; i < node.getChildCount() && output.length() < 300; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try { collect(child, id, depth + 1, output); }
            finally { child.recycle(); }
        }
    }

    private JSONObject nodeAction(JSONObject args, boolean type, String ownerId) throws Exception {
        AccessibilityNodeInfo root = allowedRoot();
        try {
            AccessibilityNodeInfo node = freshNode(args.getString("nodeId"), root);
            if (VoiceSessionHost.isControlOwner(ownerId)) requireVoiceSafeNode(node, 0, new int[] {0});
            boolean performed;
            if (type) {
                if (!node.isEditable()) throw new IllegalArgumentException("Node is not editable");
                String value = args.getString("text");
                if (value.length() > 4096) throw new IllegalArgumentException("Text is limited to 4096 characters");
                Bundle text = new Bundle();
                text.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value);
                performed = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, text);
            } else {
                if (!node.isClickable()) throw new IllegalArgumentException("Node is not clickable; choose its clickable parent or use tap");
                performed = node.performAction(AccessibilityNodeInfo.ACTION_CLICK);
            }
            invalidateSnapshot();
            if (!performed) throw new IllegalStateException("Android rejected the accessibility action");
            return new JSONObject().put("performed", true).put("action", type ? "set_text" : "click");
        } finally { root.recycle(); }
    }

    private AccessibilityNodeInfo freshNode(String nodeId, AccessibilityNodeInfo root) {
        AccessibilityNodeInfo node = nodes.get(nodeId);
        if (node == null || snapshotId == null || SystemClock.uptimeMillis() - snapshotTime > 30_000
            || !node.refresh() || node.getWindowId() != root.getWindowId()
            || !string(root.getPackageName()).equals(string(node.getPackageName())))
            throw new IllegalStateException("Stale nodeId; fetch ui_tree and use an id from its latest snapshot");
        BridgeAccessPolicy.requireAllowedPackage(this, string(node.getPackageName()));
        if (!node.isVisibleToUser() || !node.isEnabled()) throw new IllegalStateException("Node is not visible and enabled");
        if (node.isPassword()) throw new IllegalArgumentException("Password fields are excluded from this prototype");
        return node;
    }

    private Point screenSize() {
        Point size = new Point();
        ((WindowManager) getSystemService(WINDOW_SERVICE)).getDefaultDisplay().getRealSize(size);
        return size;
    }

    private int displayRotation() {
        return ((WindowManager) getSystemService(WINDOW_SERVICE)).getDefaultDisplay().getRotation();
    }

    private void requireIdle() {
        if (activeGesture != null) throw new IllegalStateException("Gesture " + activeGesture.id + " is still active; check gesture_status before further control");
        if (capturing) throw new IllegalStateException("A screenshot is in progress; wait before further control");
    }

    private int rootDisplayId(AccessibilityNodeInfo root) {
        if (Build.VERSION.SDK_INT < 30) return Display.DEFAULT_DISPLAY;
        AccessibilityWindowInfo window = root.getWindow();
        if (window == null) throw new IllegalStateException("Cannot verify the active window display");
        try { return window.getDisplayId(); }
        finally { window.recycle(); }
    }

    private GestureRun beginGesture(String type, String ownerId, String packageName, float x, float y,
                                    Point expectedSize, int expectedWindowId) {
        requireIdle();
        Point currentSize = screenSize();
        AccessibilityNodeInfo root = allowedRoot();
        int displayId;
        try {
            displayId = rootDisplayId(root);
            if (displayId != Display.DEFAULT_DISPLAY || root.getWindowId() != expectedWindowId
                || !packageName.equals(string(root.getPackageName())) || !currentSize.equals(expectedSize))
                throw new IllegalStateException("Display or active window changed before gesture; inspect a fresh screen");
        } finally { root.recycle(); }
        GestureRun run = new GestureRun(type, ownerId, packageName, x, y,
            currentSize.x, currentSize.y, expectedWindowId, displayId, displayRotation());
        gestures.put(run.id, run);
        while (gestures.size() > 16) gestures.remove(gestures.keySet().iterator().next());
        activeGesture = run;
        lastGesture = "pending";
        invalidateSnapshot();
        return run;
    }

    private JSONObject acceptedGesture(GestureRun run) throws Exception {
        return new JSONObject().put("accepted", true).put("gestureId", run.id)
            .put("completion", "Poll gesture_status with gestureId, then inspect a fresh ui_tree or screen; completion alone does not prove the icon moved");
    }

    private void finishGesture(GestureRun run, String state, String detail) {
        if (!"pending".equals(run.state)) return;
        run.state = state; run.finishedAt = System.currentTimeMillis(); run.detail = detail;
        run.pointerHeld = false;
        if (activeGesture == run) { activeGesture = null; lastGesture = state; }
        invalidateSnapshot();
    }

    private JSONObject gestureStatus(JSONObject args) throws Exception {
        GestureRun run = null;
        String id = args.optString("gestureId");
        if (!id.isEmpty()) run = gestures.get(id);
        else for (GestureRun value : gestures.values()) run = value;
        if (run == null) throw new IllegalArgumentException("No retained gesture matches gestureId");
        return run.json();
    }

    private JSONObject cancelGesture(JSONObject args, String ownerId) throws Exception {
        GestureRun run = gestures.get(args.getString("gestureId"));
        if (run == null) throw new IllegalArgumentException("Unknown or expired gestureId");
        if (!java.util.Objects.equals(ownerId, run.ownerId)) throw new IllegalStateException("Only the gesture owner can request cancellation");
        if ("pending".equals(run.state)) run.cancelRequested = true;
        JSONObject response = run.json();
        response.put("cancellation", "Held drags release at the next continuation boundary; an in-flight short gesture may finish. Inspect the screen before any retry.");
        return response;
    }

    private JSONObject gesture(JSONObject args, boolean swipe, String ownerId) throws Exception {
        AccessibilityNodeInfo root = allowedRoot();
        String packageName = string(root.getPackageName());
        int windowId = root.getWindowId();
        root.recycle();
        Point size = screenSize();
        float x1 = coordinate(args, swipe ? "x1" : "x", size.x);
        float y1 = coordinate(args, swipe ? "y1" : "y", size.y);
        requireInsideTarget(packageName, x1, y1);
        Path path = new Path(); path.moveTo(x1, y1);
        if (swipe) {
            float x2 = coordinate(args, "x2", size.x), y2 = coordinate(args, "y2", size.y);
            requireInsideTarget(packageName, x2, y2);
            path.lineTo(x2, y2);
        }
        int duration = swipe ? boundedInt(args, "durationMs", 300, 50, 2000) : 80;
        GestureRun run = beginGesture(swipe ? "swipe" : "tap", ownerId, packageName, x1, y1, size, windowId);
        run.phase = swipe ? "swipe" : "tap";
        run.stroke = new GestureDescription.StrokeDescription(path, 0, duration);
        dispatchStroke(run, run.stroke, () -> finishGesture(run, run.cancelRequested ? "cancelled" : "completed",
            run.cancelRequested ? "Cancellation requested while the gesture was in flight; it may have completed" : ""));
        if (!"pending".equals(run.state)) throw new IllegalStateException("Android rejected gesture dispatch; gestureId=" + run.id);
        return acceptedGesture(run);
    }

    private JSONObject longGesture(JSONObject args, boolean drag, String ownerId) throws Exception {
        Point size = screenSize();
        float x, y;
        String packageName;
        int windowId;
        AccessibilityNodeInfo root = allowedRoot();
        try {
            AccessibilityNodeInfo node = freshNode(args.getString("nodeId"), root);
            Rect bounds = new Rect(); node.getBoundsInScreen(bounds);
            if (!bounds.intersect(0, 0, size.x, size.y) || bounds.isEmpty())
                throw new IllegalArgumentException("Node has no visible screen area");
            x = bounds.exactCenterX(); y = bounds.exactCenterY();
            packageName = string(root.getPackageName());
            windowId = root.getWindowId();
        } finally { root.recycle(); }
        float x2 = drag ? coordinate(args, "x2", size.x) : x;
        float y2 = drag ? coordinate(args, "y2", size.y) : y;
        if (drag) requireInsideTarget(packageName, x2, y2);
        int holdMs = boundedInt(args, "holdMs", 700, 400, 1500);
        int dragMs = boundedInt(args, "dragMs", 600, 200, 2000);
        int hoverMs = boundedInt(args, "hoverMs", 400, 0, 1500);
        GestureRun run = beginGesture(drag ? "long_press_drag" : "long_press", ownerId, packageName, x, y, size, windowId);
        Path hold = new Path(); hold.moveTo(x, y);
        run.phase = "hold";
        run.stroke = new GestureDescription.StrokeDescription(hold, 0, holdMs, drag);
        long holdUntil = SystemClock.uptimeMillis() + holdMs;
        dispatchStroke(run, run.stroke, () -> {
            if (!drag) { finishGesture(run, run.cancelRequested ? "cancelled" : "completed", ""); return; }
            // Android's injector callbacks follow the last emitted MotionEvent.
            // A stationary continuing stroke emits DOWN but no UP, so its callback
            // can arrive immediately rather than after holdMs.
            awaitHeldDeadline(run, holdUntil, () -> {
                if (x == x2 && y == y2) continueHover(run, hoverMs);
                else continueDrag(run, x, y, x2, y2, dragMs, hoverMs, 1, (dragMs + 149) / 150);
            });
        });
        if (!"pending".equals(run.state)) throw new IllegalStateException("Android rejected gesture dispatch; gestureId=" + run.id);
        return acceptedGesture(run);
    }

    private int boundedInt(JSONObject args, String key, int fallback, int min, int max) throws Exception {
        if (!args.has(key)) return fallback;
        Object raw = args.get(key);
        if (!(raw instanceof Number) || !Double.isFinite(((Number) raw).doubleValue())
            || ((Number) raw).doubleValue() != ((Number) raw).intValue())
            throw new IllegalArgumentException(key + " must be an integer");
        int value = ((Number) raw).intValue();
        if (value < min || value > max) throw new IllegalArgumentException(key + " must be between " + min + " and " + max);
        return value;
    }

    private void dispatchStroke(GestureRun run, GestureDescription.StrokeDescription stroke, Runnable completed) {
        boolean accepted;
        try {
            accepted = dispatchGesture(new GestureDescription.Builder().addStroke(stroke).build(), new GestureResultCallback() {
                @Override public void onCompleted(GestureDescription description) {
                    if (activeGesture != run || !"pending".equals(run.state) || run.stroke != stroke) return;
                    run.confirmedStroke = stroke;
                    run.confirmedX = run.x; run.confirmedY = run.y;
                    run.pointerHeld = stroke.willContinue();
                    try { completed.run(); }
                    catch (Exception error) { releaseGesture(run, "Continuation failed: " + error.getClass().getSimpleName()); }
                }
                @Override public void onCancelled(GestureDescription description) {
                    if (activeGesture != run || !"pending".equals(run.state) || run.stroke != stroke) return;
                    if ("release".equals(run.phase)) markReleaseUnconfirmed(run);
                    else if (run.pointerHeld && run.confirmedStroke != null)
                        releaseGesture(run, "Android cancelled a continuation; inspect the screen before further action");
                    else finishGesture(run, "cancelled", "Android cancelled the gesture; inspect the screen before further action");
                }
            }, main);
        } catch (RuntimeException error) { accepted = false; }
        if (!accepted) {
            if ("release".equals(run.phase)) markReleaseUnconfirmed(run);
            else if (run.pointerHeld && run.confirmedStroke != null)
                releaseGesture(run, "Android rejected a continuation; previous segments may already have changed the screen");
            else finishGesture(run, "rejected", "Android rejected gesture dispatch before a held pointer was confirmed");
        }
    }

    private boolean continuePermitted(GestureRun run) {
        try {
            if (run.cancelRequested) throw new IllegalStateException("Cancellation requested");
            requireOwner(run.ownerId);
            Point currentSize = screenSize();
            if (currentSize.x != run.displayWidth || currentSize.y != run.displayHeight || displayRotation() != run.displayRotation)
                throw new IllegalStateException("Display geometry changed during gesture");
            AccessibilityNodeInfo root = allowedRoot();
            try {
                if (!run.packageName.equals(string(root.getPackageName()))) throw new IllegalStateException("Foreground changed");
                // Launchers may open a same-package menu/drag window after the hold.
                // Preserve the display contract while allowing that legitimate window change.
                if (rootDisplayId(root) != run.displayId || run.displayId != Display.DEFAULT_DISPLAY)
                    throw new IllegalStateException("Active display changed during gesture");
            } finally { root.recycle(); }
            return true;
        } catch (Exception failure) { releaseGesture(run, failure.getMessage()); return false; }
    }

    private void continueDrag(GestureRun run, float x1, float y1, float x2, float y2,
                              int durationMs, int hoverMs, int step, int count) {
        if (!continuePermitted(run)) return;
        float nextX = x1 + (x2 - x1) * step / count;
        float nextY = y1 + (y2 - y1) * step / count;
        Path path = new Path(); path.moveTo(run.x, run.y); path.lineTo(nextX, nextY);
        run.stroke = run.stroke.continueStroke(path, 0, Math.max(1, durationMs / count), true);
        run.phase = "drag"; run.x = nextX; run.y = nextY;
        dispatchStroke(run, run.stroke, () -> {
            if (step < count) continueDrag(run, x1, y1, x2, y2, durationMs, hoverMs, step + 1, count);
            else continueHover(run, hoverMs);
        });
    }

    private void continueHover(GestureRun run, int remainingMs) {
        if (!continuePermitted(run)) return;
        run.phase = "hover";
        // Continuing an unmoving pointer produces no events and Android rejects
        // that empty sequence. The existing pointer stays down during this wait.
        awaitHeldDeadline(run, SystemClock.uptimeMillis() + remainingMs, () -> releaseGesture(run, null));
    }

    private void awaitHeldDeadline(GestureRun run, long deadline, Runnable completed) {
        if (activeGesture != run || !"pending".equals(run.state) || !continuePermitted(run)) return;
        long remaining = deadline - SystemClock.uptimeMillis();
        if (remaining <= 0) {
            try { completed.run(); }
            catch (RuntimeException failure) { releaseGesture(run, "Held-pointer continuation failed: " + failure.getClass().getSimpleName()); }
            return;
        }
        main.postDelayed(() -> awaitHeldDeadline(run, deadline, completed), Math.min(100, remaining));
    }

    /** Finish an existing pointer without starting another touch or navigating away. */
    private void releaseGesture(GestureRun run, String cancellationReason) {
        if (activeGesture != run || !"pending".equals(run.state)) return;
        try {
            if (!run.pointerHeld || run.confirmedStroke == null) {
                finishGesture(run, cancellationReason == null ? "completed" : "cancelled", cancellationReason == null ? "" : cancellationReason);
                return;
            }
            // A rejected continuation never became the current pointer. Continue
            // from the last confirmed stroke and endpoint, not its planned target.
            run.x = run.confirmedX; run.y = run.confirmedY;
            Path release = new Path(); release.moveTo(run.x, run.y);
            run.stroke = run.confirmedStroke.continueStroke(release, 0, 1, false);
            run.phase = "release";
            dispatchStroke(run, run.stroke, () -> finishGesture(run, cancellationReason == null ? "completed" : "cancelled",
                cancellationReason == null ? "" : cancellationReason + "; the held item was released where it was. Inspect the screen before further action."));
        } catch (RuntimeException error) {
            markReleaseUnconfirmed(run);
        }
    }

    private void markReleaseUnconfirmed(GestureRun run) {
        if (activeGesture != run || !"pending".equals(run.state)) return;
        run.state = "release_unconfirmed";
        run.phase = "release";
        run.finishedAt = System.currentTimeMillis();
        run.detail = "Android did not confirm pointer release. Control remains blocked; inspect the device and reconnect its accessibility service before another mutation. No gesture was retried.";
        lastGesture = run.state;
        invalidateSnapshot();
        // Deliberately retain activeGesture so a client cannot blindly follow a
        // failed release with a new touch, node action or navigation operation.
    }

    /** The target's own window bounds when it is a pop-up or split beside the workbench; null when it fills the display. */
    private Rect targetBounds(String packageName) {
        JSONObject slot = controlWindow;
        if (slot == null || !packageName.equals(slot.optString("packageName"))) return null;
        Rect bounds = new Rect(slot.optInt("left"), slot.optInt("top"), slot.optInt("right"), slot.optInt("bottom"));
        Point size = screenSize();
        return bounds.width() >= size.x * 0.85 && bounds.height() >= size.y * 0.85 ? null : bounds;
    }

    /** Display coordinates that fall on the workbench or another app instead of the target are refused, not executed. */
    private void requireInsideTarget(String packageName, float x, float y) {
        Rect bounds = targetBounds(packageName);
        if (bounds != null && !bounds.contains((int) x, (int) y))
            throw new IllegalArgumentException("Point (" + (int) x + "," + (int) y + ") is outside the " + packageName
                + " window " + bounds.flattenToString() + "; use targetWindow from screen_read");
    }

    private float coordinate(JSONObject args, String key, int max) throws Exception {
        double value = args.getDouble(key);
        if (!Double.isFinite(value) || value < 0 || value >= max)
            throw new IllegalArgumentException(key + " must be within screen bounds 0.." + (max - 1));
        return (float) value;
    }

    private JSONObject global(int action) throws Exception {
        invalidateSnapshot();
        if (!performGlobalAction(action)) throw new IllegalStateException("Android rejected global navigation action");
        return new JSONObject().put("performed", true);
    }

    private void invalidateSnapshot() {
        for (AccessibilityNodeInfo node : nodes.values()) node.recycle();
        nodes.clear(); snapshotId = null;
    }

    /** Ends only the ephemeral voice owner's cached observation and outstanding gesture. */
    void endVoiceControl(String ownerId) {
        if (ownerId == null || !ownerId.startsWith("voice:")) return;
        Runnable cleanup = () -> {
            if (activeGesture != null && ownerId.equals(activeGesture.ownerId)) activeGesture.cancelRequested = true;
            invalidateSnapshot();
        };
        if (Looper.myLooper() == Looper.getMainLooper()) cleanup.run(); else main.post(cleanup);
    }

    private void requireOwner(String ownerId) {
        if (!BridgeSession.supported()) throw new IllegalStateException("A supported Ppomi debug install is required");
        if (VoiceSessionHost.hasActiveControl()) {
            if (!VoiceSessionHost.isControlOwner(ownerId) || LocalTaskRunner.actionOwner() != null)
                throw new IllegalStateException("An active voice session owns control");
            return;
        }
        if (ownerId != null && ownerId.startsWith("voice:")) throw new IllegalStateException("Voice session ended");
        if (!LocalTaskRunner.permitsOwner(ownerId))
            throw new IllegalStateException("A local task owns control or is waiting for user approval");
    }

    /** The voice prototype cannot authorize known destructive, financial, credential or send targets. */
    private void requireVoiceSafeNode(AccessibilityNodeInfo node, int depth, int[] visited) {
        // A clickable parent may expose its action label only through a child. Check
        // the refreshed subtree, bounded and fail-closed, immediately before acting.
        if (++visited[0] > 64 || depth > 6 || node.isPassword()) throw new VoiceToolErrors.Failure("protected_action");
        String label = (string(node.getText()) + " " + string(node.getContentDescription()) + " "
            + string(node.getViewIdResourceName()) + " " + string(node.getHintText()));
        if (ProtectedActionPolicy.protectedLabel(label))
            throw new VoiceToolErrors.Failure("protected_action");
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo child = node.getChild(index);
            if (child == null) throw new VoiceToolErrors.Failure("stale_screen");
            try { requireVoiceSafeNode(child, depth + 1, visited); }
            finally { child.recycle(); }
        }
    }

    /** Split the screen with the target app in front, then open the workbench in the other half. */
    public void sideBySide() {
        boolean accepted = performGlobalAction(GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN);
        android.util.Log.i("PpomiSplit", "toggle split screen accepted=" + accepted);
        if (!accepted) {
            // Which global actions this system actually offers (Samsung may not register the split toggle).
            if (Build.VERSION.SDK_INT >= 30) android.util.Log.i("PpomiSplit", "system actions: " + getSystemActions());
            // Already split by the user (taskbar drag, recents): the adjacent flag puts the workbench in the other half.
            startActivity(new Intent(this, MainActivity.class).setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT));
            return;
        }
        main.postDelayed(() -> {
            Intent intent = new Intent(this, MainActivity.class)
                .setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT);
            startActivity(intent);
        }, 800);
    }

    public void openWorkbench() {
        Intent intent = new Intent(this, MainActivity.class)
            .setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        String taskId = LocalTaskRunner.actionOwner();
        if (taskId != null) intent.putExtra("task_id", taskId);
        startActivity(intent);
    }

    /** Saves an actual device screenshot in private app storage, without ADB or a host. */
    public JSONObject captureLocal(String absolutePath, String ownerId) throws Exception {
        if (Looper.myLooper() == Looper.getMainLooper())
            throw new IllegalStateException("Screenshot calls must run on a worker thread");
        if (Build.VERSION.SDK_INT < 30) throw new IllegalStateException("Screenshots require Android 11 or later");
        File output = new File(absolutePath).getCanonicalFile();
        String privateRoot = getFilesDir().getCanonicalPath() + File.separator;
        if (!output.getPath().startsWith(privateRoot) || !output.getName().endsWith(".png"))
            throw new IllegalArgumentException("Evidence must be a PNG inside private app files");
        CompletableFuture<JSONObject> result = new CompletableFuture<>();
        Object captureTicket = new Object();
        main.post(() -> {
            try {
                if (result.isDone()) return;
                requireOwner(ownerId);
                requireIdle();
                AccessibilityNodeInfo root = allowedRoot();
                String expectedPackage;
                try {
                    expectedPackage = string(root.getPackageName());
                    if (rootDisplayId(root) != Display.DEFAULT_DISPLAY)
                        throw new IllegalStateException("Screenshots require the allowed foreground app on the default display");
                } finally { root.recycle(); }
                Point expectedSize = screenSize();
                int expectedRotation = displayRotation();
                captureOwner = captureTicket;
                capturing = true;
                removeOverlay();
                main.postDelayed(() -> {
                    try {
                        if (result.isDone()) { finishCapture(captureTicket); return; }
                        requireOwner(ownerId);
                        requireCaptureSurface(expectedPackage, expectedSize, expectedRotation);
                        takeScreenshot(Display.DEFAULT_DISPLAY, getMainExecutor(), new TakeScreenshotCallback() {
                            @Override public void onSuccess(ScreenshotResult screenshot) {
                                HardwareBuffer buffer = screenshot.getHardwareBuffer();
                                Bitmap hardware = null;
                                Bitmap bitmap = null;
                                try {
                                    if (result.isDone()) return;
                                    requireOwner(ownerId);
                                    requireCaptureSurface(expectedPackage, expectedSize, expectedRotation);
                                    hardware = Bitmap.wrapHardwareBuffer(buffer, screenshot.getColorSpace());
                                    if (hardware == null) throw new IllegalStateException("Screenshot buffer unavailable");
                                    bitmap = hardware.copy(Bitmap.Config.ARGB_8888, false);
                                    if (bitmap == null) throw new IllegalStateException("Screenshot conversion failed");
                                    if (bitmap.getWidth() != expectedSize.x || bitmap.getHeight() != expectedSize.y)
                                        throw new IllegalStateException("Captured display dimensions changed during screenshot");
                                    File parent = output.getParentFile();
                                    if (!parent.isDirectory() && !parent.mkdirs()) throw new IllegalStateException("Cannot create evidence directory");
                                    try (FileOutputStream stream = new FileOutputStream(output)) {
                                        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
                                            throw new IllegalStateException("Cannot encode evidence");
                                    }
                                    if (!result.complete(new JSONObject().put("path", output.getAbsolutePath())
                                        .put("width", bitmap.getWidth()).put("height", bitmap.getHeight())
                                        .put("capturedAt", java.time.Instant.now().toString())
                                        .put("displayId", Display.DEFAULT_DISPLAY).put("displayRotation", expectedRotation)
                                        .put("packageName", expectedPackage).put("source", "android_accessibility"))) output.delete();
                                } catch (Exception failure) { output.delete(); result.completeExceptionally(failure); }
                                finally {
                                    if (bitmap != null) bitmap.recycle();
                                    if (hardware != null) hardware.recycle();
                                    buffer.close();
                                    finishCapture(captureTicket);
                                }
                            }
                            @Override public void onFailure(int errorCode) {
                                result.completeExceptionally(new IllegalStateException("Android screenshot failed: " + errorCode));
                                finishCapture(captureTicket);
                            }
                        });
                    } catch (Exception failure) { finishCapture(captureTicket); result.completeExceptionally(failure); }
                }, 150);
            } catch (Exception failure) { finishCapture(captureTicket); result.completeExceptionally(failure); }
        });
        try { return result.get(6, TimeUnit.SECONDS); }
        finally {
            result.cancel(false);
            main.post(() -> finishCapture(captureTicket));
        }
    }

    private void finishCapture(Object ticket) {
        if (captureOwner != ticket) return;
        captureOwner = null;
        capturing = false;
        updateOverlay();
    }

    private void requireCaptureSurface(String expectedPackage, Point expectedSize, int expectedRotation) {
        if (!screenSize().equals(expectedSize) || displayRotation() != expectedRotation)
            throw new IllegalStateException("Display geometry changed during screenshot");
        AccessibilityNodeInfo root = allowedRoot();
        try {
            if (!expectedPackage.equals(string(root.getPackageName())) || rootDisplayId(root) != Display.DEFAULT_DISPLAY)
                throw new IllegalStateException("Foreground or display changed during screenshot");
        } finally { root.recycle(); }
    }

    private void updateOverlay() {
        try {
            JSONObject task = LocalTaskRunner.get(this).activeTask();
            boolean workbench = false;
            for (AccessibilityWindowInfo window : getWindows()) {
                if (window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) continue;
                AccessibilityNodeInfo root = window.getRoot();
                if (root == null) continue;
                workbench |= getPackageName().equals(string(root.getPackageName()));
                root.recycle();
            }
            // A chat turn that is driving another app shows the panel too, without a stop button (the chat owns it).
            boolean chat = task == null && VoiceSessionHost.hasActiveControl();
            if ((task == null && !chat) || capturing || workbench) { removeOverlay(); return; }
            if (overlay == null) {
                // A bottom panel over the target app: the app keeps the rest of the screen and its touches.
                overlay = new LinearLayout(this);
                overlay.setOrientation(LinearLayout.VERTICAL);
                overlay.setPadding(40, 28, 40, 24);
                // Generated ThemeColors (agent/theme.json), light or dark from the system.
                boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
                int surface = (int) (dark ? ThemeColors.Dark.SURFACE : ThemeColors.Light.SURFACE);
                int surface2 = (int) (dark ? ThemeColors.Dark.SURFACE_2 : ThemeColors.Light.SURFACE_2);
                int fg = (int) (dark ? ThemeColors.Dark.FG : ThemeColors.Light.FG);
                int fg2 = (int) (dark ? ThemeColors.Dark.FG_2 : ThemeColors.Light.FG_2);
                int accentFg = (int) (dark ? ThemeColors.Dark.ACCENT_FG : ThemeColors.Light.ACCENT_FG);
                Typeface font = getResources().getFont(R.font.pretendard_variable);
                overlay.setBackgroundColor((surface & 0x00FFFFFF) | 0xF2000000);
                overlayStatus = new TextView(this);
                overlayStatus.setTextColor(fg);
                overlayStatus.setTextSize(16);
                overlayStatus.setTypeface(font);
                overlayStatus.setFontVariationSettings("'wght' 500");
                overlayStatus.setOnClickListener(v -> openWorkbench());
                overlay.addView(overlayStatus);
                overlayRequest = new TextView(this);
                overlayRequest.setTextColor(fg2);
                overlayRequest.setTextSize(14);
                overlayRequest.setTypeface(font);
                overlayRequest.setMaxLines(3);
                overlayRequest.setPadding(0, 8, 0, 16);
                overlay.addView(overlayRequest);
                LinearLayout row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                Button open = new Button(this);
                open.setText("뽀미");
                open.setOnClickListener(v -> openWorkbench());
                row.addView(open);
                Button split = new Button(this);
                split.setText("나란히");
                split.setContentDescription("분할 화면");
                split.setOnClickListener(v -> { android.util.Log.i("PpomiSplit", "side-by-side tapped"); sideBySide(); });
                row.addView(split);
                overlayStop = new Button(this);
                overlayStop.setText("중지");
                overlayStop.setContentDescription("작업 중지");
                for (Button button : new Button[] { open, split, overlayStop }) {
                    button.setTypeface(font);
                    button.setTextSize(14);
                    button.setTextColor(accentFg);
                    button.setBackgroundTintList(ColorStateList.valueOf(surface2));
                }
                overlayStop.setOnClickListener(v -> {
                    String owner = LocalTaskRunner.actionOwner();
                    if (owner != null) LocalTaskRunner.get(this).cancel(owner);
                    openWorkbench();
                });
                row.addView(overlayStop);
                overlay.addView(row);
                WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT, (int) (screenSize().y * 0.28),
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                    PixelFormat.TRANSLUCENT);
                params.gravity = Gravity.BOTTOM;
                ((WindowManager) getSystemService(WINDOW_SERVICE)).addView(overlay, params);
            }
            String request = task == null ? "대화 처리 중" : task.optString("request");
            if (!request.contentEquals(overlayRequest.getText())) overlayRequest.setText(request);
            overlayStop.setVisibility(task == null ? View.GONE : View.VISIBLE);
            String label = task == null ? "뽀미 · 대화"
                : "waiting_approval".equals(task.optString("state")) ? "뽀미 · 승인" : "뽀미 · 실행";
            if (!label.contentEquals(overlayStatus.getText())) overlayStatus.setText(label);
        } catch (Exception ignored) { removeOverlay(); }
    }

    private void removeOverlay() {
        if (overlay != null) {
            try { ((WindowManager) getSystemService(WINDOW_SERVICE)).removeView(overlay); }
            catch (RuntimeException ignored) { }
            overlay = null;
            overlayStatus = null;
            overlayRequest = null;
            overlayStop = null;
        }
    }

    private static String string(CharSequence value) {
        if (value == null) return "";
        String text = value.toString();
        return text.length() > 4096 ? text.substring(0, 4096) : text;
    }
}
