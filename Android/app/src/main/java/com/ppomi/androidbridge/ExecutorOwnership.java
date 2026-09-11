package com.ppomi.androidbridge;

import java.lang.ref.WeakReference;

/** Main-thread lifecycle ownership: stopped owners retain teardown rights until a new host takes over. */
final class ExecutorOwnership<T> {
    private WeakReference<T> owner = new WeakReference<>(null);
    private WeakReference<T> foreground = new WeakReference<>(null);

    void attach(T host) {
        owner = new WeakReference<>(host);
        foreground = new WeakReference<>(host);
    }
    T foreground() { return foreground.get(); }
    boolean owns(T host) { return host != null && owner.get() == host; }
    boolean detach(T host) {
        if (host == null || foreground.get() != host) return false;
        foreground.clear();
        return true;
    }
}
