# MeshTalk - Flutter WebRTC Intercom

A peer-to-peer audio intercom application built with Flutter, WebRTC, and Firebase Realtime Database for signaling. Uses TURN servers (Metered.ca) for NAT traversal and relay fallback.

## Features

- **Dual Mode Operation**: Single app with two modes - Caller (initiates calls) and Callee (auto-answers)
- **P2P Audio Communication**: 1-way or 2-way audio via WebRTC
- **Auto-Answer on Callee**: Zero-touch incoming call handling
- **TURN/STUN Relay**: Metered.ca servers (UDP/TCP/TLS) for NAT traversal and relay fallback
- **Firebase Signaling**: Real-time signaling via Firebase Realtime Database
- **Speakerphone Routing**: Forces audio output to speakerphone on Callee
- **Proximity Sensor**: Screen off when device near ear during active calls
- **Foreground Service**: Keeps Callee alive in background for instant call reception
- **Call Duration Timer**: Auto-hangup after 3 minutes (configurable)
- **Microphone Mute Toggle**: Local mute control
- **Connection Diagnostics**: Detailed ICE candidate logging and stats polling

## Architecture

```
┌─────────────────┐     Firebase RTDB      ┌─────────────────┐
│   Caller App    │ ◄─────────────────────► │   Callee App    │
│  (Your Phone)   │   intercom_rooms/      │  (Home Phone)   │
└────────┬────────┘   rumah_utama          └────────┬────────┘
         │                                           │
         │              ICE/NAT                      │
         │        Traversal                          │
         │   (STUN + TURN Relay)                     │
         └──────────────────┬────────────────────────┘
                            │
                    ┌───────▼───────┐
                    │  WebRTC Media │
                    │  (P2P/Relay)  │
                    └───────────────┘
```

**Network Path:**
1. **STUN** (`stun.relay.metered.ca:80`) - Discovers public IP/port
2. **TURN UDP** (`turn:global.relay.metered.ca:80`) - Primary relay
3. **TURN TCP** (`turn:global.relay.metered.ca:80?transport=tcp`) - Firewall traversal
4. **TURN TLS** (`turns:global.relay.metered.ca:443`) - Encrypted relay over 443

### Signaling Flow

**Caller:**
1. Clean room → Create PeerConnection → Get local audio stream
2. Create SDP Offer → Set local description → Push to `offer` node
3. Listen for `answer` → Set remote description
4. Push local ICE candidates to `caller_candidates`
5. Listen `callee_candidates` → Add remote candidates

**Callee (Auto-Answer):**
1. Enter standby → Listen `offer` node
2. On offer: Create PeerConnection → Get local audio stream
3. Set remote offer → Create Answer → Set local → Push to `answer`
4. Push local ICE candidates to `callee_candidates`
5. Listen `caller_candidates` → Add remote candidates
6. Force speakerphone ON

### Firebase Data Model

Path: `intercom_rooms/rumah_utama`

```json
{
  "offer": { "type": "offer", "sdp": "...", "createdAt": 1234567890 },
  "answer": { "type": "answer", "sdp": "..." },
  "caller_candidates": {
    "key1": { "candidate": "...", "sdpMid": "0", "sdpMLineIndex": 0 }
  },
  "callee_candidates": {
    "key2": { "candidate": "...", "sdpMid": "0", "sdpMLineIndex": 0 }
  }
}
```

## Tech Stack

| Component | Technology |
|-----------|------------|
| Framework | Flutter (Dart) |
| WebRTC | `flutter_webrtc` ^1.6.0 |
| Signaling | `firebase_database` ^12.4.7 |
| Auth/Core | `firebase_core` ^4.13.0 |
| Permissions | `permission_handler` ^12.0.0 |
| Network | `connectivity_plus` ^7.3.1 |
| ICE/NAT | STUN/TURN (Metered.ca: UDP/TCP/TLS) |
| Sensors | `proximity_sensor` ^2.0.0 |
| Background | `flutter_foreground_task` ^11.0.1 |
| Config | `flutter_dotenv` ^6.0.1 |

## Getting Started

### Prerequisites

- Flutter SDK ^3.12.2
- Firebase project with Realtime Database enabled
- TURN server credentials (Metered.ca or compatible)

### Configuration

1. **Firebase Setup**:
   - Create a Firebase project
   - Enable Realtime Database in test mode (or configure rules)
   - Add `google-services.json` (Android) / `GoogleService-Info.plist` (iOS)

