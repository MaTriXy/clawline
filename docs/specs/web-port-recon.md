# Clawline Web Port Recon

Date: 2026-03-30
Author: Codex
Status: Recon spec for feasibility study

## Scope and Method

This document is based on direct source inspection of the Clawline iOS/iPad codebase in `/Users/mike/src/clawline`, with emphasis on the main iOS target plus relevant companion targets when they affect architecture or shared behavior.

Primary source footprint inspected:

- Main iOS app target: 103 Swift source files, approximately 34.6k LOC
- Watch target: 16 Swift source files, approximately 4.3k LOC
- Spatial target: 2 Swift source files
- Main unit tests: 20 files
- UI tests: 2 files

Main target module distribution:

- `Views`: 21 files
- `Services`: 20 files
- `Models`: 20 files
- `DesignSystem`: 16 files
- `Protocols`: 7 files
- `Support`: 6 files
- `ViewModels`: 3 files
- `Settings`: 2 files
- `Networking`: 2 files

The dominant complexity is not pairing or raw transport. It is the chat surface: message orchestration, stream/session management, replay/reconnection semantics, message rendering, scroll restoration, rich attachments, and native view behavior.

This spec focuses on porting the full iOS/iPad app experience into a browser-delivered web app, likely React-based. Watch and spatial targets are covered only where they reveal business rules, shared protocol expectations, or future parity considerations.

## Executive Assessment

Porting Clawline to the web is feasible, but this is not a straightforward view rewrite. The portable parts are the product model, pairing/auth semantics, provider protocol behavior, stream/session lifecycle, attachment semantics, and much of the message presentation grammar. The expensive parts are the chat UI runtime, native rendering surfaces, native storage/security integrations, and platform-specific features such as watch relay, Siri intents, Apple Intelligence salience, and SwiftTerm-backed terminals.

Two conclusions matter most:

1. The server contract is portable enough for a web app.
2. The current client architecture is not portable as-is.

The web effort should therefore treat the existing iOS app as a behavioral reference, not as a source layout to imitate directly. A literal port of the `ChatViewModel` plus UIKit/SwiftUI presentation structure would carry over too much client-side coupling.

Rough sizing:

- MVP web client with pairing, auth, chat, streams, attachments, reconnect/replay, markdown/code/table rendering, settings, and basic link previews: 10-14 engineer-weeks
- Near-parity web client including terminal sessions, interactive HTML attachments, advanced unread/scroll behavior, richer keyboard behavior, and production hardening: 20-30 engineer-weeks

Those estimates assume:

- One experienced engineer with product context
- Existing provider APIs remain stable
- No server-side redesign is required
- Design polish is targeted, not pixel-perfect UIKit mimicry

## Current iOS Architecture Overview

### App Entry and Dependency Wiring

The app boots through `ClawlineApp.swift`, which creates and injects the major runtime services into SwiftUI environment values:

- `AuthManager`
- `SettingsManager`
- `DeviceIdentifier`
- `ProviderConnectionService`
- `ProviderChatService`
- `UploadService`
- `WatchConnectivityService`

`ClawlineCoreRuntimeServicesFactory` builds the transport and upload graph. `RootView` then decides whether the user sees pairing or chat, owns the shared `ToastManager`, creates `SalientHighlightService`, and lazily instantiates `ChatViewModel`.

Observations:

- Service construction is centralized at the app root, which is portable in principle.
- Runtime state ownership is split between environment injection, observable services, `NotificationCenter`, persistent stores, and a singleton `SessionRegistry`.
- The app already has a de facto dependency graph, but the chat domain is still too centralized inside `ChatViewModel`.

### State Management Pattern

The state model is a mix of:

- `@Observable` / `@MainActor` model objects
- SwiftUI environment injection
- `AsyncStream`-based event streams from services
- `NotificationCenter` for some command routing
- `UserDefaults` for lightweight persistence
- Keychain for auth/device identity
- JSON files under `Application Support` for message and stream caches
- Global singleton `SessionRegistry.shared` for stream registry concerns

This is not a single, clean state architecture. Instead, it is a layered but mixed system:

- Transport state lives in `ProviderChatService` and `ConnectionLifecycleCoordinator`
- Product state lives mostly in `ChatViewModel`
- Security/session state lives in `AuthManager`
- Theme/settings state lives in `SettingsManager`
- Durable caches live partly in disk JSON and partly in `UserDefaults`

For the web port, this mixed state ownership is the main architectural hazard. The port should preserve behavior while simplifying ownership boundaries.

### Data Flow

At a high level:

1. Pairing collects user name and server address.
2. `ProviderConnectionService` performs pairing over a WebSocket handshake.
3. `AuthManager` persists the returned token, user ID, and admin status.
4. `ProviderChatService` opens the authenticated chat WebSocket.
5. `ConnectionLifecycleCoordinator` manages connection phases, replay, and recovery.
6. `ChatViewModel` consumes transport events and owns all high-level conversation/stream UI state.
7. `MessagePresentation` plus markdown/rendering helpers transform raw messages into presentable parts.
8. SwiftUI/UIKit views render those parts with specialized native surfaces.

This architecture is portable conceptually. The implementation shape is not.

## Major Modules in the iOS App

### Pairing and Auth

Primary files:

- `ViewModels/PairingViewModel.swift`
- `Views/Pairing/PairingView.swift`
- `Services/AuthManager.swift`
- `Services/KeychainSecureStore.swift`
- `Services/ProviderBaseURLStore.swift`
- `Services/DeviceIdentifier.swift`
- `Services/ProviderConnectionService.swift`

