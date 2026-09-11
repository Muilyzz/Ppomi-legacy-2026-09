package com.ppomi.androidbridge

import android.content.Context
import android.webkit.WebResourceResponse
import androidx.webkit.WebViewAssetLoader
import java.io.ByteArrayInputStream
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/** The packaged configuration is the only trust source; downloaded pages cannot configure or trigger updates. */
internal class FamilyWebUpdates private constructor(context: Context) {
    private var store: FamilyWebStore? = null
    private var config: FamilyWebPackage.Config? = null
    private var selectedRoot: File? = null
    var release = "bundled"
        private set
    var trial = false
        private set
    private val checked = AtomicBoolean(false)
    private var confirmed = false
    var startupFailed = false
        private set
    val canStartSession: Boolean get() = !startupFailed && (!trial || confirmed)

    init {
        // Missing, malformed, or unavailable configuration/state fails closed to the APK's bundled release.
        runCatching {
            val packaged = context.assets.open("Updates.json").use { FamilyWebStore.readBounded(it, 8192) }
            val trusted = FamilyWebPackage.Config(packaged)
            val storage = FamilyWebStore(File(context.noBackupFilesDir, "FamilyWebUpdates"), trusted)
            val selected = storage.beginLaunch()
            config = trusted
            store = storage
            selectedRoot = selected.root
            release = selected.release
            trial = selected.trial
        }
    }

    fun pathHandler(context: Context): WebViewAssetLoader.PathHandler {
        val root = selectedRoot ?: return WebViewAssetLoader.AssetsPathHandler(context)
        return WebViewAssetLoader.PathHandler { path ->
            // Preserve the existing appassets origin and bridge entry URL for both packaged and signed assets.
            val response = runCatching {
                check(path.startsWith("agent/"))
                val relative = "Agent/" + path.removePrefix("agent/")
                FamilyWebPackage.safePath(relative)
                val file = File(root, relative)
                check(file.canonicalPath.startsWith(root.canonicalPath + File.separator) && file.isFile)
                val mime = when (file.extension.lowercase()) {
                    "html" -> "text/html"
                    "js" -> "application/javascript"
                    "css" -> "text/css"
                    "json" -> "application/json"
                    "woff2" -> "font/woff2"
                    "png" -> "image/png"
                    "jpg", "jpeg" -> "image/jpeg"
                    "svg" -> "image/svg+xml"
                    "webp" -> "image/webp"
                    else -> error("Unsupported asset")
                }
                WebResourceResponse(mime, null, file.inputStream())
            }.getOrNull()
            // A release is indivisible. Never mix a missing signed asset with the APK's older file.
            response ?: WebResourceResponse("text/plain", "UTF-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))
        }
    }

    fun checkInBackground() {
        val trusted = config ?: return
        val storage = store ?: return
        if (!checked.compareAndSet(false, true)) return
        Thread({
            runCatching {
                val connection = trusted.endpoint.toURL().openConnection() as HttpsURLConnection
                try {
                    connection.instanceFollowRedirects = false
                    connection.useCaches = false
                    connection.connectTimeout = 15_000
                    connection.readTimeout = 15_000
                    connection.setRequestProperty("Accept", "application/json")
                    connection.setRequestProperty("Accept-Encoding", "identity")
                    connection.setRequestProperty("Cookie", "")
                    connection.setRequestProperty("Authorization", "")
                    check(connection.responseCode == 200)
                    check(connection.contentEncoding == null || connection.contentEncoding.equals("identity", true))
                    check(connection.contentLengthLong <= FamilyWebPackage.MAX_ENVELOPE)
                    val deadline = System.nanoTime() + 60_000_000_000L
                    val bytes = connection.inputStream.use { input ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(16_384)
                        while (true) {
                            check(System.nanoTime() < deadline)
                            val count = input.read(buffer)
                            if (count < 0) break
                            check(output.size().toLong() + count <= FamilyWebPackage.MAX_ENVELOPE)
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    }
                    storage.stage(bytes)
                } finally { connection.disconnect() }
            }
            // Update endpoints, responses, and exceptions are never put into conversation or device logs.
        }, "ppomi-family-update").apply { isDaemon = true; start() }
    }

    fun ready() {
        check(!startupFailed)
        store?.ready()
        confirmed = true
    }

    /** Return true once for a native notice. Recovery occurs at the next process launch, never mid-session. */
    fun failedStartup(): Boolean {
        if (!trial || confirmed || startupFailed) return false
        store?.failedStartup()
        startupFailed = true
        return true
    }

    companion object {
        @Volatile private var instance: FamilyWebUpdates? = null
        fun get(context: Context): FamilyWebUpdates = instance ?: synchronized(this) {
            instance ?: FamilyWebUpdates(context.applicationContext).also { instance = it }
        }
    }
}