2. **Environment Variables** (`.env` at project root):
   ```env
   TURN_USERNAME=your_turn_username
   TURN_CREDENTIAL=your_turn_credential
   ```

3. **TURN Server** (Metered.ca defaults in code):
   - STUN: `stun:stun.relay.metered.ca:80`
   - TURN UDP: `turn:global.relay.metered.ca:80`
   - TURN TCP: `turn:global.relay.metered.ca:80?transport=tcp`
   - TURN TLS: `turns:global.relay.metered.ca:443?transport=tcp`
   - Override in `signaling_service.dart:_iceConfiguration` if using different provider

### Installation

```bash
# Clone and navigate
git clone https://github.com/ShrlJamil/MeshTalk.git
cd MeshTalk

# Install dependencies
flutter pub get

# Generate launcher icons (optional)
flutter pub run flutter_launcher_icons:main

# Run
flutter run
```

## Project Structure

```
lib/
├── main.dart                      # App entry, Firebase init, theme
├── theme.dart                     # Material 3 theme (light/dark)
├── services/
│   ├── signaling_service.dart     # Core WebRTC + Firebase signaling
│   ├── audio_route_controller.dart # Audio routing (speaker/earpiece)
│   ├── notice_tone_player.dart    # Connection notice sound
│   ├── hangup_tone_player.dart    # Disconnect sound
│   ├── proximity_screen_controller.dart # Proximity sensor
│   ├── screen_wake_controller.dart # Wake screen on incoming call
│   └── foreground_service_controller.dart # Android foreground service
├── views/
│   ├── home_screen.dart           # Mode selection (Caller/Callee)
│   └── call_screen.dart           # Active call UI
└── widgets/
    └── liquid_glass.dart          # Glassmorphism UI component
```

## Usage

### Caller Mode (Your Phone)
1. Open app → Tap **"Panggil Rumah"** (Call Home)
2. Grant microphone permission when prompted
3. Wait for connection → Speak into microphone
4. Tap **End Call** to disconnect

### Callee Mode (Home Phone)
1. Open app → Tap **"Mode Rumah (Auto Answer)"**
2. App enters standby (screen dims, foreground service starts)
3. Incoming call auto-answers → Audio plays on speakerphone
4. Call ends automatically when caller hangs up or 3-min timeout

## Key Implementation Details

### ICE Configuration
Uses STUN + TURN servers from `.env` (Metered.ca relays by default):
- STUN for public IP discovery
- TURN UDP/TCP/TLS for relay when direct P2P fails (symmetric NAT, firewalls)
- Configured in `signaling_service.dart:_iceConfiguration`

### Audio Constraints
- Echo cancellation: ON
- Noise suppression: ON
- Auto gain control: OFF (relies on Android `MODE_IN_COMMUNICATION` hardware AGC)
- High-pass filter: ON

### Audio Session Management
- **During call**: `MODE_IN_COMMUNICATION` + `voiceCall` stream (activates secondary mic)
- **After call**: Reset to `MODE_NORMAL` + speakerphone OFF

### Session Management
- Each call gets unique `sessionId` (incremented on cleanup)
- All async callbacks validate session ID before executing
- Prevents stale callbacks from previous sessions

### Cleanup Guarantees
- `cleanupRoom()` is single choke-point for all teardown paths
- Re-entrancy guard (`_isCleaningUp`) prevents duplicate cleanup
- Firebase room node removed, PeerConnection closed, audio tracks stopped, native session reset

## Troubleshooting

### Call Fails to Connect
- Check Firebase RTDB rules allow read/write
- Ensure TURN credentials valid in `.env`
- Check logs for ICE candidate types (host/srflx/relay)
- Verify STUN/TURN servers reachable from device network

### No Audio on Callee
- Verify speakerphone permission not blocked by OS
- Check `Helper.setSpeakerphoneOn(true)` executed after handshake
- MediaTek devices: ensure mic not locked by early speaker activation

### Callee Doesn't Auto-Answer
- Foreground service running? (persistent notification visible)
- Firebase listeners attached? Check `_offerSub` installed
- Network transition? App forces RTDB reconnect on connectivity change

### Mic Fails on 2nd+ Call
- Fixed: explicit `track.stop()` + `stream.dispose()` in `_closePeerConnection()`
- Native audio tracks now properly released

## License

Private project - not for distribution.

## Acknowledgments

- [flutter_webrtc](https://github.com/flutter-webrtc/flutter-webrtc)
- [Firebase Flutter](https://firebase.flutter.dev/)
- [Metered.ca](https://metered.ca/) (TURN/STUN relay provider)