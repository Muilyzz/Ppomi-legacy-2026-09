package com.ppomi.androidbridge

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRouting
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** A lease is issued only after the native sink's actual route was checked. Never accepts a JS verified flag. */
internal class ReceiverAudioLease(private val epoch: Int) {
    private val revoked = AtomicBoolean(false)
    private val value = AtomicReference<String?>(null)
    fun verify(currentEpoch: Int, receiverRouted: Boolean): String? {
        if (revoked.get() || currentEpoch != epoch || !receiverRouted) return null
        value.compareAndSet(null, UUID.randomUUID().toString())
        return if (revoked.get()) null else value.get()
    }
    fun accepts(token: String, currentEpoch: Int, receiverRouted: Boolean): Boolean =
        !revoked.get() && currentEpoch == epoch && receiverRouted && value.get() == token
    fun token(): String? = if (revoked.get()) null else value.get()
    fun revoke(): Boolean {
        revoked.set(true)
        return value.getAndSet(null) != null
    }
}

/** PCM is never stored. This bound includes the chunk currently being written. */
internal class ReceiverAudioBudget(private val maximum: Int) {
    private val count = AtomicInteger(0)
    fun reserve(size: Int): Boolean {
        if (size <= 0 || size > maximum) return false
        while (true) {
            val old = count.get()
            if (old > maximum - size) return false
            if (count.compareAndSet(old, old + size)) return true
        }
    }
    fun release(size: Int) { check(count.addAndGet(-size) >= 0) }
    fun size(): Int = count.get()
}

/** Owns the only audible sink. WebView audio playback is not used for private answers.
 * Route callbacks and every nonblocking PCM write check the actual AudioTrack route.
 * Android routing is asynchronous; these checks do not promise zero physical latency on OS reroutes.
 */
