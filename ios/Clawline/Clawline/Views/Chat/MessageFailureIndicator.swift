//
//  MessageFailureIndicator.swift
//  Clawline
//
//  Created by Codex on 1/18/26.
//

import SwiftUI

struct MessageFailureModifier: ViewModifier {
    let reason: String?

    func body(content: Content) -> some View {
        if let reason {
            content
                .padding(.bottom, 32)
                .overlay(alignment: .bottomLeading) {
                    MessageFailureBadge(reason: reason)
                        .offset(y: 18)
                }
        } else {
            content
        }
    }
}

struct MessageFailureBadge: View {
    let reason: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
            Text(reason)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundColor(labelColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(backgroundColor)
        )
        .accessibilityLabel("Message failed. \(reason)")
    }

    private var labelColor: Color {
        colorScheme == .dark ? Color.yellow : Color(red: 0.6, green: 0.12, blue: 0.12)
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.yellow.opacity(0.15)
            : Color(red: 0.98, green: 0.92, blue: 0.92)
    }
}

extension View {
    func messageFailureIndicator(_ reason: String?) -> some View {
        modifier(MessageFailureModifier(reason: reason))
    }
}
