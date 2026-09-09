package com.example.meshtalk_native

import android.content.res.AssetManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector

private const val TAG = "MeshTalkMsgRingtone"

/**
 * Plays the short "announcement incoming" ringtone
 * (`assets/sounds/message_ringtone.mp3`) exactly once and reports TRUE
 * playback completion back to Dart, so the Announcement flow starts
 * Text-to-Speech only after the ringtone has actually finished - no
 * arbitrary delay.
 *
 * Uses [MediaPlayer] rather than `SoundPool` purely because `SoundPool`
 * exposes no end-of-playback callback. Exactly like `SoundPoolTone` it sets
 * explicit [AudioAttributes] (`USAGE_MEDIA` / `CONTENT_TYPE_SONIFICATION`)
 * and NEVER calls `AudioManager.setMode()`, `setSpeakerphoneOn()`, or
 * `requestAudioFocus()`, so it cannot disturb an active
 * `MODE_IN_COMMUNICATION` WebRTC call. The existing NoticeTone / HangupTone
 * `SoundPool` players are left completely untouched.
 */
class MessageRingtonePlayer(private val assetPath: String) {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var pendingComplete: (() -> Unit)? = null
    private var watchdog: Runnable? = null

    private val audioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    /**
     * Starts playback. [onComplete] is invoked on the main thread exactly
     * once - on natural completion, on error, on [stop], or on a
     * duration-derived watchdog - so the caller's await never hangs.
     */
    fun play(assets: AssetManager, onComplete: () -> Unit) {
        stopInternal(resolvePending = true)
        pendingComplete = onComplete

        val mp = MediaPlayer()
        player = mp
        try {
            mp.setAudioAttributes(audioAttributes)
            val assetKey = FlutterInjector.instance().flutterLoader()
                .getLookupKeyForAsset(assetPath)
            assets.openFd(assetKey).use { afd ->
                mp.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            }
            mp.setOnCompletionListener {
                Log.d(TAG, "message ringtone completed")
                finish()
            }
            mp.setOnErrorListener { _, what, extra ->
                Log.e(TAG, "message ringtone error what=$what extra=$extra")
                finish()
                true
            }
            mp.prepare()
            mp.start()

            // Safety net derived from the actual clip length (not an
            // arbitrary delay): guarantees the pending completion resolves
            // even if onCompletion/onError never fire.
            val cap = (mp.duration.takeIf { it > 0 }?.toLong() ?: 15_000L) + 2_000L
            val wd = Runnable {
                Log.w(TAG, "message ringtone watchdog fired after ${cap}ms")
                finish()
            }
            watchdog = wd
            mainHandler.postDelayed(wd, cap)
            Log.d(TAG, "message ringtone started (duration=${mp.duration}ms, cap=${cap}ms)")
        } catch (e: Exception) {
            Log.e(TAG, "message ringtone playback failed", e)
            finish()
        }
    }

    /** Force-stop; still resolves any pending completion so the caller proceeds. */
    fun stop() = stopInternal(resolvePending = true)

    private fun finish() {
        watchdog?.let { mainHandler.removeCallbacks(it) }
        watchdog = null
        releasePlayer()
        val cb = pendingComplete
        pendingComplete = null
        if (cb != null) mainHandler.post(cb)
    }

    private fun stopInternal(resolvePending: Boolean) {
        watchdog?.let { mainHandler.removeCallbacks(it) }
        watchdog = null
        releasePlayer()
        val cb = pendingComplete
        pendingComplete = null
        if (resolvePending && cb != null) mainHandler.post(cb)
    }

    private fun releasePlayer() {
        try {
            player?.let { if (it.isPlaying) it.stop() }
        } catch (e: Exception) {
            Log.w(TAG, "message ringtone stop() during release failed (ignored): $e")
        }
        try {
            player?.release()
        } catch (e: Exception) {
            Log.w(TAG, "message ringtone release() failed (ignored): $e")
        }
        player = null
    }
}