internal class ReceiverAudioPlayer(
    context: Context,
    private val epoch: Int,
    private val currentEpoch: () -> Int,
    private val onRevoked: () -> Unit,
) {
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val lease = ReceiverAudioLease(epoch)
    private val closed = AtomicBoolean(false)
    private val ready = AtomicBoolean(false)
    private val playbackEpoch = AtomicInteger(0)
    private val track = AtomicReference<AudioTrack?>(null)
    // Only volume changes use this lock. No PCM write or wait holds it.
    private val volumeLock = Any()
    private val budget = ReceiverAudioBudget(MAX_PENDING_BYTES)
    private val writer = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue(8),
        { task -> Thread(task, "ppomi-receiver-pcm") }, ThreadPoolExecutor.AbortPolicy())
    private val routingThread = HandlerThread("ppomi-receiver-route").apply { start() }
    private val routingHandler = Handler(routingThread.looper)
    @Volatile private var receiver: AudioDeviceInfo? = null
    @Volatile private var selected = false
    @Volatile private var communicationListener: AudioManager.OnCommunicationDeviceChangedListener? = null
    private val trackListener = AudioRouting.OnRoutingChangedListener {
        if (ready.get() && !actualReceiverRoute()) revoke()
    }

    fun start(completion: (String?) -> Unit) {
        try {
            writer.execute {
                var result: String? = null
                try {
                    check(Build.VERSION.SDK_INT >= 31 && !closed.get() && currentEpoch() == epoch)
                    val device = manager.availableCommunicationDevices.firstOrNull {
                        it.isSink && it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                    } ?: error("receiver unavailable")
                    receiver = device
                    check(manager.mode == AudioManager.MODE_IN_COMMUNICATION)
                    check(manager.setCommunicationDevice(device))
                    selected = true
                    val minimum = AudioTrack.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO,
                        AudioFormat.ENCODING_PCM_16BIT)
                    check(minimum > 0)
                    val sink = AudioTrack.Builder()
                        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                        .setAudioFormat(AudioFormat.Builder().setSampleRate(SAMPLE_RATE)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .setBufferSizeInBytes(maxOf(minimum, WRITE_SLICE_BYTES * 4)).build()
                    // Muted before play, and only zero PCM is supplied until the actual route is known.
                    sink.setVolume(0f)
                    synchronized(volumeLock) {
                        if (closed.get()) { sink.release(); error("closed") }
                        track.set(sink)
                    }
                    check(sink.state == AudioTrack.STATE_INITIALIZED && sink.setPreferredDevice(device))
                    sink.addOnRoutingChangedListener(trackListener, routingHandler)
                    val listener = AudioManager.OnCommunicationDeviceChangedListener {
                        if (ready.get() && !actualReceiverRoute()) revoke()
                    }
                    communicationListener = listener
                    manager.addOnCommunicationDeviceChangedListener({ task -> routingHandler.post(task) }, listener)
                    check(prime(sink, playbackEpoch.get()))
                    synchronized(volumeLock) {
                        check(!closed.get() && currentEpoch() == epoch && actualReceiverRoute())
                        result = lease.verify(currentEpoch(), true)
                        check(result != null)
                        sink.setVolume(1f)
                        ready.set(true)
                    }
                } catch (_: Exception) { close() }
                // Closing during native setup may happen before the track/listener was installed.
                if (closed.get()) { disposeResources(); result = null }
                completion(result)
            }
        } catch (_: Exception) { close(); completion(null) }
    }

    fun verifiedToken(): String? {
        val token = lease.token() ?: return null
        if (closed.get() || !ready.get() || !lease.accepts(token, currentEpoch(), actualReceiverRoute())) {
            revoke(); return null
        }
        return token
    }

    /** Completion follows the actual writes, providing backpressure to the caller. */
    fun enqueue(token: String, pcm: ByteArray, completion: (Boolean) -> Unit): Boolean {
        if (closed.get() || !ready.get() || !lease.accepts(token, currentEpoch(), actualReceiverRoute())) {
            pcm.fill(0)
            if (lease.token() == token) revoke()
            return false
        }
        if (!budget.reserve(pcm.size)) { pcm.fill(0); revoke(); return false }
        val job = AudioJob(token, playbackEpoch.get(), pcm, completion)
        return try { writer.execute(job); true }
        catch (_: Exception) { job.cancel(); revoke(); false }
    }

    /** Invalidates queued/running old chunks before flushing; no new PCM is accepted during priming. */
    fun clear(token: String, completion: (Boolean) -> Unit): Boolean {
        if (closed.get() || !lease.accepts(token, currentEpoch(), actualReceiverRoute())) return false
        ready.set(false)
        val next = playbackEpoch.incrementAndGet()
        synchronized(volumeLock) { runCatching { track.get()?.setVolume(0f) } }
        discardQueued()
        return try {
            writer.execute {
                var success = false
                try {
                    val sink = track.get() ?: error("closed")
                    sink.pause(); sink.flush()
                    check(prime(sink, next))
                    synchronized(volumeLock) {
                        check(!closed.get() && next == playbackEpoch.get()
                            && lease.accepts(token, currentEpoch(), actualReceiverRoute()))
                        sink.setVolume(1f)
                        ready.set(true)
                        success = true
                    }
                } catch (_: Exception) { revoke() }
                completion(success)
            }
            true
        } catch (_: Exception) { revoke(); false }
    }

    private inner class AudioJob(
        private val token: String,
        private val turn: Int,
        private val pcm: ByteArray,
        private val completion: (Boolean) -> Unit,
    ) : Runnable {
        private val finished = AtomicBoolean(false)
        override fun run() {
            var success = false
            try {
                val sink = track.get() ?: error("closed")
                val deadline = SystemClock.elapsedRealtime() + 10_000
                var offset = 0
                while (offset < pcm.size) {
                    if (closed.get() || !ready.get() || turn != playbackEpoch.get()) break
                    if (!lease.accepts(token, currentEpoch(), actualReceiverRoute())) { revoke(); break }
                    // Nonblocking, small writes let routing callbacks mute/release without waiting on this thread.
                    val written = sink.write(pcm, offset, minOf(WRITE_SLICE_BYTES, pcm.size - offset), AudioTrack.WRITE_NON_BLOCKING)
                    if (written < 0 || written % 2 != 0 || SystemClock.elapsedRealtime() >= deadline) { revoke(); break }
                    if (written == 0) Thread.sleep(5) else offset += written
                }
                success = offset == pcm.size && !closed.get() && turn == playbackEpoch.get()
            } catch (_: Exception) { if (!closed.get() && turn == playbackEpoch.get()) revoke() }
            finally { finish(success) }
        }
        private fun finish(success: Boolean) {
            if (!finished.compareAndSet(false, true)) return
            pcm.fill(0); budget.release(pcm.size); completion(success)
        }
        fun cancel() = finish(false)
    }

    private fun prime(sink: AudioTrack, turn: Int): Boolean {
        val silence = ByteArray(WRITE_SLICE_BYTES)
        sink.play()
        val deadline = SystemClock.elapsedRealtime() + 1_500
        while (!closed.get() && currentEpoch() == epoch && turn == playbackEpoch.get()
            && SystemClock.elapsedRealtime() < deadline) {
            if (sink.write(silence, 0, silence.size, AudioTrack.WRITE_NON_BLOCKING) < 0) return false
            if (actualReceiverRoute()) return true
            Thread.sleep(10)
        }
        return false
    }

    private fun actualReceiverRoute(): Boolean = runCatching {
        if (Build.VERSION.SDK_INT < 31) return@runCatching false
        val expected = receiver ?: return@runCatching false
        val sink = track.get() ?: return@runCatching false
        val actual = sink.routedDevice ?: return@runCatching false
        val communication = manager.communicationDevice ?: return@runCatching false
        sink.playState == AudioTrack.PLAYSTATE_PLAYING && manager.mode == AudioManager.MODE_IN_COMMUNICATION
            && actual.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE && actual.id == expected.id
            && communication.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE && communication.id == expected.id
    }.getOrDefault(false)

    private fun discardQueued() {
        for (job in writer.queue.toList()) if (job is AudioJob && writer.remove(job)) job.cancel()
    }

    private fun revoke() { shutdown(notify = true) }
    fun close() { shutdown(notify = false) }
    private fun shutdown(notify: Boolean) {
        val hadToken = lease.revoke()
        if (!closed.compareAndSet(false, true)) return
        ready.set(false); playbackEpoch.incrementAndGet()
        // These operations never wait for a PCM writer lock or the main/tool queues.
        disposeResources()
        for (job in writer.shutdownNow()) if (job is AudioJob) job.cancel()
        if (notify && hadToken) onRevoked()
    }

    private fun disposeResources() {
        val sink = synchronized(volumeLock) {
            track.getAndSet(null)?.also { runCatching { it.setVolume(0f) } }
        }
        if (sink != null) {
            runCatching { sink.pause() }
            runCatching { sink.flush() }
            runCatching { sink.stop() }
            runCatching { sink.removeOnRoutingChangedListener(trackListener) }
            runCatching { sink.release() }
        }
        if (Build.VERSION.SDK_INT >= 31) {
            communicationListener?.let { runCatching { manager.removeOnCommunicationDeviceChangedListener(it) } }
            communicationListener = null
            // The audible sink was muted, discarded and released before releasing its route request.
            if (selected) { runCatching { manager.clearCommunicationDevice() }; selected = false }
        }
        routingThread.quitSafely()
    }

    companion object {
        const val SAMPLE_RATE = 24_000
        const val MAX_CHUNK_BYTES = 65_536
        const val MAX_PENDING_BYTES = MAX_CHUNK_BYTES * 8
        private const val WRITE_SLICE_BYTES = 960 // 20 ms, PCM16 mono
        @JvmStatic fun supported(context: Context): Boolean = Build.VERSION.SDK_INT >= 31 && runCatching {
            (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager).availableCommunicationDevices.any {
                it.isSink && it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            }
        }.getOrDefault(false)
        @JvmStatic fun decodePcm(encoded: String): ByteArray {
            require(encoded.isNotEmpty() && encoded.length <= ((MAX_CHUNK_BYTES + 2) / 3) * 4 && encoded.length % 4 == 0)
            val pcm = Base64.getDecoder().decode(encoded)
            if (pcm.isEmpty() || pcm.size > MAX_CHUNK_BYTES || pcm.size % 2 != 0
                || Base64.getEncoder().encodeToString(pcm) != encoded) {
                pcm.fill(0); throw IllegalArgumentException()
            }
            return pcm
        }
    }
}
