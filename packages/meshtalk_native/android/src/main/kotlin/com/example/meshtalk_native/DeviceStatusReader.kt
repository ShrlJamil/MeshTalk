package com.example.meshtalk_native

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.util.Log

private const val TAG = "MeshTalkDeviceStatus"

/**
 * Phase 3 "Callee status" — a synchronous, read-only snapshot of the House
 * phone's battery / charging / (battery) temperature / network quality,
 * published to RTDB by [com.example.meshtalk_native] callers so the Caller
 * can glance at the House's state before dialing.
 *
 * Design contract (see the Phase 3 audit):
 *  - PURE READS. No `BroadcastReceiver` is ever kept registered — the single
 *    [Intent.ACTION_BATTERY_CHANGED] read is the OS's sticky broadcast,
 *    returned immediately by `registerReceiver(null, ...)`. Nothing to
 *    unregister, no polling of hardware.
 *  - NO permissions. `ACCESS_NETWORK_STATE` (already in the app manifest) is
 *    all that is used. No `ACCESS_FINE_LOCATION`, so no SSID/BSSID is read
 *    or wanted.
 *  - NEVER touches `AudioManager`, audio focus, media tracks, WebRTC, the
 *    foreground service, wake locks, or any RTDB node. It only returns a Map.
 *  - Temperature is the BATTERY temperature (`EXTRA_TEMPERATURE`). It is
 *    reported with `source = "battery"` so the UI can label it "Baterai",
 *    never "CPU". No reliable skin/CPU thermal API is available to a normal
 *    app on the target device (Realme C12 / Android 10): `HardwarePropertiesManager`
 *    needs device-owner, `PowerManager.getThermalHeadroom()` is API 30+.
 */
object DeviceStatusReader {

    /**
     * Builds the full status snapshot. Every field is independently
     * fail-safe: a sub-read that throws or returns a nonsense value yields
     * `null` (battery level / temperature / rssi / validated) or `"unknown"`
     * (network type / quality) rather than a fabricated number. Never throws.
     */
    fun read(context: Context): Map<String, Any?> {
        val app = context.applicationContext
        val battery = readBattery(app)
        val network = readNetwork(app)
        return mapOf(
            "battery" to battery,
            "network" to network,
            "temperature" to mapOf(
                "celsius" to battery["temperatureCelsius"],
                "source" to "battery",
            ),
        )
    }

    // --- Battery / charging / temperature -----------------------------------

    /**
     * Single sticky `ACTION_BATTERY_CHANGED` read: gives level, charging
     * state and battery temperature in one shot with no permission and no
     * hardware polling. `BatteryManager.BATTERY_PROPERTY_CAPACITY` is used
     * only as a level fallback when the sticky intent is somehow missing.
     */
    private fun readBattery(context: Context): Map<String, Any?> {
        var level: Int? = null
        var charging = false
        var temperatureCelsius: Double? = null

        try {
            val intent: Intent? =
                context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            if (intent != null) {
                val raw = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (raw >= 0 && scale > 0) {
                    level = (raw * 100 / scale).coerceIn(0, 100)
                }

                val status = intent.getIntExtra(
                    BatteryManager.EXTRA_STATUS,
                    BatteryManager.BATTERY_STATUS_UNKNOWN,
                )
                charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL

                // Tenths of a degree Celsius. <= 0 is the documented
                // "unavailable" sentinel on many devices; treat it as null
                // rather than reporting 0.0 C.
                val tenths = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
                if (tenths != Int.MIN_VALUE && tenths > 0) {
                    temperatureCelsius = tenths / 10.0
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "battery sticky-intent read failed (continuing): $e")
        }

        if (level == null) {
            try {
                val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                val capacity = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                if (capacity != null && capacity in 0..100) {
                    level = capacity
                }
            } catch (e: Exception) {
                Log.w(TAG, "BatteryManager capacity fallback failed (continuing): $e")
            }
        }

        return mapOf(
            "level" to level,
            "charging" to charging,
            // Consumed by read() for the temperature block; not part of the
            // battery block written to RTDB.
            "temperatureCelsius" to temperatureCelsius,
        )
    }

    // --- Network type / quality ------------------------------------------------

    /**
     * Reads the active network's transport, whether it has verified internet
     * (`NET_CAPABILITY_VALIDATED`), and — API 29+ only — its signal strength
     * in dBm (`NetworkCapabilities.getSignalStrength()`, which needs no
     * location permission). Quality is derived conservatively: when the
     * signal is unknown the result is `"unknown"`, never an assumed `"good"`.
     */
    private fun readNetwork(context: Context): Map<String, Any?> {
        var type = "unknown"
        var validated: Boolean? = null
        var rssi: Int? = null
        var quality = "unknown"

        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val network = cm?.activeNetwork
            val caps = network?.let { cm.getNetworkCapabilities(it) }

            if (cm == null || network == null || caps == null) {
                return mapOf(
                    "type" to "none",
                    "quality" to "offline",
                    "rssi" to null,
                    "validated" to null,
                )
            }

            type = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                else -> "unknown"
            }

            validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val strength = caps.signalStrength
                // SIGNAL_STRENGTH_UNSPECIFIED == Integer.MIN_VALUE.
                if (strength != Int.MIN_VALUE) rssi = strength
            }

            quality = deriveQuality(type, validated, rssi)
        } catch (e: Exception) {
            Log.w(TAG, "network read failed (reporting unknown): $e")
        }

        return mapOf(
            "type" to type,
            "quality" to quality,
            "rssi" to rssi,
            "validated" to validated,
        )
    }

    /**
     * Maps (transport, validated, dBm) to offline|poor|fair|good|unknown.
     * Where only RSSI is available this reflects LINK SIGNAL quality, not a
     * measured internet throughput/latency — MeshTalk has no existing
     * latency probe to borrow (the 15-min standby heartbeat only forces a
     * socket reconnect, it does not time a round trip).
     */
    private fun deriveQuality(type: String, validated: Boolean?, rssi: Int?): String {
        if (type == "none" || type == "unknown") return "unknown"
        // Connected to a network that has NOT passed the OS internet check
        // (captive portal / dead uplink): worse than any signal reading.
        if (validated == false) return "poor"

        return when (type) {
            "wifi" -> when {
                rssi == null -> "unknown"
                rssi >= -60 -> "good"
                rssi >= -75 -> "fair"
                else -> "poor"
            }
            "cellular" -> when {
                rssi == null -> "unknown"
                rssi >= -95 -> "good"
                rssi >= -110 -> "fair"
                else -> "poor"
            }
            // Wired / VPN with a validated uplink is as good as this phone
            // can report.
            "ethernet", "vpn" -> if (validated == true) "good" else "unknown"
            else -> "unknown"
        }
    }
}
