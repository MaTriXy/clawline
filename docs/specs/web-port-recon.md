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

## Proposed React Web Architecture

### Recommended Application Shape

Use a client-rendered React SPA with route-based onboarding and a state architecture split by domain, not by screen.

Recommended high-level layers:

1. App shell
2. Domain stores/controllers
3. Transport/data services
4. Presentational components
5. Browser storage adapters

### Recommended Tech Stack

- React 19
- TypeScript
- Vite for app build and dev workflow
- React Router for routing
- Zustand for local domain stores
- TanStack Query for REST-backed server state
- IndexedDB via Dexie for message and stream caches
- `react-virtuoso` or TanStack Virtual for message virtualization
- `react-markdown` or `remark`/`rehype` pipeline plus custom renderers
- `highlight.js` or Shiki for code blocks
- `xterm.js` for terminal sessions
- `DOMPurify` plus sandboxed iframes for interactive HTML and embedded previews
- CSS variables plus a thin design-token layer; no heavy component framework

Why this stack:

- The app is interaction-heavy, not SEO-heavy, so SSR is not a primary requirement.
- The domain needs explicit client state ownership because the WebSocket session is central.
- IndexedDB is the correct browser analogue for durable message caches.
- A thin design system is preferable to importing a large UI framework that will fight the custom chat surface.

### Routing

Recommended routes:

- `/pair`
- `/chat`
- `/chat/:sessionKey`
- `/settings`

Routing notes:

- Pairing should be a first-run/onboarding route
- Session selection should be reflected in the URL
- Deep links to a specific stream/session are useful and natural on web

### Domain Stores

Recommended store split:

- `authStore`
  - token/session presence
  - user ID
  - device ID
  - provider base URL

- `settingsStore`
  - appearance
  - font scale
  - debug flags

- `connectionStore`
  - socket status
  - lifecycle phase
  - reconnect state
  - replay status

- `chatStore`
  - messages by session
  - optimistic sends
  - read/unread state
  - input drafts
  - attachment staging

- `streamStore`
  - stream metadata
  - selected session
  - active engine session
  - adoption/tracking state
  - provisioning state

- `uiStore`
  - sheet/modal state
  - toasts
  - scroll-to-bottom affordance state
  - expanded message state

This split directly addresses the current `ChatViewModel` overreach.

### Service Layer

Recommended services:

- `PairingClient`
- `ProviderSocketClient`
- `StreamApiClient`
- `UploadClient`
- `TerminalSessionClient`
- `MetadataPreviewClient`
- `MessageCacheRepository`
- `StreamCacheRepository`

Transport rules:

- Keep WebSocket connection and replay state out of React components
- Express provider events as typed actions into stores
- Keep one authoritative owner for connection phase and one for stream selection

### Component Structure

Recommended component tree:

- `AppShell`
- `PairingPage`
- `ChatPage`
- `ChatLayout`
- `StreamSidebar` or `StreamPopover`
- `MessageList`
- `MessageRow`
- `MessageBubble`
- `MessageRenderer`
- `MarkdownBlock`
- `CodeBlock`
- `TableBlock`
- `LinkCard`
- `LinkPreview`
- `ImageGallery`
- `FileAttachment`
- `InteractiveHtmlBubble`
- `TerminalBubble`
- `Composer`
- `AttachmentTray`
- `SettingsDialog`
- `ToastLayer`

Important implementation note:

Do not collapse the chat page into a single huge component. The current iOS complexity argues for smaller domain-driven UI seams.

### Styling Approach

Recommended styling model:

- CSS variables for theme tokens
- CSS modules or scoped component CSS for large bespoke surfaces
- Minimal utility classes if desired, but avoid a Tailwind-only architecture that obscures product-specific layout rules

Rationale:

- The app already has its own design language
- The chat surface needs deliberate CSS, not purely utility-composed styles
- Theme tokens should map from current `ChatFlowTheme` and typography settings

### Storage Model

Recommended browser persistence:

- IndexedDB
  - message caches
  - stream metadata cache
  - optional attachment metadata cache