Responsibilities:

- Three-step pairing UX
- URL normalization and provider endpoint derivation
- Pairing request/response handshake
- Keychain-backed auth persistence
- Device identity generation/persistence
- Provider TLS preferences and pinning settings

Portability:

- UX flow is portable
- Pairing handshake logic is portable
- Keychain implementation is not portable
- TLS trust/pinning behavior is only partly portable in browsers

### Core Chat Transport

Primary files:

- `Services/ProviderChatService.swift`
- `ViewModels/ConnectionLifecycleCoordinator.swift`
- `Networking/URLSessionWebSocketConnector.swift`
- `Networking/WebSocketClient.swift`
- `Services/StreamAPIClient.swift`

Responsibilities:

- Authenticated WebSocket session
- Replay cursor handling
- Reconnect/recovery lifecycle
- Message send/ack
- Typing and service events
- Stream snapshot/mutation events
- REST stream CRUD and adoption

Portability:

- Protocol logic is highly portable
- Browser TLS policy differences may require server-side cleanup
- AsyncStream broadcast mechanics need a different state/event implementation on web

### Chat Domain Orchestration

Primary file:

- `ViewModels/ChatViewModel.swift`

Responsibilities:

- Message state by session
- Active stream selection
- Optimistic send pipeline
- Attachment staging
- Read/unread markers
- Stream create/rename/delete/adopt/untrack
- Session provisioning state
- Disk cache management
- Scroll/read coupling with active stream state
- Scene lifecycle handling

Assessment:

- This file is the main product brain.
- It is also a god object.
- The web port should treat it as a behavior reference and split it into several domain stores/controllers.

### Message Presentation and Rendering

Primary files:

- `Models/MessagePresentation.swift`
- `Models/UnifiedMarkdownParser.swift`
- `Views/Chat/UnifiedMarkdownRenderer.swift`
- `Services/SalientHighlightService.swift`
- `Views/Chat/SalientHighlightApplier.swift`

Responsibilities:

- Break messages into presentable parts
- Parse markdown/code blocks/tables
- Detect special cases such as single-link and emoji-only messages
- Render attributed text
- Apply salience highlighting on supported devices

Portability:

- Message decomposition rules are portable
- iOS attributed-string rendering is not
- Apple Intelligence salience is not client-portable
- The browser needs its own markdown/render pipeline

### Chat UI Shell and Native Surfaces

Primary files:

- `Views/Chat/ChatView.swift`
- `Views/Chat/MessageFlowCollectionView.swift`
- `Views/Chat/MessageBubbleUIKitView.swift`
- `DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift`
- `DesignSystem/ChatFlowOrganic/Components/RichTextEditor.swift`
- `Views/Chat/ExpandedMessageSheet.swift`
- `Views/Chat/StreamManagerSheet.swift`
- `Views/Chat/ChannelToast.swift`

Responsibilities:

- Main chat screen composition
- Keyboard-aware layout
- Virtualized message list behavior
- Scroll restoration
- Bubble rendering
- Stream picker/popover
- Toasts, sheets, and overlays
- Attachment source pickers
- Debug overlay

Assessment:

- This is the most expensive area to port.
- The current implementation is deeply native and heavily optimized around UIKit/SwiftUI behavior.

### Rich Attachment Surfaces

Primary files:

- `Views/Chat/LinkPreviewView.swift`
- `Views/Chat/LinkCardUIKitView.swift`
- `Services/LinkCardMetadataFetcher.swift`
- `Views/Chat/InteractiveHTMLBubbleUIKitView.swift`
- `Views/Chat/TerminalBubbleUIKitView.swift`
- `Services/TerminalSessionService.swift`
- `Services/TerminalSessionConnectionPool.swift`
- `Models/TerminalSessionDescriptor.swift`
- `Models/InteractiveHTMLDescriptor.swift`

Responsibilities:

- In-bubble rich web preview
- OG metadata cards
- Embedded interactive HTML experiences
- Embedded terminal sessions

Assessment:

- Link cards port cleanly
- Full web previews need a new security model
- Interactive HTML and terminal sessions are feasible but materially expensive

### Settings and Theming

Primary files:

- `Settings/SettingsManager.swift`
- `Settings/SettingsView.swift`
- `DesignSystem/ChatFlowOrganic/Theme/ChatFlowTheme.swift`
- `Support/ClawlineTypography.swift`
- `Shaders/BackgroundEffect.swift`

Responsibilities:

- Appearance mode
- Font scaling
- Background effects
- TLS trust/self-signed preferences
- Debug overlay toggle

Portability:

- Theme tokens and settings map well to web
- Metal/SwiftUI shader effects need new implementations
- Certificate trust toggles are not browser-equivalent

### Platform Integrations

Primary files:

- `Intents/SiriSendMessageIntent.swift`
- `Services/WatchConnectivityService.swift`
- watch target services and UI
- spatial target app shell

Responsibilities:

- Siri/App Intent sending
- Watch relay
- Watch auth sync
- Watch-originated sends and callbacks
- Companion-device presence

Assessment:

- These are outside core web scope
- They should not block a web client
- They should be tracked as follow-on ecosystem decisions, not v1 requirements

## Feature Inventory

The inventory below focuses on user-facing behavior and the current iOS implementation approach.

