Date: 2026-03-06
Owner: Clawline iOS client
Status: Ready for implementation handoff

# URLSession Isolation

## Goal

Restore strict transport isolation in the Clawline iOS app while keeping one shared provider TLS trust policy.

The bug this spec addresses:
- Commit `8628e70b9` fixed large-image TLS failures by injecting the WebSocket connector's `URLSession` into `UploadService`.
- That fix coupled HTTP upload/download traffic to the WebSocket transport session.
- Result: one `URLSession` and one delegate boundary now serve multiple transport roles, so HTTP activity can interfere with the WebSocket lifecycle.

This spec separates provider-facing transports so each owns its own `URLSession`, while all of them evaluate the same TLS trust policy.

## Non-Goals

- No TLS policy redesign. `ProviderTLSSettingsStore` remains the source of truth for trust settings.
- No protocol changes for `/ws`, `/upload`, or `/download/{assetId}`.
- No changes to unrelated networking such as external link previews or arbitrary web content fetches.
- No change to authentication, message replay, or attachment payload rules.
- No attempt to retroactively change trust on an already-established TLS connection mid-flight; policy changes apply by rotating sessions and reconnecting/retrying through normal transport lifecycles.

## Baseline

Current relevant state in `ios/Clawline/Clawline`:
- `URLSessionWebSocketConnector` owns a TLS-aware `URLSession` for the provider chat WebSocket.
- `UploadService` performs both `POST /upload` and `GET /download/{assetId}`.
- Commit `8628e70b9` exposed `connector.tlsAwareURLSession` and injected that same session into `UploadService`.
- `ProviderTLSSettingsStore.policy` is already read through a closure at TLS challenge time.

This shape is wrong even if the current delegate only handles TLS challenges: transport ownership is now shared, future delegate behavior cannot stay transport-local, and session lifecycle for WebSocket and HTTP is no longer independent.

## Provider Transport Inventory

This spec covers the provider-facing transports in the main app graph:
1. Chat WebSocket transport: `URLSessionWebSocketConnector`
2. HTTP upload transport: `UploadService`
3. Provider asset download transport: a dedicated `DownloadService` or `AssetDownloadService` responsible for `GET /download/{assetId}`

External fetchers such as link preview metadata/image loading are out of scope because they do not use the provider TLS policy.

## Canonical Invariants

### 1. TLS Policy SSOT

- `ProviderTLSSettingsStore` is the only source of truth for provider trust policy.
- All provider-facing sessions covered by this spec must evaluate the same effective `ProviderTLSPolicy`.
- No transport may hardcode or cache a divergent trust decision outside the shared policy path.

### 2. Session Instance Isolation

- Each transport owner must own its own `URLSession` instance.
- No provider `URLSession` instance may be shared between WebSocket, upload, and asset-download transports.
- `URLSession.shared` must not be used for provider upload/download work.
- A transport owner may replace its own session over time, but another owner must never borrow that session.

### 3. Delegate Isolation

- Each transport owner must use a delegate object that belongs only to that owner's session.
- The chat WebSocket session must have a WebSocket-owned delegate boundary.
- Upload and asset-download sessions must use TLS-only delegate handling; they must not share a delegate instance with the WebSocket transport.
- No delegate object may observe callbacks for more than one transport owner.

### 4. Lifecycle Isolation

- Session creation, invalidation, and teardown are the responsibility of the owning transport only.
- Rotating or invalidating the upload session must not directly cancel, reconfigure, or otherwise perturb the WebSocket session.
- Rotating or invalidating the asset-download session must not directly affect the upload or WebSocket sessions.
- The app composition root may share a factory dependency, but not a session instance.

### 5. Runtime TLS Policy Propagation

- When provider TLS policy changes at runtime, all covered transport owners must stop using stale sessions.
- New transport work started after the policy change must run on a session created from the new policy generation.
- Because existing TLS handshakes cannot be mutated in place:
  - active WebSocket connections must reconnect through the normal connection lifecycle so the next handshake uses the new policy
  - in-flight HTTP upload/download tasks may finish or fail under the old connection, but any subsequent task must use a rotated session

## Target End State

### 1. Shared TLS Session Factory

Introduce a shared provider TLS session factory. This is a shared factory object, not a shared `URLSession`.

Required responsibilities:
- Read provider TLS policy from one shared source (`ProviderTLSSettingsStore`, directly or via injected provider closure).
- Build fresh `URLSessionConfiguration` values with common provider defaults.
- Create a fresh `URLSession` per caller.
- Attach the correct delegate boundary for the requested transport role.
- Surface TLS policy change events or generation changes so transport owners know when to rotate their sessions.

Required non-responsibilities:
- The factory must not cache and hand out a singleton `URLSession`.
- The factory must not own WebSocket connection state, upload state, or download state.
- The factory must not become a shared transport manager.

### 2. WebSocket Session Ownership

`URLSessionWebSocketConnector` must own its own session created by the shared TLS session factory.

