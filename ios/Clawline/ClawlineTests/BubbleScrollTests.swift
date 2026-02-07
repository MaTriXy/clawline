//
//  BubbleScrollTests.swift
//  ClawlineTests
//
//  Regression coverage for inner bubble scrolling when truncated content includes embedded previews.
//

import Testing
import UIKit
@testable import Clawline

struct BubbleScrollTests {

    @Test("Bug #62: Truncated bubbles enable inner scroll when link preview pushes content past cap")
    @MainActor
    func bubbleEnablesInnerScrollForEmbeddedPreview() {
        let url = "https://example.com/some/path"
        let content = """
        This is a message with enough text to be near the truncation cap but not exceed it by itself.

        It has multiple paragraphs so it lays out like a real message, and then a URL.

        \(url)
        """

        let message = Message(
            id: "bubbleScroll62",
            role: .assistant,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )

        let metrics = ChatFlowTheme.Metrics(isCompact: false) // larger cap to avoid false positives from text-only truncation

        let presentationNoPreview = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let presentationWithPreview = buildPresentation(message, metrics: metrics, enableLinkPreviews: true)

        let scrollEnabledNoPreview = isInnerBubbleScrollEnabled(
            message: message,
            presentation: presentationNoPreview,
            metrics: metrics,
            maxWidth: 360
        )
        let scrollEnabledWithPreview = isInnerBubbleScrollEnabled(
            message: message,
            presentation: presentationWithPreview,
            metrics: metrics,
            maxWidth: 360
        )

        #expect(scrollEnabledNoPreview == false)
        #expect(scrollEnabledWithPreview == true)
    }

    // MARK: Helpers

    @MainActor
    private func isInnerBubbleScrollEnabled(message: Message,
                                           presentation: MessagePresentation,
                                           metrics: ChatFlowTheme.Metrics,
                                           maxWidth: CGFloat) -> Bool {
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)

        let bubble = MessageBubbleUIKitView(frame: .zero)
        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth,
            truncationHeightOverride: nil,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil
        )
        bubble.setNeedsLayout()
        bubble.layoutIfNeeded()

        // Identify the bubble's inner scroll view: it is vertical-only and has directional lock enabled.
        let scrolls = allScrollViews(in: bubble)
        guard let inner = scrolls.first(where: { $0.isDirectionalLockEnabled && !$0.showsHorizontalScrollIndicator }) else {
            Issue.record("Expected inner bubble UIScrollView not found")
            return false
        }
        return inner.isScrollEnabled
    }

    private func allScrollViews(in view: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        if let scroll = view as? UIScrollView {
            result.append(scroll)
        }
        for sub in view.subviews {
            result.append(contentsOf: allScrollViews(in: sub))
        }
        return result
    }

    private func buildPresentation(_ message: Message,
                                   metrics: ChatFlowTheme.Metrics,
                                   enableLinkPreviews: Bool) -> MessagePresentation {
        var state = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &state
        )
        guard !enableLinkPreviews else { return presentation }

        let filtered = presentation.parts.filter { part in
            if case .linkPreview = part { return false }
            return true
        }
        return MessagePresentation(
            parts: filtered,
            wordCount: presentation.wordCount,
            hasTextualContent: presentation.hasTextualContent,
            isEmojiOnly: presentation.isEmojiOnly,
            hasMediaOnly: presentation.hasMediaOnly,
            detectedURLs: presentation.detectedURLs,
            detectedURLCount: presentation.detectedURLCount,
            hasSingleURL: presentation.hasSingleURL
        )
    }
}