| Feature | Current iOS implementation | Portability and notes |
| --- | --- | --- |
| Pairing flow | `PairingViewModel` + `PairingView`; 3-stage UI with auto-normalized provider address and pending/retry state | Portable; implement as route-based onboarding |
| Auth persistence | `AuthManager` with keychain + `UserDefaults` migration | Browser needs token storage redesign; use secure cookies if possible, else local storage with explicit risk acceptance |
| Device identity | `DeviceIdentifier` persisted in keychain/defaults | Portable concept; use generated UUID in local storage/IndexedDB |
| Provider URL and TLS settings | `ProviderBaseURLStore`; self-signed trust and fingerprint pinning | Base URL portable; browser cannot truly mirror self-signed trust or cert pinning |
| Root routing | `RootView` switches pairing vs chat | Portable; use router/guarded routes |
| Chat connection | `ProviderChatService` authenticated WebSocket | Portable |
| Replay/recovery lifecycle | `ConnectionLifecycleCoordinator` phases and backoff | Portable, but must be rebuilt explicitly |
| Message send/ack | `ChatViewModel` optimistic send with placeholder reconciliation | Portable and required |
| Slash commands | `/logout`, `/settings`, connection/debug commands interpreted client-side | Portable; good candidate for command palette abstraction |
| Typing indicators | Provider event handling in `ProviderChatService` and `ChatViewModel` | Portable |
| Stream/session switching | `uiSelectedSessionKey` vs `engineActiveSessionKey` split | Portable concept; preserve to avoid expensive rerender churn |
| Stream CRUD | `StreamAPIClient` + `ChatViewModel` + `StreamManagerSheet` | Portable |
| Adopt/untrack sessions | REST APIs plus `SessionRegistry` integration | Portable; should move to explicit domain store |
| Session provisioning state | `session_info`, snapshot handling, send eligibility states | Portable and important |
| Unread/read markers | Active-session reads plus per-session last-read persistence | Portable |
| Message disk cache | JSON files in app support | Replace with IndexedDB |
| Stream metadata cache | JSON files in app support | Replace with IndexedDB or local storage |
| Message list virtualization | Custom UIKit collection view | Reimplement using web virtualization library |
| Scroll restoration | Custom persisted offsets, anchors, unread anchoring | Reimplement; high-risk behavior area |
| Scroll-to-bottom affordance | Native overlay with draggable persisted detent | Portable; web can simplify initial version |
| Message rendering | `MessagePresentation` + markdown renderer + bubble views | Portable concept, new implementation |
| Markdown | Unified parser for mixed streaming markdown | Portable behavior, new parser/render path needed |
| Code blocks | Native text rendering + syntax highlighting support | Portable |
| Tables | Specialized parsing and rendering | Portable |
| Link cards | OG fetch + UIKit card | Portable, likely server-backed metadata fetch preferred |
| Inline web preview | `WKWebView` preview surface | Partially portable; security-sensitive |
| Images | Inline bubble rendering, paste, picker, upload/download | Portable |
| Documents/files | UIDocumentPicker + file attachment pipeline | Portable via `<input type=file>` and drag/drop |
| Pasted images | `UITextView` interception | Portable via paste event handling |
| Camera capture | Native sheet camera flow | Portable on supported browsers through file capture / media APIs |
| Photos library | `PhotosPicker` | Portable via file picker; no photo-library-native UX parity |
| Expanded message sheet | Dedicated message drill-in sheet | Portable |
| Interactive HTML attachments | `WKWebView` with CSP injection and callback bridge | Feasible with sandboxed iframe; needs new trust model |
| Terminal attachments | `SwiftTerm` + separate WebSocket session service/pool | Feasible with `xterm.js`; expensive |
| Haptics | UIKit feedback generators | Limited browser support; optional |
| Keyboard commands | App commands + text editor key handling | Portable, but browser/browser-OS conflicts must be handled |
| Background visual effects | SwiftUI shader backgrounds | Portable in CSS/WebGL/canvas, but not 1:1 |
| Appearance modes | Settings-backed theme selection | Portable |
| Font scaling | App-level scaling plus Dynamic Type integration | Portable using CSS variables and browser zoom-aware typography |
| Salience highlighting | `FoundationModels` on-device model + cache | Not directly portable in-browser; can be dropped, server-powered, or LLM-backed |
| Siri send intent | `AppIntent` that can send without foregrounding app | Not portable to browser in same form |
| Watch relay | `WatchConnectivityService` plus watch app transport | Not applicable to web v1 |
| Spatial target reuse | Thin reuse of shared app shell | Not relevant to web v1 |

## Platform Dependency Inventory

### Portable or Mostly Portable

- Provider wire protocol and message payloads
- Pairing handshake semantics
- Auth/session model
- Stream/session concepts
- Replay cursor concepts
- Message/attachment models
- Read/unread behavior
- Stream CRUD and adoption rules
- Markdown/table/code/link classification behavior
- Optimistic send and ack reconciliation
- Local caching concepts

### iOS-Only or Deeply Native

- Keychain storage
- `UserDefaults`/`Application Support` storage APIs
- SwiftUI environment and observation model
- UIKit collection view layout logic
- `UITextView`-backed editor behavior
- `keyboardLayoutGuide`
- `PhotosPicker`, `UIDocumentPicker`, native camera sheets
- `WKWebView` and `SFSafariViewController`
- `SwiftTerm`
- UIKit haptics
- `WatchConnectivity`
- `AppIntents`
- `FoundationModels`
- Metal/SwiftUI shader-backed backgrounds

### Browser Constraints that Affect Scope

- Browser TLS trust cannot mirror app-level self-signed certificate acceptance
- Leaf fingerprint pinning is not available to arbitrary web clients
- Token storage is weaker than keychain unless auth moves to cookie-backed web sessions
- Embedded arbitrary HTML must use stricter isolation than the native client
- Embedded terminal UX depends on browser focus and keyboard handling
- Mobile Safari and iPad browser keyboard behavior will differ from native iPad app behavior

