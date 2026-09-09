package com.example.meshtalk_native

import android.content.Context
import android.media.AudioAttributes
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

private const val TAG = "MeshTalkTTS"

/**
 * Minimal bridge to `android.speech.tts.TextToSpeech` for the Announcement
 * feature (Phase 1). Reached from Dart via the `meshtalk/tts` MethodChannel
 * registered in [MainActivity.configureFlutterEngine].
 *
 * Audio-safety contract (see the Announcement TTS audit) — this class:
 *  - NEVER requests audio focus
 *  - NEVER calls `AudioManager.setMode()` / `setSpeakerphoneOn()`
 *  - NEVER uses `KEY_PARAM_STREAM`
 *  - emits with the SAME [AudioAttributes] as `SoundPoolTone`
 *    (`USAGE_MEDIA` / `CONTENT_TYPE_SONIFICATION`), so the spoken audio only
 *    mixes into whatever output route WebRTC has already configured and can
 *    never disturb an active `MODE_IN_COMMUNICATION` call, its mic, or its
 *    routing.
 *
 * Initialisation is asynchronous. [speak] requests made before the engine
 * reports ready are queued and replayed on a successful `onInit`; if the
 * engine never initialises they are drained (their completion callbacks are
 * still invoked) so the Dart-side announcement queue can never hang.
 */
class TtsSpeaker(context: Context) : TextToSpeech.OnInitListener {

    private data class Utterance(val text: String, val onComplete: () -> Unit)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val counter = AtomicInteger(0)

    private var tts: TextToSpeech? = null
    private var ready = false
    private var initFailed = false

    /** Requests received before `onInit(SUCCESS)`. */
    private val pending = ArrayDeque<Utterance>()

    /** utteranceId -> completion callback for utterances currently dispatched. */
    private val active = HashMap<String, () -> Unit>()

    /** utteranceId -> watchdog runnable, cancelled on natural completion. */
    private val watchdogs = HashMap<String, Runnable>()

    private val audioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    init {
        try {
            tts = TextToSpeech(context.applicationContext, this)
        } catch (e: Exception) {
            Log.e(TAG, "TextToSpeech construction failed", e)
            initFailed = true
        }
    }

    override fun onInit(status: Int) {
        if (status != TextToSpeech.SUCCESS) {
            Log.e(TAG, "onInit ERROR (status=$status) - announcements disabled")
            val drained: List<Utterance>
            synchronized(lock) {
                initFailed = true
                drained = pending.toList()
                pending.clear()
            }
            drained.forEach { mainHandler.post(it.onComplete) }
            return
        }

        val engine = tts
        if (engine == null) {
            initFailed = true
            return
        }

        engine.setAudioAttributes(audioAttributes)
        applySafeLanguage(engine)
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                Log.d(TAG, "TTS onStart id=$utteranceId")
            }

            override fun onDone(utteranceId: String?) {
                Log.d(TAG, "TTS onDone id=$utteranceId")
                resolve(utteranceId)
            }

