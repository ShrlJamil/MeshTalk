# 🎙️ MeshTalk

**A peer-to-peer audio intercom for Flutter** — dial home, and the other phone answers itself.

MeshTalk turns two Android phones into a private, always-listening intercom: one phone calls, the other auto-answers with zero touch — even after sitting locked and idle for hours. Audio flows directly between devices over WebRTC; Firebase Realtime Database only carries the signaling handshake, and a Cloudflare Worker gives the sleeping phone a push-notification nudge when Android's own power management tries to freeze it.

> Private project — not for distribution.

---

## Table of Contents

- [Features](#-features)
- [Architecture](#-architecture)
- [Firebase Data Model](#-firebase-data-model)
- [Tech Stack](#-tech-stack)
- [Setup](#-setup)
  - [1. Prerequisites](#1-prerequisites)
  - [2. Firebase Project](#2-firebase-project)
  - [3. TURN/STUN Server](#3-turnstun-server)
  - [4. Cloudflare Worker (FCM Wake-Up Backend)](#4-cloudflare-worker-fcm-wake-up-backend)
  - [5. Environment Variables](#5-environment-variables)
  - [6. Install & Run](#6-install--run)
  - [7. Android Runtime Permissions](#7-android-runtime-permissions)
- [Project Structure](#-project-structure)
- [Usage](#-usage)
- [Key Implementation Details](#-key-implementation-details)
- [Troubleshooting](#-troubleshooting)
- [Acknowledgments](#-acknowledgments)

---

## ✨ Features

- **Dual-mode, one app** — the same build is either the **Caller** or the **Callee (Standby)**, chosen at launch.
- **True auto-answer** — the Callee never touches the screen; an incoming offer is accepted, speakerphone is forced on, and the call connects on its own.
- **Push-triggered wake-up** — a dedicated Cloudflare Worker sends a high-priority FCM message the instant the Caller dials, pulling the Callee's phone out of Doze/App-Standby before the WebRTC handshake even starts.
- **Presence indicator** — the Caller sees a live "Rumah: Siap / Membangunkan.../Sedang Menelepon/Offline" badge before dialing, read straight from Realtime Database.
- **Dedicated incoming-call notification** — a high-importance Android notification channel, shown by the app itself (not by FCM's own auto-display), so the wake-up logic keeps running even while backgrounded.
- **FCM delivery breadcrumb trace** — every wake-up attempt is timestamped stage-by-stage in RTDB, so a failed wake-up after hours of standby can be diagnosed from the Firebase Console instead of guessed at.
- **STUN + multi-transport TURN relay** — UDP, TCP, and TLS-over-443 fallbacks so calls still connect behind strict NATs and firewalls.
- **Foreground service** — keeps the Callee's process (and its Firebase listener) alive in the background, immune to most OEM battery killers.
- **Proximity-aware screen** — screen turns off automatically when the phone is held to the ear mid-call.
- **Auto-hangup safety net** — calls end automatically after 3 minutes if nobody hangs up manually.
- **Liquid-glass UI** — a custom glassmorphism widget set for the call/standby screens.

## 🏗️ Architecture

```
┌──────────────────┐                                          ┌──────────────────┐
│   Caller App      │                                          │   Callee App      │
│  (Your Phone)      │                                          │  (Home Phone)      │
└─────────┬─────────┘                                          └─────────┬─────────┘
          │                                                               │
          │ 1. POST {roomId, fcmToken}                                   │
          ▼                                                               │
 ┌─────────────────────┐        3. FCM HTTP v1, data-only,     ┌────────────────────┐
 │  Cloudflare Worker    │ ─────  high-priority, ttl=60s ─────► │  Google FCM /        │
 │  worker/index.js       │        (wakes the Callee out of      │  Android OS transport │
 │  (holds the Firebase   │        Doze/App-Standby)              └──────────┬─────────┘
 │  service-account       │                                                  │
 │  secret — never in      │        4. onBackgroundMessage: wake screen,     │
 │  the Flutter client)     │           show notification, force RTDB       │
 └───────────┬─────────────┘           reconnect ◄────────────────────────┘
             │ 2. writes breadcrumb                        5. RTDB signaling
             ▼                                                        │
   ┌────────────────────────────────────────────────────────────────┴──┐
   │            Firebase Realtime Database — intercom_rooms/rumah_utama  │
   │   offer · answer · caller_candidates · callee_candidates            │
   │   presence · callee_fcm_token · debug/fcm_wakeup                    │
   └────────────────────────────────────────┬──────────────────────────┘
                                              │
                                     6. ICE / NAT traversal
                                     (STUN discovery, TURN relay)
                                              │
                                    ┌─────────▼─────────┐
                                    │   WebRTC Media       │
                                    │   (P2P or relayed)    │
                                    └───────────────────────┘
```

**ICE servers** (Metered.ca, configured in `signaling_service.dart:_iceConfiguration`):
1. **STUN** `stun:stun.relay.metered.ca:80` — discovers the device's public IP/port
2. **TURN UDP** `turn:global.relay.metered.ca:80` — primary relay
3. **TURN TCP** `turn:global.relay.metered.ca:80?transport=tcp` — firewall traversal
4. **TURN** `turn:global.relay.metered.ca:443` / **TURN TLS** `turns:global.relay.metered.ca:443?transport=tcp` — last-resort relay over the port almost nothing blocks

### Signaling flow

**Caller:**
1. Clear the room's per-call nodes → create `RTCPeerConnection` → grab local audio.
2. Create SDP offer → set local description → push to `offer`.
3. POST the Callee's `callee_fcm_token` to the Cloudflare Worker (fire-and-forget wake-up).
4. Listen for `answer` → set remote description.
5. Push local ICE candidates to `caller_candidates`; listen to `callee_candidates` and add them.

**Callee (Standby / Auto-Answer):**
1. Enter Standby → register presence (`ready`) → store the device's FCM token → listen for `offer`.
2. If backgrounded, an incoming FCM wake-up runs first: wake the screen, ensure the foreground service and RTDB socket are alive, show the incoming-call notification.
3. On `offer`: create `RTCPeerConnection` → grab local audio → set remote offer → create answer → set local → push to `answer`.
4. Push local ICE candidates to `callee_candidates`; listen to `caller_candidates` and add them.
5. Force speakerphone on.

## 📦 Firebase Data Model

Everything lives under one static room: `intercom_rooms/rumah_utama`.

```jsonc
{
  // Per-call signaling — cleared on every new call/hangup (never presence/callee_fcm_token)
  "offer": { "type": "offer", "sdp": "..." },
  "answer": { "type": "answer", "sdp": "..." },
  "caller_candidates": { "key1": { "candidate": "...", "sdpMid": "0", "sdpMLineIndex": 0 } },
  "callee_candidates": { "key2": { "candidate": "...", "sdpMid": "0", "sdpMLineIndex": 0 } },

  // Session-level Standby state — survives call cleanup
  "presence": { "status": "ready", "last_seen": 1234567890 },
  "callee_fcm_token": "device-fcm-registration-token",

  // Diagnostic only — reset fresh on every wake-up attempt, never grown
  "debug": {
    "fcm_wakeup": {
      "worker_received": true, "worker_received_at": 1234567890,
      "fcm_attempted": true, "fcm_sent_at": 1234567890, "fcm_message_id": "projects/.../messages/...",
      "last_error": null,
      "handler_received": true, "handler_received_at": 1234567890,
      "reconnect_started_at": 1234567890, "reconnect_completed_at": 1234567890
    }
  }
}
```

## 🧰 Tech Stack

| Component | Technology |
|---|---|
| Framework | Flutter (Dart) |
| WebRTC | `flutter_webrtc` |
| Signaling | `firebase_database` (Realtime Database) |
| Push wake-up | `firebase_messaging` + a Cloudflare Worker (`worker/`) sending FCM HTTP v1 |
| Local notifications | `flutter_local_notifications` |
| Firebase core | `firebase_core` |
| Permissions | `permission_handler` |
| Network state | `connectivity_plus` |
| ICE/NAT | STUN/TURN via Metered.ca (UDP/TCP/TLS) |
| Sensors | `proximity_sensor` |
| Background execution | `flutter_foreground_task` |
| HTTP | `http` (Worker calls) |
| Config | `flutter_dotenv` |

## 🚀 Setup

### 1. Prerequisites

- Flutter SDK with Dart `^3.12.2`
- A Firebase project with **Realtime Database** enabled
- A TURN/STUN provider (Metered.ca or compatible)
- A [Cloudflare](https://dash.cloudflare.com/sign-up) account (free tier) + [Node.js](https://nodejs.org/) for the Worker CLI (`wrangler`)
- Android SDK/toolchain for building and testing (the app targets Android first — see [Usage](#-usage))

### 2. Firebase Project

1. Create a Firebase project and enable **Realtime Database** (any region — this project uses `asia-southeast1`).
2. Set Realtime Database rules to allow the app to read/write `intercom_rooms/` (this project uses no Firebase Auth — it's a private, single-room intercom, not a multi-tenant service. Scope your rules accordingly for your own deployment).
3. Add an Android app in the Firebase console, download **`google-services.json`**, and place it at `android/app/google-services.json` (git-ignored — never commit it).
4. Enable **Cloud Messaging** for the project (used for the Standby wake-up push).

### 3. TURN/STUN Server

MeshTalk assumes Metered.ca-style STUN/TURN by default. Sign up at [metered.ca](https://www.metered.ca/) (or any TURN provider) and grab a username/credential pair. Using a different provider? Update the `urls` in `signaling_service.dart:_iceConfiguration`.

### 4. Cloudflare Worker (FCM Wake-Up Backend)

The Worker is what actually sends the wake-up push — it holds the one credential that must **never** ship inside the Flutter app: a Firebase service-account key with permission to send FCM messages.

**a. Get a Firebase service-account key**
Firebase Console → ⚙️ Project Settings → **Service Accounts** tab → **Generate new private key**. This downloads a JSON file — keep it safe, do not commit it anywhere.

**b. Install Wrangler and log in**
```bash
cd worker
npm install -g wrangler   # or: npx wrangler <command>, without a global install
wrangler login            # opens a browser to authorize your Cloudflare account
```

**c. Store the service-account key as a Worker secret**
```bash
wrangler secret put FIREBASE_SERVICE_ACCOUNT
# paste the ENTIRE contents of the downloaded JSON file when prompted, then press Enter
```
This secret lives only on Cloudflare's servers — it is never read by, or shipped inside, the Flutter app.

**d. Deploy**
```bash
wrangler deploy
```
Wrangler prints a URL like `https://meshtalk-wake.<your-subdomain>.workers.dev` — the app calls it at the `/wake` path, e.g. `https://meshtalk-wake.<your-subdomain>.workers.dev/wake`.

**e. (If deploying your own fork)** Update `FIREBASE_PROJECT_ID` and `DATABASE_URL` near the top of `worker/index.js` to match your own Firebase project before deploying.

### 5. Environment Variables

Copy the template and fill it in:
```bash
cp .env.example .env
```
```env
TURN_USERNAME=your_turn_username
TURN_CREDENTIAL=your_turn_credential
WORKER_WAKE_UP_URL=https://meshtalk-wake.<your-subdomain>.workers.dev/wake
```
`.env` is git-ignored — never commit it. If `WORKER_WAKE_UP_URL` is left unset, the app still works over direct RTDB signaling; it just skips the push wake-up (no external Worker call is attempted), so the Callee only auto-answers reliably while its process is already alive/foregrounded.

### 6. Install & Run

```bash
# Clone and navigate
git clone https://github.com/ShrlJamil/MeshTalk.git
cd MeshTalk

# Install Flutter dependencies
flutter pub get

# Generate launcher icons (optional)
flutter pub run flutter_launcher_icons:main

# Run on a connected device/emulator
flutter run
```

### 7. Android Runtime Permissions

On first entering Standby, the app requests two Android permissions the Callee needs to stay reachable:
- **Ignore battery optimizations** — so OS-level power management doesn't freeze the background process.
- **Post notifications** (Android 13+) — required for both the Standby foreground-service notification and the incoming-call notification to actually display.

Grant both when prompted; on some OEM ROMs (ColorOS/Realme UI, MIUI, etc.) you may also need to manually allow **auto-launch/background activity** in the phone's own battery-management settings for fully reliable wake-up after long idle periods.

## 📁 Project Structure

```
lib/
├── main.dart                                   # App entry, Firebase init, FCM handler registration
├── theme.dart                                  # Material 3 theme (light/dark)
├── services/
│   ├── signaling_service.dart                  # Core WebRTC + Firebase signaling, presence, FCM wake-up
│   ├── audio_route_controller.dart             # Audio routing (speaker/earpiece)
│   ├── incoming_call_notification_controller.dart # Dedicated incoming-call notification channel
│   ├── notice_tone_player.dart                 # Connection notice sound
│   ├── hangup_tone_player.dart                 # Disconnect sound
│   ├── proximity_screen_controller.dart        # Proximity sensor
│   ├── screen_wake_controller.dart             # Wake screen on incoming call
│   └── foreground_service_controller.dart      # Android foreground service (Standby keep-alive)
├── views/
│   ├── home_screen.dart                        # Mode selection (Caller/Standby) + presence badge
│   └── call_screen.dart                        # Active call UI
└── widgets/
    └── liquid_glass.dart                       # Glassmorphism UI component

worker/
├── index.js                                    # Cloudflare Worker — signs/sends the FCM wake-up
└── wrangler.jsonc                              # Worker deploy config
```

## 📱 Usage

### Caller Mode (Your Phone)
1. Open the app → tap **Call**.
2. Grant microphone permission when prompted.
3. Optionally check the presence badge first ("Rumah: Siap" = ready to answer).
4. Wait for connection → speak into the microphone.
5. Tap **End Call** to disconnect.

### Standby Mode (Home Phone)
1. Open the app → tap **Standby**.
2. Grant battery-optimization and notification permissions when prompted.
3. The app enters Standby (foreground service starts, presence is published as `ready`).
4. An incoming call auto-answers with zero interaction — the screen wakes, a notification appears, and audio plays on speakerphone.
5. The call ends automatically when the Caller hangs up, or after the 3-minute safety timeout.

## 🔍 Key Implementation Details

### ICE Configuration
STUN + multi-transport TURN, credentials from `.env`. See [Architecture](#-architecture) for the full server list. Configured in `signaling_service.dart:_iceConfiguration`.

### Audio Constraints
- Echo cancellation: **ON**
- Noise suppression: **ON**
- Auto gain control: **OFF** (relies on Android's `MODE_IN_COMMUNICATION` hardware AGC)
- High-pass filter: **ON**

### Audio Session Management
- **During call**: `MODE_IN_COMMUNICATION` + `voiceCall` stream (activates the secondary mic).
- **After call**: reset to `MODE_NORMAL`, speakerphone off.

### Session Management
- Each call gets a unique `sessionId` (incremented on every cleanup).
- Every async callback validates its session ID before acting — stale callbacks from a previous call/session are ignored.

### Cleanup Guarantees
- `cleanupRoom()` is the single choke-point for all teardown paths, guarded against re-entrancy (`_isCleaningUp`).
- Clears **only** the per-call signaling nodes (`offer`/`answer`/`caller_candidates`/`callee_candidates`) via a scoped RTDB multi-path update — `presence` and `callee_fcm_token` are deliberately preserved, since they're session-level Standby state, not call state.
- PeerConnection closed, audio tracks stopped, native audio session reset.

### Presence Lifecycle
- `ready` → `waking` → `in_call` → `offline`, published to `presence/status` and shown live on the Caller's `HomeScreen`.
- An RTDB `onDisconnect()` hook is (re-)armed on every fresh socket connection — including after a forced reconnect cycle — so a crashed/killed Callee process reliably reports `offline` instead of leaving a stale `ready` status behind.

### FCM Wake-Up & Diagnostics
- The Worker sends a **data-only**, high-priority FCM message (never `notification`-type) — this is what guarantees the Flutter background handler actually runs while the app is backgrounded/terminated; a `notification`-type payload would let Android auto-display it and skip invoking app code entirely.
- Every wake-up attempt writes a breadcrumb trace to `debug/fcm_wakeup` in RTDB (see [Firebase Data Model](#-firebase-data-model)) — check it in the Firebase Console after a failed wake-up to see exactly which stage never completed.

## 🩺 Troubleshooting

### Call Fails to Connect
- Check Firebase RTDB rules allow read/write on `intercom_rooms/`.
- Ensure `TURN_USERNAME`/`TURN_CREDENTIAL` are valid in `.env`.
- Check logs for ICE candidate types (`host`/`srflx`/`relay`).
- Verify STUN/TURN servers are reachable from the device's network.

### Callee Doesn't Wake Up After Long Standby
- Read `intercom_rooms/rumah_utama/debug/fcm_wakeup` in the Firebase Console right after a failed test — the last field written tells you exactly where the chain stopped (Worker never sent it, Android never delivered it, the handler ran but couldn't reconnect, etc.).
- Confirm `WORKER_WAKE_UP_URL` is set in `.env` and the Worker is actually deployed (`wrangler deploy`, see [Setup §4](#4-cloudflare-worker-fcm-wake-up-backend)).
- Confirm the Callee granted **Post Notifications** and **Ignore Battery Optimizations**, and check OEM-specific settings (auto-launch/background activity) — some ROMs freeze background apps through mechanisms invisible to standard Android battery-optimization settings.

### No Audio on Callee
- Verify speakerphone isn't blocked by the OS.
- Check `Helper.setSpeakerphoneOn(true)` executed after the handshake.
- MediaTek devices: ensure the mic isn't locked by early speaker activation.

### Mic Fails on 2nd+ Call
- Fixed by explicit `track.stop()` + `stream.dispose()` in `_closePeerConnection()` — native audio tracks are properly released between calls.

## 🙏 Acknowledgments

- [flutter_webrtc](https://github.com/flutter-webrtc/flutter-webrtc)
- [Firebase Flutter](https://firebase.flutter.dev/)
- [Metered.ca](https://metered.ca/) — TURN/STUN relay provider
- [Cloudflare Workers](https://workers.cloudflare.com/) — FCM wake-up backend