## Current Architectural Risks Relevant to a Port

### 1. `ChatViewModel` Is Too Centralized

It owns transport-adjacent state, domain state, cache state, send state, attachment staging, active stream switching, unread/read logic, and screen-lifecycle handling. This is manageable in one native client, but it is the wrong shape for a clean web implementation.

Implication for web:

- Split into multiple stores/controllers
- Keep mutation seams explicit
- Avoid one large React store that recreates the same coupling

### 2. Message List Behavior Is a Product Feature, Not Just UI Plumbing

The iOS implementation spent thousands of lines on:

- staged materialization
- anchor compensation
- unread anchoring
- bottom inset behavior
- scroll restoration
- bubble sizing
- scroll-to-bottom affordances

Implication for web:

- Treat scroll behavior as product-critical
- Prototype the virtualized list early
- Do not leave this for end-stage polish

### 3. Native Rendering Surfaces Hide Real Port Cost

The current app relies on specialized native renderers for:

- rich attributed markdown
- `WKWebView` previews
- interactive HTML
- terminal sessions
- typed input with image interception

Implication for web:

- Rendering parity requires deliberate component and security design
- “Message bubble parity” is a full subsystem, not a component ticket

### 4. TLS and Trust UX Cannot Be Copied Literally

The app supports self-signed cert trust and optional fingerprint pinning. A browser app cannot give the user equivalent per-app trust behavior.

Implication for web:

- Either standardize on valid browser-trusted TLS
- Or introduce a proxy/gateway layer that terminates trusted TLS for the browser

### 5. Singleton and Notification-Based Seams Should Not Be Reproduced

`SessionRegistry.shared` and notification-based command paths are survivable in the current app but are poor portability anchors.

Implication for web:

- Replace them with typed domain stores and explicit actions

## Deployment Preconditions

Before implementation starts, the following must be fixed or explicitly gated. These are not late-stage polish decisions; they shape the web app architecture.

### Auth and Deployment Topology

The web client needs an approved answer for all of the following:

- Is the app same-origin with a web gateway/BFF, or a pure client app talking directly to the provider?
- Is auth cookie-backed, token-backed, or proxied through a gateway?
- Does the gateway terminate WebSocket auth on behalf of the browser, or does the browser talk directly to the provider?

Until those are decided, the framework recommendation is conditional rather than final.

### TLS

The native app supports self-signed trust and optional leaf fingerprint pinning through `ProviderBaseURLStore` and `URLSessionWebSocketConnector`. Browsers cannot reproduce this trust model.

The web port therefore requires one of two approved paths:

- Browser-trusted TLS on the provider endpoint
- A browser-safe gateway/proxy that terminates trusted TLS and forwards to the provider

If neither path is available, the web app should not proceed beyond prototype stage.

## Browser Runtime Invariants

The web client must define browser-specific behavior explicitly rather than inheriting iOS scene assumptions.

### Chosen Runtime Model

The recommended model is single-leader transport per authenticated browser profile:

- One tab is the transport leader.
- The leader owns the main chat WebSocket, replay cursor advancement, incoming event ordering, and durable unread/read projection updates.
- Follower tabs use `BroadcastChannel` to mirror live state and issue user intents such as send, mark-read, or stream mutations through the leader.
- If the leader closes or becomes unavailable, a follower may acquire leadership and reconnect using the persisted cursor state.

Rationale:

- It avoids duplicate sockets and duplicate replay advancement across tabs.
- It reduces unread divergence between tabs.
- It preserves a single authoritative connection lifecycle owner.

### Per-Tab Versus Shared State

- URL state is per-tab.
- Selected session is per-tab because each tab may be focused on a different conversation.
- Live transport, replay progress, unread/read projection updates, and message ordering are shared at the browser-profile level through the leader.
- Settings and identity are shared persisted preferences.

### Visibility and Focus

- Hidden follower tabs do not open the main chat socket.
- The leader may remain connected while backgrounded if the browser permits it.
- Focus changes do not directly mutate read state. Read state changes only through explicit visible-message acknowledgement rules in the chat domain owner.

### Online and Offline

- Offline transitions move the leader transport machine into a disconnected/recovering phase.
- Optimistic local sends remain visible but unsent until transport resumes or the user cancels them.
- Reconnect must be idempotent and replay from the last committed cursor only.

### Reload and Tab Closure

- Reload of a leader tab should not lose durable state because replay cursor, optimistic send journal, and unread projection state are persisted before acknowledgement.
- Follower reloads are cheap because they recover from persisted snapshot plus leader sync.
- Leader exit triggers transport leadership re-election.

## SSOT Ownership Matrix

The web implementation should start from ownership, not from a list of stores.

