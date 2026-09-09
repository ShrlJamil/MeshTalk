package com.example.meshtalk_native

import android.content.res.AssetManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

private const val TTS_CHANNEL = "meshtalk/tts"
private const val MESSAGE_RINGTONE_CHANNEL = "meshtalk/message_ringtone"
private const val MESSAGE_RINGTONE_ASSET = "assets/sounds/message_ringtone.mp3"

/**
 * Phase 3 "Callee status": a single synchronous, read-only device snapshot
 * (battery / charging / battery-temperature / network quality). Registered
 * on the same engines as the TTS/ringtone channels so the Callee can publish
 * its status from the main isolate; see [DeviceStatusReader] for the
 * no-permission, no-BroadcastReceiver, no-audio-contact guarantees.
 */
private const val DEVICE_STATUS_CHANNEL = "meshtalk/device_status"

/**
 * Registers the native Text-to-Speech ([TtsSpeaker]) and message-ringtone
 * ([MessageRingtonePlayer]) MethodChannels on EVERY [io.flutter.embedding.engine.FlutterEngine]
 * the app creates:
 *  - the foreground `MainActivity` engine, and
 *  - the **headless engine** `firebase_messaging` spins up for
 *    `onBackgroundMessage` (where `MainActivity`-scoped channels do not
 *    exist).
 *
 * This is the only thing Phase 2 adds on the native side: the exact same
 * [TtsSpeaker] / [MessageRingtonePlayer] implementations from Phase 1 (moved
 * here unchanged, still the single source of truth) are now reachable from
 * the standby/background/Doze code path too. No change to the audio itself:
 * still `USAGE_MEDIA` / `CONTENT_TYPE_SONIFICATION`, still no audio-focus
 * request, no `AudioManager` mode / speakerphone changes, no WebRTC contact.
 */
class MeshTalkNativePlugin : FlutterPlugin {

    private var ttsChannel: MethodChannel? = null
    private var ringtoneChannel: MethodChannel? = null
    private var deviceStatusChannel: MethodChannel? = null
    private var ttsSpeaker: TtsSpeaker? = null
    private var messageRingtone: MessageRingtonePlayer? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val assets: AssetManager = binding.applicationContext.assets
        val appContext = binding.applicationContext

        val speaker = TtsSpeaker(binding.applicationContext)
        ttsSpeaker = speaker
        val ringtone = MessageRingtonePlayer(MESSAGE_RINGTONE_ASSET)
        messageRingtone = ringtone

        ttsChannel = MethodChannel(binding.binaryMessenger, TTS_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "speak" -> {
                        val text = call.argument<String>("text").orEmpty()
                        speaker.speak(text) { safeSuccess(result) }
                    }
                    "stop" -> {
                        speaker.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        ringtoneChannel = MethodChannel(binding.binaryMessenger, MESSAGE_RINGTONE_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> ringtone.play(assets) { safeSuccess(result) }
                    "stop" -> {
                        ringtone.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        deviceStatusChannel = MethodChannel(binding.binaryMessenger, DEVICE_STATUS_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // Synchronous, read-only, fail-safe (see DeviceStatusReader):
                    // always returns a Map, never throws.
                    "getDeviceStatus" -> result.success(DeviceStatusReader.read(appContext))
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ttsChannel?.setMethodCallHandler(null)
        ringtoneChannel?.setMethodCallHandler(null)
        deviceStatusChannel?.setMethodCallHandler(null)
        ttsChannel = null
        ringtoneChannel = null
        deviceStatusChannel = null
        try {
            ttsSpeaker?.shutdown()
        } catch (_: Exception) {
        }
        try {
            messageRingtone?.stop()
        } catch (_: Exception) {
        }
        ttsSpeaker = null
        messageRingtone = null
    }

    /**
     * Resolves a deferred MethodChannel result, tolerating the case where the
     * (headless) engine has already been torn down by the time a native
     * completion callback (ringtone finished / TTS utterance done) fires.
     */
    private fun safeSuccess(result: MethodChannel.Result) {
        try {
            result.success(null)
        } catch (_: Exception) {
            // Engine/channel gone — nothing to deliver the result to.
        }
    }
}
