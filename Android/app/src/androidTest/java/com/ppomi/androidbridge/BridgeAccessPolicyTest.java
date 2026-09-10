package com.ppomi.androidbridge;

import android.content.Context;
import android.test.AndroidTestCase;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** Selection changes are restricted to this emulator test's isolated preference restoration. */
public final class BridgeAccessPolicyTest extends AndroidTestCase {
    public void testExactResolutionAndAmbiguity() {
        List<BridgeAccessPolicy.App> apps = Arrays.asList(new BridgeAccessPolicy.App("Notes", "test.notes.one"),
            new BridgeAccessPolicy.App("Notes", "test.notes.two"), new BridgeAccessPolicy.App("Calendar", "test.calendar"));
        assertEquals("test.notes.two", BridgeAccessPolicy.resolveTarget(apps, "test.notes.two"));
        assertEquals("test.calendar", BridgeAccessPolicy.resolveTarget(apps, " Calendar "));
        assertCode("app_ambiguous", () -> BridgeAccessPolicy.resolveTarget(apps, "notes"));
        assertCode("app_not_found", () -> BridgeAccessPolicy.resolveTarget(apps, "Note"));
    }

    public void testSelectionAddsOnlyChosenLaunchableAppAndRevocationPreservesDefaults() throws Exception {
        assertTrue("Preference mutations are emulator-only", BridgeSession.isEmulator());
        assertFalse(VoiceSessionHost.hasActiveControl());
        assertNull(LocalTaskRunner.actionOwner());
        Context context = getContext();
        Set<String> before = BridgeAccessPolicy.userPackages(context);
        Set<String> defaults = BridgeAccessPolicy.defaultPackages(context);
        List<BridgeAccessPolicy.App> apps = BridgeAccessPolicy.launchableApps(context);
        for (BridgeAccessPolicy.App app : apps) assertFalse(context.getPackageName().equals(app.packageName));
        BridgeAccessPolicy.App candidate = null;
        for (BridgeAccessPolicy.App app : apps) if (!defaults.contains(app.packageName)) { candidate = app; break; }
        assertNotNull("Emulator needs one launchable app outside the fixed defaults", candidate);
        try {
            BridgeAccessPolicy.saveUserPackages(context, java.util.Collections.emptySet());
            assertCode("app_not_allowed", () -> BridgeAccessPolicy.requireAllowedPackage(context, "missing.unselected.app"));
            Set<String> chosen = new LinkedHashSet<>(); chosen.add(candidate.packageName);
            BridgeAccessPolicy.saveUserPackages(context, chosen);
            Set<String> expected = new LinkedHashSet<>(defaults); expected.add(candidate.packageName);
            assertEquals(expected, BridgeAccessPolicy.allowedPackages(context));
            BridgeAccessPolicy.requireAllowedPackage(context, candidate.packageName);
            assertEquals(candidate.packageName, BridgeAccessPolicy.resolveTarget(context, candidate.packageName));
            assertTrue(BridgeAccessPolicy.appList(context, candidate.packageName).getJSONArray("apps").getJSONObject(0).getBoolean("allowed"));
            BridgeAccessPolicy.saveUserPackages(context, java.util.Collections.emptySet());
            assertEquals(defaults, BridgeAccessPolicy.allowedPackages(context));
            assertFalse(BridgeAccessPolicy.appList(context, candidate.packageName).getJSONArray("apps").getJSONObject(0).getBoolean("allowed"));
            try { BridgeAccessPolicy.saveUserPackages(context, java.util.Collections.singleton(context.getPackageName())); fail("Self-selection accepted"); }
            catch (IllegalArgumentException expectedFailure) {}
            assertTrue(BridgeAccessPolicy.appList(context, "").getJSONArray("apps").length() <= BridgeAccessPolicy.LIST_LIMIT);
        } finally {
            assertTrue(context.getSharedPreferences("control_app_access", Context.MODE_PRIVATE).edit().putStringSet("user_packages", before).commit());
        }
    }

    private void assertCode(String expected, Runnable operation) {
        try { operation.run(); fail("Expected stable error code"); }
        catch (VoiceToolErrors.Failure error) { assertEquals(expected, error.code); }
    }
}
