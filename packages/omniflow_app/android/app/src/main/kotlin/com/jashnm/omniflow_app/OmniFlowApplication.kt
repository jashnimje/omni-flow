package com.jashnm.omniflow_app

import android.app.Application
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin

/**
 * Registers the service's bridges (the multicast lock, the phone's battery
 * and Wi-Fi) before any service starts. The service can start without an
 * activity (after a reboot, or when Android restarts it), so MainActivity is
 * too late.
 */
class OmniFlowApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(MulticastLockBridge(this))
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(PhoneSensorsBridge(this))
    }
}
