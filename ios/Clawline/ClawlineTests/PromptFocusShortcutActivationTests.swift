//
//  PromptFocusShortcutActivationTests.swift
//  ClawlineTests
//
//  Created by Codex on 4/24/26.
//

import Testing
@testable import Clawline

struct PromptFocusShortcutActivationTests {
    @Test("Prompt focus shortcut does not steal focus from active text input")
    func promptFocusShortcutDoesNotStealFocusFromActiveTextInput() {
        #expect(
            PromptFocusShortcutActivation.shouldActivate(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: false
            )
        )
        #expect(
            !PromptFocusShortcutActivation.shouldActivate(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: true
            )
        )
        #expect(
            !PromptFocusShortcutActivation.shouldActivate(
                isShortcutEnabled: false,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: false
            )
        )
        #expect(
            !PromptFocusShortcutActivation.shouldActivate(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: true,
                currentFirstResponderIsTextInput: false
            )
        )
    }
}
