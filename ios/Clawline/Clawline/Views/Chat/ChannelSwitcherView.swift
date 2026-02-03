//
//  StreamSwitcherView.swift
//  Clawline
//
//  Created by Codex on 1/16/26.
//

import SwiftUI
#if !os(visionOS)
import UIKit
#endif

struct StreamSwitcherView: View {
    let activeStream: ChatStream
    let onSelect: (ChatStream) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings
#if !os(visionOS)
    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
#endif

    private var effectiveColorScheme: ColorScheme {
#if os(visionOS)
        return settings.appearanceMode == .dark ? .dark : .light
#else
        return colorScheme
#endif
    }

    var body: some View {
        let base = HStack(spacing: 12) {
            switchButton(for: .personal)
            switchButton(for: .admin)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color.white.opacity(effectiveColorScheme == .dark ? 0.08 : 0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(effectiveColorScheme == .dark ? 0.15 : 0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 12)

#if os(visionOS)
        base
#else
        base
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .onAppear { feedbackGenerator.prepare() }
#endif
    }

    private func switchButton(for channel: ChatStream) -> some View {
        let isSelected = channel == activeStream
        let accent = accentColor(for: channel)

        return Button {
            guard channel != activeStream else { return }
#if !os(visionOS)
            feedbackGenerator.impactOccurred()
#endif
            onSelect(channel)
        } label: {
            Text(channel.displayName)
                .font(.system(size: 15, weight: .semibold))
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(accent.opacity(isSelected ? 0.3 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(accent.opacity(isSelected ? 0.9 : 0.3), lineWidth: isSelected ? 2 : 1)
                )
                .foregroundColor(accent)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: activeStream)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(channel.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func accentColor(for channel: ChatStream) -> Color {
        switch channel {
        case .personal:
            return ChatFlowTheme.terracotta(effectiveColorScheme)
        case .admin:
            return ChatFlowTheme.adminAccent(effectiveColorScheme)
        }
    }
}
