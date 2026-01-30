//
//  ChannelToast.swift
//  Clawline
//
//  Created by Claude on 1/24/26.
//

import SwiftUI

/// A Liquid Glass toast that displays the current channel name.
/// Designed for debounced display during swipe-to-switch gestures.
struct ChannelToast: View {
    let channelName: String

    @Environment(\.colorScheme) private var colorScheme

    private var toastTextColor: Color {
#if os(visionOS)
        return colorScheme == .dark ? .black : .white
#else
        return colorScheme == .dark ? .white : .primary
#endif
    }

#if os(visionOS)
    private var toastBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.85) : Color.black.opacity(0.7)
    }
#endif

    var body: some View {
        Text(channelName)
            .font(.system(size: 32, weight: .semibold, design: .rounded))
            .foregroundStyle(toastTextColor)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
#if os(visionOS)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(toastBackgroundColor)
            )
#else
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
#endif
            .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
    }
}

/// Manages the channel toast display with debounce behavior.
/// Toast stays visible while switching and only dismisses after 1 second of no activity.
@Observable
@MainActor
final class ChannelToastManager {
    private(set) var isVisible = false
    private(set) var channelName: String = ""

    private var dismissTask: Task<Void, Never>?
    private let dismissDelay: Duration = .seconds(1)

    /// Shows or updates the toast with the given channel name.
    /// If already visible, just updates the name without dismissing.
    func show(channel: ChatChannelType) {
        // Cancel any pending dismiss
        dismissTask?.cancel()
        dismissTask = nil

        // Update channel name and show
        channelName = channel.displayName
        isVisible = true

        // Schedule new dismiss
        dismissTask = Task {
            try? await Task.sleep(for: dismissDelay)
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }

    /// Immediately hides the toast.
    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        isVisible = false
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()

        ChannelToast(channelName: "Personal")
    }
}
