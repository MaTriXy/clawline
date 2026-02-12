//
//  SalientHighlightApplier.swift
//  Clawline
//

import Foundation
import UIKit

enum SalientHighlightApplier {
    private static let darkModeColor = UIColor(red: 217.0 / 255.0, green: 175.0 / 255.0, blue: 98.0 / 255.0, alpha: 1)
    private static let lightModeColor = UIColor(red: 158.0 / 255.0, green: 62.0 / 255.0, blue: 28.0 / 255.0, alpha: 1)

    static func highlightColor(isDark: Bool) -> UIColor {
        isDark ? darkModeColor : lightModeColor
    }

    static func apply(_ highlights: SalientHighlights, to attributed: NSAttributedString, isDark: Bool) -> NSAttributedString {
        guard !highlights.spans.isEmpty else { return attributed }
        guard !spansCoverEntireText(highlights.spans, textLength: attributed.length) else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        apply(highlights, to: mutable, isDark: isDark)
        return mutable
    }

    static func apply(_ highlights: SalientHighlights, to mutable: NSMutableAttributedString, isDark: Bool) {
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return }
        guard !spansCoverEntireText(highlights.spans, textLength: mutable.length) else { return }
        let color = highlightColor(isDark: isDark)

        for span in highlights.spans {
            let start = span.startUTF16
            let end = start + span.lengthUTF16
            guard start >= 0, span.lengthUTF16 > 0, end <= mutable.length else { continue }

            let range = NSRange(location: start, length: span.lengthUTF16)
            switch span.style {
            case .bold:
                mutable.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }

    private static func spansCoverEntireText(_ spans: [SalientSpan], textLength: Int) -> Bool {
        guard textLength > 0 else { return false }

        let ranges: [NSRange] = spans.compactMap { span in
            guard span.lengthUTF16 > 0 else { return nil }
            let start = max(0, span.startUTF16)
            let end = min(textLength, span.startUTF16 + span.lengthUTF16)
            guard end > start else { return nil }
            return NSRange(location: start, length: end - start)
        }

        guard !ranges.isEmpty else { return false }
        let sorted = ranges.sorted { lhs, rhs in
            if lhs.location == rhs.location {
                return lhs.length < rhs.length
            }
            return lhs.location < rhs.location
        }
        guard sorted[0].location == 0 else { return false }

        var coveredUntil = sorted[0].location + sorted[0].length
        if coveredUntil >= textLength { return true }

        for range in sorted.dropFirst() {
            if range.location > coveredUntil { return false }
            coveredUntil = max(coveredUntil, range.location + range.length)
            if coveredUntil >= textLength { return true }
        }
        return false
    }
}
