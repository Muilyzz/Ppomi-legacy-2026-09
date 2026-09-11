package com.ppomi.androidbridge;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/** Fixed defaults plus apps selected explicitly in the native UI. No bridge tool changes this policy. */
final class BridgeAccessPolicy {
    private static final String PREFERENCES = "control_app_access";
    private static final String USER_PACKAGES = "user_packages";
    static final int LIST_LIMIT = 80;
    private BridgeAccessPolicy() {}

    static final class App {
        final String label;
        final String packageName;
        App(String label, String packageName) { this.label = label; this.packageName = packageName; }
    }

    static String launcherPackage(Context context) {
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        ResolveInfo resolved = context.getPackageManager().resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY);
        if (resolved == null || resolved.activityInfo == null || !resolved.activityInfo.exported) return null;
        String name = resolved.activityInfo.packageName;
        // The system chooser is not a selected launcher and does not expand access to android.
        if (name == null || name.equals("android") || name.equals(context.getPackageName())) return null;
        return name;
    }

    static Set<String> defaultPackages(Context context) {
        Set<String> result = new LinkedHashSet<>(BridgePolicy.ALLOWED_PACKAGES);
        String launcher = launcherPackage(context);
        if (launcher != null) result.add(launcher);
        return result;
    }

    static Set<String> userPackages(Context context) {
        return new LinkedHashSet<>(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getStringSet(USER_PACKAGES, java.util.Collections.emptySet()));
    }

    static Set<String> allowedPackages(Context context) {
        Set<String> result = defaultPackages(context);
        for (String name : userPackages(context))
            if (!name.equals(context.getPackageName()) && context.getPackageManager().getLaunchIntentForPackage(name) != null)
                result.add(name);
        return result;
    }

    /** Called only by native user UI; never exposed through MCP, WebView, or a model tool. */
    static void saveUserPackages(Context context, Set<String> selected) {
        if (AndroidExecutor.hasActiveControl() || LocalTaskRunner.actionOwner() != null)
            throw new IllegalStateException("진행 중인 대화나 작업을 종료한 뒤 제어 앱을 변경해 주세요.");
        Set<String> launchable = new LinkedHashSet<>();
        for (App app : launchableApps(context)) launchable.add(app.packageName);
        if (!launchable.containsAll(selected)) throw new IllegalArgumentException("실행 가능한 앱만 선택할 수 있습니다.");
        Set<String> extra = new LinkedHashSet<>(selected);
        extra.removeAll(defaultPackages(context));
        extra.remove(context.getPackageName());
        if (!context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putStringSet(USER_PACKAGES, extra).commit())
            throw new IllegalStateException("제어 앱 선택을 저장하지 못했습니다.");
    }

    static List<App> launchableApps(Context context) {
        PackageManager manager = context.getPackageManager();
        LinkedHashMap<String, App> apps = new LinkedHashMap<>();
        Intent query = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        for (ResolveInfo resolved : manager.queryIntentActivities(query, 0)) {
            if (resolved.activityInfo == null || !resolved.activityInfo.exported || !resolved.activityInfo.enabled
                || !resolved.activityInfo.applicationInfo.enabled) continue;
            String name = resolved.activityInfo.packageName;
            if (context.getPackageName().equals(name) || manager.getLaunchIntentForPackage(name) == null) continue;
            CharSequence rawLabel = resolved.activityInfo.applicationInfo.loadLabel(manager);
            String label = rawLabel == null ? name : rawLabel.toString();
            apps.putIfAbsent(name, new App(label, name));
        }
        String home = launcherPackage(context);
        if (home != null && !apps.containsKey(home)) {
            try { apps.put(home, new App(manager.getApplicationLabel(manager.getApplicationInfo(home, 0)).toString(), home)); }
            catch (PackageManager.NameNotFoundException ignored) {}
        }
        List<App> result = new ArrayList<>(apps.values());
        result.sort(Comparator.comparing((App app) -> app.label, String.CASE_INSENSITIVE_ORDER).thenComparing(app -> app.packageName));
        return result;
    }

    static JSONObject appList(Context context, String query) throws Exception {
        if (query == null || query.length() > 160) throw new IllegalArgumentException();
        String needle = query.trim().toLowerCase(Locale.ROOT);
        Set<String> allowed = allowedPackages(context);
        JSONArray apps = new JSONArray();
        boolean truncated = false;
        for (App app : launchableApps(context)) {
            if (!app.label.toLowerCase(Locale.ROOT).contains(needle) && !app.packageName.toLowerCase(Locale.ROOT).contains(needle)) continue;
            if (apps.length() >= LIST_LIMIT) { truncated = true; break; }
            apps.put(new JSONObject().put("label", app.label).put("packageName", app.packageName).put("allowed", allowed.contains(app.packageName)));
        }
        return new JSONObject().put("apps", apps).put("truncated", truncated);
    }

    static JSONArray controlApps(Context context) throws Exception {
        Set<String> allowed = allowedPackages(context);
        JSONArray result = new JSONArray();
        for (App app : launchableApps(context)) if (allowed.contains(app.packageName))
            result.put(new JSONObject().put("label", app.label).put("packageName", app.packageName));
        return result;
    }

    static String resolveTarget(Context context, String target) {
        if (context.getPackageName().equals(target)) throw new VoiceToolErrors.Failure("protected_action");
        return resolveTarget(launchableApps(context), target);
    }

    static String resolveTarget(List<App> apps, String target) {
        if (target == null || target.trim().isEmpty()) throw new VoiceToolErrors.Failure("app_not_found");
        String value = target.trim();
        for (App app : apps) if (app.packageName.equals(value)) return app.packageName;
        String match = null;
        for (App app : apps) if (app.label.equalsIgnoreCase(value)) {
            if (match != null && !match.equals(app.packageName)) throw new VoiceToolErrors.Failure("app_ambiguous");
            match = app.packageName;
        }
        if (match == null) throw new VoiceToolErrors.Failure("app_not_found");
        return match;
    }

    static void requireAllowedPackage(Context context, String packageName) {
        if (!allowedPackages(context).contains(packageName))
            throw new VoiceToolErrors.Failure("app_not_allowed");
    }
}
