//
//  AppCommandNotifications.swift
//  Clawline
//

import Foundation

extension Notification.Name {
    static let clawlineOpenStreamPopupCommand = Notification.Name("clawline.openStreamPopupCommand")
    static let clawlineNavigateToPreviousStreamCommand = Notification.Name("clawline.navigateToPreviousStreamCommand")
    static let clawlineNavigateToNextStreamCommand = Notification.Name("clawline.navigateToNextStreamCommand")
    static let clawlineScrollToBottomCommand = Notification.Name("clawline.scrollToBottomCommand")
    static let clawlineScrollToTopCommand = Notification.Name("clawline.scrollToTopCommand")
}
