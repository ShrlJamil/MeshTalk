/**
 * MeshTalk — "External Wake-Up" backend, on Cloudflare Workers (free tier).
 *
 * Supersedes the earlier `functions/index.js` Firebase Cloud Function design
 * (RTDB `onWrite`-triggered), which required upgrading the Firebase project
 * to the Blaze (pay-as-you-go) plan just to deploy any Cloud Function at
 * all — even one that never leaves the free-tier usage band. This Worker
 * gives the exact same "send FCM from a trusted server, never from the
 * client" security property at $0, using Cloudflare's free tier instead.
 *
 * Flow:
 *   1. Caller publishes `offer` to RTDB (unchanged, still the actual call
 *      signaling — this Worker never sees or carries SDP/ICE).
 *   2. Caller POSTs {roomId, fcmToken} to this Worker's `/wake` route.
 *   3. This Worker exchanges its `FIREBASE_SERVICE_ACCOUNT` secret for a
 *      short-lived Google OAuth2 access token (self-signed RS256 JWT ->
 *      https://oauth2.googleapis.com/token), then calls the FCM HTTP v1 API
 *      with that token to send one high-priority, data-only "doorbell"
 *      message to the Callee's device.
 *   4. The Callee's `firebaseMessagingBackgroundHandler` (see
 *      lib/services/signaling_service.dart) wakes the screen, ensures the
 *      Standby foreground service is running, and forces the RTDB socket to
 *      reconnect — after which the actual WebRTC offer/answer/ICE exchange
 *      proceeds over RTDB exactly as it always has.
 *
 * The `FIREBASE_SERVICE_ACCOUNT` secret (the full JSON key file for a
 * service account with the "Firebase Cloud Messaging API" role) must never
 * be embedded in the Flutter client — only this trusted server holds it.
 *
 * Phase 3 additions (see the Phase 3 audit for the full reasoning):
 *   - Writes a breadcrumb trace to `debug/fcm_wakeup` in RTDB so a failed
 *     wake-up can be diagnosed after the fact (see resetBreadcrumb/
 *     patchBreadcrumb below) — fire-and-forget, never a dependency of the
 *     actual wake-up.
 *   - The FCM payload stays deliberately data-only. A `notification` block
 *     was considered and rejected: Android/FCM auto-displays notification
 *     (or combined notification+data) messages itself while the app is
 *     backgrounded/terminated and does NOT invoke the Flutter background
 *     handler in that case — which is exactly the Standby state this whole
 *     mechanism targets. Data-only is what guarantees
 *     `firebaseMessagingBackgroundHandler` keeps running; any visible
 *     notification is shown by that handler itself afterwards, not by FCM.
 */

const FIREBASE_PROJECT_ID = 'meshtalk-95d6e';
const FCM_ENDPOINT = `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`;
const TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token';
const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

// Wake-up messages are only useful for a short window after the Caller
// actually places the call — a message that finally gets delivered minutes
// later (after the Caller has already given up) is pointless. `0s` is
// deliberately NOT used: a 0-second TTL tells FCM to drop the message
// entirely if it cannot be delivered on the very first attempt, which is
// too aggressive for a device that may need a few seconds to come out of
// Doze/App-Standby before its Play Services connection is reachable again
// — exactly the scenario this mechanism exists to handle. 60s is long
// enough to tolerate that brief high-priority Doze-exit delay, short
// enough that a late delivery is not worth acting on.
const WAKE_UP_TTL_SECONDS = 60;

// RTDB REST endpoint for the diagnostic breadcrumb trace. This project uses
// no Firebase Auth anywhere (the Flutter client itself talks to RTDB
// unauthenticated, per the app's existing open-room trust model — see
// CLAUDE.md), so these are plain unauthenticated REST calls, matching that
// same trust boundary rather than expanding the service account's granted
// scope to include database access just for a debug write.
const DATABASE_URL = 'https://meshtalk-95d6e-default-rtdb.asia-southeast1.firebasedatabase.app';
const ROOM_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function breadcrumbUrl(roomId) {
  return `${DATABASE_URL}/intercom_rooms/${roomId}/debug/fcm_wakeup.json`;
}

/**
 * Resets the `debug/fcm_wakeup` breadcrumb node to a fresh baseline for this
 * `/wake` attempt (PUT, not PATCH), so a stale field left over from a prior
 * attempt (e.g. `handler_received: true` from an earlier successful wake)
 * can never be misread as evidence about *this* attempt. Every later
 * breadcrumb write in the same pipeline (this Worker's own FCM-result
 * write, and the Flutter client's handler/reconnect writes) merges onto
 * this baseline via PATCH — the node is never appended to, so it never
 * grows unbounded.
 *
 * Fire-and-forget by design (see the caller, wrapped in `ctx.waitUntil`): a
 * breadcrumb write failing must never affect whether the actual wake-up
 * proceeds, and must never delay the response. Never stores the FCM token
 * or any credential.
 */
async function resetBreadcrumb(roomId) {
  try {
    await fetch(breadcrumbUrl(roomId), {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        worker_received: true,
        worker_received_at: { '.sv': 'timestamp' },
      }),
    });
  } catch (error) {
    console.error('[meshtalk-wake] breadcrumb reset failed (continuing anyway):', error);
  }
}

/** Merges additional fields onto the current `fcm_wakeup` breadcrumb node. */
async function patchBreadcrumb(roomId, patch) {
  try {
    await fetch(breadcrumbUrl(roomId), {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(patch),
    });
  } catch (error) {
    console.error('[meshtalk-wake] breadcrumb patch failed (continuing anyway):', error);
  }
}

