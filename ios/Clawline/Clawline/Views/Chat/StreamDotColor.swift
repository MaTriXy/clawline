//
//  StreamDotColor.swift
//  Clawline
//
//  Created by Codex on 2/21/26.
//

import SwiftUI

enum StreamDotColor {
    private static let avatarGreen = Color(red: 0.42, green: 0.61, blue: 0.42)

    static func unread(_ colorScheme: ColorScheme) -> Color {
        ChatFlowTheme.terracotta(colorScheme)
    }

    static func activeGlow(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? avatarGreen.opacity(0.55)
            : avatarGreen.opacity(0.32)
    }

    static func resolve(
        isActive: Bool,
        hasUnread: Bool,
        colorScheme: ColorScheme
    ) -> Color {
        if hasUnread {
            return unread(colorScheme)
        }
        if isActive {
            return avatarGreen
        }
        return ChatFlowTheme.stone(colorScheme)
    }
}
