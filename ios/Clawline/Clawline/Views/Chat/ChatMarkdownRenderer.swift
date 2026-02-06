//
//  ChatMarkdownRenderer.swift
//  Clawline
//
//  Shared markdown rendering for chat bubbles and expanded message sheet.
//

import Foundation
import UIKit

enum ChatMarkdownRenderer {
    static func renderAttributedString(markdown: String,
                                       baseFont: UIFont,
                                       inkColor: UIColor,
                                       lineSpacing: CGFloat) -> AttributedString? {
        guard let ns = renderNSAttributedString(
            markdown: markdown,
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing
        ) else {
            return nil
        }
        return AttributedString(ns)
    }

    static func renderNSAttributedString(markdown: String,
                                         baseFont: UIFont,
                                         inkColor: UIColor,
                                         lineSpacing: CGFloat) -> NSAttributedString? {
        // Prefer full parsing (block syntax like headings), but fall back to inline-only.
        let attributed: AttributedString
        if let full = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) {
            attributed = full
        } else if let inline = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            attributed = inline
        } else {
            return nil
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left

        let nsAttributed = NSMutableAttributedString(attributed)
        let fullRange = NSRange(location: 0, length: nsAttributed.length)
        nsAttributed.addAttribute(.foregroundColor, value: inkColor, range: fullRange)
        nsAttributed.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        // Preserve bold/italic/monospace traits while using the chat base font family.
        nsAttributed.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let existingFont = value as? UIFont else {
                nsAttributed.addAttribute(.font, value: baseFont, range: range)
                return
            }

            let traits = existingFont.fontDescriptor.symbolicTraits
            let size = baseFont.pointSize
            var newFont = UIFont(descriptor: baseFont.fontDescriptor, size: size)

            if traits.contains(.traitBold) && traits.contains(.traitItalic) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
                    newFont = UIFont(descriptor: descriptor, size: size)
                }
            } else if traits.contains(.traitBold) {
                newFont = UIFont.systemFont(ofSize: size, weight: .bold)
            } else if traits.contains(.traitItalic) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    newFont = UIFont(descriptor: descriptor, size: size)
                }
            } else if traits.contains(.traitMonoSpace) {
                // Inline code runs: keep slightly smaller and add background fill.
                newFont = UIFont.monospacedSystemFont(ofSize: max(9, size - 1), weight: .medium)
                nsAttributed.addAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, range: range)
            }

            nsAttributed.addAttribute(.font, value: newFont, range: range)
        }

        // Ensure ATX heading levels (#..######) render visibly.
        applyHeadingStyles(markdown: markdown, nsAttributed: nsAttributed, baseFont: baseFont)

        return nsAttributed
    }

    private static func applyHeadingStyles(markdown: String,
                                          nsAttributed: NSMutableAttributedString,
                                          baseFont: UIFont) {
        let headings = extractMarkdownHeadings(markdown)
        guard !headings.isEmpty else { return }

        let fullText = nsAttributed.string as NSString
        var searchStart = 0

        for heading in headings {
            let target = heading.text
            guard !target.isEmpty else { continue }

            // Find the heading text at the start of a line to reduce false matches.
            var foundRange: NSRange?
            while searchStart < fullText.length {
                let searchRange = NSRange(location: searchStart, length: fullText.length - searchStart)
                let range = fullText.range(of: target, options: [], range: searchRange)
                if range.location == NSNotFound { break }

                let isLineStart = (range.location == 0) || (fullText.substring(with: NSRange(location: range.location - 1, length: 1)) == "\n")
                if isLineStart {
                    foundRange = range
                    break
                }
                searchStart = range.location + range.length
            }

            guard let range = foundRange else { continue }

            let level = max(1, min(6, heading.level))
            let delta: CGFloat
            switch level {
            case 1: delta = 8
            case 2: delta = 6
            case 3: delta = 4
            case 4: delta = 2
            case 5: delta = 1
            default: delta = 0
            }

            let size = min(32, baseFont.pointSize + delta)
            let weight: UIFont.Weight = (level <= 2) ? .bold : .semibold
            nsAttributed.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: weight), range: range)

            searchStart = range.location + range.length
        }
    }

    private static func extractMarkdownHeadings(_ markdown: String) -> [(level: Int, text: String)] {
        var results: [(level: Int, text: String)] = []
        var inFence = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            // ATX headings: #..###### <text> (optionally closing with trailing #'s)
            guard line.hasPrefix("#") else { continue }

            var level = 0
            for ch in line {
                if ch == "#" { level += 1 } else { break }
            }
            guard level >= 1 && level <= 6 else { continue }

            let afterHashes = line.dropFirst(level)
            guard afterHashes.first == " " || afterHashes.first == "\t" else { continue }
            var text = afterHashes.trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip optional closing #'s: "### Title ###"
            if let hashIndex = text.firstIndex(of: "#") {
                let suffix = text[hashIndex...]
                if suffix.allSatisfy({ $0 == "#" || $0 == " " || $0 == "\t" }) {
                    text = text[..<hashIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            results.append((level: level, text: String(text)))
        }

        return results
    }
}

