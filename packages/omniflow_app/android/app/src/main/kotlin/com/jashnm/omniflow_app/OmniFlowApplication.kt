package com.jashnm.omniflow_app

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin

/**
 * Registers the service's bridges (the multicast lock, the phone's battery
 * and Wi-Fi, its actions) before any service starts. The service can start
 * without an activity (after a reboot, or when Android restarts it), so
 * MainActivity is too late.
 */
class OmniFlowApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(MulticastLockBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(PhoneSensorsBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(NotifyBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(UsbSerialBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(PhoneActionsBridge(this))
        registerActivityLifecycleCallbacks(Visible)
    }

    /** Counts OmniFlow's started activities, so a phone action knows
     * whether Android lets it open an app or a link at once. */
    private object Visible : ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            started++
        }

        override fun onActivityStopped(activity: Activity) {
            started = (started - 1).coerceAtLeast(0)
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
