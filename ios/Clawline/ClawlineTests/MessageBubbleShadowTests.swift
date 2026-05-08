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
    @Test("Bubble shadow canvas owns shadow layers under cells")
    func bubbleShadowCanvasOwnsShadowLayers() throws {
        let canvas = BubbleShadowCanvasView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let descriptor = MessageBubbleShadowDescriptor(
            frame: CGRect(x: 20, y: 24, width: 140, height: 52),
            cornerRadius: MessageBubbleShadowStyle.cornerRadius,
            opacity: MessageBubbleShadowStyle.opacity(isDark: false),
            radius: MessageBubbleShadowStyle.radius,
            offset: MessageBubbleShadowStyle.offset
        )

        canvas.update(descriptors: [descriptor])

        let layer = try #require(canvas.layer.sublayers?.first)
        #expect(layer.frame == descriptor.frame)
        #expect(layer.shadowOpacity == descriptor.opacity)
        #expect(layer.shadowRadius == descriptor.radius)
        #expect(layer.shadowOffset == descriptor.offset)
        #expect(layer.shadowPath != nil)
    }
}