            @Deprecated("Deprecated in API level 21", ReplaceWith("onError(utteranceId, errorCode)"))
            override fun onError(utteranceId: String?) {
                Log.e(TAG, "TTS onError id=$utteranceId")
                resolve(utteranceId)
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                Log.e(TAG, "TTS onError id=$utteranceId code=$errorCode")
                resolve(utteranceId)
            }
        })

        val drained: List<Utterance>
        synchronized(lock) {
            ready = true
            drained = pending.toList()
            pending.clear()
        }
        Log.d(TAG, "TTS initialized; replaying ${drained.size} queued utterance(s)")
        drained.forEach { dispatch(it) }
    }

    /**
     * Picks a usable language without ever failing hard: tries the device
     * locale first, then US / generic English. If none is available the
     * engine keeps its own default voice.
     */
    private fun applySafeLanguage(engine: TextToSpeech) {
        for (locale in listOf(Locale.getDefault(), Locale.US, Locale.ENGLISH)) {
            val availability = try {
                engine.isLanguageAvailable(locale)
            } catch (e: Exception) {
                TextToSpeech.LANG_NOT_SUPPORTED
            }
            if (availability >= TextToSpeech.LANG_AVAILABLE) {
                val set = engine.setLanguage(locale)
                Log.d(TAG, "setLanguage($locale) -> $set")
                if (set >= TextToSpeech.LANG_AVAILABLE) return
            } else {
                Log.w(TAG, "TTS language $locale unavailable (code=$availability)")
            }
        }
        Log.w(TAG, "no preferred TTS language available; using engine default")
    }

    /**
     * MethodChannel entry point. [onComplete] is invoked exactly once, on
     * the main thread, when the utterance finishes / errors / times out /
     * is cancelled — so the Dart-side await can never hang.
     */
    fun speak(rawText: String, onComplete: () -> Unit) {
        val text = sanitize(rawText)
        if (text == null) {
            Log.w(TAG, "speak() ignored: empty text")
            mainHandler.post(onComplete)
            return
        }

        val shouldQueue: Boolean
        synchronized(lock) {
            if (initFailed) {
                mainHandler.post(onComplete)
                return
            }
            shouldQueue = !ready
            if (shouldQueue) {
                if (pending.size >= MAX_PENDING) {
                    pending.removeFirst().let { mainHandler.post(it.onComplete) }
                }
                pending.addLast(Utterance(text, onComplete))
                Log.d(TAG, "speak() queued (engine not ready); depth=${pending.size}")
            }
        }
        if (!shouldQueue) dispatch(Utterance(text, onComplete))
    }

    private fun dispatch(u: Utterance) {
        val engine = tts
        if (engine == null) {
            mainHandler.post(u.onComplete)
            return
        }

        val id = "meshtalk-ann-${counter.getAndIncrement()}"
        synchronized(lock) { active[id] = u.onComplete }

        // Last-resort liveness guard so a silently-dead engine cannot hang
        // the announcement queue forever. This is NOT a retry and NOT a
        // substitute for onDone/onError (which is the real completion
        // signal) - it mirrors the existing SoundPoolTone auto-stop timeout.
        val cap = (8_000L + u.text.length * 140L).coerceAtMost(60_000L)
        val watchdog = Runnable {
            Log.w(TAG, "TTS watchdog fired id=$id after ${cap}ms")
            resolve(id)
        }
        synchronized(lock) { watchdogs[id] = watchdog }
        mainHandler.postDelayed(watchdog, cap)

        val res = engine.speak(u.text, TextToSpeech.QUEUE_FLUSH, Bundle(), id)
        Log.d(TAG, "TTS speak dispatched id=$id len=${u.text.length} result=$res")
        if (res == TextToSpeech.ERROR) {
            Log.e(TAG, "TTS speak() returned ERROR id=$id")
            resolve(id)
        }
    }

    private fun resolve(id: String?) {
        if (id == null) return
        val cb: (() -> Unit)?
        val watchdog: Runnable?
        synchronized(lock) {
            cb = active.remove(id)
            watchdog = watchdogs.remove(id)
        }
        watchdog?.let { mainHandler.removeCallbacks(it) }
        cb?.let { mainHandler.post(it) }
    }

    /** Cancels any in-flight and queued speech; resolves every callback. */
    fun stop() {
        val callbacks: List<() -> Unit>
        val pendingWatchdogs: List<Runnable>
        synchronized(lock) {
            callbacks = active.values.toList() + pending.map { it.onComplete }
            pendingWatchdogs = watchdogs.values.toList()
            active.clear()
            watchdogs.clear()
            pending.clear()
        }
        pendingWatchdogs.forEach { mainHandler.removeCallbacks(it) }
        try {
            tts?.stop()
        } catch (e: Exception) {
            Log.e(TAG, "stop() failed", e)
        }
        callbacks.forEach { mainHandler.post(it) }
    }

    /** Releases the engine. Must be called from [MainActivity.cleanUpFlutterEngine]. */
    fun shutdown() {
        stop()
        try {
            tts?.shutdown()
        } catch (e: Exception) {
            Log.e(TAG, "shutdown() failed", e)
        }
        synchronized(lock) {
            tts = null
            ready = false
        }
    }

    private fun sanitize(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val hardMax = try {
            TextToSpeech.getMaxSpeechInputLength()
        } catch (e: Exception) {
            4000
        }
        val limit = (hardMax - 1).coerceAtLeast(1)
        return if (trimmed.length > limit) {
            Log.w(TAG, "text length ${trimmed.length} exceeds $limit; truncating")
            trimmed.substring(0, limit)
        } else {
            trimmed
        }
    }

    companion object {
        private const val MAX_PENDING = 5
    }
}