| Product concept | Single authoritative owner | Readers | Allowed mutation paths |
| --- | --- | --- | --- |
| Authenticated user/session presence | `authSessionStore` | router guards, transport machine, settings UI | pairing success, logout, auth refresh |
| Provider base URL and auth transport config | `authSessionStore` | pairing flow, transport machine, upload/terminal adapters | pairing success, settings edit, logout reset |
| Device/browser identity | `authSessionStore` persisted via browser storage adapter | transport machine | first-run generation, explicit reset |
| Transport phase (`idle`, `connecting`, `authenticating`, `replaying`, `live`, `recovering`, `failed`) | `transportMachine` | chat feature, diagnostics UI, send controls | transport reducer transitions only |
| Replay cursor advancement | `transportMachine` | chat projection hydrator, persistence adapter | leader-only message commit path |
| Selected session | URL state | chat shell, stream UI, composer | router navigation only |
| Send eligibility / provisioning state | `chatDomainStore` | composer, stream UI, banners | session snapshot handling, stream mutations, server events |
| Stream metadata and ordering | `chatDomainStore` | sidebar/popover, chat shell, settings/debug UI | stream snapshot events, stream CRUD responses, adopt/untrack actions |
| Messages and optimistic send reconciliation | `chatDomainStore` | message list, search/debug tooling, expanded message view | send pipeline, inbound events, replay hydrate, attachment hydrate |
| Read/unread projection | `chatDomainStore` | stream UI, document title/badge, follower-tab mirrors | explicit mark-read action, incoming assistant messages, stream switch rules |
| Draft text and staged attachments | component-local state within chat route subtree | composer and attachment tray only | local user input actions |
| Appearance/font/debug preferences | `settingsStore` | all feature modules | settings UI only |
| Toasts/global transient notifications | small notification service only | app shell | explicit publish calls from feature modules |

Two rules matter:

- If a concept appears in this table, no second mutable owner may be introduced for convenience.
- REST responses, WebSocket events, and local persistence hydration must all converge through the owner listed above.

## Proposed Web Architecture

### Recommended Application Shape

Use React as the UI layer, but gate the app runtime around the approved deployment topology:

- If the app is a pure browser client that talks directly to provider endpoints, a Vite-based SPA is a good fit.
- If auth, TLS termination, or WebSocket brokering require a same-origin gateway/BFF, use a React framework with a server boundary instead of forcing a pure SPA shape.

This is the concrete recommendation:

- UI layer: React 19 + TypeScript
- Runtime/build:
  - Direct-client variant: Vite
  - Gateway/BFF variant: a server-capable React framework
- Browser automation and E2E: Playwright
- Durable local persistence: IndexedDB via Dexie or equivalent
- Virtualized message rendering: `react-virtuoso` or TanStack Virtual
- Rich content:
  - markdown/render pipeline via `remark`/`rehype` or equivalent
  - syntax highlighting via Shiki or `highlight.js`
  - terminal rendering via `xterm.js`
  - embedded HTML via sandboxed iframe plus strict sanitization

### Minimum Shared Runtime Owners

The revised architecture should keep the number of shared mutable authorities intentionally small:

- `authSessionStore`
  - identity, provider config, persisted device ID
- `transportMachine`
  - socket leadership, phase transitions, replay cursor, reconnect/backoff
- `chatDomainStore`
  - streams, messages, unread/read projection, optimistic sends, provisioning state
- `settingsStore`
  - appearance, font scale, debug toggles

What is intentionally not present:

- no global `uiStore`
- no global `selectedSession` store
- no parallel `streamStore` plus `chatStore` split unless runtime pressure proves it necessary

Selected session belongs in the URL. Draft text and staged attachments belong to route-local state, not a global store.

### Routing and Overlay Model

Recommended routes:

- `/pair`
- `/chat/:sessionKey?`

Overlay model:

- Settings should open as a modal or drawer anchored inside the chat shell, not as a full-route page that navigates the user away from the conversation.
- Expanded message views, stream management, and similar flows should prefer route-backed overlays or subtree state, depending on whether deep-linking is product-useful.

Why:

- The iOS app treats settings as a natural sheet from the main shell.
- On web, full-page navigation away from chat is a product-feel regression for a conversation app.

### Feature Modules and Boundary Rules

The module split exists to separate different dependency shapes and different mutation rights. A module boundary is justified only when it groups code that changes for the same reason, depends on the same runtime inputs, and fails in the same way.

#### `auth-pairing`

Architectural reason this boundary exists:

- Everything in this module is about establishing or clearing identity and provider connectivity before chat can begin.
- It is the only feature area that is allowed to create or destroy the authenticated session.
- Its failure modes are first-run and auth/bootstrap failures, not live chat failures.

Relationship to other modules:

- It writes into `authSessionStore`.
- It may trigger transport startup indirectly by completing pairing or logout.
- It does not read or mutate chat projection state, unread state, or rendering state.
- Other modules are allowed to read auth/session presence, but they must not duplicate pair/logout behavior.

Decision rule for new code:

- If the code exists to establish identity, bootstrap provider config, recover first-run auth, or clear identity on logout, it belongs here.
- If the code assumes chat is already running, it does not belong here.

#### `chat-runtime`

Architectural reason this boundary exists:

- This is the live chat shell. Everything in it depends on transport state, session activation, or the chat domain projection.
- If the WebSocket drops, reconnects, replays, or changes send eligibility, this module reacts immediately.
- It is the only module that should feel “live” in the sense of transport-coupled UI behavior.

Relationship to other modules:

- It reads `transportMachine`, `chatDomainStore`, URL-selected session state, and `settingsStore`.
- It delegates message body rendering to `message-rendering`.
- It delegates upload and staging behavior to `attachments`.
- It opens `stream-management` and `settings-appearance` as overlays.
- It must not perform direct REST mutations or embed secondary transports itself.

Decision rule for new code:

- If the component exists because chat is live right now and must react to connection phase, session activation, unread/read changes, or composer send state, it belongs here.
- If it can render entirely from static message data with no transport awareness, it belongs elsewhere.

#### `stream-management`

Architectural reason this boundary exists:

- This boundary exists because stream/session administration mutates server state through explicit CRUD/adopt/untrack actions, not through the primary live message stream.
- These actions have different failure modes, retry semantics, and permission/provisioning rules than live message receipt.
- Keeping them separate prevents REST mutation concerns from leaking into the chat shell.

Relationship to other modules:

- It reads stream metadata and provisioning state from `chatDomainStore`.
- It dispatches explicit stream mutation actions that flow through typed HTTP modules and then back into `chatDomainStore`.
- It may be launched from `chat-runtime`, but `chat-runtime` should not own the mutation workflows themselves.
- It never touches message rendering rules or secondary rich-surface lifecycles.

Decision rule for new code:

- If the code exists to create, rename, delete, adopt, untrack, reorder, or explain the sendability of a stream/session, it belongs here.
- If the code exists only to show the currently selected stream inside the running chat shell, it belongs in `chat-runtime`.

#### `message-rendering`

Architectural reason this boundary exists:

- This module is pure transformation: message data in, presentational UI out.
- It should have no transport dependency, no mutation rights, and no side effects beyond local view behavior.
- That purity is exactly why it can be tested with fixtures and snapshots instead of live servers.

Relationship to other modules:

- It reads normalized message/attachment data from `chatDomainStore`.
- It may consume theme tokens from `settings-appearance`.
- It must not open sockets, call REST endpoints, own uploads, or mutate chat state directly.
- `chat-runtime` composes it, but should treat it as a pure renderer rather than another domain owner.

Decision rule for new code:

- If a component can be rendered from a static message fixture and should behave the same whether the app is live or disconnected, it belongs here.
- If it needs to open a socket, mutate server state, or coordinate uploads, it does not belong here.

#### `attachments`

Architectural reason this boundary exists:

- Attachments have a distinct side-effect surface: local file access, paste/drop handling, upload progress, hydration of uploaded assets, and failure/retry behavior.
- Those concerns are neither pure rendering nor general chat-runtime logic.
- This boundary keeps browser file APIs and upload lifecycle code out of the transport shell and out of the message renderer.

Relationship to other modules:

- It reads draft/composer context from `chat-runtime`.
- It dispatches staged attachment and upload completion events into `chatDomainStore`.
- It may use typed upload HTTP modules, but it does not own stream CRUD or live message replay.
- It hands fully described message parts to `message-rendering`; it does not render rich bodies itself.

Decision rule for new code:

- If the code touches file inputs, paste/drop events, upload progress, asset hydration, or attachment retry semantics, it belongs here.
- If the code only decides how an already-hydrated attachment should look on screen, it belongs in `message-rendering`.

#### `rich-surfaces`

Architectural reason this boundary exists:

- This module owns the features that bring their own secondary runtime boundaries: terminal WebSockets, iframe sandboxing, postMessage bridges, richer preview surfaces, and expanded content views.
- Each of these surfaces has an independent lifecycle and a security profile that is stricter than ordinary chat rendering.
- Keeping them isolated prevents the main chat shell from becoming responsible for transport types and trust boundaries it should not own.

Relationship to other modules:

- It reads already-authoritative message and stream context from `chatDomainStore`.
- It may own secondary transports such as terminal connections or isolated iframe bridges.
- It is opened by `chat-runtime`, but `chat-runtime` must not manage its secondary transport or sandbox policy.
- It may reuse primitives from `message-rendering`, but it must not inherit mutation rights from chat-runtime.

Decision rule for new code:

- If the feature introduces a new transport, a new sandbox, a new security policy, or a new embedded runtime, it belongs here.
- If it is just another static way to render a normal message body, it belongs in `message-rendering`.

#### `settings-appearance`

Architectural reason this boundary exists:

- This boundary exists because settings and appearance are shared preferences, not conversation state.
- They should be available from the chat shell without becoming part of chat runtime logic.
- Their change frequency and persistence rules are different from both transport state and message state.

Relationship to other modules:

- It reads and writes `settingsStore`.
- It may be opened from `chat-runtime`, but it should not know about live transport internals.
- Other modules may read theme tokens and preference values, but they must not own the preference-editing workflow.

Decision rule for new code:

- If the code edits shared appearance, font, or debug preferences, it belongs here.
- If it only consumes theme tokens while performing another module’s job, it stays in that other module.

### Boundary Enforcement Rule

When a new component or controller is added, the deciding questions are:

1. What runtime dependency does it react to first: auth bootstrap, live transport, REST mutation flow, pure rendering, browser file APIs, secondary transports, or shared preferences?
2. What state is it allowed to mutate?
3. What failure mode defines it: auth failure, disconnect/replay, REST mutation failure, upload failure, sandbox failure, or pure render correctness?

If those answers point to different modules, the code is probably trying to span too many responsibilities and should be split before it lands.

### Transport and Data Flow

Transport rules:

- Keep WebSocket connection, replay, and cross-tab leadership out of React components.
- Express provider events as reducer/state-machine inputs, not as direct component mutations.
- All stream CRUD and send actions must write through the authoritative owner listed in the SSOT matrix.

REST strategy:

- The current provider REST surface is small enough that typed fetch modules are sufficient at first.
- Introduce TanStack Query only if the REST surface grows enough to justify an additional cache authority.
- Do not make TanStack Query a second source of truth for streams or messages while the WebSocket remains primary.

### Persistence Boundaries and Cache Semantics

This is a persistence problem, not a repository-pattern exercise.

Recommended boundaries:

- IndexedDB
  - hydrated transcript snapshots by session
  - stream metadata snapshots
  - optimistic send journal
  - optional attachment metadata

- `localStorage`
  - appearance/font preferences
  - low-risk debug flags
  - non-sensitive routing or UI preferences only if URL state is not appropriate