/** Base64url-encodes a UTF-8 string or raw bytes (ArrayBuffer/TypedArray), no padding. */
function base64url(input) {
  const base64 =
    typeof input === 'string' ? btoa(input) : btoa(String.fromCharCode(...new Uint8Array(input)));
  return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Builds the unsigned `<header>.<claims>` half of a Google service-account JWT. */
function buildUnsignedJwt(serviceAccount) {
  const header = { alg: 'RS256', typ: 'JWT' };
  const nowSeconds = Math.floor(Date.now() / 1000);
  const claims = {
    iss: serviceAccount.client_email,
    scope: FCM_SCOPE,
    aud: TOKEN_ENDPOINT,
    iat: nowSeconds,
    // Google caps this at 1 hour; a fresh JWT/token is minted on every
    // `/wake` request, so there is no refresh/expiry bookkeeping to do here.
    exp: nowSeconds + 3600,
  };
  return `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;
}

/**
 * Signs the unsigned JWT with the service account's PEM private key via
 * `node:crypto` (available thanks to the `nodejs_compat` compatibility
 * flag), avoiding manual PKCS8 parsing against the Web Crypto API.
 */
async function signJwt(unsignedJwt, privateKeyPem) {
  const { createSign } = await import('node:crypto');
  const signer = createSign('RSA-SHA256');
  signer.update(unsignedJwt);
  signer.end();
  const signature = signer.sign(privateKeyPem);
  return base64url(signature);
}

/** Exchanges the service-account JSON for a short-lived FCM-scoped OAuth2 access token. */
async function getAccessToken(serviceAccount) {
  const unsignedJwt = buildUnsignedJwt(serviceAccount);
  const signature = await signJwt(unsignedJwt, serviceAccount.private_key);
  const jwt = `${unsignedJwt}.${signature}`;

  const response = await fetch(TOKEN_ENDPOINT, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });

  if (!response.ok) {
    throw new Error(`OAuth2 token exchange failed (${response.status}): ${await response.text()}`);
  }

  const data = await response.json();
  return data.access_token;
}

/**
 * Sends the actual high-priority, data-only "doorbell" FCM message. Stays
 * data-only deliberately — see the Phase 3 doc comment at the top of this
 * file for why a `notification` block is not used here.
 *
 * Returns the FCM message id (from the API's `{"name": "projects/.../
 * messages/..."}` response shape) for the breadcrumb trace, or `null` if
 * the response couldn't be parsed as expected — never throws on that.
 */
async function sendFcmWakeUp(accessToken, fcmToken, roomId) {
  const response = await fetch(FCM_ENDPOINT, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      message: {
        token: fcmToken,
        data: {
          type: 'incoming_call',
          room: roomId,
        },
        android: {
          // High priority is required to punch through Doze; normal
          // priority gets deferred to the next maintenance window, which
          // defeats the entire point of this Worker.
          priority: 'high',
          ttl: `${WAKE_UP_TTL_SECONDS}s`,
        },
      },
    }),
  });

  const bodyText = await response.text();
  if (!response.ok) {
    throw new Error(`FCM send failed (${response.status}): ${bodyText}`);
  }

  try {
    return JSON.parse(bodyText).name ?? null;
  } catch (_error) {
    return null;
  }
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method !== 'POST' || url.pathname !== '/wake') {
      return jsonResponse({ success: false, error: 'not_found' }, 404);
    }

    let requestBody;
    try {
      requestBody = await request.json();
    } catch (error) {
      return jsonResponse({ success: false, error: 'invalid_json' }, 400);
    }

    const { roomId, fcmToken } = requestBody ?? {};
    if (!roomId || !fcmToken) {
      return jsonResponse({ success: false, error: 'roomId and fcmToken are required' }, 400);
    }
    if (!ROOM_ID_PATTERN.test(roomId)) {
      // roomId is used verbatim as an RTDB path segment for the breadcrumb
      // write below — reject anything that isn't a plain path-safe token
      // before it ever reaches a fetch() URL.
      return jsonResponse({ success: false, error: 'invalid roomId' }, 400);
    }

    // Fire-and-forget: resets the breadcrumb node for this attempt without
    // making the actual wake-up wait on it. `ctx.waitUntil` lets this
    // complete after the response is returned, rather than blocking it.
    ctx.waitUntil(resetBreadcrumb(roomId));

    let serviceAccount;
    try {
      serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
    } catch (error) {
      console.error('[meshtalk-wake] FIREBASE_SERVICE_ACCOUNT secret missing/invalid:', error);
      return jsonResponse({ success: false, error: 'server_misconfigured' }, 500);
    }

    try {
      const accessToken = await getAccessToken(serviceAccount);
      const messageId = await sendFcmWakeUp(accessToken, fcmToken, roomId);
      ctx.waitUntil(
        patchBreadcrumb(roomId, {
          fcm_attempted: true,
          fcm_sent_at: { '.sv': 'timestamp' },
          fcm_message_id: messageId,
          last_error: null,
        }),
      );
      return jsonResponse({ success: true });
    } catch (error) {
      // Safe to store: this is the same non-sensitive HTTP-failure string
      // already returned in the response below — never the service account
      // JSON, its private key, or the FCM token itself.
      const safeError = String(error).slice(0, 300);
      ctx.waitUntil(
        patchBreadcrumb(roomId, {
          fcm_attempted: true,
          fcm_sent_at: null,
          fcm_message_id: null,
          last_error: safeError,
        }),
      );
      console.error('[meshtalk-wake] wake-up failed:', error);
      return jsonResponse({ success: false, error: String(error) }, 502);
    }
  },
};
