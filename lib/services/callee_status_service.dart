import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Phase 3 (on-demand) — reads the House phone's status snapshot
/// (battery / charging / network quality / battery temperature) and writes it
/// once to the isolated `intercom_rooms/rumah_utama/callee_status` node.
///
/// This used to publish on a 60s [Timer.periodic] while in standby. It no
/// longer does: [readAndPublish] is invoked exactly once per explicit Caller
/// refresh request (see `SignalingService`'s `callee_status_request`
/// listener). In standby with no Caller request, this class does nothing and
/// writes nothing.
///
/// Isolation contract (unchanged):
///  - NO timer, NO background worker, NO retry loop, NO polling.
///  - Writes ONLY the `callee_status` child node via `set()` — never the room
///    root, never a multi-path update, never anything the announcement /
///    presence / signaling nodes touch.
///  - The native read ([DeviceStatusReader]) registers no permanent
///    BroadcastReceiver / network callback and needs no permission.
///  - Native read + RTDB write are time-boxed and every failure is swallowed
///    and logged. A failure here must never affect standby, the heartbeat,
///    the foreground service, presence, or a call.
class CalleeStatusService {
  CalleeStatusService({DatabaseReference? statusRef, MethodChannel? channel})
      : _statusRef = statusRef ??
            FirebaseDatabase.instance
                .ref('intercom_rooms/rumah_utama/callee_status'),
        _channel = channel ?? const MethodChannel('meshtalk/device_status');

  final DatabaseReference _statusRef;
  final MethodChannel _channel;

  /// Hard cap on a single request (native read + RTDB `set()`), so a frozen
  /// socket or a wedged native call fails fast instead of hanging.
  static const Duration _timeout = Duration(seconds: 8);

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Reads the current device status and writes it to `callee_status`.
  /// Returns `true` iff the RTDB write succeeded. Best-effort throughout:
  /// never throws, never retries. [requestId] (when given) is echoed into the
  /// snapshot as `requestId` for optional Caller-side correlation.
  Future<bool> readAndPublish({String? requestId}) async {
    if (!_isAndroid) return false;
    try {
      final raw = await _readDeviceStatus().timeout(_timeout);
      if (raw == null) {
        debugPrint('[CalleeStatus] native read unavailable -> no publish');
        return false;
      }
      final payload = _buildPayload(raw, requestId);
      await _statusRef.set(payload).timeout(_timeout);
      debugPrint(
        '[CalleeStatus] published (requestId=$requestId) '
        'battery=${payload['battery']} network=${payload['network']} '
        'temp=${payload['temperature']}',
      );
      return true;
    } catch (error) {
      debugPrint('[CalleeStatus] readAndPublish failed (standby unaffected): $error');
      return false;
    }
  }

  Future<Map<Object?, Object?>?> _readDeviceStatus() async {
    try {
      return await _channel
          .invokeMethod<Map<Object?, Object?>>('getDeviceStatus');
    } on MissingPluginException catch (error) {
      debugPrint('[CalleeStatus] device_status channel unavailable: $error');
      return null;
    } on PlatformException catch (error) {
      debugPrint('[CalleeStatus] getDeviceStatus failed: $error');
      return null;
    } catch (error) {
      debugPrint('[CalleeStatus] getDeviceStatus error: $error');
      return null;
    }
  }

  /// Normalises the loosely-typed native Map into the exact RTDB schema,
  /// coercing every field defensively so a missing/odd native value lands as
  /// `null` / `"unknown"` rather than propagating a bad type into RTDB.
  Map<String, Object?> _buildPayload(Map<Object?, Object?> raw, String? requestId) {
    final battery = _asMap(raw['battery']);
    final network = _asMap(raw['network']);
    final temperature = _asMap(raw['temperature']);

    return {
      'requestId': ?requestId,
      'battery': {
        'level': _asInt(battery['level']),
        'charging': battery['charging'] == true,
      },
      'network': {
        'type': _asString(network['type']) ?? 'unknown',
        'quality': _asString(network['quality']) ?? 'unknown',
        'rssi': _asInt(network['rssi']),
        'validated': network['validated'] is bool ? network['validated'] : null,
      },
      'temperature': {
        'celsius': _asDouble(temperature['celsius']),
        'source': _asString(temperature['source']) ?? 'battery',
      },
      // Server-stamped (not the Callee's clock): the Caller compares this
      // against its own clock for freshness, so the write side must not add a
      // second skewed clock into that comparison.
      'updatedAt': ServerValue.timestamp,
    };
  }

  static Map<Object?, Object?> _asMap(Object? value) =>
      value is Map ? value : const {};

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static String? _asString(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    return null;
  }
}
