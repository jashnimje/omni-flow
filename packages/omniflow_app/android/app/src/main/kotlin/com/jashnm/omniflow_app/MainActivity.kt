package com.jashnm.omniflow_app

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.provider.Settings
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.nfc.tech.MifareClassic
import android.nfc.tech.MifareUltralight
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.nfc.tech.NfcA
import android.nfc.tech.NfcB
import android.nfc.tech.NfcF
import android.nfc.tech.NfcV
import android.nfc.tech.TagTechnology
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Hands the UI the NFC tag that opened the app (an omniflow://tag/ link, or
 * any other tag through the tech and tag filters), and later ones Android
 * delivers while the app is not reading, on omniflow/nfc_intent. On omniflow/permissions it asks for the location
 * access Android requires before it names the Wi-Fi network, and for the
 * local network access Android 17 requires before an app reaches devices on
 * the LAN, and reports both.
 */
class MainActivity : FlutterActivity() {
    private var nfc: MethodChannel? = null
    private var pendingScan: Map<String, Any?>? = null
    private var launchReading = false
    private var takeWaiting: MethodChannel.Result? = null
    private val permissionResults = mutableMapOf<Int, MethodChannel.Result>()
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
                "wifiNameAlways" -> askForLocationAlways(result)
                "localNetwork" -> askForLocalNetwork(result)
                "lastLocation" -> result.success(lastLocation())
                "bluetooth" -> askForBluetooth(result)
                "usageAccess" -> openSettings(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS), result)
                "notificationAccess" -> openSettings(notificationAccessIntent(), result)
                "pickTiles" -> openSettings(Intent(this, TilePickerActivity::class.java), result)
                "pickShortcuts" -> openSettings(Intent(this, ShortcutsPickerActivity::class.java), result)
                "status" -> result.success(
                    mapOf(
                        "location" to granted(Manifest.permission.ACCESS_FINE_LOCATION),
                        "locationAlways" to locationAlways(),
                        "localNetwork" to (!localNetworkNeeded() || granted(LOCAL_NETWORK)),
                        "localNetworkNeeded" to localNetworkNeeded(),
                        "usageAccess" to PhoneSensorsBridge.usageAllowed(this),
                        "notificationAccess" to NotificationManagerCompat.getEnabledListenerPackages(this)
                            .contains(packageName),
                        "bluetooth" to bluetoothAllowed(),
                        "bluetoothNeeded" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S),
                    ),
                )
                "appSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Opens a system page (or one of the app's pickers) and answers at
     * once: the page shows the grant, and Settings reads it on return. */
    private fun openSettings(intent: Intent, result: MethodChannel.Result) {
        try {
            startActivity(intent)
            result.success(true)
        } catch (_: android.content.ActivityNotFoundException) {
            result.success(false)
        }
    }

    /** Android 11 and later open OmniFlow's own switch; earlier ones the
     * list of apps. */
    private fun notificationAccessIntent(): Intent =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS).putExtra(
                Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                ComponentName(this, NotificationTriggers::class.java).flattenToString(),
            )
        } else {
            Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
        }

    /** Before Android 12, Bluetooth connections need no runtime grant. */
    private fun bluetoothAllowed() = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
        granted(Manifest.permission.BLUETOOTH_CONNECT)

    private fun askForBluetooth(result: MethodChannel.Result) {
        if (bluetoothAllowed()) return result.success(true)
        ask(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), BLUETOOTH_REQUEST, result)
    }

    /** Names on widgets, tiles and shortcuts follow renames made in the app. */
    override fun onResume() {
        super.onResume()
        val app = applicationContext
        Thread {
            if (RunTargets.refreshNames(app)) {
                runCatching { RunShortcuts.republish(app) }
                mainThread.post {
                    RunWidget.renderAll(app)
                    RunTile.refreshAll(app)
                }
            }
        }.start()
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
     * The tag an NFC intent names, once. Reopening the app from recents
     * replays the launching intent, so that one is skipped, and a taken intent
     * is replaced so a recreated activity does not send it again.
     *
     * The activity is exported for the NFC service, so any app can start it
     * with this action and made-up extras. The id and messages in the extras
     * are never used: only a Tag, which [readLive] then has to read.
     */
    private fun takeTag(intent: Intent?): Tag? {
        if (intent == null || intent.action !in NFC_ACTIONS) return null
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
     * tells the Dart side the records came from this read. A tag with no
     * NDEF records, or none at all, is read by its UID alone, which is how
     * the engine knows a tag OmniFlow never wrote.
     */
    private fun readLive(tag: Tag, done: (Map<String, Any?>?) -> Unit) {
        reader.execute {
            val scan = try {
                val ndef = Ndef.get(tag)
                val records = if (ndef != null) {
                    ndef.use {
                        it.connect()
                        it.ndefMessage?.records?.map { r ->
                            mapOf("tnf" to r.tnf.toInt(), "type" to r.type, "payload" to r.payload)
                        } ?: emptyList()
                    }
                } else if (connects(tag)) {
                    emptyList()
                } else {
                    null
                }
                records?.let { mapOf("uid" to tag.id, "live" to true, "records" to it) }
            } catch (e: Exception) {
                null
            }
            mainThread.post { done(scan) }
        }
    }

    /** Whether [tag] answers through one of its technologies, which proves it is real. */
    private fun connects(tag: Tag): Boolean {
        val tech: TagTechnology = NfcA.get(tag) ?: NfcB.get(tag) ?: NfcF.get(tag)
            ?: NfcV.get(tag) ?: IsoDep.get(tag) ?: MifareUltralight.get(tag)
            ?: MifareClassic.get(tag) ?: NdefFormatable.get(tag) ?: return false
        tech.use { it.connect() }
        return true
    }

    private fun granted(permission: String) =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /**
     * Where the phone last was, for sunrise and sunset at home: the newest
     * fix any provider kept, so nothing turns on GPS. Null without the
     * location permission or with no fix yet.
     */
    private fun lastLocation(): Map<String, Double>? {
        if (!granted(Manifest.permission.ACCESS_FINE_LOCATION) &&
            !granted(Manifest.permission.ACCESS_COARSE_LOCATION)
        ) {
            return null
        }
        val manager = getSystemService(LOCATION_SERVICE) as LocationManager
        val best = try {
            manager.getProviders(true)
                .mapNotNull { manager.getLastKnownLocation(it) }
                .maxByOrNull { it.time }
        } catch (_: SecurityException) {
            null
        } ?: return null
        return mapOf("latitude" to best.latitude, "longitude" to best.longitude)
    }

    /**
     * Whether this Android has the local network permission. It arrived with
     * Android 17; on earlier versions the LAN needs no runtime grant.
     */
    private fun localNetworkNeeded(): Boolean = try {
        packageManager.getPermissionInfo(LOCAL_NETWORK, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun askForLocation(result: MethodChannel.Result) {
        if (granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
            result.success(true)
            return
        }
        ask(
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
            LOCATION_REQUEST,
            result,
        )
    }

    /** Android 10 and later name the Wi-Fi to a background service only
     * with location "all the time". */
    private fun locationAlways() = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
        granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    /** Android 11 and later open the app's location page for this, where
     * the user picks "Allow all the time". It needs location first. */
    private fun askForLocationAlways(result: MethodChannel.Result) {
        if (locationAlways()) return result.success(true)
        if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) return result.success(false)
        ask(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), LOCATION_ALWAYS_REQUEST, result)
    }

    private fun askForLocalNetwork(result: MethodChannel.Result) {
        if (!localNetworkNeeded() || granted(LOCAL_NETWORK)) {
            result.success(true)
            return
        }
        ask(arrayOf(LOCAL_NETWORK), LOCAL_NETWORK_REQUEST, result)
    }

    /** A second ask of the same kind answers the first one false. */
    private fun ask(permissions: Array<String>, requestCode: Int, result: MethodChannel.Result) {
        permissionResults.remove(requestCode)?.success(false)
        permissionResults[requestCode] = result
        requestPermissions(permissions, requestCode)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val result = permissionResults.remove(requestCode) ?: return
        result.success(
            when (requestCode) {
                LOCATION_REQUEST -> granted(Manifest.permission.ACCESS_FINE_LOCATION)
                LOCATION_ALWAYS_REQUEST -> locationAlways()
                BLUETOOTH_REQUEST -> bluetoothAllowed()
                else -> granted(LOCAL_NETWORK)
            },
        )
    }

    companion object {
        private const val NFC_CHANNEL = "omniflow/nfc_intent"
        private val NFC_ACTIONS = setOf(
            NfcAdapter.ACTION_NDEF_DISCOVERED,
            NfcAdapter.ACTION_TECH_DISCOVERED,
            NfcAdapter.ACTION_TAG_DISCOVERED,
        )
        private const val PERMISSIONS_CHANNEL = "omniflow/permissions"
        private const val LOCATION_REQUEST = 7102
        private const val LOCAL_NETWORK_REQUEST = 7103
        private const val LOCATION_ALWAYS_REQUEST = 7104
        private const val BLUETOOTH_REQUEST = 7105
        private const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
    }
}