Requirements:
- Remove the API that exposes the connector's session for reuse by other services.
- The connector's session is used only to create and manage provider chat WebSocket tasks.
- The connector retains sole ownership of its delegate and session lifecycle.
- On TLS policy change, the connector must rotate its session and force the provider connection to reconnect through the existing connection lifecycle.

### 3. Upload Session Ownership

`UploadService` must own its own session created by the shared TLS session factory.

Requirements:
- `UploadService` must use a session dedicated to `POST /upload`.
- That session must use TLS-only delegate handling.
- `UploadService` must not accept a `URLSession` borrowed from the WebSocket connector.
- On TLS policy change, `UploadService` must invalidate its stale session and lazily recreate or eagerly replace it before the next upload starts.

### 4. Asset Download Session Ownership

Provider asset download must move behind its own service boundary with its own session created by the shared TLS session factory.

Requirements:
- Extract `GET /download/{assetId}` out of the upload transport owner.
- Introduce a dedicated asset-download owner (`DownloadService` or `AssetDownloadService`) so session ownership is explicit in the type graph.
- That service must use its own dedicated session and TLS-only delegate handling.
- Chat/image asset fetch code must depend on this download owner instead of reusing the upload session.
- On TLS policy change, this service must invalidate its stale session and recreate it before the next asset fetch.

## Factory Contract

The implementation may use dedicated `makeWebSocketSession` / `makeUploadSession` / `makeDownloadSession` helpers or a single role-based API, but the following contract is mandatory:

1. Every factory call returns a fresh `URLSession`.
2. Every produced session applies the same current `ProviderTLSPolicy`.
3. WebSocket sessions and HTTP sessions do not share delegate instances.
4. Per-transport timeouts/configuration remain transport-specific:
   - WebSocket keeps the existing connect/resource timeout behavior.
   - Upload and download may use their own HTTP-appropriate timeouts.
5. The factory exposes a stable way for owners to detect TLS policy changes.

One acceptable shape is:
- a policy provider closure used by challenge delegates for per-handshake evaluation
- plus a policy-generation or notification signal used by transport owners to rotate stale sessions

Both parts are required. Per-challenge policy lookup alone is not sufficient, because keep-alive/reused connections may otherwise continue using a pre-change TLS session indefinitely.

## Runtime TLS Policy Change Contract

Changing either of these settings counts as a TLS policy change:
- `trustSelfSignedCertificates`
- `pinnedLeafCertificateSHA256`

Required behavior:
1. `ProviderTLSSettingsStore` must emit a policy-change signal whenever the effective policy changes.
2. The shared TLS session factory must make that signal available to transport owners, directly or indirectly.
3. Each transport owner must treat that signal as invalidating its current session.
4. After invalidation:
   - WebSocket transport reconnects using a newly-created session.
   - Upload transport must not start another upload on the stale session.
   - Asset-download transport must not start another fetch on the stale session.

Clarifications:
- No transport is required to mutate an already-established TLS connection in place.
- No transport is required to transparently retry failed in-flight work unless existing behavior already does so.
- The invariant is forward-looking: once policy changes, all subsequent handshakes and new tasks use fresh sessions built from the new policy.

## Composition Root Changes

In `ClawlineApp` and `Clawline_SpatialApp`:
- Create one shared TLS session factory dependency.
- Inject that factory into the WebSocket connector.
- Inject that factory into `UploadService`.
- Inject that factory into the new asset-download service.
- Do not pass raw `URLSession` instances across service boundaries.

## Required API/Ownership Changes

1. Remove connector session sharing
- Delete the public/internal escape hatch that exposes the connector's `URLSession` for reuse.

2. Make asset download a first-class owner
- `UploadService` must no longer be the owner of both upload and download transport sessions.
- The type graph must make upload ownership and asset-download ownership distinct.

3. Preserve TLS behavior parity
- Existing self-signed trust and pinned-leaf behavior must remain identical across all three transport owners.

4. Invalidate sessions on owner teardown
- Each owner must invalidate its own session when the owner is torn down or replaced.

## Acceptance Checks

1. The app graph contains three distinct provider-facing `URLSession` instances for chat WebSocket, upload, and asset download.
2. No code path injects the WebSocket connector's session into `UploadService` or the asset-download owner.
3. WebSocket, upload, and asset-download transports all evaluate the same current `ProviderTLSPolicy`.
4. A TLS policy change causes all three transport owners to rotate away from stale sessions.
5. After a TLS policy change, new uploads, new asset downloads, and the reconnected WebSocket all use sessions created after the change.
6. Upload or asset-download activity no longer shares delegate/session state with the chat WebSocket transport.

## Implementation Handoff

- Keep the scope to provider chat WebSocket, provider upload, and provider asset download.
- Do not fold unrelated networking clients into this change.
- Prefer explicit ownership in the type graph over hidden internal session multiplexing.
- If implementation cannot make runtime TLS policy changes observable without broadening `ProviderTLSSettingsStore`, update this spec first rather than silently weakening the invariant.
