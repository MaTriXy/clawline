//
//  StreamPageDotsViewTests.swift
//  ClawlineTests
//
//  Created by Codex on 4/1/26.
//

import Testing
import CoreGraphics
@testable import Clawline

@MainActor
struct StreamPageDotsViewTests {

    @Test("Expanded indicator width allows more visible dots than the collapsed cap")
    func expandedIndicatorShowsMoreDots() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )

        #expect(visibleCount > 11)
    }

    @Test("Expanded indicator fills the available width envelope when it can reveal more dots")
    func expandedIndicatorUsesAvailableWidthEnvelope() {
        let targetWidth = StreamPageDotsView.targetControlWidth(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )

        #expect(targetWidth != nil)
        #expect(targetWidth == CGFloat(640))
    }

    @Test("Expanded indicator stays collapsed when the width budget cannot reveal more dots")
    func expandedIndicatorSkipsWidthExpansionWithoutAdditionalCapacity() {
        let collapsedWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: 11,
            includesOverflowIndicators: true
        )
        let targetWidth = StreamPageDotsView.targetControlWidth(
            totalSessionCount: 40,
            maxWidth: collapsedWidth
        )

        #expect(targetWidth == nil)
    }

    @Test("Collapsed indicator keeps the legacy visible-dot cap")
    func collapsedIndicatorKeepsLegacyCap() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: nil
        )

        #expect(visibleCount == 11)
    }

    @Test("Unread dots keep highest precedence over user-tail and active styling")
    func unreadKindWinsPrecedence() {
        let kind = StreamDotColor.kind(
            isActive: true,
            hasUnread: true,
            hasUserTail: true
        )

        #expect(kind == .unread)
    }

    @Test("User-tail dots use the dedicated gold state when not active or unread")
    func userTailKindIsDistinct() {
        let kind = StreamDotColor.kind(
            isActive: false,
            hasUnread: false,
            hasUserTail: true
        )

        #expect(kind == .userTail)
    }
}
