//
//  AppCommandNotifications.swift
//  Clawline
//

import Foundation
import SwiftUI

extension Notification.Name {
    static let clawlineOpenStreamPopupCommand = Notification.Name("clawline.openStreamPopupCommand")
    static let clawlineScrollToBottomCommand = Notification.Name("clawline.scrollToBottomCommand")
    static let clawlineScrollToTopCommand = Notification.Name("clawline.scrollToTopCommand")
}

struct CancelCurrentPromptCommand {
    let presentConfirmation: @MainActor () -> Void
}

private struct CancelCurrentPromptCommandKey: FocusedValueKey {
    typealias Value = CancelCurrentPromptCommand
}

extension FocusedValues {
    var cancelCurrentPromptCommand: CancelCurrentPromptCommand? {
        get { self[CancelCurrentPromptCommandKey.self] }
        set { self[CancelCurrentPromptCommandKey.self] = newValue }
    }
}
