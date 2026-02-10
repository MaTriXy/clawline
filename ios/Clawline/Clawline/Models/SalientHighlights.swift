//
//  SalientHighlights.swift
//  Clawline
//
//  On-device salient point highlighting results for user messages.
//

import Foundation

nonisolated enum SalientEmphasisStyle: String, Codable, Equatable {
    case bold
    case italic
}

nonisolated struct SalientSpan: Codable, Equatable {
    /// UTF-16 offsets into the *rendered* bubble text (`NSAttributedString.string`).
    var startUTF16: Int
    var lengthUTF16: Int
    var style: SalientEmphasisStyle

    var kind: Kind?
    var confidence: Double?

    nonisolated enum Kind: String, Codable, Equatable {
        case decision
        case question
        case fact
        case actionItem
    }
}

nonisolated struct SalientHighlights: Codable, Equatable {
    var messageId: String
    var renderedTextHash: String
    var renderedTextLengthUTF16: Int
    var algorithmVersion: Int
    var spans: [SalientSpan]
}
