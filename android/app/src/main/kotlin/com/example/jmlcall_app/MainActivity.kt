package com.example.jmlcall_app

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.WindowManager
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val NOTICE_TONE_CHANNEL = "meshtalk/notice_tone"
private const val NOTICE_TONE_ASSET = "assets/sounds/notice.mp3"
private const val NOTICE_TONE_MAX_DURATION_MS = 5000L

private const val HANGUP_TONE_CHANNEL = "meshtalk/hangup_tone"
private const val HANGUP_TONE_ASSET = "assets/sounds/hangup_tone.mp3"
private const val HANGUP_TONE_MAX_DURATION_MS = 2000L

private const val SCREEN_WAKE_CHANNEL = "meshtalk/screen_wake"

/// Auto-release timeout for the screen wake-up lock. This is deliberately
/// short: the lock's only job is to force the physical panel out of deep
/// sleep at the moment an offer arrives, not to keep it on — `onResume`'s
/// `setShowWhenLocked`/`setTurnScreenOn` (already in place) takes over for
/// keeping the call screen visible once the Activity is actually resumed.
/// A hard timeout (rather than relying on an explicit release() call from
/// the Dart side) guarantees the lock can never be leaked/held indefinitely
/// if that release call is ever missed, which would otherwise silently
/// drain the battery.
private const val SCREEN_WAKE_TIMEOUT_MS = 10_000L

/**
 * Plays the short "connection notice" / "call ended" chimes via [SoundPool]
 * instead of the `audioplayers` plugin. SoundPool.play() only mixes decoded
 * PCM into whichever output route/mode WebRTC has already configured;
 * unlike `audioplayers` it never calls AudioManager.setMode(),
 * setSpeakerphoneOn(), or requestAudioFocus(), so it cannot interfere with
 * the active MODE_IN_COMMUNICATION call session or its teardown.
 *
 * The two tones are fully isolated (separate SoundPool/Handler/state) so
 * that stopping one can never cut off the other.
 */
class MainActivity : FlutterActivity() {
    private val noticeTone = SoundPoolTone(NOTICE_TONE_ASSET, NOTICE_TONE_MAX_DURATION_MS)
    private val hangupTone = SoundPoolTone(HANGUP_TONE_ASSET, HANGUP_TONE_MAX_DURATION_MS)
    private val screenWaker by lazy { ScreenWakeManager(applicationContext) }

    // Lets an incoming/active call surface fullscreen over the lockscreen and
    // turn the display on, matching standard VoIP/dialer app behavior on the
    // Callee side. Re-applied on every onResume since these flags are not
    // persistent across the activity lifecycle.
    override fun onResume() {
        super.onResume()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerToneChannel(flutterEngine, NOTICE_TONE_CHANNEL, noticeTone)
        registerToneChannel(flutterEngine, HANGUP_TONE_CHANNEL, hangupTone)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_WAKE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "wakeScreen" -> {
                        screenWaker.wake()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        noticeTone.stop()
        hangupTone.stop()
        screenWaker.release()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun registerToneChannel(
        flutterEngine: FlutterEngine,
        channelName: String,
        tone: SoundPoolTone,
    ) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> {
                        tone.play(assets)
                        result.success(null)
                    }
                    "stop" -> {
                        tone.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

/**
 * Forces the physical display panel out of deep sleep the moment an
 * incoming offer arrives on the Callee. `setShowWhenLocked`/`setTurnScreenOn`
 * (see [MainActivity.onResume]) only take effect once the Activity is
 * actually resumed/visible to the window manager — on a device whose screen
 * is fully off, that's frequently too late or unreliable on its own. A
 * [PowerManager.WakeLock] built from the legacy `SCREEN_BRIGHT_WAKE_LOCK` +
 * `ACQUIRE_CAUSES_WAKEUP` flags is the mechanism that actually forces the
 * panel hardware on, exactly like a real incoming-call/alarm screen would.
 *
 * These flags are deprecated in favor of `Activity.setTurnScreenOn()`, but
 * that replacement only keeps the screen on for an *already-resumed*
 * Activity — it cannot itself wake a fully-off panel, which is the one
 * capability needed here. Both mechanisms are used together (this class for
 * the initial wake pulse, `setTurnScreenOn` for keeping it on once resumed).
 */
private class ScreenWakeManager(context: Context) {
    private val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
    private var wakeLock: PowerManager.WakeLock? = null

    /**
     * Acquires a short, self-releasing wake lock. Safe to call repeatedly —
     * an already-held lock is released first so a burst of calls (e.g. a
     * retried offer) never stacks up multiple timers. Fully try-caught: a
     * failure here (missing WAKE_LOCK permission, no PowerManager on some
     * OEM ROM, etc.) must never crash or interrupt the incoming-call flow.
     */
    fun wake() {
        try {
            release()
            val pm = powerManager ?: return
            @Suppress("DEPRECATION")
            val lock = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "meshtalk:incoming_call_screen_wake",
            )
            // acquire(timeout) auto-releases itself — the guaranteed
            // battery-safety net even if release() below is never reached.
            lock.acquire(SCREEN_WAKE_TIMEOUT_MS)
            wakeLock = lock
        } catch (_: Exception) {
            wakeLock = null
        }
    }

    /** Releases the lock early if still held. Safe to call anytime. */
    fun release() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
            // Ignored: nothing meaningful to recover from a release failure.
        } finally {
            wakeLock = null
        }
    }
}

/**
 * One isolated, one-shot [SoundPool] player for a single short audio asset.
 * Every call to [play] tears down and recreates its own player, so two
 * instances of this class (e.g. notice tone and hangup tone) never share or
 * contend for state.
 */
private class SoundPoolTone(
    private val assetPath: String,
    private val maxDurationMs: Long,
) {
    private var soundPool: SoundPool? = null
    private val stopHandler = Handler(Looper.getMainLooper())
    private var pendingStop: Runnable? = null

    fun play(assets: android.content.res.AssetManager) {
        stop()

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val pool = SoundPool.Builder()
            .setMaxStreams(1)
            .setAudioAttributes(attributes)
            .build()
        soundPool = pool

        pool.setOnLoadCompleteListener { sp, sampleId, status ->
            if (status == 0) {
                sp.play(sampleId, 1f, 1f, 1, 0, 1f)
            }
        }

        try {
            val assetKey = FlutterInjector.instance().flutterLoader()
                .getLookupKeyForAsset(assetPath)
            assets.openFd(assetKey).use { afd -> pool.load(afd, 1) }
        } catch (_: Exception) {
            stop()
            return
        }

        val stopRunnable = Runnable { stop() }
        pendingStop = stopRunnable
        stopHandler.postDelayed(stopRunnable, maxDurationMs)
    }

    fun stop() {
        pendingStop?.let { stopHandler.removeCallbacks(it) }
        pendingStop = null
        soundPool?.release()
        soundPool = null
    }
}
