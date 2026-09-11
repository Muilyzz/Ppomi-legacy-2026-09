package com.ppomi.androidbridge;

/** Lifecycle order regressions without a device, permissions, or a running foreground service. */
public final class ExecutorOwnershipTest {
    private static int assertions;
    public static void main(String[] args) {
        ExecutorOwnership<Object> owners = new ExecutorOwnership<>();
        Object oldHost = new Object(), newHost = new Object();
        check(owners.foreground() == null, "initially no foreground");
        check(!owners.owns(null), "null is never an owner");
        owners.attach(oldHost);
        check(owners.owns(oldHost), "first host owns teardown");
        check(owners.detach(oldHost), "stopping foreground succeeds");
        check(owners.foreground() == null, "stopped host is not foreground");
        check(owners.owns(oldHost), "background host can still end its session on destruction");
        owners.attach(newHost);
        check(!owners.detach(oldHost), "late old onStop cannot cancel successor startup");
        check(owners.foreground() == newHost, "successor remains foreground");
        check(!owners.owns(oldHost), "late old onDestroy cannot end successor work");
        check(owners.owns(newHost), "successor owns teardown");
        owners.detach(newHost);
        check(!owners.detach(oldHost), "old host remains stale while successor is background");
        check(owners.owns(newHost), "background transfer retains successor identity");
        owners.attach(oldHost);
        check(!owners.owns(newHost), "reattachment transfers ownership back explicitly");
        check(owners.foreground() == oldHost, "returning activity becomes foreground");
        System.out.println("Executor lifecycle ownership " + assertions + " assertions passed");
    }
    private static void check(boolean accepted, String reason) {
        assertions++;
        if (!accepted) throw new AssertionError(reason);
    }
}
