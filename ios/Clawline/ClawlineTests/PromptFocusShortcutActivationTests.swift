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

    @Test("Chat navigation shortcuts include Cmd-H and Cmd-L")
    func chatNavigationShortcutsIncludeCommandHAndCommandL() {
        #expect(
            PromptFocusShortcutConfiguration.keyCommandSpecs.contains { spec in
                spec.input == "h"
                    && spec.modifierFlags == [.command]
                    && spec.action == .navigatePreviousStream
                    && spec.wantsPriorityOverSystemBehavior
            }
        )
        #expect(
            PromptFocusShortcutConfiguration.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command]
                    && spec.action == .navigateNextStream
                    && spec.wantsPriorityOverSystemBehavior
            }
        )
    }

    @Test("Popup shortcuts include Cmd-semicolon and not Cmd-slash")
    func popupShortcutsIncludeCommandSemicolonAndNotCommandSlash() {
        #expect(
            PromptFocusShortcutConfiguration.keyCommandSpecs.contains { spec in
                spec.input == ";"
                    && spec.modifierFlags == [.command]
                    && spec.action == .openStreamPopup
                    && spec.wantsPriorityOverSystemBehavior
            }
        )
        #expect(
            !PromptFocusShortcutConfiguration.keyCommandSpecs.contains { spec in
                spec.input == "/"
                    && spec.modifierFlags == [.command]
                    && spec.action == .openStreamPopup
            }
        )
    }

    @Test("Command-modified press fallback resolves only intended shortcuts")
    func commandModifiedPressFallbackResolvesOnlyIntendedShortcuts() {
        #expect(
            PromptFocusShortcutConfiguration.actionForCommandModifiedPress(
                input: "l",
                modifierFlags: [.command]
            ) == .navigateNextStream
        )
        #expect(
            PromptFocusShortcutConfiguration.actionForCommandModifiedPress(
                input: "h",
                modifierFlags: [.command]
            ) == .navigatePreviousStream
        )
        #expect(
            PromptFocusShortcutConfiguration.actionForCommandModifiedPress(
                input: ";",
                modifierFlags: [.command]
            ) == .openStreamPopup
        )
        #expect(
            PromptFocusShortcutConfiguration.actionForCommandModifiedPress(
                input: "/",
                modifierFlags: [.command]
            ) == nil
        )
        #expect(
            PromptFocusShortcutConfiguration.actionForCommandModifiedPress(
                input: "l",
                modifierFlags: []
            ) == nil
        )
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
