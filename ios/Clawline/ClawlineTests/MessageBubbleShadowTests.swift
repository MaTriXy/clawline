//
//  MessageBubbleShadowTests.swift
//  ClawlineTests
//
//  Created by Codex on 5/7/26.
//

import Testing
import UIKit
@testable import Clawline

@MainActor
struct MessageBubbleShadowTests {
    @Test("Bubble shadows use the pre-canvas per-bubble opacity")
    func bubbleShadowsUsePreCanvasOpacity() {
        #expect(MessageBubbleShadowStyle.opacity(isDark: false) == 0.32)
        #expect(MessageBubbleShadowStyle.opacity(isDark: true) == 0.25)
        #expect(MessageBubbleShadowStyle.radius == 12)
        #expect(MessageBubbleShadowStyle.offset == CGSize(width: 0, height: 5))
    }

    @Test("Light user prompt bubble fill is flat")
    func lightUserPromptBubbleFillIsFlat() {
        let colors = ChatFlowUIKitTheme.palette(isDark: false).bubbleSelfGradient

        #expect(colors.count == 2)
        #expect(colors.first == colors.last)
    }
}