- Prefer secure HTTP-only cookies for auth if the deployment topology allows it.
- If token storage is unavoidable, document the risk explicitly and keep tokens out of general-purpose UI state.

Cache semantics:

- `live`: current state built from acknowledged transport events
- `hydrated`: restored from persisted snapshot before live replay completes
- `replaying`: actively reconciling persisted state with server replay
- `stale`: usable for immediate paint but known to require confirmation
- `failed`: persistence restore or sync failed; app falls back to live fetch/replay

Rules:

- Persisted caches accelerate reload and cold start; they are not the final authority over live message order.
- Replay cursor commit and message projection commit must happen together.
- Read/unread projection state must not live in a separate, unsynchronized cache path.

### Accessibility and Embedded-Content Security Constraints

These are architecture inputs and belong in the main design, not in the final hardening phase.

Accessibility requirements from the start:

- The message list virtualization layer must preserve keyboard navigation, focus visibility, and screen-reader readable ordering.
- Composer interactions must be operable without pointer input.
- Font scaling and contrast theming must remain functional at every supported breakpoint.
- Stream switching, reconnect banners, and toasts must have clear accessible announcements.

Embedded-content security requirements from the start:

- Interactive HTML must render only in sandboxed iframes with a narrowly scoped postMessage bridge.
- Sanitization must happen before render, not after a user interaction.
- Link previews and rich embeds must not inherit ambient app credentials unless explicitly designed for it.
- Terminal sessions must use isolated auth and lifecycle handling rather than piggybacking on generic chat socket state.

### Styling Approach

Recommended styling model:

- CSS variables for theme tokens
- scoped component CSS or CSS modules for bespoke chat surfaces
- minimal utility classes only where they do not obscure layout rules

Theme guidance:

- Translate `ChatFlowTheme` and typography roles into web tokens
- Preserve visual identity, but do not reproduce native layout mechanics literally

## Test Strategy

The migration needs explicit testing layers from the start.

### Protocol and State Correctness

- Fixture tests for pairing/auth/chat payloads derived from current Swift behavior
- Reducer/state-machine tests for transport phase transitions and replay semantics
- Projection tests for unread/read rules, provisioning state, and optimistic send reconciliation

### Browser Runtime Behavior

- Multi-tab leadership tests
- Reload/reconnect tests
- offline/online recovery tests
- duplicate-send prevention tests

### UI and Interaction

- Playwright tests for pair flow, chat send/receive, stream switching, attachment upload, and settings overlay behavior
- Scroll behavior tests for unread anchors, restore-on-reload, and scroll-to-bottom affordance logic
- Accessibility checks for keyboard flow, focus order, announcements, and scalable typography

### Rich Surface and Security

- Terminal lifecycle tests
- Interactive HTML sandbox contract tests
- visual regression or screenshot diff coverage for critical chat surfaces

Testing should follow the ownership model:

- transport bugs are caught at the state-machine layer
- projection bugs are caught at the domain-store layer
- browser/runtime bugs are caught in end-to-end automation

## Migration Strategy

### Phase 0: Contract Capture and Runtime Definition

Before major UI work, capture the behavior that the web client must preserve:

- pairing request/result payloads
- auth payload and token/cookie contract
- message payloads and ack semantics
- typing/service/session/stream event payloads
- replay cursor behavior
- stream CRUD payloads
- terminal session protocol
- upload API assumptions
- chosen browser runtime invariants and cross-tab leadership rules

Deliverables:

- TypeScript protocol models
- fixture payloads captured from Swift behavior
- transport state-machine notes
- browser runtime invariant document

This is the only non-user-facing step in the high-level strategy. The detailed phase plan should still ensure each implementation phase yields a runnable app.

### Phase 1: Runnable Pairing and Text Chat

Build:

- pair flow
- auth bootstrap
- chat shell
- leader-tab transport machine
- text send/receive
- basic stream selection
- baseline Playwright coverage

Include from the start:

- keyboard-operable composer
- settings as in-chat overlay, not full navigation
- basic accessibility announcements for connection/send state

### Phase 2: Session Fidelity and Durable Reload

Build:

- replay/recovery
- unread/read projection
- persisted transcript snapshots
- durable reload behavior
- multi-tab leadership tests
- reconnect/offline handling

### Phase 3: Rich Rendering and Common Attachments

Build:

- markdown/code/tables
- image/file attachments
- paste/drop/file-input flows
- link cards
- upload/download pipeline
- visual regression coverage for core message surfaces

### Phase 4: Stream Management and Chat-Surface Maturity

Build:

- create/rename/delete/adopt/untrack stream flows
- improved message list virtualization
- scroll restoration and unread anchors
- mobile Safari/iPad browser tuning
- accessibility pass on chat shell and stream management

### Phase 5: Advanced Rich Surfaces

Build:

- terminal sessions
- interactive HTML attachments
- richer embedded previews
- expanded message surfaces

Gate:

- Only proceed if these are confirmed product requirements.
- Their security constraints must be designed before implementation, not retrofitted after.

### Phase 6: Release Hardening

Build:

- cross-browser compatibility pass
- deeper failure-mode coverage
- production observability
- performance tuning
- final security review

## What Ports Cleanly, What Needs Reimplementation, What Should Be Dropped

### Ports Cleanly

- Pairing UX and logic
- Provider transport protocol
- Stream/session mental model
- Read/unread semantics
- Optimistic send/ack reconciliation
- Message and stream data models
- Most settings semantics
- Markdown/code/table/link/image/file behavior

