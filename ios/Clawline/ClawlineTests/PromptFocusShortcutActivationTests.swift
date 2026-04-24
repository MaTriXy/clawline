//
//  PromptFocusShortcutActivationTests.swift
//  ClawlineTests
//
//  Created by Codex on 4/24/26.
//

import Testing
import UIKit
@testable import Clawline

struct PromptFocusShortcutActivationTests {
    @Test("Prompt focus shortcuts do not include Cmd-L")
    func promptFocusShortcutsDoNotIncludeCommandL() {
        #expect(
            !PromptFocusShortcutConfiguration.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command]
                    && spec.action == .focusPromptInput
            }
        )
    }

    @Test("No-text shortcut host owns only unmodified prompt and popup keys")
    func noTextShortcutHostOwnsOnlyUnmodifiedPromptAndPopupKeys() {
        #expect(
            PromptFocusShortcutConfiguration.keyCommandSpecs.map(\.input) == ["/", " ", "\r"]
        )
        #expect(
            PromptFocusShortcutConfiguration.keyCommandSpecs.allSatisfy { $0.modifierFlags.isEmpty }
        )
    }

    @Test("Shortcut routing separates app commands from no-text responder keys")
    func shortcutRoutingSeparatesAppCommandsFromNoTextResponderKeys() {
        #expect(ChatShortcutRouting.owner(input: "l", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "h", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: ";", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "/", modifierFlags: [.command]) == .textInput)
        #expect(ChatShortcutRouting.owner(input: "/", modifierFlags: []) == .noTextResponder)
        #expect(ChatShortcutRouting.owner(input: " ", modifierFlags: []) == .noTextResponder)
        #expect(ChatShortcutRouting.owner(input: "\r", modifierFlags: []) == .noTextResponder)
    }

    @Test("Chat keyboard navigation follows stream order without wrapping")
    func chatKeyboardNavigationFollowsStreamOrderWithoutWrapping() {
        let sessionKeys = ["left", "middle", "right"]

        #expect(
            ChatKeyboardNavigation.targetSessionKey(
                sessionKeys: sessionKeys,
                currentSessionKey: "middle",
                step: -1
            ) == "left"
        )
        #expect(
            ChatKeyboardNavigation.targetSessionKey(
                sessionKeys: sessionKeys,
                currentSessionKey: "middle",
                step: 1
            ) == "right"
        )
        #expect(
            ChatKeyboardNavigation.targetSessionKey(
                sessionKeys: sessionKeys,
                currentSessionKey: "left",
                step: -1
            ) == nil
        )
        #expect(
            ChatKeyboardNavigation.targetSessionKey(
                sessionKeys: sessionKeys,
                currentSessionKey: "right",
                step: 1
            ) == nil
        )
    }

    @Test("Prompt focus shortcut does not steal focus from active text input")
    func promptFocusShortcutDoesNotStealFocusFromActiveTextInput() {
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: false,
                canRetryAfterTextInput: true
            ) == .activate
        )
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: true,
                canRetryAfterTextInput: false
            ) == .skip
        )
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: false,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: false,
                canRetryAfterTextInput: true
            ) == .skip
        )
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: true,
                currentFirstResponderIsTextInput: false,
                canRetryAfterTextInput: true
            ) == .skip
        )
    }

    @Test("Prompt focus shortcut retries after Esc text input handoff")
    func promptFocusShortcutRetriesAfterEscTextInputHandoff() {
        #expect(
            PromptFocusShortcutActivation.action(
                isShortcutEnabled: true,
                isAlreadyFirstResponder: false,
                currentFirstResponderIsTextInput: true,
                canRetryAfterTextInput: true
            ) == .retryAfterTextInputResigns
        )
    }
}
