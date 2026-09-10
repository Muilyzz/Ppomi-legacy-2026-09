package com.ppomi.androidbridge;

import android.content.Intent;
import android.net.Uri;
import android.test.AndroidTestCase;
import java.util.Arrays;
import java.util.HashSet;

/** Intent construction only: this test never opens a store or installs anything. */
public final class StoreSearchIntentTest extends AndroidTestCase {
    public void testSearchQueryCannotChangeDestinationOrAddParameters() {
        String query = "어카운트인포 &c=books # ? + % / 앱";
        Intent search = BridgeAccessibilityService.storeSearchIntent("  " + query + "  ");
        assertEquals(Intent.ACTION_VIEW, search.getAction());
        assertEquals("com.android.vending", search.getPackage());
        assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK, search.getFlags());
        Uri uri = search.getData();
        assertNotNull(uri);
        assertEquals("market", uri.getScheme());
        assertEquals("search", uri.getHost());
        assertEquals(query, uri.getQueryParameter("q"));
        assertEquals("apps", uri.getQueryParameter("c"));
        assertEquals(new HashSet<>(Arrays.asList("q", "c")), uri.getQueryParameterNames());
        assertNull(uri.getFragment());
        assertEquals(-1, uri.getPort());
        assertNull(uri.getUserInfo());
        assertNull(search.getComponent());
        assertNull(search.getExtras());
    }
}
