package com.jashnm.omniflow_app

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.PreferencesKey as PrefsKey

/**
 * Registers the service's bridges (the multicast lock, the phone's battery
 * and Wi-Fi, its actions) before any service starts. The service can start
 * without an activity (after a reboot, or when Android restarts it), so
 * MainActivity is too late.
 */
class OmniFlowApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        dropServiceLocks()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(MulticastLockBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(PhoneSensorsBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(NotifyBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(UsbSerialBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(PhoneActionsBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(PowerBridge(this))
        registerActivityLifecycleCallbacks(Visible)
    }

    /**
     * The plugin keeps the options of the service's first start and reads
     * them again on every start after a reboot or an update, so a phone set
     * up before PowerBridge would still take a wake lock and a Wi-Fi lock
     * for the service's whole life. This process starts before any of those
     * starts, so the saved options are put right here.
     */
    private fun dropServiceLocks() {
        val prefs = getSharedPreferences(PrefsKey.FOREGROUND_TASK_OPTIONS_PREFS, MODE_PRIVATE)
        if (!prefs.contains(PrefsKey.ALLOW_WAKE_LOCK)) return
        if (!prefs.getBoolean(PrefsKey.ALLOW_WAKE_LOCK, true) && !prefs.getBoolean(PrefsKey.ALLOW_WIFI_LOCK, false)) return
        prefs.edit()
            .putBoolean(PrefsKey.ALLOW_WAKE_LOCK, false)
            .putBoolean(PrefsKey.ALLOW_WIFI_LOCK, false)
            .commit()
    }

    /** Counts OmniFlow's started activities, so a phone action knows
     * whether Android lets it open an app or a link at once. */
    private object Visible : ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            started++
            if (started == 1) MulticastLockBridge.screenChanged()
        }

        override fun onActivityStopped(activity: Activity) {
            started = (started - 1).coerceAtLeast(0)
            if (started == 0) MulticastLockBridge.screenChanged()
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityResumed(activity: Activity) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }

    companion object {
        @Volatile private var started = 0

        /** Whether one of OmniFlow's screens is showing. */
        val onScreen: Boolean get() = started > 0
    }
}
