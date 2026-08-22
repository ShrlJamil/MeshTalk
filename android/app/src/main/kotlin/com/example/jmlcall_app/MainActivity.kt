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

/**
 * Plays the short "connection notice" chime via [SoundPool] instead of the
 * `audioplayers` plugin. SoundPool.play() only mixes decoded PCM into
 * whichever output route/mode WebRTC has already configured; unlike
 * `audioplayers` it never calls AudioManager.setMode(), setSpeakerphoneOn(),
 * or requestAudioFocus(), so it cannot interfere with the active
 * MODE_IN_COMMUNICATION call session.
 */
class MainActivity : FlutterActivity() {
    private var soundPool: SoundPool? = null
    private val stopHandler = Handler(Looper.getMainLooper())
    private var pendingStop: Runnable? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTICE_TONE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> {
                        playNoticeTone()
                        result.success(null)
                    }
                    "stop" -> {
                        stopNoticeTone()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        stopNoticeTone()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun playNoticeTone() {
        stopNoticeTone()

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
                .getLookupKeyForAsset(NOTICE_TONE_ASSET)
            assets.openFd(assetKey).use { afd -> pool.load(afd, 1) }
        } catch (_: Exception) {
            stopNoticeTone()
            return
        }

        val stopRunnable = Runnable { stopNoticeTone() }
        pendingStop = stopRunnable
        stopHandler.postDelayed(stopRunnable, NOTICE_TONE_MAX_DURATION_MS)
    }

    private fun stopNoticeTone() {
        pendingStop?.let { stopHandler.removeCallbacks(it) }
        pendingStop = null
        soundPool?.release()
        soundPool = null
    }
}
