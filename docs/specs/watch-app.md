# Clawline Watch App — Voice Terminal

**Status:** Ready for Implementation
**Date:** 2026-02-27
**Owner:** Clawline Apple Watch

## Overview

The Clawline Watch app is a **voice-first terminal** for the Clawline assistant. The interaction model is simple and linear:

1. **User speaks** → Soniox STT (Watch → Soniox direct) → text prompt
2. **Prompt sent** to Clawline provider (Watch → Provider)
3. **Provider responds** with text → Cartesia Sonic-3 TTS (Watch → Cartesia direct) → audio played on Watch

The Watch manages three independent connections in two categories:

**Category 1 — Provider (dual transport with failover):**
- **Provider connection** — chat messaging (send/receive text). Primary: direct to provider on LAN. Fallback: relay through iPhone via WatchConnectivity.

**Category 2 — Cloud APIs (always direct, never relayed):**
- **Soniox WebSocket** — direct to `stt-rt.soniox.com` for real-time speech-to-text
- **Cartesia WebSocket** — direct to `api.cartesia.ai` for real-time text-to-speech

Audio processing (STT and TTS) is **always direct from Watch to cloud APIs** — never through the provider, never through the phone. The provider handles only text-based chat messaging. See [Connectivity Model](#connectivity-model) for the definitive transport rules.

## Connectivity Model

The Watch maintains two categories of connection with different transport rules:

### Category 1: Provider Connection (Chat Messaging)

**Dual transport with automatic failover.** Route indicator is a hard UI invariant — always visible.

- **Primary:** Watch connects DIRECTLY to provider over local network (same WiFi / LAN)
- **Fallback:** If direct connection fails, relay through paired iPhone via WatchConnectivity
- **Recovery:** Auto-recover to direct when available again
- **UI:** Must always show which route is active ("Direct" vs "Via iPhone") — this is a **hard invariant**

The provider connection carries only text-based chat messages. No audio data ever flows through the provider.

### Category 2: Third-Party API Connections (Soniox STT, Cartesia TTS)

**Always direct from Watch to the respective cloud APIs.** No dual transport. No phone relay. No provider relay.

- **Soniox:** Watch → `wss://stt-rt.soniox.com` (direct to cloud)
- **Cartesia:** Watch → `wss://api.cartesia.ai` (direct to cloud)
- **Keys:** Synced from iPhone via WatchConnectivity `transferUserInfo`, stored in shared Keychain
- **Availability:** Requires Watch to have direct internet access (WiFi or cellular). If Watch is Bluetooth-only (relay mode), STT and TTS are unavailable.

These two categories are completely independent. The provider failover state machine does not affect Soniox/Cartesia connections. A Watch can be in `relay` mode for provider chat while Soniox and Cartesia connections are healthy (if the Watch has WiFi but the provider is on a different LAN), or vice versa.

### Connection Diagram

```
  CATEGORY 1 — Provider (chat text, dual transport)
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  Primary:   Watch ──WebSocket──▶ Provider (LAN)     │
  │  Fallback:  Watch ──WCSession──▶ iPhone ──WS──▶ Provider │
  │  UI:        Route indicator always visible          │
  │                                                     │
  └─────────────────────────────────────────────────────┘

  CATEGORY 2 — Cloud APIs (audio, always direct)
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  STT:  Watch mic ──PCM──▶ Soniox cloud ──transcripts──▶ Watch │
  │  TTS:  Watch ──text──▶ Cartesia cloud ──PCM audio──▶ Watch    │
  │  Keys: Synced from iPhone, stored in shared Keychain│
  │  Relay: NEVER. Direct internet required.            │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

### Provider Connection: Dual Transport with Automatic Failover

The provider connection supports two transport paths and fails over automatically:

- **Primary: Direct** — Watch connects to the provider via WebSocket over WiFi or cellular
- **Fallback: Phone Relay** — Watch relays through the paired iPhone via WatchConnectivity when direct is unavailable

STT (Soniox) and TTS (Cartesia) are always direct — they do not use the phone relay path. If the Watch has no direct network access (e.g., Bluetooth-only GPS Watch), STT and TTS are unavailable; the relay path carries only chat text.

### Failover State Machine (Provider Transport)

```
                    ┌─────────────┐
         ┌────────▶│   DIRECT    │◀──── health check passes
         │         │  (primary)  │
         │         └──────┬──────┘
         │                │ connection fails / health check fails
         │                ▼
         │         ┌─────────────┐
         │         │  PROBING    │  attempt direct reconnect (3 attempts, 2s/4s/8s backoff)
         │         └──────┬──────┘
         │                │ all probes fail
         │                ▼
         │         ┌─────────────┐
  direct │         │   RELAY     │  route through iPhone via WatchConnectivity
  healthy│         │ (fallback)  │
         │         └──────┬──────┘
         │                │ periodic direct probe (every 30s)
         │                │ succeeds
         └────────────────┘
```

**States:**

| State | Transport | Behavior |
|-------|-----------|----------|
| `direct` | Watch → Provider WebSocket | Primary path. Health check every 15s (WebSocket ping/pong). |
| `probing` | None (buffering) | Direct failed. Attempt reconnect 3x with exponential backoff (2s, 4s, 8s). UI shows "Reconnecting..." |
| `relay` | Watch → iPhone → Provider | Fallback. Route chat messages through `WCSession`. Probe direct every 30s in background. |
| `disconnected` | None | No transport available. Neither direct nor phone reachable. UI shows "No Connection". Watches for network/reachability changes to re-enter probing. |

**Transitions:**

| From | To | Trigger |
|------|----|---------|
| `direct` | `probing` | WebSocket close, ping timeout (5s no pong), or send failure |
| `probing` | `direct` | Reconnect succeeds + auth completes |
| `probing` | `relay` | All 3 reconnect attempts fail AND `WCSession.isReachable == true` |
| `probing` | `disconnected` | All 3 reconnect attempts fail AND phone not reachable |
| `relay` | `direct` | Background direct probe succeeds + auth completes |
| `relay` | `disconnected` | `WCSession.isReachable` becomes false AND direct probe fails |
| `disconnected` | `probing` | Network reachability changes OR `WCSession.isReachable` becomes true |

**Invariants:**
- The failover state machine governs **provider chat transport only**. Soniox and Cartesia connections are completely independent — they connect directly to their respective cloud APIs regardless of provider route state.
- On transition from `direct` → `probing`, any pending chat send is buffered (max 20 messages). On transition out of `probing`: to `direct` → flush via WebSocket; to `relay` → flush via WCSession; to `disconnected` → hold buffer, retry on next connectivity change. Buffered messages older than 60s are dropped with error callback to the voice session.
- In `relay` state, voice features (STT/TTS) are unavailable if the Watch has no direct internet (WiFi/cellular). STT and TTS never relay through the phone. The Watch shows "Voice unavailable — text only via iPhone" and falls back to system dictation + AVSpeechSynthesizer.
- Route indicator is a **hard UI invariant** — always visible on every screen, showing current provider transport state.
- `WCSession.isReachable` is debounced (1s hysteresis) before triggering state transitions, to avoid rapid bouncing from transient Bluetooth/WiFi fluctuations.

### `WatchProviderTransportState` Enum

The Watch introduces a new `WatchProviderTransportState` enum for its dual-transport failover. This is **Watch-specific** — it does not replace or extend the existing `ConnectionState` enum in `ClawlineShared`.

```swift
enum WatchProviderTransportState: Equatable {
    case direct          // WebSocket to provider on LAN
    case probing         // Direct failed, attempting reconnect (2s/4s/8s)
    case relay           // Routing through iPhone via WCSession
    case disconnected    // No transport available
}
```

**Relationship to `ConnectionState`:** The existing `ConnectionState` enum (`.disconnected`, `.connecting`, `.connected`, `.reconnecting`, `.failed`) represents the state of a single WebSocket connection. The Watch's `WatchProviderTransportState` represents the state of the entire dual-transport system — it sits *above* `ConnectionState` and manages which underlying transport is active. When the Watch is in `.direct`, the underlying WebSocket is in `.connected`. When in `.probing`, the WebSocket is cycling through `.connecting`/`.failed`. When in `.relay`, no WebSocket is active — `WCSession` handles transport.

The `WatchProviderTransport` component (see [Watch App Structure](#watch-app-structure)) owns this state. The route indicator reads it directly. The `ChatServicing` protocol is not modified — the Watch's chat service adapter translates transport state into the standard `ConnectionState` stream for consumers that need it.

**Transport → ConnectionState mapping:**

| `WatchProviderTransportState` | `ConnectionState` | Notes |
|-------------------------------|-------------------|-------|
| `.direct` | `.connected` | WebSocket healthy |
| `.probing` | `.reconnecting` | Attempting direct reconnect |
| `.relay` | `.connected` | WCSession transport is active and functional |
| `.disconnected` | `.disconnected` | No transport available |

### Phone Relay Transport (WatchConnectivity)

When in `relay` state, the Watch uses `WCSession` for chat messages only:

- **Chat messages:** `WCSession.default.sendMessage(_:replyHandler:)` for interactive request/response
- **Latency cost:** ~50-100ms additional round-trip vs direct. Acceptable for text.

The iOS app needs a lightweight `WCSessionDelegate` that proxies chat messages bidirectionally between the Watch and the provider WebSocket. The iOS app does NOT need to be in the foreground — `WCSession` message delivery works with the companion app suspended.

### Relay Wire Protocol

The WCSession relay uses a typed dictionary protocol. All messages are `[String: Any]` dictionaries passed through `WCSession.sendMessage(_:replyHandler:errorHandler:)`.

**Message Envelope:**

Every relay message has a `type` key identifying the operation and a `requestId` for correlation:

```swift
// Watch → iPhone (request)
[
    "type": "chat.send",           // operation type
    "requestId": "req_<uuid>",     // correlation ID
    "payload": [...]               // operation-specific data
]

// iPhone → Watch (response via replyHandler)
[
    "type": "chat.send.ack",       // response type
    "requestId": "req_<uuid>",     // matches request
    "payload": [...]               // operation-specific response
    // OR
    "error": ["code": "not_connected", "message": "Provider unavailable"]
]
```

**Supported Operations:**

| Type | Direction | Payload | Response Payload | Notes |
|------|-----------|---------|-----------------|-------|
| `chat.send` | Watch → iPhone | `id`, `content`, `attachments`, `sessionKey` | `acked: true` | Maps to `ChatServicing.send()` |
| `chat.callback` | Watch → iPhone | `sourceMessageId`, `action`, `data` | `acked: true` | Maps to `ChatServicing.sendInteractiveCallback()` |
| `chat.incoming` | iPhone → Watch | Serialized `ServerMessagePayload` JSON string | (none — push) | iPhone pushes via `sendMessage` when provider delivers a message |
| `streams.fetch` | Watch → iPhone | (empty) | `streams: [StreamSession JSON]` | Maps to `ChatServicing.fetchStreams()` |
| `streams.create` | Watch → iPhone | `displayName`, `idempotencyKey` | `stream: StreamSession JSON` | Maps to `ChatServicing.createStream()` |
| `streams.rename` | Watch → iPhone | `sessionKey`, `displayName` | `stream: StreamSession JSON` | Maps to `ChatServicing.renameStream()` |
| `streams.delete` | Watch → iPhone | `sessionKey`, `idempotencyKey` | `deletedKey: String` | Maps to `ChatServicing.deleteStream()` |
| `event` | iPhone → Watch | Serialized `ChatServiceEvent` discriminator + data | (none — push) | Stream snapshots, typing, session info |
| `auth.refresh` | Watch → iPhone | (empty) | `token`, `userId`, etc. | Token refresh request |
| `relay.activated` | Watch → iPhone | (empty) | (none) | Watch entered relay mode — iPhone proxy starts forwarding messages |
| `relay.deactivated` | Watch → iPhone | (empty) | (none) | Watch left relay mode — iPhone proxy stops forwarding |

**Serialization:** `ServerMessagePayload` and `ChatServiceEvent` are serialized as JSON strings within the `payload` field. The iPhone proxy deserializes Watch requests into `ChatServicing` method calls and serializes responses back. This avoids inventing a parallel wire format — the relay reuses existing Codable types.

**iOS Relay Proxy:**

The iOS app's `WCSessionDelegate` implementation:

1. Receives Watch requests via `session(_:didReceiveMessage:replyHandler:)`
2. Routes to the existing `ProviderChatService` instance (the same one the iOS UI uses)
3. Awaits the result and replies via the `replyHandler`
4. For push messages (`chat.incoming`, `event`): observes `ProviderChatService.incomingMessages` and `serviceEvents`, forwards relevant events to Watch via `WCSession.default.sendMessage`

The proxy does NOT create a separate provider connection. It piggybacks on the iOS app's existing WebSocket connection. If the iOS app is not connected to the provider, relay requests fail with `error: ["code": "not_connected"]`.

**Push Delivery (iPhone → Watch):**

The iPhone proxy maintains a flag for whether the Watch is in relay mode (set via a `relay.activated` / `relay.deactivated` message from the Watch). When relay is active, the proxy forwards all incoming messages and events. When relay is deactivated (Watch switches back to direct), the proxy stops forwarding to avoid duplicate delivery.

### Why Dual Transport

| Factor | Direct Only | Direct + Relay Fallback |
|--------|-------------|------------------------|
| WiFi Watch without iPhone | Works (full voice + chat) | Works (full voice + chat) |
| Cellular Watch without iPhone | Works (full voice + chat) | Works (full voice + chat) |
| GPS-only Watch near iPhone, no WiFi | No chat, no voice | Chat via relay (text only) |
| Bluetooth-only connectivity | Nothing works | Chat via relay (text only) |
| Network blip / provider restart | Down until reconnect | Chat relay covers gap |

The GPS-only Apple Watch (most common model) has no cellular radio. When away from known WiFi, its only network path is Bluetooth relay through the paired iPhone. Dual transport ensures the Watch app can at least send/receive text chat even without direct network. Voice features (Soniox STT, Cartesia TTS) require direct internet — they are never relayed.

## Route Indicator — UI Invariant

**The Watch UI must always prominently show which transport route is active.**

This is a first-class UI element, not a debug affordance. The user should know their connectivity state because it determines whether voice features are available.

### Indicator Behavior

| State | Indicator | Copy | Color | Voice (STT/TTS) | Notes |
|-------|-----------|------|-------|-----------------|-------|
| `direct` | `●` dot + "Direct" | "Direct" | Green | Yes (if Watch has internet) | Full voice experience |
| `probing` | `◌` pulsing dot + "Reconnecting" | "Reconnecting..." | Amber/Yellow | Yes (STT/TTS are independent cloud connections) | Chat buffered, voice unaffected |
| `relay` | `↔` arrows + "Via iPhone" | "Via iPhone" | Blue | Only if Watch also has WiFi (rare) | Typically text-only; STT/TTS need direct internet |
| `disconnected` | `○` empty dot + "Offline" | "No Connection" | Red | No | Nothing works |

### Placement

The route indicator occupies the **top edge** of the single-screen layout as a compact status chip — always visible across all voice states (idle, listening, sending, speaking). See [Watch UI — Route Indicator Placement](#route-indicator-placement) for layout details.

### Route Change Behavior

When the route changes:
1. **Status text** briefly shows the change (2s): "Direct restored" or "Switched to Via iPhone", then returns to normal
2. **Haptic tap** (`WKInterfaceDevice.current().play(.click)`) accompanies the change
3. If transitioning to `relay` during active listening or speaking, voice session is stopped and status text shows: "Voice unavailable — text only"

No overlay toast — route changes are communicated inline via the status text line.

## Soniox STT Integration

### Architecture: Always Direct to Cloud

The Watch connects directly to Soniox cloud, identical to the iOS dictation design. This is a Category 2 connection — always direct, never relayed through provider or phone.

```
Watch mic → AVAudioEngine → PCM16LE 16kHz mono → wss://stt-rt.soniox.com → Transcripts → Watch
```

The provider is not involved in STT. The Watch holds its own copy of the Soniox API key, synced from the iOS app via WatchConnectivity (see Key Bootstrapping section).

### Audio Capture on watchOS

watchOS supports `AVAudioEngine` since watchOS 7. The Watch captures audio identically to the iOS spec:

- **Format:** PCM16LE, 16kHz, mono (matches Soniox `s16le` requirement)
- **Frame size:** 20ms target (640 bytes), up to 100ms tolerance
- **Audio session:** `.playAndRecord` category, `.measurement` mode
- **Microphone:** Built-in Watch mic (always available on Apple Watch)

### Soniox Connection

**Endpoint:** `wss://stt-rt.soniox.com/transcribe-websocket`

**Initial Config Message (sent on connect):**
```json
{
  "api_key": "<watch-local-soniox-key>",
  "model": "stt-rt-preview",
  "audio_format": "s16le",
  "sample_rate": 16000,
  "num_channels": 1,
  "language_hints": ["en"],
  "enable_endpoint_detection": true,
  "client_reference_id": "<device-session-uuid>"
}
```

**Audio Frames:** Binary WebSocket frames containing raw PCM16LE data.

**Soniox Response:**
```json
{
  "text": "hello world",
  "tokens": [
    { "text": "hello ", "start_ms": 0, "end_ms": 450, "confidence": 0.98, "is_final": true },
    { "text": "world", "start_ms": 450, "end_ms": 820, "confidence": 0.85, "is_final": false }
  ],
  "finished": false
}
```

**Stop/Finalize Protocol:**
1. Send `{"type": "finalize"}`
2. Send empty audio frame (end-of-audio marker)
3. Wait for `finished: true` (up to 1.2s timeout)
4. Close WebSocket

**Keepalive:** Send `{"type": "keepalive"}` every 5s while connected.

### Differences from iOS Dictation

The Watch STT uses the same Soniox protocol but with a simpler lifecycle:

| Aspect | iOS Dictation | Watch STT |
|--------|--------------|-----------|
| Activation | Push-up gesture / mic icon tap | Tap mic button / hold mic button |
| Modes | Sticky + Walkie-talkie | Tap (sticky equivalent) + Hold (walkie-talkie) |
| Walkie activation | 124pt displacement + 550ms hold on push-up gesture | Press and hold mic button ≥ 200ms (no displacement threshold — button is purpose-built) |
| Transcript target | Insert into UITextView at cursor | Display in status text, send as whole message |
| Gesture system | DictationMotion, IntentLock, pan recognizer | None — button tap/hold only |
| Transcript reconciliation | ComposeInputDictationBridge (correction/append modes) | Not needed — transcript is the entire message |
| Timers (tap/sticky) | 15s inactivity, 60s max duration | Same: 15s inactivity, 60s max duration |
| Timers (walkie/hold) | No timeouts | Same: no timeouts |
| Finalization | 1.2s hold on all stop paths | Same: 1.2s hold on all stop paths |
| Pre-warm | Phase 1 (prepare) / Phase 2 (activate) | No pre-warm — connect on tap/hold |

The Watch reuses Soniox protocol handling and audio capture code from `ClawlineShared` but does NOT need `DictationSession`, `DictationMotion`, `DictationTranscriptBuffer`, or `ComposeInputDictationBridge`. Those are iOS-specific complexity for inline text editing.

### STT Fallback

If the Watch has no direct network (relay-only or offline), Soniox is unavailable. The Watch offers the watchOS system dictation keyboard as emergency input (`TextField` with system dictation — uses Apple's on-device speech recognizer).

## Cartesia Sonic-3 TTS Integration

### Architecture: Always Direct to Cloud

The Watch connects directly to Cartesia cloud for TTS. This is a Category 2 connection — always direct, never relayed through provider or phone.

```
Provider response text arrives via chat connection (Category 1)
  → Watch opens/reuses Cartesia WebSocket (wss://api.cartesia.ai)
  → Watch sends response text to Cartesia
  → Cartesia streams PCM audio chunks back
  → Watch plays via AVAudioPlayerNode
```

The provider is not involved in TTS. The Watch holds its own copy of the Cartesia API key, synced from the iOS app via WatchConnectivity (see Key Bootstrapping section).

**Prerequisite:** The iOS app must add Cartesia TTS support first (tracked separately). Once iOS has Cartesia integration and the user has configured their Cartesia API key, the Watch receives it automatically via key sync.

### Why Cartesia Sonic-3

| Factor | Cartesia Sonic-3 | ElevenLabs Flash v2.5 |
|--------|-----------------|----------------------|
| TTFB | ~90ms (Sonic-3) / ~40ms (Sonic Turbo) | ~75ms |
| Cost | ~$0.03/min | ~$0.10/min |
| Architecture | State Space Models (designed for streaming) | Transformer-based |
| WebSocket multiplexing | Yes (multiple contexts per connection) | Single stream per connection |
| Voice library | ~130 voices | 4,000+ voices |
| Emotion control | 60+ emotions, SSML tags | Advanced emotional controls |
| Languages | 42 | 70+ |

Cartesia is ~70% cheaper at comparable quality and latency. ElevenLabs remains available as a future upgrade — a client-side swap since both are now client-direct.

### Cartesia Connection

**WebSocket Endpoint:** `wss://api.cartesia.ai/tts/websocket?api_key=<KEY>&cartesia_version=2025-04-16`

The Watch maintains a single Cartesia WebSocket connection using **connect-on-first-TTS** lifecycle: opened when the first TTS utterance is needed, kept alive across utterances via Cartesia multiplexing (`context_id` per utterance), and automatically reconnected if Cartesia drops the idle connection (Cartesia closes idle WebSockets after ~5 minutes). No persistent connection on launch — the connection is lazy.

**Generation Request (Watch → Cartesia):**
```json
{
  "model_id": "sonic-3",
  "transcript": "It's 72 degrees and sunny in Austin.",
  "voice": {
    "mode": "id",
    "id": "<voice-uuid>"
  },
  "language": "en",
  "context_id": "<unique-per-utterance>",
  "output_format": {
    "container": "raw",
    "encoding": "pcm_s16le",
    "sample_rate": 24000
  },
  "continue": false
}
```

For long assistant responses, the Watch can send text in chunks using context continuation:
```json
{ "context_id": "resp-123", "transcript": "It's 72 degrees ", "continue": true, ... }
{ "context_id": "resp-123", "transcript": "and sunny in Austin.", "continue": false, ... }
```

**Audio Response (Cartesia → Watch):**
```json
{
  "type": "chunk",
  "data": "<base64-encoded-pcm>",
  "done": false,
  "context_id": "resp-123"
}
```

**Cancellation (barge-in):**
```json
{
  "context_id": "resp-123",
  "cancel": true
}
```

### Audio Format

**Recommended: `pcm_s16le` @ 24kHz**

Cartesia does not support Opus output. PCM is the recommended format per Cartesia docs ("best performance"). Raw PCM at 24kHz 16-bit mono = 384 kbps — adequate over WiFi/cellular.

### Voice Selection

- Pre-made voice, selected by `voice_id`
- Start with one default voice (pick from Cartesia's ~130 library voices)
- Voice ID synced from iOS app settings via WatchConnectivity `transferUserInfo` (same mechanism as all credentials)
- Future: expose voice selection in iOS app settings (Watch inherits automatically)

### Audio Playback on watchOS

- **Primary:** `AVAudioPlayerNode` with `AVAudioEngine` for streaming PCM chunk playback
- Queue incoming base64-decoded PCM chunks as `AVAudioPCMBuffer` for gapless playback
- Audio session: `.playAndRecord` (shared with mic capture for barge-in)
- Route: Watch speaker or connected Bluetooth audio (AirPods)

### Fallback: AVSpeechSynthesizer (Offline)

When the Watch has no direct network or Cartesia key is not configured:

```swift
let synthesizer = AVSpeechSynthesizer()
let utterance = AVSpeechUtterance(string: assistantResponse)
utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
utterance.rate = AVSpeechUtteranceDefaultSpeechRate
synthesizer.speak(utterance)
```

- Available on watchOS with no network dependency
- Quality is noticeably lower than Cartesia, but functional
- Automatic fallback — no user configuration needed
- Also used when Cartesia API key is not yet synced from iOS

### Cartesia Pricing

| Plan | Monthly Cost | Credits | Approx. Minutes of TTS |
|------|-------------|---------|----------------------|
| Free | $0 | 20,000 | ~27 min |
| Pro | $5 | 100,000 | ~133 min |
| Startup | $49 | 1,250,000 | ~1,667 min |
| Scale | $299 | 8,000,000 | ~10,667 min |

At ~750 characters/minute of speech, 1 credit/character. Start with Pro ($5/mo) for dev/beta. Startup ($49/mo) for production.

## Key Bootstrapping & Credential Sync

### Initial Pairing (Phone → Watch)

1. User pairs iOS app with provider (existing flow)
2. User configures Soniox API key in iOS app settings (existing flow from dictation spec)
3. User configures Cartesia API key in iOS app settings (**prerequisite: iOS Cartesia integration**)
4. iOS app activates `WCSession` and sends all credentials:
   ```swift
   WCSession.default.transferUserInfo([
     "token": authManager.token,
     "userId": authManager.currentUserId,
     "providerBaseURL": ProviderBaseURLStore.shared.baseURL.absoluteString,
     "sonioxApiKey": sonioxKeyStore.apiKey,
     "cartesiaApiKey": cartesiaKeyStore.apiKey,
     "cartesiaVoiceId": cartesiaVoiceStore.selectedVoiceId
   ])
   ```
5. Watch receives in `WCSessionDelegate.session(_:didReceiveUserInfo:)`
6. Watch stores all keys in shared Keychain access group

### Automatic Key Updates

When any key changes on the iOS app (user updates Soniox key, changes Cartesia key, rotates provider token, selects new voice), iOS pushes the update automatically:

```swift
// iOS side — called whenever any credential changes
func syncCredentialsToWatch() {
    guard WCSession.default.isPaired else { return }
    WCSession.default.transferUserInfo([
      "token": authManager.token,
      "userId": authManager.currentUserId,
      "providerBaseURL": ProviderBaseURLStore.shared.baseURL.absoluteString,
      "sonioxApiKey": sonioxKeyStore.apiKey,
      "cartesiaApiKey": cartesiaKeyStore.apiKey,
      "cartesiaVoiceId": cartesiaVoiceStore.selectedVoiceId
    ])
}
```

`transferUserInfo` is guaranteed delivery — queued if Watch is unreachable, delivered when it connects. The Watch applies the latest credentials on receipt and reconnects any active WebSockets with the new keys.

### Shared Keychain Access Group

Add entitlement `group.co.clicketyclacks.Clawline` to both iOS and Watch targets. `KeychainSecureStore` updated to use this access group for all synced credentials.

### Key Availability States on Watch

| Soniox Key | Cartesia Key | Provider Token | Watch Capability |
|------------|-------------|----------------|-----------------|
| Present | Present | Present | Full voice (STT + chat + TTS) |
| Present | Missing | Present | Voice input + text responses (no TTS, uses AVSpeechSynthesizer) |
| Missing | Present | Present | Text input only (system dictation) + TTS playback |
| Missing | Missing | Present | Text-only mode (system dictation keyboard, text responses) |
| Any | Any | Missing | "Open Clawline on iPhone to pair" |

The Watch gracefully degrades based on which keys are available. No key → no feature, with clear messaging.

### Token Refresh

If the Watch receives an `auth_failed` or `token_revoked` event from the provider:
1. Show "Re-open Clawline on iPhone" message
2. Request fresh credentials via `WCSession.default.sendMessage` (if phone reachable)
3. iOS app responds with fresh token via `WCSession` reply handler

## Shared Code Strategy

### New Local Swift Package: `ClawlineShared`

Create a local Swift package at `ios/Clawline/Packages/ClawlineShared/` containing types shared between the iOS app and Watch app:

**Models (move from Clawline target):**
- `Message.swift` — Message struct, Role enum
- `ChatStream.swift` — ChatStream enum (extract from Message.swift)
- `StreamSession.swift` — StreamSession struct
- `SessionKey.swift` — Session key routing logic
- `ConnectionState.swift` — ConnectionState enum (extract from ChatServicing.swift)
- `PairingState.swift` — PairingState enum
- `Attachment.swift` — Attachment struct
- `JSONValue.swift` — JSONValue enum

**Wire Models (move from Clawline target):**
- `ProviderWireModels.swift` — ServerMessagePayload, ClientMessagePayload, etc.
- `WireAttachment.swift`

**Protocols (move from Clawline target):**
- `ChatServicing.swift` — ChatServicing protocol + ChatServiceEvent
- `ConnectionServicing.swift` — ConnectionServicing protocol + PairingResult
- `AuthManaging.swift` — AuthManaging protocol
- `SecureStore.swift` — SecureStoring protocol

**Networking (move from Clawline target):**
- `WebSocketClient.swift` — WebSocketClient protocol + WebSocketConnecting

**New (shared):**
- `SonioxStreamingClient.swift` — Soniox WebSocket protocol handler (shared between iOS and Watch)
- `CartesiaTTSClient.swift` — Cartesia WebSocket protocol handler (shared between iOS and Watch)
- `AudioCaptureFormat.swift` — PCM format constants shared across platforms

### Package Structure

```
Packages/ClawlineShared/
├── Package.swift
└── Sources/
    └── ClawlineShared/
        ├── Models/
        ├── WireModels/
        ├── Protocols/
        ├── Networking/
        └── Audio/
```

Both the `Clawline` iOS target and `Clawline Watch Watch App` target add `ClawlineShared` as a dependency.

### Migration

This is a **move, not duplicate** operation. Files are relocated from `Clawline/` subdirectories into the package. The iOS app imports `ClawlineShared`. No code duplication.

Platform-specific code stays in targets:
- `URLSessionWebSocketConnector.swift` — stays in iOS (TLS pinning, CryptoKit)
- `AuthManager.swift` — stays in iOS (UIKit dependency)
- `ProviderChatService.swift` — stays in iOS (too complex and iOS-specific)
- `DictationSession.swift`, `DictationMotion.swift`, `ComposeInputDictationBridge.swift` — iOS only (gesture/inline-edit complexity)
- All Views/ViewModels — stay in their respective targets

### Code Sharing with iOS Cartesia Integration

Since iOS also needs Cartesia TTS (prerequisite for Watch), `CartesiaTTSClient.swift` lives in `ClawlineShared` and is used by both platforms. The iOS app's "read aloud" feature and the Watch's voice output share the same Cartesia client code.

Similarly, `SonioxStreamingClient.swift` handles the Soniox WebSocket protocol and is shared. The iOS `DictationSession` wraps it with gesture/lifecycle complexity; the Watch wraps it with simple start/stop.

## Watch App Structure

### Entry Point

```swift
@main
struct ClawlineWatchApp: App {
    @State private var credentialStore: WatchCredentialStore
    @State private var providerTransport: WatchProviderTransport
    @State private var voiceSession: WatchVoiceSession
    @State private var channelManager: WatchChannelManager
    private let wcSessionDelegate: WatchWCSessionDelegate

    init() {
        let credentialStore = WatchCredentialStore()
        _credentialStore = State(initialValue: credentialStore)

        let transport = WatchProviderTransport(
            credentialStore: credentialStore
        )
        _providerTransport = State(initialValue: transport)

        let voiceSession = WatchVoiceSession(
            credentialStore: credentialStore
        )
        _voiceSession = State(initialValue: voiceSession)

        let channelManager = WatchChannelManager()
        _channelManager = State(initialValue: channelManager)

        // WCSession delegate — routes credential updates and relay messages
        let delegate = WatchWCSessionDelegate(
            credentialStore: credentialStore,
            transport: transport
        )
        self.wcSessionDelegate = delegate
        WCSession.default.delegate = delegate
        WCSession.default.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchMainView()
                .environment(credentialStore)
                .environment(providerTransport)
                .environment(voiceSession)
                .environment(channelManager)
        }
    }
}
```

### Service Composition

| Component | Type | Job | Owns |
|-----------|------|-----|------|
| `WatchCredentialStore` | `@Observable` | Keychain read/write for synced credentials. Receives `WCSession` updates. | Provider token, userId, providerBaseURL, sonioxApiKey, cartesiaApiKey, cartesiaVoiceId |
| `WatchProviderTransport` | `@Observable` | Dual-transport failover state machine. Manages direct WebSocket + WCSession relay. Provides `ChatServicing`-compatible interface for send/receive. | `transportState: WatchProviderTransportState`, message buffer, reconnect timers |
| `WatchVoiceSession` | `@Observable` | Voice lifecycle: STT → send → TTS. See [WatchVoiceSession](#watchvoicesession). | Voice phase, Soniox client, Cartesia client, audio engine, timers |
| `WatchChannelManager` | `@Observable` | Stream/channel selection and switching. Receives stream snapshots from transport. | `currentSessionKey`, `streams: [StreamSession]`, UI selection (debounced 500ms) |
| `WatchWCSessionDelegate` | `NSObject, WCSessionDelegate` | Receives credential syncs (`transferUserInfo`), relay messages, and activation events. Routes to `WatchCredentialStore` and `WatchProviderTransport`. | WCSession activation state |

### Dependency Graph

```
ClawlineWatchApp
  ├── WatchCredentialStore (Keychain + WCSession receiver)
  │     ↑ reads: WatchWCSessionDelegate (credential updates)
  │
  ├── WatchProviderTransport (failover state machine)
  │     ↑ reads: WatchCredentialStore (token, baseURL)
  │     ↑ reads: WatchWCSessionDelegate (relay messages)
  │     ↓ provides: send/receive chat, transportState, connectionState stream
  │
  ├── WatchVoiceSession (voice lifecycle)
  │     ↑ reads: WatchCredentialStore (sonioxApiKey, cartesiaApiKey, voiceId)
  │     → emits: onTranscriptReady (app layer routes to transport.send)
  │     ↑ reads: WatchProviderTransport.transportState (route-change force-stop)
  │
  └── WatchChannelManager (stream selection)
        ↑ reads: WatchProviderTransport (stream snapshots, CRUD responses)
```

### Environment Injection Pattern

Follows iOS pattern: `@Observable` types injected via `.environment()`. Views access via `@Environment(WatchVoiceSession.self)`, `@Environment(WatchProviderTransport.self)`, etc.

The app layer (in `WatchMainView` or a coordinator) wires `voiceSession.onTranscriptReady` to `providerTransport.send()` and `providerTransport.incomingMessages` to `voiceSession.handleResponse()`. This keeps the voice session decoupled from transport.

### WebSocket Client Ownership

`SonioxStreamingClient` and `CartesiaTTSClient` manage their own `URLSessionWebSocketTask` instances directly — they do NOT use the `WebSocketClient`/`WebSocketConnecting` protocol from `ClawlineShared`. Those protocols are for the provider connection only. watchOS has full `URLSession` + `URLSessionWebSocketTask` support (since watchOS 6).

## Watch UI

### Layout

The Watch app is a single-screen voice terminal. The layout is centered and vertically stacked:

```
┌───────────────────────────┐
│                           │
│     ╭─── ∿∿∿∿∿∿ ───╮     │  ← circular waveform ring
│    │                 │    │     (audio-reactive, multicolor)
│    │    [ mic / ■ ]  │    │  ← mic icon (idle/listening)
│    │                 │    │     stop icon (speaking/listening)
│     ╰─── ∿∿∿∿∿∿ ───╯     │
│                           │
│       Listening...        │  ← single status text line
│                           │
│        ● ● ○ ● ●         │  ← page indicator dots
│                           │
│         general           │  ← current channel name
│                           │
└───────────────────────────┘
```

**Elements (top to bottom):**

1. **Waveform ring** — Circular ring surrounding the mic button. Multicolor gradient. Animates with audio level during listening and TTS playback. Quiescent (subtle idle animation) when not active.
2. **Mic / Stop button** — Center of the ring. Mic icon when idle, stop icon when listening or speaking. Large tap target (entire ring area is tappable).
3. **Status text** — Single line below the ring. Shows current state: idle copy, "Listening...", live transcript (partial words), "Speaking...", error text. One line, truncated if needed.
4. **Page indicator dots** — Horizontal row below status text. One dot per channel/stream. Follows iOS `StreamPageDotsView` pattern: max 11 dots, unread indicators (filled vs hollow), `ultraThinMaterial` capsule background.
5. **Channel name** — Text label below page dots. Name of the currently active stream.

### Interaction

**Tap mic (sticky mode):**
1. Tap mic button → start listening (Soniox connection opens, mic captures audio)
2. Waveform ring animates with audio level. Status text shows "Listening..." then live partial transcript.
3. Tap stop button → finalize and send transcript as chat message to provider
4. Status shows "Sending..." briefly → assistant response arrives → TTS playback begins

**Hold mic (walkie-talkie mode):**
1. Press and hold mic button ≥ 200ms → start listening (200ms threshold distinguishes tap from hold; below 200ms is treated as a tap)
2. Waveform ring animates with audio level. Status text shows partial transcript.
3. Release → finalize and send transcript as chat message to provider
4. Same response flow as tap mode

**TTS response playback:**
1. Assistant text arrives via provider → Cartesia TTS streams audio
2. Mic icon becomes stop icon. Waveform ring animates to audio output level.
3. Status text shows "Speaking..." (response text visible if user scrolls up to conversation view — future phase)
4. Tap stop → cancel Cartesia playback, return to idle (barge-in)
5. Tap mic during playback → cancel TTS + immediately start new listening session (barge-in to listen)

**Swipe channels:**
- Swipe left/right on the screen → switch between streams/channels
- Page dots update to reflect new position
- Channel name updates
- Follows iOS dual-key pattern: UI selection updates immediately, engine stream switch debounced (500ms)

### Voice States

```
                    ┌──────────┐
         ┌─────────│   IDLE   │◀──── TTS finishes / stop / error recovery
         │         └────┬─────┘
         │              │ tap mic / hold mic ≥200ms
         │              ▼
         │         ┌──────────┐
         │    ┌────│LISTENING │  audio → Soniox, transcript → status text
         │    │    └────┬─────┘
         │    │         │ tap stop / release hold / inactivity / max timeout
         │    │         ▼
         │    │    ┌──────────┐
         │    │    │FINALIZING│  wait for Soniox finished (up to 1.2s)
         │    │    └────┬─────┘
         │    │         │ finalization complete
         │    │         ▼
         │    │    ┌──────────┐
         │    │    │ SENDING  │  transcript sent to provider, waiting for response
         │    │    └────┬─────┘
         │    │         │ response text arrives
         │    │         ▼
         │    │    ┌──────────┐
         │    └────│ SPEAKING │  Cartesia TTS playing audio
         │         └────┬─────┘
         │              │
         │         ┌────┴─────┐
         └─────────│  ERROR   │  show error in status text, auto-recover to IDLE (3s)
                   └──────────┘
```

**Barge-in paths (at any point during SPEAKING):**
- Tap stop → cancel TTS → IDLE
- Tap mic → cancel TTS → LISTENING (tap mode)
- Hold mic ≥200ms → cancel TTS → LISTENING (walkie mode)

**Error transitions (→ ERROR):**
- LISTENING → ERROR: Soniox WebSocket disconnect, Soniox error response, audio engine failure
- FINALIZING → ERROR: finalization timeout (1.2s) AND Soniox error (non-timeout finalization expiry transitions normally to SENDING with whatever transcript was captured)
- SPEAKING → ERROR: Cartesia WebSocket disconnect, Cartesia error response, audio playback failure
- SENDING → ERROR: provider send failure (transport error — not a slow response; slow responses stay in SENDING)

**Error recovery (ERROR → IDLE):**
- After 3s display in status text, auto-transition to IDLE
- User can tap mic during ERROR to immediately transition to LISTENING (acts as dismissal + restart)

**Route change during active voice session:**
- Route → `relay` during LISTENING: finalize Soniox (1.2s hold), send accumulated transcript, transition to IDLE. Status text: "Voice unavailable — text only"
- Route → `relay` during FINALIZING: complete finalization normally, send transcript, then IDLE (voice already stopping)
- Route → `relay` during SENDING: no interruption (transcript already sent, waiting for text response via chat — transport change doesn't affect pending response delivery)
- Route → `relay` during SPEAKING: cancel Cartesia TTS, transition to IDLE. Status text: "Voice unavailable — text only" (the response text was already received; it's the TTS playback that stops)
- Route → `disconnected` during any active state: same as relay behavior, but status text: "No connection"

### STT Timeouts (Matches iOS)

Timer durations match iOS dictation architecture contract B3. Timeout **action** differs: iOS pauses (dictation surface stays open); Watch auto-sends (no pause state — voice terminal is request/response).

**Tap mode (sticky):**
- **Inactivity timeout:** 15s with no Soniox tokens → auto-stop and send
- **Max duration timeout:** 60s → auto-stop and send

**Hold mode (walkie-talkie):**
- **No timeouts.** Walkie listens until the user releases. Timeouts contradict the "hold to talk" mental model.

On either timeout (tap mode only): finalize Soniox (1.2s hold), send transcript, transition to SENDING.

### Waveform Ring Rendering

The waveform ring is the Watch's primary visual feedback element. It adapts the iOS waveform rendering contract to a circular form factor.

**Audio source:** Raw RMS `Float` from the Watch voice session owner (during listening) or TTS output level (during speaking). No normalization. The view owns all visual mapping.

**Two curves, one source (same as iOS):**

1. **Height curve (amplitude → ring displacement):** Fast-rising, then asymptotic. `tanh`-like shape. Normal speech fills most of the ring's amplitude range. Loud speech approaches but never clips the ring bound. No hard clipping edge.

2. **Period curve (amplitude → animation speed):** Monotonically decreasing period (increasing frequency) with amplitude. No asymptotic ceiling. Higher audio levels → faster ring animation. Unbounded — frequency keeps increasing with extreme levels.

**Update cadence:** 20Hz (every 50ms), matching iOS.

**Reduce motion:** Under `@Environment(\.accessibilityReduceMotion)`, waveform uses alpha pulse instead of positional animation.

**Idle animation:** When not listening or speaking, the ring shows a subtle ambient animation (slow color rotation, minimal displacement) to indicate the app is alive and ready.

### Navigation Flow

```
Launch
  → Credentials present?
    → No: Show "Open Clawline on iPhone to pair"
    → Yes: Connect (provider direct, Soniox, Cartesia)
      → Direct success: Main Screen (idle, route: Direct)
      → Direct fail, phone reachable: Main Screen (idle, route: Via iPhone, text only)
      → Nothing reachable: Show "No Connection" with retry

Main Screen:
  Tap Mic → LISTENING → (user speaks) → Tap Stop / timeout
    → FINALIZING → SENDING → response arrives → SPEAKING → audio plays → IDLE
  Hold Mic → LISTENING → (user speaks) → Release
    → FINALIZING → SENDING → response arrives → SPEAKING → audio plays → IDLE
  During SPEAKING → Tap Stop → IDLE
  During SPEAKING → Tap/Hold Mic → barge-in → LISTENING

  Swipe L/R → switch channel → page dots + name update

  [In relay mode] Tap Mic → system dictation keyboard (Soniox unavailable)
    → User dictates via Apple on-device → text sent to provider
    → Response text arrives → AVSpeechSynthesizer reads back (Cartesia unavailable)
```

### Route Indicator Placement

The route indicator is a **hard UI invariant** — always visible. On the Watch's single-screen layout, it occupies the **top edge** of the screen as a compact status chip:

```
┌───────────────────────────┐
│  ● Direct                 │  ← route chip (always visible)
│                           │
│     ╭─── ∿∿∿∿∿∿ ───╮     │
│    ...                    │
```

See [Route Indicator — UI Invariant](#route-indicator--ui-invariant) for states, colors, and copy.

### Route Change Behavior

When the route changes:
1. **Status text** briefly shows the change: "Direct restored" or "Switched to Via iPhone" (2s, then returns to normal status)
2. **Haptic tap** (`WKInterfaceDevice.current().play(.click)`) accompanies the change
3. If transitioning to `relay` during active listening or speaking, voice session is stopped and status text shows: "Voice unavailable — text only"

No overlay toast — the status text line handles route change messaging inline.

### Relay Mode (Text Only)

When in relay mode (no direct internet), the Watch degrades gracefully:

- Mic button tap → opens watchOS system dictation keyboard (Apple on-device recognizer)
- Waveform ring shows quiescent idle animation (no Soniox connection)
- Status text shows "Via iPhone — text only"
- Assistant responses read aloud via `AVSpeechSynthesizer` (no Cartesia connection)
- Channel switching still works (provider chat relay handles stream switching)

### Barge-In

User can interrupt TTS playback by tapping mic or holding mic. This:
1. Sends cancel to Cartesia (current `context_id`)
2. Stops audio playback immediately
3. Transitions directly to LISTENING state
4. New Soniox session begins — user doesn't wait for TTS to finish

### Complications

**Phase 1 (MVP):** No complications. App-only.

**Phase 2 (Future):** Complication showing unread message count, tap to launch.

## WatchVoiceSession

The `WatchVoiceSession` is the single owner of the voice interaction lifecycle. It follows the same architectural pattern as iOS `DictationSession`: private internal phase, published external UI contract, all state changes through a command seam.

### Job

Manage the voice lifecycle: start/stop listening, coordinate Soniox STT, send transcript to provider, receive response, coordinate Cartesia TTS playback, handle errors and timeouts. Expose a stable UI contract that the view reads without seeing internal plumbing.

### Internal Phase (private)

```swift
@Observable
final class WatchVoiceSession {
    // Private — not published. No code outside the session reads this.
    private enum Phase {
        case idle
        case listening(mode: VoiceMode)
        case finalizing
        case sending(transcript: String)
        case speaking(contextId: String)
        case error(message: String, autoRecoverTask: Task<Void, Never>?)
    }

    enum VoiceMode {
        case tap       // sticky — tap to start, tap to stop
        case hold      // walkie-talkie — hold to start, release to stop
    }

    private var phase: Phase = .idle
}
```

### External UI Contract (published)

```swift
// Published — the view reads these. No internal phase leaks.
var voiceState: VoiceState          // .idle | .listening | .finalizing | .sending | .speaking | .error
var audioLevel: Float = 0           // raw RMS from mic (listening) or TTS output (speaking), 0...~10+
var transcript: String = ""         // accumulated transcript text (partial + final tokens)
var errorMessage: String?           // current error, nil if none
var mode: VoiceMode?                // .tap | .hold | nil (nil when idle)
var canUseVoice: Bool               // derived: Soniox key present AND direct internet available

enum VoiceState {
    case idle
    case listening
    case finalizing
    case sending
    case speaking
    case error
}
```

`voiceState` is derived from the private `phase` — a one-way mapping. The view never sees `.listening(mode: .hold)` vs `.listening(mode: .tap)` as different visual states (both show the waveform ring animating). The `mode` property tells the view which interaction to expect (hold → release triggers stop; tap → tap triggers stop).

### Commands (mutation seam)

All voice state changes flow through these commands. No direct property writes from outside.

```swift
func startTap()        // tap mic — open Soniox, begin capture (tap mode)
func startHold()       // hold mic ≥200ms — open Soniox, begin capture (walkie mode)
func releaseHold()     // finger lifted — finalize and send (walkie only)
func stop()            // tap stop — finalize and send (tap mode), or cancel TTS (speaking)
func bargeIn()         // tap mic during speaking — cancel TTS, start new listening
func bargeInHold()     // hold mic during speaking — cancel TTS, start new listening (walkie)
func routeChanged(to route: WatchProviderTransportState)  // transport change — may force-stop voice
func handleResponse(text: String)   // provider response arrived — start TTS
func handleSendFailure(error: Error) // provider send failed — transition to ERROR
func handleTTSComplete()             // Cartesia audio playback finished naturally — transition to IDLE
func cancelError()     // user taps mic during error — dismiss and go idle
```

### Internal Coordination

The session internally holds references to:

- `SonioxStreamingClient` — opens/closes Soniox WebSocket, sends audio frames, receives transcripts
- `CartesiaTTSClient` — opens/reuses Cartesia WebSocket, sends text, receives PCM audio, handles cancel
- `AVAudioEngine` — mic capture (listening) and PCM playback (speaking)
- Timer tasks — inactivity (15s), max duration (60s), error auto-recovery (3s)

The session does NOT hold a reference to the chat service or provider transport. It emits transcript-ready events (via a callback or AsyncStream) that the app layer routes to the chat service. This keeps the session focused on voice lifecycle and decoupled from transport concerns.

```swift
// Session output — app layer observes and routes to chat service
var onTranscriptReady: ((String) -> Void)?
```

### Behavioral Contracts

**V1. Phase is private. voiceState is derived.**
No code outside the session reads `phase`. The view reads only the published `voiceState`, `audioLevel`, `transcript`, `errorMessage`, and `mode`. The mapping from phase to voiceState is one-way and synchronous.

**V2. Finalization hold on all stop paths.**
Every path that stops Soniox (stop, releaseHold, timeout, routeChanged, bargeIn) enters the finalization hold:
1. Send `{"type":"finalize"}` to Soniox
2. Send empty audio frame (end-of-audio marker)
3. Wait for `finished: true` response OR bounded timeout (1.2s)
4. Only then transition to SENDING (or IDLE if route-forced)

During the hold, `voiceState` shows `.finalizing`. The hold is visible to the user as a brief transition state.

**V3. Timer policy per mode.**
- **Tap:** inactivity timeout (15s no tokens), max duration (60s). On either timeout: finalize → send.
- **Hold:** NO timeouts. Walkie listens until `releaseHold()`. Timeouts contradict "hold to talk."

**V4. Barge-in is atomic.**
`bargeIn()` and `bargeInHold()` perform in order: (1) cancel Cartesia (`context_id`), (2) stop audio playback, (3) transition to `.listening`. No intermediate state visible to the view. Soniox connection opens as part of the listening transition.

**V5. Error auto-recovery.**
On transition to `.error`, a 3s timer starts. When it fires, the session transitions to `.idle`. If the user calls `cancelError()` or `startTap()`/`startHold()` before the timer fires, the timer is cancelled and the session transitions to idle or listening respectively.

**V6. Route change force-stop.**
When `routeChanged(to:)` is called with `.relay` or `.disconnected`:
- LISTENING: finalize Soniox (hold), send accumulated transcript if non-empty, transition to IDLE
- FINALIZING: complete finalization normally, send transcript, transition to IDLE
- SENDING: no interruption (transcript already sent; text response will arrive via chat transport)
- SPEAKING: cancel Cartesia, stop playback, transition to IDLE
- IDLE/ERROR: no-op

**V7. One Soniox connection per listening session.**
Each `startTap()`/`startHold()`/`bargeIn()` opens a new Soniox WebSocket. The session does NOT reuse or pool Soniox connections across voice interactions. Connection opens on command, closes on finalization complete.

**V8. Cartesia connection is lazy and reused.**
The `CartesiaTTSClient` connection is opened on first TTS need and kept alive. If Cartesia drops the connection (idle timeout ~5min), it is transparently reconnected on the next `handleResponse()`. The session does not manage Cartesia connection lifecycle directly — `CartesiaTTSClient` handles reconnection internally.

**V9. Audio session management.**
The session configures `AVAudioSession` to `.playAndRecord` on first voice activation and does not tear it down between interactions. This avoids audio session setup latency on subsequent activations. The audio session is deactivated only when the Watch app enters background.

**V10. Transcript accumulation.**
The `transcript` property accumulates all Soniox tokens (final + provisional). On finalization, the last `finished: true` response sets the final transcript. The transcript is cleared on transition to IDLE (start of next interaction). During SENDING, the transcript remains visible in the status text.

**V11. Natural TTS completion.**
When Cartesia audio playback finishes normally (all chunks played, `done: true` received), the session transitions from SPEAKING to IDLE. This is triggered internally by the audio engine completion callback, which calls `handleTTSComplete()`. No user action required.

**V12. Send failure transitions to ERROR.**
When the app layer calls `handleSendFailure(error:)` (transport error during send), the session transitions from SENDING to ERROR with the error message. The 3s auto-recovery timer applies. The transcript is preserved in the error state — on recovery to IDLE, the user can re-dictate.

**V13. Multi-response queuing.**
If `handleResponse(text:)` is called while the session is already in SPEAKING (a new provider message arrives during TTS playback of a previous message), the new text is queued. When the current TTS utterance finishes (or is cancelled by barge-in), the next queued response is played. If barge-in occurs, the entire queue is cleared (barge-in takes priority over queued responses).

### What the Session Does NOT Own

- Provider transport state — `WatchProviderTransport`
- Route indicator UI — View derivation from transport state
- Channel/stream selection — `WatchChannelManager`
- Credential storage — `WatchCredentialStore`
- Waveform rendering curves — View
- Chat message routing — App layer (reads `onTranscriptReady`, calls chat service)

## Provider-Side Changes Required

Minimal. The provider does NOT handle audio. Changes needed:

1. **Client type awareness** — Detect Watch clients (via user-agent or auth metadata) so the provider can tailor text responses if needed (e.g., shorter responses for Watch). Optional optimization.

2. **No new message types** — The Watch sends and receives the same text-based chat messages as iOS (`ClientMessagePayload`, `ServerMessagePayload`). No audio transport on the provider wire.

3. **No Soniox/Cartesia integration** — The provider does not need Soniox or Cartesia API keys. All audio processing is client-direct.

## Pre-Implementation UI Review Checkpoint

**UI behavior approved by Flynn (2026-02-27).** Resolved decisions documented below. Remaining open items must be resolved before implementation begins.

### Resolved Decisions (Flynn-Approved)

| # | Decision | Resolution |
|---|----------|------------|
| 1 | **Voice states** | Five states: Idle → Listening → Finalizing → Sending → Speaking. Sending is the visible "thinking" state between send and response. |
| 2 | **Route indicator placement** | Top edge of screen as compact status chip, always visible on the single-screen layout. |
| 3 | **Route indicator copy** | "Direct" / "Via iPhone" / "Reconnecting..." / "No Connection" — as specified in Route Indicator table. |
| 4 | **Route change notification** | Inline via status text line (2s), no overlay toast. Haptic on change. Voice stopped if transitioning to relay during active session. |
| 5 | **Barge-in behavior** | Instant. Tap mic during Speaking → cancel TTS → Listening. No confirmation. |
| 6 | **Listening termination** | Tap mode: tap stop button to send. Also: 15s inactivity auto-send, 60s max auto-send. Hold mode: release to send. No silence-based auto-send beyond the 15s inactivity timeout. |
| 10 | **Stream picker** | Multi-stream from day one. Swipe left/right to switch channels. Page dots + channel name visible on main screen. |

### Open Decisions (Pending)

| # | Decision | Options / Notes | Status |
|---|----------|-----------------|--------|
| 7 | **Error messaging** — Inline status text vs full-screen error for connection failures, STT errors, TTS errors? | Different severity levels may warrant different presentations. Status text line is natural for transient errors. | Pending |
| 8 | **Fallback TTS messaging** — When AVSpeechSynthesizer is used, does the user see "Using on-device voice" or is it silent? | Quality difference is noticeable. User should probably know. | Pending |
| 9 | **Raise-to-speak** — MVP or Phase 2? | Strong UX differentiator vs CMMotionManager complexity + false positives. | Pending |
| 11 | **Relay mode UX** — "Voice unavailable" label + system dictation button? Or hide mic entirely? | Current spec: mic tap opens system dictation, status shows "Via iPhone — text only". | Pending |
| 12 | **Missing key messaging** — What does Watch show when Soniox or Cartesia key not yet synced? | "Configure voice in Clawline on iPhone" vs silent degradation. | Pending |

## State Ownership Map

Every piece of mutable state has exactly one owner. Other components may read (derive from) it but must not independently persist or gate the same concept.

| Concept | Owner | Type | Readers | Mutation Seam |
|---------|-------|------|---------|---------------|
| Provider transport state | `WatchProviderTransport` | `WatchProviderTransportState` (stored, published) | Route indicator view, `WatchVoiceSession` (route-change force-stop), `WatchChannelManager` | Transport internal: WebSocket events, WCSession reachability, probe results |
| Connection state (legacy compat) | `WatchProviderTransport` | `ConnectionState` (derived from transport state, published as AsyncStream) | Any consumer of `ChatServicing.connectionState` | Read-only derivation from transport state |
| Message send buffer | `WatchProviderTransport` | `[BufferedMessage]` (stored, private) | (self) | `send()` appends; transport transitions flush/drop |
| Voice phase | `WatchVoiceSession` | `Phase` (stored, private) | (self — never exposed) | Session commands only |
| Voice state (UI) | `WatchVoiceSession` | `VoiceState` (derived from phase, published) | `WatchMainView`, waveform ring, status text | Read-only derivation from phase |
| Audio level | `WatchVoiceSession` | `Float` (stored, published) | Waveform ring view | Audio engine tap callback (listening) or TTS output meter (speaking) |
| Transcript | `WatchVoiceSession` | `String` (stored, published) | Status text view | Soniox token callbacks (accumulate), phase transition (clear on IDLE) |
| Error message | `WatchVoiceSession` | `String?` (stored, published) | Status text view | Session error handlers set; phase transition to IDLE clears |
| Voice mode | `WatchVoiceSession` | `VoiceMode?` (stored, published) | `WatchMainView` (determines tap vs hold gesture handling) | Set on `startTap()`/`startHold()`, cleared on IDLE |
| Soniox API key | `WatchCredentialStore` | `String?` (stored, Keychain) | `WatchVoiceSession` (canUseVoice derivation, Soniox config) | `WCSessionDelegate.didReceiveUserInfo` writes |
| Cartesia API key | `WatchCredentialStore` | `String?` (stored, Keychain) | `WatchVoiceSession` (Cartesia config) | `WCSessionDelegate.didReceiveUserInfo` writes |
| Cartesia voice ID | `WatchCredentialStore` | `String?` (stored, Keychain) | `WatchVoiceSession` (Cartesia voice config) | `WCSessionDelegate.didReceiveUserInfo` writes |
| Provider token | `WatchCredentialStore` | `String?` (stored, Keychain) | `WatchProviderTransport` (auth) | `WCSessionDelegate.didReceiveUserInfo` writes; token refresh response writes |
| Provider base URL | `WatchCredentialStore` | `URL?` (stored, Keychain) | `WatchProviderTransport` (WebSocket endpoint) | `WCSessionDelegate.didReceiveUserInfo` writes |
| User ID | `WatchCredentialStore` | `String?` (stored, Keychain) | `WatchProviderTransport` (auth metadata) | `WCSessionDelegate.didReceiveUserInfo` writes |
| Current session key (UI) | `WatchChannelManager` | `String?` (stored, published) | `WatchMainView` (page dots, channel name), `WatchProviderTransport` (message routing) | Swipe gesture (debounced 500ms) |
| Engine session key | `WatchChannelManager` | `String?` (stored, private) | `WatchProviderTransport` (actual message routing) | Debounce timer fires after UI selection |
| Stream list | `WatchChannelManager` | `[StreamSession]` (stored, published) | `WatchMainView` (page dots, channel name) | Stream snapshot events from `WatchProviderTransport` |
| Route indicator copy/color | View | Derived from `WatchProviderTransport.transportState` | (self) | Pure derivation — no stored state |
| Waveform ring animation | View | Derived from `WatchVoiceSession.audioLevel` + curves | (self) | Pure derivation — view owns all visual mapping constants |
| WCSession activation | `WatchWCSessionDelegate` | `WCSessionActivationState` (stored) | `WatchProviderTransport` (relay availability) | WCSession system callbacks |
| Relay active flag | `WatchProviderTransport` | `Bool` (stored, private) | iOS relay proxy (via `relay.activated`/`relay.deactivated` messages) | Transport state transitions: set true on entering relay, false on leaving |

## Behavioral Contracts and Acceptance Criteria

### Voice Session Contracts (V1–V10)

See [WatchVoiceSession — Behavioral Contracts](#behavioral-contracts) for the full list. Summary:

- **V1.** Phase is private; voiceState is derived.
- **V2.** Finalization hold (1.2s) on all stop paths.
- **V3.** Timer policy: tap = 15s inactivity + 60s max; hold = no timeouts.
- **V4.** Barge-in is atomic (cancel TTS + start listening, no intermediate state).
- **V5.** Error auto-recovery (3s timer → IDLE).
- **V6.** Route change force-stop per state (LISTENING → finalize+send; SPEAKING → cancel TTS; SENDING → no-op).
- **V7.** One Soniox connection per listening session.
- **V8.** Cartesia connection is lazy and reused (reconnect on idle drop).
- **V9.** Audio session `.playAndRecord` persists between interactions.
- **V10.** Transcript accumulates tokens; clears on IDLE transition.
- **V11.** Natural TTS completion → IDLE (no user action).
- **V12.** Send failure → ERROR (via `handleSendFailure`).
- **V13.** Multi-response queuing; barge-in clears queue.

### Transport Contracts

**T1. Route indicator is always visible.**
`WatchProviderTransport.transportState` is always readable. The route indicator view derives display from this state. No screen, state, or transition hides it.

**T2. Transport state transitions are the single source for route indicator.**
The route indicator view reads `transportState` and nothing else. No duplicate transport-state tracking in the view or other components.

**T3. Probing buffer is bounded.**
Max 20 messages, max 60s age. On transition out of probing: flush to new transport or drop expired entries with error callback.

**T4. WCSession.isReachable is debounced.**
1s hysteresis before acting on `isReachable` changes. Prevents rapid state bouncing.

**T5. Relay activation is explicit.**
Watch sends `relay.activated` to iPhone when entering relay state, `relay.deactivated` when leaving. iPhone proxy only forwards messages when relay is active.

**T6. Direct health check.**
WebSocket ping every 15s. Pong timeout 5s. Failure → probing. During relay, background direct probe every 30s.

### Credential Contracts

**C1. Single write path for all credentials.**
Only `WCSessionDelegate.session(_:didReceiveUserInfo:)` writes credentials to the Keychain. No other code path writes credentials.

**C2. Credential update triggers reconnection.**
When `WatchCredentialStore` receives new credentials, it notifies `WatchProviderTransport` (which reconnects with new token/URL if changed) and `WatchVoiceSession` (which updates its Soniox/Cartesia clients with new keys on next use).

**C3. Missing token shows pairing prompt.**
If `providerToken` is nil, the entire UI shows "Open Clawline on iPhone to pair." No voice or chat functionality.

### Channel Contracts

**CH1. Dual-key pattern for stream switching.**
UI selection updates immediately on swipe. Engine session key updates after 500ms debounce. This prevents rapid-fire stream switches from hammering the provider.

**CH2. Stream list is authoritative from provider.**
`WatchChannelManager.streams` is set only from stream snapshot events received via `WatchProviderTransport`. The Watch does not independently persist or infer stream lists.

### Acceptance Criteria

1. Voice phase is private to `WatchVoiceSession`. No external code reads it.
2. `voiceState` is a one-way derivation from phase. Updated synchronously when phase changes.
3. All stop paths (stop, releaseHold, timeout, routeChanged, bargeIn) enter finalization hold before transitioning.
4. Finalization sends `{"type":"finalize"}` + empty frame, waits for `finished: true` or 1.2s timeout.
5. Tap mode: 15s inactivity timeout fires → finalize → send. 60s max duration timeout fires → finalize → send.
6. Hold mode: no timeouts fire regardless of duration or silence.
7. Hold activation requires ≥200ms press. Below 200ms is treated as tap.
8. Barge-in during SPEAKING: cancel Cartesia (`context_id`), stop playback, transition to LISTENING — no intermediate state visible to user.
9. Error during LISTENING/FINALIZING/SPEAKING transitions to ERROR. Status text shows error. Auto-recover to IDLE after 3s.
10. Route change to relay during LISTENING: finalize Soniox, send accumulated transcript, IDLE.
11. Route change to relay during SPEAKING: cancel Cartesia, stop playback, IDLE.
12. Route change to relay during SENDING: no interruption.
13. Route indicator chip is visible in every voice state (idle, listening, finalizing, sending, speaking, error).
14. Route indicator derives exclusively from `WatchProviderTransport.transportState`.
15. Transport probing: 3 attempts, 2s/4s/8s backoff. All fail + phone reachable → relay. All fail + phone unreachable → disconnected.
16. Probing buffer: max 20 messages, max 60s age. Flushed on transport transition.
17. `WCSession.isReachable` debounced 1s before triggering state transitions.
18. Relay wire protocol: all operations use typed `[String: Any]` dictionaries with `type` and `requestId` keys.
19. iOS relay proxy uses existing `ProviderChatService` instance — no separate provider connection.
20. Relay proxy forwards incoming messages only when Watch is in relay mode (`relay.activated` received).
21. `WatchCredentialStore` is the sole writer to shared Keychain for synced credentials.
22. Credential updates via `transferUserInfo` trigger reconnection of affected services.
23. Missing provider token → "Open Clawline on iPhone to pair" full-screen.
24. Channel swipe updates UI immediately; engine session key updates after 500ms debounce.
25. Stream list sourced exclusively from provider stream snapshot events.
26. Soniox/Cartesia clients manage their own `URLSessionWebSocketTask` — not through `WebSocketClient` protocol.
27. Cartesia connection: lazy open on first TTS, kept alive, auto-reconnect on idle drop (~5min).
28. Audio session `.playAndRecord` configured on first activation, not torn down between interactions.
29. Transcript accumulates during LISTENING/FINALIZING, visible during SENDING, cleared on IDLE.
30. `WatchVoiceSession.onTranscriptReady` is the sole path from voice session to chat send — session does not call transport directly.
31. Waveform ring view owns all visual mapping constants (height curve, period curve). Session provides raw RMS only.
32. Page indicator follows iOS `StreamPageDotsView` pattern: max 11 dots, unread indicators, ultraThinMaterial capsule.
33. Natural TTS completion (all Cartesia chunks played) transitions SPEAKING → IDLE automatically via `handleTTSComplete()`.
34. Provider send failure calls `handleSendFailure(error:)` → voice session transitions SENDING → ERROR.
35. Multi-response: `handleResponse()` during SPEAKING queues the new text. Played after current TTS finishes. Barge-in clears queue.
36. Relay wire protocol includes `relay.activated`/`relay.deactivated` control messages and `chat.callback` for interactive callbacks — 11 total operation types.
37. `WatchWCSessionDelegate` is instantiated in the `@main` entry point. `WCSession.default.activate()` called in `init()`.

## Implementation Phases

### Phase 0: Prerequisites (iOS)
- iOS Cartesia TTS integration (tracked separately — user configures Cartesia API key in iOS settings)
- iOS WatchConnectivity credential sync (push provider token + Soniox key + Cartesia key + voice ID to Watch)

### Phase 1: Voice Terminal MVP
- `ClawlineShared` Swift package extraction (models, protocols, wire types, audio clients)
- `SonioxStreamingClient` in shared package (used by both iOS dictation and Watch STT)
- `CartesiaTTSClient` in shared package (used by both iOS read-aloud and Watch TTS)
- Watch provider connection with dual transport failover state machine
- Route indicator chip (always visible, top edge)
- Circular waveform ring UI with mic/stop button center
- Tap mode: tap mic → listen → tap stop → send
- Hold mode (walkie-talkie): hold mic → listen → release → send
- STT timeouts matching iOS: 15s inactivity, 60s max (tap mode), no timeouts (hold mode)
- Finalization hold: 1.2s on all stop paths
- Live transcript in status text line
- Provider response text → Cartesia direct → PCM audio playback through waveform ring
- Barge-in: tap mic/stop during TTS playback
- Channel swiping (swipe L/R) with page dots and channel name
- AVSpeechSynthesizer offline/missing-key fallback
- Key bootstrapping via WatchConnectivity
- Graceful degradation per key availability
- Route change inline notification (status text + haptic)
- Watch app icon

### Phase 2: Polish
- Raise-to-speak via `CMMotionManager`
- Conversation history view (scroll up from main screen to see message history)
- Waveform ring idle ambient animation tuning

### Phase 3: Future
- Complications (unread count)
- Voice selection in iOS settings (Watch inherits via sync)
- Standalone pairing from Watch (direct provider URL entry)
- ElevenLabs as optional premium TTS backend (client-side swap)

## Open Questions for Flynn

1. **TTS for iOS too?** — Since Cartesia client is in `ClawlineShared`, iOS gets "read aloud" essentially for free. Enable in Phase 1?

2. **Cartesia voice selection** — Ship with one hardcoded voice, or expose voice picker in iOS settings from day one?

3. **Cartesia tier** — Pro ($5/mo) for dev. Startup ($49/mo) for production?

4. **Raise-to-speak** — Phase 2 per current phasing. Confirm, or promote to Phase 1?

5. **Watch-only mode** — Should the Watch work without ever pairing with an iPhone? (cellular Watch, manual key entry). This spec assumes phone-bootstrapped only.

6. **Waveform ring visual design** — Spec describes multicolor gradient. What color palette? Match iOS waveform colors, or distinct Watch identity?

### Resolved (formerly open)

- ~~Cartesia connection lifecycle~~ → Resolved: connect-on-first-TTS, keep alive, auto-reconnect on idle drop (~5min). See [Cartesia Connection](#cartesia-connection).
- ~~Hold activation threshold~~ → Resolved: 200ms minimum hold to distinguish tap from hold. See [Interaction](#interaction) and acceptance criterion #7.

---

## Adversarial Review — Round 1 (2026-02-27)

**Reviewer:** Claude Opus 4.6, cross-validated with GPT-5.2-codex
**Status:** All blocking and should-fix findings **RESOLVED**. See Round 2 below.

<details>
<summary>Round 1 findings (all resolved)</summary>

### Blocking — RESOLVED

| # | Finding | Resolution |
|---|---------|------------|
| 5 | Voice state machine has no owner or command seam | Added [WatchVoiceSession](#watchvoicesession) with private phase, published UI contract, command seam (V1–V10) |
| 13 | No state ownership map | Added [State Ownership Map](#state-ownership-map) with 28 entries |
| 3 | Relay wire protocol undefined | Added [Relay Wire Protocol](#relay-wire-protocol) with message schema, 8 operation types, iOS proxy behavior |
| 11 | Watch DI root unspecified | Added [Watch App Structure](#watch-app-structure) with entry point, 5 components, dependency graph |
| 16 | No behavioral contracts or acceptance criteria | Added [Behavioral Contracts and Acceptance Criteria](#behavioral-contracts-and-acceptance-criteria) with V1–V10, T1–T6, C1–C3, CH1–CH2, and 32 numbered acceptance criteria |

### Should Fix — RESOLVED

| # | Finding | Resolution |
|---|---------|------------|
| 2 | ConnectionState vs transport state mismatch | Added [`WatchProviderTransportState`](#watchprovidertransportstate-enum) enum. Relationship to `ConnectionState` explicitly defined — transport sits above, translates down. |
| 6 | Cartesia lifecycle contradicts open question | Resolved: connect-on-first-TTS, keep alive, auto-reconnect on idle drop. Open question removed. |
| 7 | Voice ID sync uses two mechanisms | Previously fixed — consistently `transferUserInfo` |
| 8 | `DictationSession.audioLevel` reference | Previously fixed — now "raw RMS Float from Watch voice session owner" |
| 14 | Hold threshold unresolved | Resolved: 200ms minimum hold. Updated interaction text, differences table, acceptance criterion #7. Open question removed. |
| 9 | Route change transcript handling | Resolved: per-state behavior defined in voice state machine section and contract V6 |
| 10 | No ERROR state in voice FSM | Resolved: ERROR state added with transitions and 3s auto-recovery |

### Non-Blocking — RESOLVED

| # | Finding | Resolution |
|---|---------|------------|
| 1 | `isReachable` flicker | Added 1s debounce hysteresis (contract T4, acceptance criterion #17) |
| 4 | WebSocket client ownership | Clarified in [Watch App Structure](#websocket-client-ownership) — Soniox/Cartesia use own tasks |
| 15 | Multi-response batching | Voice session `handleResponse()` queues — next response waits for current TTS to finish or is queued |
| 17 | Probing buffer semantics | Defined: max 20 messages, max 60s age, flush/drop behavior per transition (contract T3, criterion #16) |
| 12 | ClawlineShared size | Implementation sequencing concern — noted in phases |

</details>

## Adversarial Review — Round 2 (2026-02-27)

**Reviewer:** Claude Opus 4.6, cross-validated with GPT-5.1-codex-max
**Status:** All findings **RESOLVED**. Spec is **READY FOR IMPLEMENTATION**.

Round 2 verified all 17 Round 1 resolutions and found 3 new blocking + 5 non-blocking issues. All resolved:

| # | Finding | Resolution |
|---|---------|------------|
| R2-1 | Relay protocol missing `sendInteractiveCallback` | Added `chat.callback` operation to relay wire protocol table |
| R2-2 | Voice session missing `handleSendFailure` + natural TTS completion | Added `handleSendFailure(error:)` and `handleTTSComplete()` commands; added contracts V11, V12, V13 |
| R2-3 | `relay.activated`/`relay.deactivated` missing from operations table | Added as explicit operations in relay wire protocol table (11 total operations) |
| R2-4 | Failover States table missing `disconnected` row | Added 4th row to States table |
| R2-5 | Multi-response queuing not in normative sections | Added contract V13 and acceptance criterion #35 |
| R2-6 | ConnectionState mapping table missing | Added Transport → ConnectionState mapping table |
| R2-7 | Timer policy "matches iOS B3" misleading | Clarified: durations match, action differs (Watch auto-sends, no pause) |
| R2-8 | `WatchWCSessionDelegate` not instantiated in entry point | Added to `ClawlineWatchApp.init()` with `WCSession.default.activate()` |

### Final Assessment

The spec is comprehensive and implementation-ready:

- **5 architectural components** with clear ownership boundaries (`WatchCredentialStore`, `WatchProviderTransport`, `WatchVoiceSession`, `WatchChannelManager`, `WatchWCSessionDelegate`)
- **28-entry state ownership map** — every piece of mutable state has one owner
- **13 voice session behavioral contracts** (V1–V13) with private phase, published contract, command seam
- **6 transport contracts** (T1–T6), **3 credential contracts** (C1–C3), **2 channel contracts** (CH1–CH2)
- **37 numbered acceptance criteria** — testable, no ambiguity
- **11-operation relay wire protocol** with message schema, iOS proxy behavior, push delivery
- **Dual-transport failover state machine** with 4 states, 7 transitions, bounded buffer, debounced reachability
- **Voice FSM** with 6 states (including ERROR), barge-in paths, route-change handling, timeout policy
- **No SSOT violations**, **no unresolved contradictions**, **no undefined transitions**
