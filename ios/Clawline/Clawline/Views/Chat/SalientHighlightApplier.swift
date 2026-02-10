//
//  SalientHighlightApplier.swift
//  Clawline
//

import Foundation
import UIKit

enum SalientHighlightApplier {
    static func apply(_ highlights: SalientHighlights, to attributed: NSAttributedString) -> NSAttributedString {
        guard !highlights.spans.isEmpty else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        apply(highlights, to: mutable)
        return mutable
    }

    static func apply(_ highlights: SalientHighlights, to mutable: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return }

        for span in highlights.spans {
            let start = span.startUTF16
            let end = start + span.lengthUTF16
            guard start >= 0, span.lengthUTF16 > 0, end <= mutable.length else { continue }

            let range = NSRange(location: start, length: span.lengthUTF16)
            mutable.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
                guard let font = value as? UIFont else { return }

                // Never modify inline code runs (monospace).
                if font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) {
                    return
                }

                let desiredTraits: UIFontDescriptor.SymbolicTraits
                switch span.style {
                case .bold:
                    desiredTraits = [.traitBold]
                case .italic:
                    desiredTraits = [.traitItalic]
                }

                let mergedTraits = font.fontDescriptor.symbolicTraits.union(desiredTraits)
                if mergedTraits == font.fontDescriptor.symbolicTraits {
                    return
                }

                let size = font.pointSize
                if let descriptor = font.fontDescriptor.withSymbolicTraits(mergedTraits) {
                    let newFont = UIFont(descriptor: descriptor, size: size)
                    mutable.addAttribute(.font, value: newFont, range: subRange)
                } else {
                    // Fallbacks for fonts that can't express the symbolic traits we want.
                    let newFont: UIFont
                    switch span.style {
                    case .bold:
                        newFont = UIFont.systemFont(ofSize: size, weight: .bold)
                    case .italic:
                        newFont = UIFont.italicSystemFont(ofSize: size)
                    }
                    mutable.addAttribute(.font, value: newFont, range: subRange)
                }
            }
        }
    }
}

