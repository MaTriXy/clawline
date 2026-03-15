//
//  StreamDotColor.swift
//  Clawline
//
//  Created by Codex on 2/21/26.
//

import SwiftUI

enum StreamDotColor {
    private static let avatarGreen = Color(red: 0.42, green: 0.61, blue: 0.42)

    static func resolve(
        isActive: Bool,
        hasUnread: Bool,
        colorScheme: ColorScheme
    ) -> Color {
        if hasUnread {
            return ChatFlowTheme.terracotta(colorScheme)
        }
        if isActive {
            return avatarGreen
        }
        return ChatFlowTheme.stone(colorScheme)
    }

    static func activeGlow(colorScheme: ColorScheme) -> Color {
        avatarGreen.opacity(colorScheme == .dark ? 0.88 : 0.62)
    }
}
