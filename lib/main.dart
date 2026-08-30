import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'services/incoming_call_notification_controller.dart';
import 'services/signaling_service.dart';
import 'theme.dart';
import 'views/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Required by flutter_foreground_task before any start/stopService call —
  // sets up the isolate communication port the Standby foreground service
  // relies on (see ForegroundServiceController).
  FlutterForegroundTask.initCommunicationPort();
  await dotenv.load();
  _requireTurnCredentials();
  await Firebase.initializeApp();
  // Creates the dedicated `meshtalk_incoming_call` notification channel up
  // front. Channel creation is idempotent, and IncomingCallNotificationController
  // also re-ensures it defensively before showing a notification (a
  // background isolate handling a wake-up has no memory of this call ever
  // having run) — this startup call just means the channel already exists
  // in system settings even before the user ever enters Standby.
  unawaited(IncomingCallNotificationController().ensureChannel());
  // Must be registered here (top-level, before runApp) rather than lazily
  // inside SignalingService: a background/terminated-app FCM data message
  // can spin up this isolate before any SignalingService instance ever
  // exists, and FlutterFire requires the handler be wired this early to
  // reliably catch that case. See firebaseMessagingBackgroundHandler's own
  // doc comment for why it lives in signaling_service.dart despite being
  // registered from here.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  runApp(const IntercomApp());
}

/// Fails fast at startup — before any screen is shown and long before
/// [SignalingService] could ever build a peer connection — if the TURN
/// credentials are missing from `.env`. Never logs the values themselves.
void _requireTurnCredentials() {
  final missing = <String>[
    if (dotenv.env['TURN_USERNAME']?.isEmpty ?? true) 'TURN_USERNAME',
    if (dotenv.env['TURN_CREDENTIAL']?.isEmpty ?? true) 'TURN_CREDENTIAL',
  ];
  if (missing.isNotEmpty) {
    throw StateError(
      'Missing required .env key(s): ${missing.join(', ')}. '
      'Create a .env file at the project root with TURN_USERNAME and '
      'TURN_CREDENTIAL set before running the app.',
    );
  }
}

class IntercomApp extends StatelessWidget {
  const IntercomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'MeshTalk',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: buildMeshTalkTheme(Brightness.light),
          darkTheme: buildMeshTalkTheme(Brightness.dark),
          home: const HomeScreen(),
        );
      },
    );
  }
}
