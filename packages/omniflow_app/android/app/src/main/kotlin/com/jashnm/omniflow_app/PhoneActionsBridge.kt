package com.jashnm.omniflow_app

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.RingtoneManager
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.view.KeyEvent
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The omniflow/phone_actions channel on the foreground service's engine.
 *
 * `run` does one phone action the engine asked for and answers
 * `{ok, error?, errorType?, note?}`. Nothing here decides when: the engine
 * does, and the Dart side only passes the request on.
 *
 * `watch` turns on the readings the automations use, and nothing else: the
 * accelerometer only for shake and face down, the call state only with the
 * phone permission, media sessions only with notification access. Each
 * reading goes to the engine through [PhoneSensorsBridge.emit].
 *
 * `calendar` reads the next 24 hours of events and gives back only those
 * whose title has one of the words asked for.
 */
class PhoneActionsBridge(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val notifications = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var channel: MethodChannel? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val ttsWaiting = mutableListOf<() -> Unit>()

    private var motion: MotionSensor? = null
    private var calls: Any? = null
    private var callState = TelephonyManager.CALL_STATE_IDLE
    private var receivers = mutableMapOf<String, BroadcastReceiver>()
    private var sessions: MediaSessionManager.OnActiveSessionsChangedListener? = null
    private val controllers = mutableMapOf<MediaController, MediaController.Callback>()
    private var playing: Boolean? = null

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "run" -> {
                        val action = call.argument<String>("action") ?: ""
                        val params = call.argument<Map<String, Any?>>("params") ?: emptyMap()
                        run(action, params) { answer -> main.post { result.success(answer) } }
                    }
                    "watch" -> {
                        @Suppress("UNCHECKED_CAST")
                        watch((call.arguments as? Map<String, Any?>) ?: emptyMap())
                        result.success(null)
                    }
                    "calendar" -> {
                        val words = call.argument<List<String>>("words") ?: emptyList()
                        Thread {
                            val found = try {
                                calendar(words)
                            } catch (_: RuntimeException) {
                                emptyList()
                            }
                            main.post { result.success(found) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

    override fun onTaskRepeatEvent() {}

    override fun onTaskDestroy() = stopAll()

    override fun onEngineWillDestroy() {
        stopAll()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun stopAll() {
        watch(emptyMap())
        tts?.shutdown()
        tts = null
        ttsReady = false
    }

    // Actions.

    private fun ok(note: String? = null): Map<String, Any?> = mapOf("ok" to true, "note" to note)

    private fun failed(error: String, type: String = "device_error"): Map<String, Any?> =
        mapOf("ok" to false, "error" to error, "errorType" to type)

    private fun run(action: String, params: Map<String, Any?>, answer: (Map<String, Any?>) -> Unit) {
        try {
            when (action) {
                "speak" -> speak(params["text"] as? String ?: "", answer)
                "vibrate" -> answer(vibrate(params["pattern"] == "long"))
                "torch" -> answer(torch(params["value"] == true))
                "play_sound" -> answer(playSound())
                "ringer" -> answer(ringer(params["mode"] as? String))
                "dnd" -> answer(dnd(params["value"] == true))
                "media_volume" -> answer(mediaVolume((params["value"] as? Number)?.toDouble() ?: 0.0))
                "media" -> answer(media(params["key"] as? String ?: "play_pause"))
                "open_app" -> answer(openApp(params["package"] as? String ?: ""))
                "open_link" -> answer(openLink(params["url"] as? String ?: ""))
                "set_alarm" -> answer(setAlarm(params["time"] as? String ?: "", params["label"] as? String))
                "set_timer" -> answer(
                    setTimer((params["minutes"] as? Number)?.toInt() ?: 0, params["label"] as? String),
                )
                "show_message" -> answer(showMessage(params["title"] as? String ?: "", params["text"] as? String))
                else -> answer(failed("This phone does not know how to $action"))
            }
        } catch (e: SecurityException) {
            answer(failed("Android did not allow it: ${e.message ?: "no reason given"}", "needs_user"))
        } catch (e: RuntimeException) {
            answer(failed(e.message ?: "The phone could not do it"))
        }
    }

    /** Answers once the phone starts speaking, so a long text does not
     * keep the automation waiting. */
    private fun speak(text: String, answer: (Map<String, Any?>) -> Unit) {
        if (text.isBlank()) return answer(failed("There is nothing to say", "invalid"))
        val answered = AtomicBoolean(false)
        val once = { a: Map<String, Any?> -> if (answered.compareAndSet(false, true)) answer(a) }
        main.postDelayed({ once(ok("Still speaking")) }, SPEAK_ANSWER_MS)
        val say = {
            val engine = tts
            if (engine == null || !ttsReady) {
                once(failed("Text to speech is not set up on this phone. Install or turn on a voice in Android settings"))
            } else {
                val id = "omniflow-${SystemClock.elapsedRealtime()}"
                engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) = once(ok())
                    override fun onDone(utteranceId: String?) = once(ok())

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) = once(failed("The phone could not say it"))
                })
                if (engine.speak(text, TextToSpeech.QUEUE_ADD, null, id) != TextToSpeech.SUCCESS) {
                    once(failed("The phone could not say it"))
                }
            }
        }
        if (tts != null && ttsReady) return say()
        ttsWaiting.add(say)
        if (tts == null) {
            tts = TextToSpeech(app) { status ->
                main.post {
                    ttsReady = status == TextToSpeech.SUCCESS
                    if (ttsReady) tts?.language = Locale.getDefault()
                    val waiting = ttsWaiting.toList()
                    ttsWaiting.clear()
                    waiting.forEach { it() }
                }
            }
        }
    }

    private fun vibrator(): Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        (app.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        app.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    private fun vibrate(long: Boolean): Map<String, Any?> {
        val v = vibrator()
        if (v == null || !v.hasVibrator()) return failed("This phone cannot vibrate")
        val effect = if (long) {
            VibrationEffect.createWaveform(longArrayOf(0, 600, 200, 600), -1)
        } else {
            VibrationEffect.createOneShot(250, VibrationEffect.DEFAULT_AMPLITUDE)
        }
        v.vibrate(effect)
        return ok()
    }

    private fun torch(on: Boolean): Map<String, Any?> {
        val camera = app.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = camera.cameraIdList.firstOrNull {
            camera.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return failed("This phone has no torch")
        camera.setTorchMode(id, on)
        return ok()
    }

    private fun playSound(): Map<String, Any?> {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: return failed("This phone has no notification sound set")
        val ringtone = RingtoneManager.getRingtone(app, uri) ?: return failed("The phone could not play its sound")
        ringtone.play()
        return ok()
    }

    private fun dndAllowed() = notifications.isNotificationPolicyAccessGranted

    /** Asks for Do Not Disturb access the first time a step needs it: a
     * notification whose tap opens Android's page for it. */
    private fun needsDnd(): Map<String, Any?> {
        notify(
            DND_NOTIFICATION,
            "Allow Do Not Disturb access",
            "An automation wants to change Do Not Disturb or the ringer. Tap to let OmniFlow do that.",
            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS),
        )
        return failed(
            "OmniFlow needs Do Not Disturb access to change this. Tap the notification on the phone to allow it",
            "needs_user",
        )
    }

    private fun ringer(mode: String?): Map<String, Any?> {
        val wanted = when (mode) {
            "silent" -> AudioManager.RINGER_MODE_SILENT
            "vibrate" -> AudioManager.RINGER_MODE_VIBRATE
            "normal" -> AudioManager.RINGER_MODE_NORMAL
            else -> return failed("The ringer is silent, vibrate or normal", "invalid")
        }
        return try {
            audio.ringerMode = wanted
            ok()
        } catch (_: SecurityException) {
            needsDnd()
        }
    }

    private fun dnd(on: Boolean): Map<String, Any?> {
        if (!dndAllowed()) return needsDnd()
        notifications.setInterruptionFilter(
            if (on) NotificationManager.INTERRUPTION_FILTER_PRIORITY else NotificationManager.INTERRUPTION_FILTER_ALL,
        )
        return ok()
    }

    private fun mediaVolume(percent: Double): Map<String, Any?> {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val level = Math.round(percent.coerceIn(0.0, 100.0) * max / 100.0).toInt()
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, level, 0)
        return ok()
    }

    private fun listener() = ComponentName(app, NotificationTriggers::class.java)

    private fun activeControllers(): List<MediaController> = try {
        val manager = app.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        manager.getActiveSessions(listener())
    } catch (_: SecurityException) {
        emptyList()
    }

    /** To the app playing now, through its media session when notification
     * access is on, else as a media key, which needs no access. */
    private fun media(key: String): Map<String, Any?> {
        val controller = activeControllers().firstOrNull()
        if (controller != null) {
            val controls = controller.transportControls
            val isPlaying = controller.playbackState?.state == PlaybackState.STATE_PLAYING
            when (key) {
                "play" -> controls.play()
                "pause" -> controls.pause()
                "next" -> controls.skipToNext()
                "previous" -> controls.skipToPrevious()
                else -> if (isPlaying) controls.pause() else controls.play()
            }
            return ok()
        }
        val code = when (key) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            else -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
        }
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
        return ok()
    }

    private fun openApp(packageName: String): Map<String, Any?> {
        val intent = app.packageManager.getLaunchIntentForPackage(packageName)
            ?: return failed("There is no app $packageName on this phone", "not_found")
        val label = PhoneSensorsBridge.labelOf(app, packageName) ?: packageName
        return start(intent, "Open $label")
    }

    private fun openLink(url: String): Map<String, Any?> {
        val uri = Uri.parse(url)
        if (uri.scheme != "http" && uri.scheme != "https") return failed("Only web links open", "invalid")
        return start(Intent(Intent.ACTION_VIEW, uri), "Open ${uri.host ?: url}")
    }

    private fun setAlarm(time: String, label: String?): Map<String, Any?> {
        val parts = time.split(":")
        val hour = parts.getOrNull(0)?.toIntOrNull()
        val minute = parts.getOrNull(1)?.toIntOrNull()
        if (hour == null || minute == null) return failed("The time is like 07:30", "invalid")
        val intent = Intent(AlarmClock.ACTION_SET_ALARM)
            .putExtra(AlarmClock.EXTRA_HOUR, hour)
            .putExtra(AlarmClock.EXTRA_MINUTES, minute)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (!label.isNullOrBlank()) intent.putExtra(AlarmClock.EXTRA_MESSAGE, label)
        if (intent.resolveActivity(app.packageManager) == null) {
            return failed("No clock app on this phone can set alarms", "not_found")
        }
        return start(intent, "Set an alarm for $time")
    }

    private fun setTimer(minutes: Int, label: String?): Map<String, Any?> {
        if (minutes < 1) return failed("A timer is at least a minute", "invalid")
        val intent = Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, minutes * 60)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (!label.isNullOrBlank()) intent.putExtra(AlarmClock.EXTRA_MESSAGE, label)
        if (intent.resolveActivity(app.packageManager) == null) {
            return failed("No clock app on this phone can set timers", "not_found")
        }
        return start(intent, "Set a $minutes min timer")
    }

    private fun showMessage(title: String, text: String?): Map<String, Any?> {
        val intent = Intent(app, MessageActivity::class.java)
            .putExtra(MessageActivity.EXTRA_TITLE, title)
            .putExtra(MessageActivity.EXTRA_TEXT, text)
        return start(intent, title, text, fullScreen = true)
    }

    /**
     * Opens [intent] at once while OmniFlow is on screen. Android does not
     * let an app open things from the background, so otherwise it becomes
     * a notification to tap, which also opens by itself on a locked phone
     * when full-screen alerts are allowed.
     */
    private fun start(intent: Intent, title: String, text: String? = null, fullScreen: Boolean = false): Map<String, Any?> {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (OmniFlowApplication.onScreen) {
            app.startActivity(intent)
            return ok()
        }
        notify(OPEN_NOTIFICATION + (title.hashCode() and 0xfff), title, text ?: "Tap to open", intent, fullScreen)
        val canFullScreen = Build.VERSION.SDK_INT < 34 || notifications.canUseFullScreenIntent()
        return ok(
            if (fullScreen && canFullScreen) {
                null
            } else {
                "Shown as a notification to tap, since Android does not let apps open things from the background"
            },
        )
    }

    private fun notify(id: Int, title: String, text: String, intent: Intent, fullScreen: Boolean = false) {
        if (notifications.getNotificationChannel(ACTIONS_CHANNEL) == null) {
            notifications.createNotificationChannel(
                NotificationChannel(ACTIONS_CHANNEL, "Phone actions", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Messages and things automations open on this phone"
                },
            )
        }
        val pending = PendingIntent.getActivity(
            app,
            id,
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(app, ACTIONS_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setContentIntent(pending)
            .setAutoCancel(true)
        if (fullScreen) builder.setFullScreenIntent(pending, true)
        try {
            notifications.notify(id, builder.build())
        } catch (_: SecurityException) {
        }
    }

    // Readings.

    private fun emit(reading: Map<String, Any?>) = PhoneSensorsBridge.emit(reading)

    private fun watch(w: Map<String, Any?>) {
        main.post {
            motionWatch(w["shake"] == true, w["faceDown"] == true)
            callsWatch(w["calls"] == true)
            mediaWatch(w["media"] == true)
            receiverWatch("alarm", w["alarm"] == true, IntentFilter(AlarmManager.ACTION_NEXT_ALARM_CLOCK_CHANGED)) {
                sendAlarm()
            }
            if (w["alarm"] == true) sendAlarm()
            receiverWatch("headphones", w["headphones"] == true, IntentFilter(Intent.ACTION_HEADSET_PLUG)) { intent ->
                emit(mapOf("kind" to "headphones", "plugged" to (intent.getIntExtra("state", 0) == 1)))
            }
            val packages = IntentFilter(Intent.ACTION_PACKAGE_ADDED).apply { addDataScheme("package") }
            receiverWatch("packages", w["packages"] == true, packages) { intent ->
                val name = intent.data?.schemeSpecificPart ?: return@receiverWatch
                emit(
                    mapOf(
                        "kind" to "package",
                        "package" to name,
                        "label" to PhoneSensorsBridge.labelOf(app, name),
                        "updated" to intent.getBooleanExtra(Intent.EXTRA_REPLACING, false),
                    ),
                )
            }
            if (w.isNotEmpty()) checkBoot(w["boot"] == true)
        }
    }

    private fun sendAlarm() {
        val alarms = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        emit(mapOf("kind" to "alarm", "atMs" to alarms.nextAlarmClock?.triggerTime))
    }

    private fun receiverWatch(name: String, on: Boolean, filter: IntentFilter, onIntent: (Intent) -> Unit) {
        val existing = receivers[name]
        if (on && existing == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) = onIntent(intent)
            }
            receivers[name] = receiver
            ContextCompat.registerReceiver(app, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        } else if (!on && existing != null) {
            runCatching { app.unregisterReceiver(existing) }
            receivers.remove(name)
        }
    }

    /** Android counts boots, so a start after a new boot is told apart from
     * a restart of the service. Reported once per boot, and only in the
     * first minutes after it. */
    private fun checkBoot(wanted: Boolean) {
        val count = try {
            Settings.Global.getInt(app.contentResolver, Settings.Global.BOOT_COUNT)
        } catch (_: Settings.SettingNotFoundException) {
            return
        }
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val last = prefs.getInt(LAST_BOOT, -1)
        if (last == count) return
        prefs.edit().putInt(LAST_BOOT, count).apply()
        if (wanted && last != -1 && SystemClock.elapsedRealtime() < BOOT_WINDOW_MS) {
            emit(mapOf("kind" to "boot"))
        }
    }

    private fun motionWatch(shake: Boolean, faceDown: Boolean) {
        if (!shake && !faceDown) {
            motion?.stop()
            motion = null
            return
        }
        val m = motion ?: MotionSensor(app) { emit(it) }.also { motion = it }
        m.watch(shake, faceDown)
    }

    private fun callsWatch(on: Boolean) {
        val phone = app.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return
        val allowed = app.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
        if (!on || !allowed) {
            when (val c = calls) {
                is TelephonyCallback -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) phone.unregisterTelephonyCallback(c)
                is PhoneStateListener -> {
                    @Suppress("DEPRECATION")
                    phone.listen(c, PhoneStateListener.LISTEN_NONE)
                }
            }
            calls = null
            return
        }
        if (calls != null) return
        callState = phone.currentCallState()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) = onCall(state)
            }
            phone.registerTelephonyCallback(ContextCompat.getMainExecutor(app), callback)
            calls = callback
        } else {
            @Suppress("DEPRECATION")
            val listener = object : PhoneStateListener() {
                @Deprecated("Deprecated in Java")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) = onCall(state)
            }
            @Suppress("DEPRECATION")
            phone.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            calls = listener
        }
    }

    private fun TelephonyManager.currentCallState(): Int = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) callStateForSubscription else {
            @Suppress("DEPRECATION")
            callState
        }
    } catch (_: SecurityException) {
        TelephonyManager.CALL_STATE_IDLE
    }

    /** Only the state: the number is never read. */
    private fun onCall(state: Int) {
        val before = callState
        callState = state
        val reading = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> "ringing"
            TelephonyManager.CALL_STATE_OFFHOOK -> if (before == TelephonyManager.CALL_STATE_RINGING) "answered" else null
            TelephonyManager.CALL_STATE_IDLE -> if (before != TelephonyManager.CALL_STATE_IDLE) "ended" else null
            else -> null
        } ?: return
        emit(mapOf("kind" to "call", "state" to reading))
    }

    private fun mediaWatch(on: Boolean) {
        val manager = app.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        if (!on) {
            sessions?.let { runCatching { manager.removeOnActiveSessionsChangedListener(it) } }
            sessions = null
            controllers.forEach { (c, cb) -> c.unregisterCallback(cb) }
            controllers.clear()
            playing = null
            return
        }
        if (sessions != null) return
        val listener = MediaSessionManager.OnActiveSessionsChangedListener { list -> follow(list ?: emptyList()) }
        try {
            manager.addOnActiveSessionsChangedListener(listener, listener(), main)
            sessions = listener
            follow(manager.getActiveSessions(listener()))
        } catch (_: SecurityException) {
            // Notification access is off: media triggers wait for it.
        }
    }

    private fun follow(list: List<MediaController>) {
        controllers.forEach { (c, cb) -> c.unregisterCallback(cb) }
        controllers.clear()
        for (c in list) {
            val cb = object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: PlaybackState?) = sendMedia()
                override fun onMetadataChanged(metadata: MediaMetadata?) = sendMedia()
            }
            c.registerCallback(cb, main)
            controllers[c] = cb
        }
        sendMedia()
    }

    private fun sendMedia() {
        val now = controllers.keys.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
        val isPlaying = now != null
        if (isPlaying == playing) return
        playing = isPlaying
        val c = now ?: controllers.keys.firstOrNull()
        val title = c?.metadata?.let {
            it.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE) ?: it.getString(MediaMetadata.METADATA_KEY_TITLE)
        }
        emit(
            mapOf(
                "kind" to "media",
                "playing" to isPlaying,
                "package" to c?.packageName,
                "label" to c?.packageName?.let { PhoneSensorsBridge.labelOf(app, it) },
                "title" to title,
            ),
        )
    }

    /** Events of the next 24 hours whose title has one of [words], in any
     * case. Other titles never leave this method. */
    private fun calendar(words: List<String>): List<Map<String, Any?>> {
        if (words.isEmpty()) return emptyList()
        if (app.checkSelfPermission(Manifest.permission.READ_CALENDAR) != PackageManager.PERMISSION_GRANTED) {
            return emptyList()
        }
        val now = System.currentTimeMillis()
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().apply {
            android.content.ContentUris.appendId(this, now - CALENDAR_BACK_MS)
            android.content.ContentUris.appendId(this, now + CALENDAR_AHEAD_MS)
        }.build()
        val projection = arrayOf(
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
        )
        val found = mutableListOf<Map<String, Any?>>()
        app.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val title = cursor.getString(0) ?: continue
                val lower = title.lowercase(Locale.ROOT)
                for (w in words) {
                    if (lower.contains(w.lowercase(Locale.ROOT))) {
                        found.add(mapOf("words" to w, "title" to title, "begin" to cursor.getLong(1), "end" to cursor.getLong(2)))
                    }
                }
            }
        }
        return found
    }

    companion object {
        private const val CHANNEL = "omniflow/phone_actions"
        private const val ACTIONS_CHANNEL = "omniflow_phone_actions"
        private const val DND_NOTIFICATION = 7301
        private const val OPEN_NOTIFICATION = 7400
        private const val SPEAK_ANSWER_MS = 8_000L
        private const val PREFS = "omniflow_phone"
        private const val LAST_BOOT = "lastBootCount"
        private const val BOOT_WINDOW_MS = 15 * 60_000L
        private const val CALENDAR_BACK_MS = 60_000L
        private const val CALENDAR_AHEAD_MS = 24 * 60 * 60_000L
    }
}
