//
//  StreamPageDotsView.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI

struct StreamPageDotsView: View {
    let sessionKeys: [String]
    let activeSessionKey: String
    let onTap: () -> Void

    private var activeIndex: Int {
        sessionKeys.firstIndex(of: activeSessionKey) ?? 0
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                ForEach(Array(sessionKeys.enumerated()), id: \.offset) { index, _ in
                    Circle()
                        .fill(index == activeIndex ? Color.primary : Color.primary.opacity(0.25))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage streams")
        .accessibilityHint("Opens stream manager")
    }
}
