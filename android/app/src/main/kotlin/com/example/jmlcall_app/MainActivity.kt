package com.example.jmlcall_app

import android.media.AudioAttributes
import android.media.SoundPool
import android.os.Handler
import android.os.Looper
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerToneChannel(flutterEngine, NOTICE_TONE_CHANNEL, noticeTone)
        registerToneChannel(flutterEngine, HANGUP_TONE_CHANNEL, hangupTone)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        noticeTone.stop()
        hangupTone.stop()
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
