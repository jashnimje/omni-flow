package com.jashnm.omniflow_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Hands the UI the NFC tag that opened the app (the omniflow://tag/ intent
 * filter), and later ones Android delivers while the app is not reading, on
 * omniflow/nfc_intent. Also asks for the location access Android requires
 * before it names the Wi-Fi network, on omniflow/permissions.
 */
class MainActivity : FlutterActivity() {
    private var nfc: MethodChannel? = null
    private var pendingScan: Map<String, Any?>? = null
    private var launchReading = false
    private var takeWaiting: MethodChannel.Result? = null
    private var permissionResult: MethodChannel.Result? = null
    private val reader = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        takeTag(intent)?.let { tag ->
            launchReading = true
            readLive(tag) { scan ->
                launchReading = false
                val waiting = takeWaiting
                takeWaiting = null
                if (waiting != null) waiting.success(scan) else pendingScan = scan
            }
        }
        nfc = MethodChannel(messenger, NFC_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> if (launchReading) {
                        takeWaiting = result
                    } else {
                        result.success(pendingScan)
                        pendingScan = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(messenger, PERMISSIONS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "wifiName" -> askForLocation(result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val tag = takeTag(intent) ?: return
        readLive(tag) { scan ->
            if (scan == null) return@readLive
            val channel = nfc
            if (channel != null) channel.invokeMethod("scanned", scan) else pendingScan = scan
        }
    }

    override fun onDestroy() {
        reader.shutdownNow()
        super.onDestroy()
    }

    /**
     * The tag an NDEF intent names, once. Reopening the app from recents
     * replays the launching intent, so that one is skipped, and a taken intent
     * is replaced so a recreated activity does not send it again.
     *
     * The activity is exported for the NFC service, so any app can start it
     * with this action and made-up extras. The id and messages in the extras
     * are never used: only a Tag, which [readLive] then has to read.
     */
    private fun takeTag(intent: Intent?): Tag? {
        if (intent?.action != NfcAdapter.ACTION_NDEF_DISCOVERED) return null
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        setIntent(Intent(Intent.ACTION_MAIN))
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG, Tag::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG)
        }
    }

    /**
     * Reads [tag] again through the NFC service, off the main thread, and
     * hands [done] the scan, or null when the read fails. A Tag another app
     * makes up carries no link to the NFC service, so its read fails and
     * nothing reaches the engine. Getting past this takes a Tag with a binder
     * that answers as the NFC service, far more than made-up extras. `live`
     * tells the Dart side the records came from this read.
     */
    private fun readLive(tag: Tag, done: (Map<String, Any?>?) -> Unit) {
        reader.execute {
            val scan = try {
                Ndef.get(tag)?.use { ndef ->
                    ndef.connect()
                    ndef.ndefMessage?.let { message ->
                        mapOf(
                            "uid" to tag.id,
                            "live" to true,
                            "records" to message.records.map {
                                mapOf("tnf" to it.tnf.toInt(), "type" to it.type, "payload" to it.payload)
                            },
                        )
                    }
                }
            } catch (e: Exception) {
                null
            }
            mainThread.post { done(scan) }
        }
    }

    private fun askForLocation(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        permissionResult?.success(false)
        permissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
            LOCATION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != LOCATION_REQUEST) return
        permissionResult?.success(
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED,
        )
        permissionResult = null
    }

    companion object {
        private const val NFC_CHANNEL = "omniflow/nfc_intent"
        private const val PERMISSIONS_CHANNEL = "omniflow/permissions"
        private const val LOCATION_REQUEST = 7102
    }
}
