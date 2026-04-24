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
    @Test("No-text prompt focus shortcuts keep Cmd-L out of the unmodified host")
    func noTextPromptFocusShortcutsKeepCommandLOutOfTheUnmodifiedHost() {
        #expect(
            !PromptFocusShortcutConfiguration.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command]
                    && spec.action == .focusPromptInput
            }
        )
    }

    @Test("App command shortcuts use Cmd-L focus, Cmd-semicolon, Cmd-Shift navigation, and scroll")
    func appCommandShortcutsUseCommandLFocusCommandSemicolonCommandShiftNavigationAndScroll() {
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command]
                    && spec.action.selector == #selector(UIResponder.clawlineFocusPromptInputCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == ";"
                    && spec.modifierFlags == [.command]
                    && spec.action.selector == #selector(UIResponder.clawlineOpenStreamPopupCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "h"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineNavigateToPreviousStreamCommand(_:))
            }
        )
        #expect(
            !ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command]
                    && spec.action.selector == #selector(UIResponder.clawlineNavigateToNextStreamCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "l"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineNavigateToNextStreamCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "j"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineScrollDownCommand(_:))
            }
        )
        #expect(
            ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                spec.input == "k"
                    && spec.modifierFlags == [.command, .shift]
                    && spec.action.selector == #selector(UIResponder.clawlineScrollUpCommand(_:))
            }
        )
        #expect(
            !ChatAppCommandShortcut.keyCommandSpecs.contains { spec in
                ["h", "j", "k"].contains(spec.input) && spec.modifierFlags == [.command]
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
        #expect(ChatShortcutRouting.owner(input: "l", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "h", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "j", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "k", modifierFlags: [.command, .shift]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: ";", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "l", modifierFlags: [.command]) == .appCommand)
        #expect(ChatShortcutRouting.owner(input: "h", modifierFlags: [.command]) == .textInput)
        #expect(ChatShortcutRouting.owner(input: "j", modifierFlags: [.command]) == .textInput)
        #expect(ChatShortcutRouting.owner(input: "k", modifierFlags: [.command]) == .textInput)
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
