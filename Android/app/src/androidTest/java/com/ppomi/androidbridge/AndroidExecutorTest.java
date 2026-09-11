package com.ppomi.androidbridge;

import android.test.InstrumentationTestCase;
import org.json.JSONObject;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import kotlin.Unit;

/** Exercises the native protocol without creating a WebView, enabling accessibility, or starting a session. */
public final class AndroidExecutorTest extends InstrumentationTestCase {
    private AndroidExecutor executor;

    @Override protected void setUp() throws Exception {
        super.setUp();
        executor = AndroidExecutor.Companion.get(getInstrumentation().getTargetContext());
        assertFalse("Do not interrupt an existing session", executor.getActive());
        assertNull("Do not interrupt an existing task", LocalTaskRunner.actionOwner());
    }

    public void testBootstrapWithoutWebView() throws Exception {
        JSONObject response = request("bootstrap", new JSONObject());
        assertEquals("android", response.getJSONObject("result").getString("platform"));
        assertTrue(response.getJSONObject("result").getJSONArray("tools").length() > 0);
        assertFalse(executor.getActive());
    }

    public void testSessionGatePreventsToolDispatch() throws Exception {
        JSONObject args = new JSONObject().put("name", "ui_tap")
            .put("args", new JSONObject().put("nodeId", "not-a-current-node"));
        assertEquals("protected_action", request("executeTool", args).getJSONObject("error").getString("code"));
        assertFalse(executor.getActive());
    }

    public void testUnknownMethodReturnsCorrelatedError() throws Exception {
        assertEquals("unsupported_method", request("enableAllApps", new JSONObject()).getJSONObject("error").getString("code"));
    }

    public void testMalformedEnvelopeIsRejected() throws Exception {
        assertEquals("invalid_request", raw("{broken").getJSONObject("error").getString("code"));
        assertEquals("invalid_request", raw("{\"id\":\"not-a-uuid\",\"method\":\"bootstrap\"}")
            .getJSONObject("error").getString("code"));
    }

    private JSONObject request(String method, JSONObject args) throws Exception {
        String id = UUID.randomUUID().toString();
        JSONObject response = raw(new JSONObject().put("id", id).put("method", method).put("args", args).toString());
        assertEquals(id, response.getString("id"));
        return response;
    }

    private JSONObject raw(String raw) throws Exception {
        AtomicReference<JSONObject> result = new AtomicReference<>();
        CountDownLatch ready = new CountDownLatch(1);
        getInstrumentation().runOnMainSync(() -> executor.receive(raw, response -> {
            result.set(response); ready.countDown(); return Unit.INSTANCE;
        }));
        assertTrue("Native response must settle", ready.await(5, TimeUnit.SECONDS));
        return result.get();
    }
}
