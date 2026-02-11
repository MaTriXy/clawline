//
//  SalientHighlightApplier.swift
//  Clawline
//

import Foundation
import UIKit

enum SalientHighlightApplier {
    private static let darkModeColor = UIColor(red: 217.0 / 255.0, green: 175.0 / 255.0, blue: 98.0 / 255.0, alpha: 1)
    private static let lightModeColor = UIColor(red: 158.0 / 255.0, green: 62.0 / 255.0, blue: 28.0 / 255.0, alpha: 1)

    static func apply(_ highlights: SalientHighlights, to attributed: NSAttributedString, isDark: Bool) -> NSAttributedString {
        guard !highlights.spans.isEmpty else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        apply(highlights, to: mutable, isDark: isDark)
        return mutable
    }

    static func apply(_ highlights: SalientHighlights, to mutable: NSMutableAttributedString, isDark: Bool) {
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return }
        let color = isDark ? darkModeColor : lightModeColor

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
}