### Needs Reimplementation

- Entire chat screen layout/runtime
- Message virtualization and scroll restoration
- Rich text editor/composer
- Message renderer and bubble system
- Terminal session rendering
- Interactive HTML rendering
- Persistent cache layer
- Theme/background implementation

### Likely Drop or Defer for v1

- Watch relay
- Siri/App Intent send path
- Apple Intelligence salience highlighting
- Exact native haptics parity
- Exact drag-detent behavior for scroll-to-bottom control
- Full inline web preview parity if security posture is unresolved

## Module-by-Module Complexity and Risk

| Module | Current iOS surface | Web complexity | Risk notes |
| --- | --- | --- | --- |
| Pairing and auth shell | Moderate | Medium | Easy UI, but browser auth model needs a decision |
| Provider WebSocket transport | High | Medium | Protocol is clear, but reconnect/replay semantics must be preserved exactly |
| Connection lifecycle coordinator | High | High | State machine bugs here will feel like data loss or phantom disconnects |
| Chat domain store | Very high | Very high | Current `ChatViewModel` must be decomposed carefully |
| Stream/session management | High | Medium | CRUD is straightforward; provisioning and adopted-session behavior add edge cases |
| Message list virtualization | Very high | Very high | Product-critical UX and one of the riskiest areas |
| Message rendering pipeline | High | High | Markdown, tables, streaming partial content, attachments all need exactness |
| Composer/input | Moderate | Medium | Basic textarea is easy; parity editor behavior is not |
| Attachments upload/download | Moderate | Medium | Browser file APIs are fine; camera/mobile UX requires testing |
| Link cards/previews | Moderate | Medium | Metadata cards are easy; embedded previews/security are harder |
| Interactive HTML attachments | Moderate | High | Main risk is sandboxing and callback bridge design |
| Terminal attachments | High | Very high | Requires xterm.js, separate transport handling, focus/resize/clipboard parity |
| Settings/theme | Low | Low | Straightforward except nonportable TLS settings |
| Background visuals | Low | Medium | Can be approximated without matching the native shader pipeline |
| Salience highlighting | Moderate | Medium | Needs product decision; no direct portable equivalent |
| Watch/Siri/platform extras | Moderate | Low for web v1 | Easy to omit from initial web scope |

## Recommended Product Decisions

### 1. Treat Browser TLS as a Product Constraint, Not a UI Detail

If the provider commonly uses self-signed certificates today, the web app needs an infrastructure answer. The iOS toggle-based trust model cannot be reproduced in-browser.

Recommendation:

- Require browser-trusted TLS for web
- Or add a browser-safe gateway/proxy layer

### 2. Aim for Behavioral Parity, Not Native UI Mimicry

Exact reproduction of the UIKit/SwiftUI chat surface will waste effort. Users need:

- stable streams
- correct reconnect behavior
- good rendering
- dependable message navigation
- usable composition and attachments

They do not need a literal re-creation of iOS keyboard/layout mechanics.

### 3. Defer the Hardest Rich Surfaces Unless They Are Core to Launch

Terminal sessions and interactive HTML are feasible, but they are responsible for a disproportionate amount of engineering and security complexity.

Recommendation:

- Confirm whether they are launch-critical
- If not, make them second-wave features

### 4. Rewrite Client State Boundaries Instead of Porting `ChatViewModel`

The web client should preserve behavior but adopt clearer owners:

- connection state
- stream/session state
- message state
- UI state

This will make the web client easier to reason about and will also clarify future client parity work.

## Open Questions and Decision Points

1. Is the web app expected to match only the iOS/iPad app, or also absorb watch/spatial-adjacent behaviors over time?
2. Which deployment topology is approved: direct browser-to-provider, same-origin gateway/BFF, or another mediated path?
3. Which auth model is approved for the browser: secure cookies, browser-held tokens, or gateway-brokered session auth?
4. Will the web deployment require valid CA-trusted TLS end to end, or is a trusted gateway layer expected?
5. Are terminal session attachments launch-critical?
6. Are interactive HTML attachments launch-critical?
7. Is salience highlighting a must-have feature or a native-only enhancement that can be omitted?
8. Is a responsive mobile-web experience required to replace the iPad app in practice, or is desktop web the primary target?
9. Is offline read access required, or is durable reload plus reconnect sufficient?
10. Should link preview metadata be fetched in-browser or via a server-side preview service?
11. Will interactive HTML be treated as trusted content only, or must the browser client support untrusted embeds?

## Recommended Implementation Order

1. Resolve deployment topology, auth model, and TLS strategy.
2. Freeze and document the provider contract and browser runtime invariants.
3. Build the transport machine and a runnable pair-plus-text-chat slice.
4. Add replay, unread/read projection, and durable reload behavior.
5. Add rich rendering and common attachments.
6. Add stream-management flows and mature the chat surface.
7. Decide whether terminal and interactive HTML belong in the first release.
8. Run dedicated accessibility, browser-runtime, and embedded-content security passes before launch.

## Feasibility Conclusion

Clawline is portable to the web, but it is not a thin UI port. The server-facing protocol and product model are already strong enough to support a browser client. The cost sits in reconstructing the chat runtime with browser-native primitives and in deciding which native-only features deserve true parity.

The cleanest plan is:

- preserve the protocol and product semantics
- redesign the client state boundaries
- build the web app around explicit domain stores
- treat terminal and interactive HTML as gated scope decisions
- require deliberate answers on web auth and TLS before implementation begins

If those decisions are made up front, a React web client is a credible and maintainable next platform for Clawline.