- `localStorage`
  - theme/font preferences
  - non-sensitive UI state
  - generated device ID if no stronger auth model exists

- Prefer secure HTTP-only cookies for auth if server changes are allowed
- If not, local token storage is possible but weaker than the native keychain model

## Migration Strategy

### Phase 0: Contract Capture

Before writing much web UI, explicitly document and test the provider contracts currently implied by Swift code:

- pairing request/result payloads
- auth payload
- message payloads
- ack/error behavior
- typing/service/session/stream event payloads
- replay cursor behavior
- terminal session protocol
- upload API assumptions

Deliverables:

- TypeScript protocol models
- fixture payloads captured from Swift behavior
- state machine notes for connection lifecycle

This phase reduces the chance of silently reinterpreting provider behavior.

### Phase 1: Core Shell and Pairing

Build:

- app shell
- pairing flow
- auth/provider persistence
- guarded routing
- settings baseline

Exclude:

- advanced message rendering
- rich attachment surfaces

### Phase 2: Core Transport and Basic Chat

Build:

- authenticated WebSocket
- connection lifecycle state
- replay/recovery
- message send/ack
- session selection
- stream snapshot consumption
- unread/read behavior
- basic message list

This is the first end-to-end usable milestone.

### Phase 3: Message Rendering and Attachments

Build:

- markdown
- code blocks
- tables
- image/file attachments
- link cards
- upload/download pipeline

This gets the web app to practical parity for common messaging.

### Phase 4: Stream Management and Cache Durability

Build:

- create/rename/delete/adopt/untrack stream flows
- persistent caches
- scroll restoration
- deeper active-session behavior

### Phase 5: Advanced Rich Surfaces

Build:

- terminal sessions
- interactive HTML attachments
- richer preview surfaces
- expanded message views

This phase should be gated on real product need because it adds substantial security and QA cost.

### Phase 6: Web-Specific Hardening

Build:

- offline/reload resilience
- accessibility audit
- browser compatibility pass
- mobile Safari/iPad browser tuning
- security review for embedded content

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

1. Is the web app expected to match only the iOS/iPad app, or also subsume watch/spatial companion behaviors over time?
2. Can the provider/server be changed to support a safer web auth model, ideally secure cookies instead of token-in-storage?
3. Will the web client be allowed to require valid CA-trusted TLS?
4. Are terminal session attachments launch-critical?
5. Are interactive HTML attachments launch-critical?
6. Is salience highlighting a must-have feature or a native-only enhancement that can be omitted?
7. Should session selection be URL-addressable on web?
8. Is a responsive mobile-web experience required to replace the iPad app in practice, or is desktop web the primary target?
9. Should the web app preserve the exact stream-switch model of `uiSelectedSessionKey` versus `engineActiveSessionKey`, or can the UX be simplified?
10. Is there a need for offline read access to cached messages, or is reload resilience sufficient?
11. Should link preview metadata be fetched from the browser client or from a server-side preview service?
12. Is arbitrary embedded HTML trusted content only, or must the web app handle untrusted interactive content?

## Recommended Implementation Order

1. Freeze and document the provider client contract from current Swift behavior.
2. Prototype the web message list and scroll model before heavy feature work.
3. Build pairing, auth shell, transport, and basic stream navigation.
4. Implement messaging, replay, unread state, and durable caches.
5. Add markdown/code/table/image/file rendering.
6. Add stream management flows.
7. Decide whether terminal and interactive HTML make the first release.
8. Run a dedicated security review for browser-embedded content.

## Feasibility Conclusion

Clawline is portable to the web, but it is not a thin UI port. The server-facing protocol and product model are already strong enough to support a browser client. The cost sits in reconstructing the chat runtime with browser-native primitives and in deciding which native-only features deserve true parity.

The cleanest plan is:

- preserve the protocol and product semantics
- redesign the client state boundaries
- build the web app around explicit domain stores
- treat terminal and interactive HTML as gated scope decisions
- require deliberate answers on web auth and TLS before implementation begins

If those decisions are made up front, a React web client is a credible and maintainable next platform for Clawline.
