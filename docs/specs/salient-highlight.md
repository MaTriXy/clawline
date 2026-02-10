# AI-Powered Salient Point Highlighting (GitHub #52)

## Goal
Automatically emphasize (bold/italic) the most important parts of **the user’s own messages** to make scroll-back scanning faster. The emphasis should surface:
- decisions
- questions
- important facts/constraints
- action items / next steps

This is strictly **on-device** using Apple Intelligence Foundation Models APIs (iOS 26 / visionOS), async, and cached. It must not block message send, typing, or scrolling.

## Non-Goals (v1)
- No highlighting for incoming assistant messages.
- No server-side analysis.
- No “rewrite” or summary UI; only inline emphasis in message bubbles.
- No perfect semantic diffing across edits (assume messages are immutable once sent).
- No guarantee that highlighted spans are stable across OS/model updates.

## Terms
- **Message**: `Message` model (`role`, `content`, `id`, etc.).
- **Presentation**: `MessagePresentation` output (parts like `.text`, `.markdown`, `.code`, `.table`, etc.).
- **Rendered Text**: The exact string shown in the bubble for “text-only” parts (post-markdown parsing and post-URL stripping). Concretely: the final `NSAttributedString` produced for the bubble’s text content, using its `.string` as the analysis input.
- **Span**: A byte/character range in Rendered Text that should be emphasized.
- **Algorithm Version**: A constant that represents prompt/schema/selection logic; bumping it invalidates cache.

## UX / Behavior
- Applies only when `message.role == .user`.
- Automatic (no per-message opt-in in v1).
- If the model is unavailable, disabled in Settings, or analysis fails: render normally (no emphasis).
- Emphasis is subtle: bold and italic only (no color, underline, background), so it composes with the existing bubble theme.

Recommended controls (v1.5, not required for v1):
- Settings toggle: “Salient highlights” (default ON when Apple Intelligence is available).
- Context menu: “Recompute highlights” (clears cache entry for that message and reruns).

## Architecture (Client)

### Where It Fits In The Rendering Pipeline
Current flow (simplified):
1. `Message` -> `MessagePresentation` (splits into parts: `.text`, `.markdown`, `.code`, etc.).
2. `MessageBubbleUIKitView` renders:
   - text/markdown into an `NSAttributedString` (via `ChatMarkdownRenderer` for markdown)
   - code blocks and tables as separate views
   - strips detected URLs from the attributed string in some cases (organic link cards)

Salient highlighting must be applied **after** markdown parsing and **after** link-stripping, because the model must operate on the **same string** that the user sees.

Concrete placement:
- Build the baseline attributed string for “text content only” (excluding code/table views).
- Apply cached spans by mutating the attributed string’s font traits for those ranges.
- Never call the model from inside `UIView.configure(...)` synchronously.

### Data Model: Highlight Spans
Represent cached results as ranges in **Rendered Text** (computed locally, never “counted” by the model):
```swift
enum SalientEmphasisStyle: String, Codable {
    case bold
    case italic
}

struct SalientSpan: Codable, Equatable {
    /// UTF-16 offsets (NSString indexing) in Rendered Text.
    var startUTF16: Int
    var lengthUTF16: Int
    var style: SalientEmphasisStyle

    /// Optional metadata for debugging / future UX.
    var kind: Kind?
    var confidence: Double?

    enum Kind: String, Codable { case decision, question, fact, actionItem }
}

struct SalientHighlights: Codable, Equatable {
    var messageId: String
    var renderedTextHash: String
    /// Optional: used to sanity-check that `renderedTextHash` was computed from the same bytes we apply to.
    var renderedTextLengthUTF16: Int
    var algorithmVersion: Int
    var spans: [SalientSpan]
}
```

Rationale:
- Use UTF-16 offsets so spans apply directly to `NSAttributedString` via `NSRange`.
- Hash is computed over **Rendered Text** (not raw markdown) to ensure cache is valid for exactly what we display.

### Service: Salient Highlighting (DI-Friendly)
Add a new protocol-based service (no singletons):
```swift
protocol SalientHighlightServicing {
    /// Returns cached highlights if present; otherwise schedules generation and returns nil.
    func cachedHighlights(for messageId: String, renderedText: String) -> SalientHighlights?

    /// Ensures generation is scheduled (idempotent). Completion fires on the main actor.
    func ensureHighlights(messageId: String, renderedText: String) async

    /// Async stream of updates so the list can reconfigure visible cells.
    var updates: AsyncStream<SalientHighlights> { get }
}
```

Injection:
- Construct the concrete `SalientHighlightService` at app root and inject into `ChatViewModel` (and/or environment) following existing protocol-based DI patterns.
- `ChatViewModel` becomes the coordinator that triggers analysis and relays updates to the UI.

### Foundation Models API (iOS 26 / visionOS)
Use Apple’s Foundation Models Framework (Apple Intelligence on-device):
- `SystemLanguageModel.default.availability` to gate feature.
- `LanguageModelSession` for single-turn extraction.
- `@Generable` output schema for structured spans.

Important: do **not** ask the model to return character/byte offsets. LLMs are unreliable at indexing (especially with Unicode/emoji). Instead, ask it to return exact substrings, and compute UTF-16 ranges locally by searching within Rendered Text.

Generation shape:
```swift
import FoundationModels

@Generable
struct SalientOutput {
    @Guide(description: "Candidates to emphasize; each must be an exact substring of the input text.", .count(0...12))
    var candidates: [Candidate]

    @Generable
    struct Candidate {
        @Guide(description: "Exact substring copied from the input text. Keep it short (typically <= 80 chars).")
        var substring: String

        @Guide(description: "bold for decisions/actions/facts, italic for questions when appropriate.")
        var style: String

        @Guide(description: "decision, question, fact, actionItem")
        var kind: String

        @Guide(description: "0.0-1.0 confidence")
        var confidence: Double
    }
}
```

