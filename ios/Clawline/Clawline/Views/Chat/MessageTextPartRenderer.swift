//
//  MessageTextPartRenderer.swift
//  Clawline
//
//  Created by Codex on 2/10/26.
//

import Foundation
import UIKit

enum MessageTextPartRenderer {
    static func attributedText(
        from presentation: MessagePresentation,
        sizeClass: MessageSizeClass,
        metrics: ChatFlowTheme.Metrics,
        inkColor: UIColor,
        stripDetectedURLs: Bool = true
    ) -> NSAttributedString {
        let baseFont: UIFont
        let lineSpacing: CGFloat
        switch sizeClass {
        case .short:
            baseFont = UIFont.systemFont(ofSize: metrics.shortFontSize, weight: .semibold)
            lineSpacing = 0
        case .medium:
            baseFont = UIFont.systemFont(ofSize: metrics.mediumFontSize, weight: .medium)
            lineSpacing = 4
        case .long:
            baseFont = UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular)
            lineSpacing = 4
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: inkColor,
            .paragraphStyle: paragraph
        ]

        let result = NSMutableAttributedString()
        let textParts = presentation.parts.filter {
            switch $0 {
            case .text, .markdown, .inlineEmoji:
                return true
            case .linkPreview, .code, .table, .image, .gallery, .file, .terminalSession, .interactiveHTML:
                return false
            }
        }

        for (index, part) in textParts.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n", attributes: baseAttributes))
            }

            switch part {
            case .text(let value):
                result.append(NSAttributedString(string: value, attributes: baseAttributes))
            case .markdown(let value):
                if let parsed = ChatMarkdownRenderer.renderNSAttributedString(
                    markdown: value,
                    baseFont: baseFont,
                    inkColor: inkColor,
                    lineSpacing: lineSpacing
                ) {
                    result.append(parsed)
                } else {
                    result.append(NSAttributedString(string: value, attributes: baseAttributes))
                }
            case .inlineEmoji(let value):
                result.append(NSAttributedString(string: value, attributes: baseAttributes))
            case .linkPreview, .code, .table, .image, .gallery, .file, .terminalSession, .interactiveHTML:
                break
            }
        }

        if stripDetectedURLs, presentation.detectedURLCount > 0 {
            return stripDetectedLinks(from: result)
        }
        return result
    }

    private static let detectedLinkStripper: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func stripDetectedLinks(from attributed: NSAttributedString) -> NSAttributedString {
        guard let detector = detectedLinkStripper else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.string.utf16.count)
        let matches = detector.matches(in: mutable.string, options: [], range: fullRange)
        for match in matches.reversed() {
            guard match.resultType == .link else { continue }
            mutable.replaceCharacters(in: match.range, with: "")
        }

        func isTrimmable(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while let first = mutable.string.unicodeScalars.first, isTrimmable(first) {
            mutable.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        }
        while let last = mutable.string.unicodeScalars.last, isTrimmable(last) {
            let len = mutable.string.utf16.count
            guard len > 0 else { break }
            mutable.replaceCharacters(in: NSRange(location: len - 1, length: 1), with: "")
        }

        if mutable.string.contains("\n\n\n") {
            let regex = try? NSRegularExpression(pattern: "\n{3,}", options: [])
            let range = NSRange(location: 0, length: mutable.string.utf16.count)
            regex?.replaceMatches(in: mutable.mutableString, options: [], range: range, withTemplate: "\n\n")
        }

        return mutable
    }
}
