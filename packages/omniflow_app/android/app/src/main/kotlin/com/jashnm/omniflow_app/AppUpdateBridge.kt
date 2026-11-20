package com.jashnm.omniflow_app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * Installs an OmniFlow update the app downloaded and checked against the
 * release's SHA256SUMS, on omniflow/updates. It uses Android's
 * PackageInstaller, which reports why an install failed, so a key that does
 * not match the installed app reads as that and not as a generic error. The
 * session takes only this app's own package name, so it cannot install any
 * other app. Android still shows its own prompt to confirm.
 */
class AppUpdateBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val mainThread = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var receiver: BroadcastReceiver? = null

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installed" -> result.success(installed())
                "canInstall" -> result.success(activity.packageManager.canRequestPackageInstalls())
                "openInstallSettings" -> {
                    try {
                        activity.startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}"),
                            ),
                        )
                        result.success(true)
                    } catch (_: android.content.ActivityNotFoundException) {
                        result.success(false)
                    }
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) result.notImplemented() else install(File(path), result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun installed(): Map<String, Any?> {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return mapOf("versionCode" to code, "abis" to Build.SUPPORTED_ABIS.toList())
    }

    /** One install at a time. The result answers once Android has a final
     * status, after the person confirms or closes its prompt. */
    private fun install(apk: File, result: MethodChannel.Result) {
        if (pending != null) return result.success("failed")
        if (!apk.isFile) return result.success("failed")
        pending = result
        listen()
        Thread {
            val status = try {
                commit(apk)
                null
            } catch (e: IOException) {
                "storage"
            } catch (e: SecurityException) {
                "failed"
            }
            if (status != null) mainThread.post { answer(status) }
        }.start()
    }

    private fun commit(apk: File) {
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(activity.packageName)
            setSize(apk.length())
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("omniflow.apk", 0, apk.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            val callback = PendingIntent.getBroadcast(
                activity,
                id,
                Intent(ACTION).setPackage(activity.packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            session.commit(callback.intentSender)
        }
    }

    private fun listen() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        val confirm = confirmIntent(intent)
                        if (confirm == null) {
                            answer("failed")
                        } else {
                            try {
                                activity.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            } catch (_: android.content.ActivityNotFoundException) {
                                answer("failed")
                            }
                        }
                    }
                    else -> answer(
                        statusName(status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)),
                    )
                }
            }
        }
        ContextCompat.registerReceiver(activity, r, IntentFilter(ACTION), ContextCompat.RECEIVER_NOT_EXPORTED)
        receiver = r
    }

    private fun confirmIntent(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }

    private fun answer(status: String) {
        pending?.success(status)
        pending = null
        receiver?.let {
            try {
                activity.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Already gone with the activity.
            }
        }
        receiver = null
    }

    /** Called when the activity goes away, so a pending install does not
     * keep it. */
    fun close() {
        pending?.success("cancelled")
        pending = null
        receiver?.let {
            try {
                activity.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Not registered.
            }
        }
        receiver = null
    }

    companion object {
        private const val CHANNEL = "omniflow/updates"
        private const val ACTION = "com.jashnm.omniflow_app.UPDATE_STATUS"

        /** Android's install status as the names the Dart side reads
         * (InstallResult). The message names the exact failure, so it is
         * read first: a different signing key is
         * INSTALL_FAILED_UPDATE_INCOMPATIBLE, an older build
         * INSTALL_FAILED_VERSION_DOWNGRADE. For an update of this same
         * package a conflict with no message is the key too. */
        fun statusName(status: Int, message: String?): String {
            val text = message.orEmpty()
            return when {
                status == PackageInstaller.STATUS_SUCCESS -> "started"
                text.contains("UPDATE_INCOMPATIBLE") || text.contains("signatures", ignoreCase = true) -> "otherKey"
                text.contains("VERSION_DOWNGRADE") -> "older"
                status == PackageInstaller.STATUS_FAILURE_CONFLICT -> "otherKey"
                status == PackageInstaller.STATUS_FAILURE_ABORTED -> "cancelled"
                status == PackageInstaller.STATUS_FAILURE_STORAGE -> "storage"
                status == PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "incompatible"
                else -> "failed"
            }
        }
    }
}