Prompt / Instructions (high level):
- Input is the **exact Rendered Text**.
- Task: select up to N short spans that help someone scan quickly for decisions/questions/facts/actions.
- Constraints:
  - Prefer short phrases (not whole paragraphs).
  - Every candidate must be an exact substring of the provided text.
  - Do not select purely decorative text (greetings, filler).
  - Avoid overlapping spans; do not exceed ~30% of the text.
  - If nothing is salient, return `candidates: []`.

Safety/robustness:
- Treat analysis as “best effort” and tolerate failure (decode issues, empty output, etc.).
- Locally resolve each candidate substring to one or more `NSRange`s in Rendered Text:
  - If substring occurs once: use that range.
  - If it occurs multiple times: pick the earliest occurrence (v1), and consider adding context-based disambiguation later.
  - If it does not occur: drop the candidate.
- Locally de-overlap deterministically (e.g., sort by start, then keep the longest in an overlap set, then apply confidence tie-break).

### Performance + Concurrency
Hard requirements:
- Do not block message send.
- Do not block scroll or cell configuration.
- Run on-device and asynchronously.

Strategy:
- Generation runs in background tasks with `.utility` priority.
- Rate limit concurrency:
  - Max 1-2 in-flight generations at a time (avoid CPU spikes during fast scroll-back).
  - Debounce batches when the user scrolls quickly.
- Truncate very long inputs (e.g., cap Rendered Text to a maximum character/UTF-16 length) and prefer “top of message” + “last lines” sampling for long messages to keep latency bounded.
- Use caching aggressively (see below).

### When To Generate
Only for `role == .user`.

Triggers:
1. Outgoing message pipeline:
   - When a user message is created/added to history, schedule `ensureHighlights(...)` after the message is persisted/visible.
   - Never await highlights as part of send/ack.
2. Scroll-back / history load:
   - When messages become visible (or near-visible), schedule highlights for user messages that lack cached results.
   - Use low priority and rate limiting.

### Caching + Invalidation
Two-layer cache:
- **Memory LRU**: fast access for visible messages (e.g., 300-800 entries).
- **Disk cache** in app caches directory:
  - File-per-message (`{messageId}-{renderedTextHash}-{algorithmVersion}.json`) or a small SQLite table.
  - Prefer file-per-message for simplicity in v1; SQLite if file count becomes problematic.

Cache key:
- `messageId`
- `renderedTextHash` (SHA-256 of Rendered Text, hex)
- `algorithmVersion` (int constant)

Invalidation:
- If `renderedTextHash` differs: treat as cache miss and recompute.
- If `algorithmVersion` differs: treat as cache miss and recompute.
- Optional TTL (recommended): evict disk entries older than N days (e.g., 30) during background maintenance.
- If Apple Intelligence becomes unavailable (settings or device state): do not recompute; keep existing cached results but do not fail if absent.

### Applying Spans To Attributed Text (Markdown-Compatible)
Highlighting is applied to the final `NSAttributedString` for text parts only.

Rules:
- Skip spans that intersect inline code runs (monospace / `.traitMonoSpace` or `inlinePresentationIntent == .code` if present).
- Do not override explicit markdown emphasis:
  - If a range is already bold, applying bold is a no-op.
  - If a range is already italic, applying italic is a no-op.
  - If a range is bold and the style requested is italic (or vice versa), allow combining if supported by the base font descriptor; otherwise prefer existing markdown styling.
- Do not modify link attributes; only adjust `.font`.

Font application approach:
- For each span `NSRange`, enumerate `.font` in that range and apply a new font with desired symbolic traits (bold/italic), similar to existing markdown renderer logic.
- Keep point size and family consistent with the bubble’s base font selection by size class.

### Integration With Markdown Rendering
Key constraint: analysis must run on Rendered Text (post markdown parse, post URL stripping) so offsets match.

Pipeline:
1. Render the message’s “text-only” content to an `NSAttributedString` using existing logic.
2. Derive Rendered Text via `attributed.string`.
3. Hash Rendered Text and query cache.
4. If cached: apply spans immediately (after verifying `renderedTextLengthUTF16` matches).
5. If not cached: render without highlights, schedule generation asynchronously, then:
   - get model `candidates` (substrings)
   - resolve candidates to UTF-16 ranges locally
   - persist `SalientHighlights` (resolved spans + renderedTextHash + length + algorithmVersion)
   - emit an update so visible cells can reconfigure

This avoids needing a fragile mapping from raw markdown indices to rendered output.

## Foundation Models Availability + Session Lifecycle
- Gate feature on `SystemLanguageModel.default.availability` (and any app-level setting toggle if added later).
- Treat “unavailable” as a stable disabled state: do not schedule work; just render normally.
- Create a fresh `LanguageModelSession` per generation request (single-turn extraction). Rationale: sessions are single-flight and may retain context; per-request sessions are simpler and avoid cross-message contamination.

## Telemetry / Debuggability (Optional)
- Log generation latency and cache hit rate (local only, OSLog category).
- Guard logs to avoid leaking content; log only lengths and hashes.

## Testing Plan (v1)
- Unit tests:
  - Span normalization: clamp, drop invalid/out-of-range, de-overlap deterministically.
  - Cache key + invalidation: hash change and algorithmVersion bump behavior.
  - Attributed-string application: applying bold/italic preserves existing markdown styles and does not affect inline code runs.
- Integration sanity:
  - User message with markdown (bold/italic/code) still renders correctly with highlights.
  - Scrolling back through many user messages does not hitch (verify generation rate limiting).
