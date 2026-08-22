import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'theme.dart';
import 'views/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load();
  _requireTurnCredentials();
  await Firebase.initializeApp();
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
    return MaterialApp(
      title: 'MeshTalk',
      debugShowCheckedModeBanner: false,
      theme: buildMeshTalkTheme(),
      home: const HomeScreen(),
    );
  }
}
