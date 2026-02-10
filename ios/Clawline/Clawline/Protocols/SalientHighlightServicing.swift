//
//  SalientHighlightServicing.swift
//  Clawline
//

import Foundation

protocol SalientHighlightServicing: Sendable {
    /// Returns cached highlights if present; otherwise returns nil.
    /// This may return nil while an async load/generation is in progress.
    func cachedHighlights(messageId: String, renderedText: String) -> SalientHighlights?

    /// Loads from disk or generates highlights asynchronously (idempotent for the same cache key).
    func highlights(messageId: String, renderedText: String) async -> SalientHighlights?
}

