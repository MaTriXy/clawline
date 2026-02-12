//
//  ChatMarkdownRendererMarkTests.swift
//  ClawlineTests
//

import Testing
import UIKit
@testable import Clawline

struct ChatMarkdownRendererMarkTests {
    private struct RGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    @Test("Markdown mark syntax applies rust color and skips inline code")
    func markSyntaxLightModeSkipsInlineCode() {
        let rust = SalientHighlightApplier.highlightColor(isDark: false)
        let rendered = ChatMarkdownRenderer.renderNSAttributedString(
            markdown: "Alpha ==focus== and `==literal==`.",
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            markHighlightColor: rust
        )

        guard let rendered else {
            Issue.record("Expected markdown render result")
            return
        }

        #expect(rendered.string == "Alpha focus and ==literal==.")

        let text = rendered.string as NSString
        let focusRange = text.range(of: "focus")
        #expect(focusRange.location != NSNotFound)
        #expect(rgb(rendered, at: focusRange.location) == RGB(red: 158, green: 62, blue: 28))

        let literalRange = text.range(of: "==literal==")
        #expect(literalRange.location != NSNotFound)
        #expect(rgb(rendered, at: literalRange.location) != RGB(red: 158, green: 62, blue: 28))
    }

    @Test("Markdown mark syntax applies muted gold in dark mode")
    func markSyntaxDarkModeColor() {
        let mutedGold = SalientHighlightApplier.highlightColor(isDark: true)
        let rendered = ChatMarkdownRenderer.renderNSAttributedString(
            markdown: "==focus==",
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .white,
            lineSpacing: 4,
            markHighlightColor: mutedGold
        )

        guard let rendered else {
            Issue.record("Expected markdown render result")
            return
        }

        #expect(rendered.string == "focus")
        #expect(rgb(rendered, at: 0) == RGB(red: 217, green: 175, blue: 98))
    }

    @Test("MessageTextPartRenderer only applies markdown highlights when enabled")
    func messageTextPartRendererHighlightToggle() {
        let presentation = MessagePresentation(
            parts: [.markdown("==focus==")],
            wordCount: 1,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )

        let disabled = MessageTextPartRenderer.attributedText(
            from: presentation,
            sizeClass: .long,
            metrics: ChatFlowTheme.Metrics(isCompact: true),
            inkColor: .black,
            isDarkMode: false,
            enableMarkdownHighlights: false
        )
        #expect(disabled.string == "==focus==")

        let enabled = MessageTextPartRenderer.attributedText(
            from: presentation,
            sizeClass: .long,
            metrics: ChatFlowTheme.Metrics(isCompact: true),
            inkColor: .black,
            isDarkMode: false,
            enableMarkdownHighlights: true
        )
        #expect(enabled.string == "focus")
        #expect(rgb(enabled, at: 0) == RGB(red: 158, green: 62, blue: 28))
    }

    @Test("MessagePresentationBuilder routes mark syntax through markdown renderer")
    func messagePresentationBuilderRoutesMarkSyntaxThroughMarkdownRenderer() {
        let message = Message(
            id: "s_mark_route",
            role: .assistant,
            content: "Alpha ==focus== beta",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:user:main"
        )
        var state = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: ChatFlowTheme.Metrics(isCompact: true),
            streamingState: &state
        )

        #expect(presentation.parts.contains(where: { part in
            if case .markdown(let value) = part {
                return value == "Alpha ==focus== beta"
            }
            return false
        }))

        let rendered = MessageTextPartRenderer.attributedText(
            from: presentation,
            sizeClass: .long,
            metrics: ChatFlowTheme.Metrics(isCompact: true),
            inkColor: .black,
            isDarkMode: false,
            enableMarkdownHighlights: true
        )
        #expect(rendered.string == "Alpha focus beta")
        let focusRange = (rendered.string as NSString).range(of: "focus")
        #expect(focusRange.location != NSNotFound)
        #expect(rgb(rendered, at: focusRange.location) == RGB(red: 158, green: 62, blue: 28))
    }

    private func rgb(_ attributed: NSAttributedString, at index: Int) -> RGB? {
        guard index >= 0, index < attributed.length else { return nil }
        guard let color = attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor else {
            return nil
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return RGB(
            red: Int((red * 255).rounded()),
            green: Int((green * 255).rounded()),
            blue: Int((blue * 255).rounded())
        )
    }
}
