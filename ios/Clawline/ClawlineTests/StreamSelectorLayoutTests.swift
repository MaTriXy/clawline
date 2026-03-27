//
//  StreamSelectorLayoutTests.swift
//  ClawlineTests
//
//  Created by Codex on 2/13/26.
//

import Testing
import CoreGraphics
import Foundation
@testable import Clawline

struct StreamSelectorLayoutTests {

    @Test("Short stream list uses content-driven height")
    func shortListUsesContentHeight() {
        let height = StreamSelectorLayout.containerHeight(
            itemCount: 3,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(44),
            rowSpacing: CGFloat(0),
            functionBarHeight: CGFloat(52),
            outerVerticalPadding: CGFloat(16),
            maxAvailableHeight: CGFloat(640),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(height == CGFloat(216))
    }

    @Test("Long stream list caps height and relies on internal scrolling")
    func longListUsesCappedHeight() {
        let height = StreamSelectorLayout.containerHeight(
            itemCount: 22,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(44),
            rowSpacing: CGFloat(0),
            functionBarHeight: CGFloat(52),
            outerVerticalPadding: CGFloat(16),
            maxAvailableHeight: CGFloat(340),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(height == CGFloat(340))
    }

    @Test("Stream manager popup keeps a compact action-bar gutter")
    func streamManagerPopupUsesCompactActionBarHeight() {
        let height = StreamSelectorLayout.containerHeight(
            itemCount: 1,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(52),
            rowSpacing: CGFloat(2),
            functionBarHeight: CGFloat(72),
            outerVerticalPadding: CGFloat(20),
            maxAvailableHeight: CGFloat(640),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(height == CGFloat(164))
    }

    @Test("Stream manager action bar bottom padding switches for keyboard-up layout")
    func streamManagerActionBarBottomPaddingTracksKeyboardVisibility() {
        let restingPadding = StreamSelectorLayout.actionBarBottomPadding(
            restingPadding: CGFloat(20),
            keyboardVisiblePadding: CGFloat(12),
            keyboardBottomInset: CGFloat(0)
        )
        let keyboardVisiblePadding = StreamSelectorLayout.actionBarBottomPadding(
            restingPadding: CGFloat(20),
            keyboardVisiblePadding: CGFloat(12),
            keyboardBottomInset: CGFloat(18)
        )

        #expect(restingPadding == CGFloat(20))
        #expect(keyboardVisiblePadding == CGFloat(12))
    }

    @Test("Overflow detection stays false when content fits")
    func overflowDetectionRespectsFitContent() {
        let isOverflowing = StreamSelectorLayout.isOverflowing(
            itemCount: 3,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(52),
            rowSpacing: CGFloat(8),
            functionBarHeight: CGFloat(58),
            outerVerticalPadding: CGFloat(16),
            maxAvailableHeight: CGFloat(480),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(isOverflowing == false)
    }

    @Test("Overflow detection turns on only when capped")
    func overflowDetectionRespectsCap() {
        let isOverflowing = StreamSelectorLayout.isOverflowing(
            itemCount: 8,
            showsCreateInlineRow: false,
            rowHeight: CGFloat(52),
            rowSpacing: CGFloat(8),
            functionBarHeight: CGFloat(58),
            outerVerticalPadding: CGFloat(16),
            maxAvailableHeight: CGFloat(320),
            minimumPopoverHeight: CGFloat(140)
        )

        #expect(isOverflowing == true)
    }

    @Test("Stream filter matches display names case-insensitively")
    func streamFilterMatchesCaseInsensitively() {
        let streams = [
            StreamSession(
                sessionKey: "agent:main:main",
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_1",
                displayName: "Research Notes",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        ]

        let filtered = StreamSelectorLayout.filter(streams: streams, query: "research")

        #expect(filtered.count == 1)
        #expect(filtered.first?.displayName == "Research Notes")
    }

    @Test("Blank stream filter returns all streams")
    func blankStreamFilterReturnsAll() {
        let streams = [
            StreamSession(
                sessionKey: "agent:main:main",
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: Date(),
                updatedAt: Date()
            ),
            StreamSession(
                sessionKey: "agent:main:clawline:user:s_2",
                displayName: "Planning",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        ]

        let filtered = StreamSelectorLayout.filter(streams: streams, query: "   ")

        #expect(filtered.count == streams.count)
    }
}
