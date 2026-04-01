//
//  StreamPageDotsView.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI

struct StreamPageDotsView: View {
    @Environment(\.colorScheme) private var colorScheme

    let sessionKeys: [String]
    let activeSessionKey: String
    let unreadSessionKeys: Set<String>
    let userTailSessionKeys: Set<String>
    let maxWidth: CGFloat?
    let onTap: () -> Void

    private static let collapsedMaxVisibleDots = 11
    private static let dotDiameter: CGFloat = 7
    private static let overflowDotDiameter: CGFloat = 4
    private static let dotSpacing: CGFloat = 7
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 8
    static let controlHeight: CGFloat = 23

    private var activeIndex: Int {
        sessionKeys.firstIndex(of: activeSessionKey) ?? 0
    }

    private var maxVisibleDots: Int {
        Self.fittingVisibleDotCount(totalSessionCount: sessionKeys.count, maxWidth: expandedMaxWidth)
    }

    private var expandedMaxWidth: CGFloat? {
        guard shouldExpandToMaxWidth else { return nil }
        return maxWidth
    }

    private var shouldExpandToMaxWidth: Bool {
        guard maxWidth != nil else { return false }
        return sessionKeys.count > Self.collapsedMaxVisibleDots
    }

    private var visibleDotIndices: [Int] {
        guard sessionKeys.count > maxVisibleDots else {
            return Array(sessionKeys.indices)
        }
        let halfWindow = maxVisibleDots / 2
        let maxStart = sessionKeys.count - maxVisibleDots
        let start = min(max(0, activeIndex - halfWindow), maxStart)
        return Array(start..<(start + maxVisibleDots))
    }

    private var showsLeadingOverflow: Bool {
        (visibleDotIndices.first ?? 0) > 0
    }

    private var showsTrailingOverflow: Bool {
        (visibleDotIndices.last ?? -1) < sessionKeys.count - 1
    }

    private var hasHiddenUnreadLeading: Bool {
        guard let firstVisibleIndex = visibleDotIndices.first, firstVisibleIndex > 0 else {
            return false
        }
        return sessionKeys[..<firstVisibleIndex].contains { unreadSessionKeys.contains($0) }
    }

    private var hasHiddenUnreadTrailing: Bool {
        guard let lastVisibleIndex = visibleDotIndices.last, lastVisibleIndex < sessionKeys.count - 1 else {
            return false
        }
        return sessionKeys[(lastVisibleIndex + 1)...].contains { unreadSessionKeys.contains($0) }
    }

    private var warningBloomColor: Color {
        ChatFlowTheme.unreadIndicator(colorScheme).opacity(colorScheme == .dark ? 0.98 : 0.92)
    }

    static func fittingVisibleDotCount(totalSessionCount: Int, maxWidth: CGFloat?) -> Int {
        let collapsedCount = min(totalSessionCount, collapsedMaxVisibleDots)
        guard totalSessionCount > collapsedMaxVisibleDots, let maxWidth else {
            return collapsedCount
        }

        var bestCount = collapsedCount
        for candidateCount in collapsedCount...totalSessionCount {
            let requiredWidth = requiredControlWidth(
                visibleDotCount: candidateCount,
                includesOverflowIndicators: candidateCount < totalSessionCount
            )
            if requiredWidth <= maxWidth {
                bestCount = candidateCount
            } else {
                break
            }
        }
        return bestCount
    }

    static func requiredControlWidth(
        visibleDotCount: Int,
        includesOverflowIndicators: Bool
    ) -> CGFloat {
        let overflowCount = includesOverflowIndicators ? 2 : 0
        let elementCount = visibleDotCount + overflowCount
        let totalDotWidth = (CGFloat(visibleDotCount) * dotDiameter)
            + (CGFloat(overflowCount) * overflowDotDiameter)
        let totalSpacing = CGFloat(max(0, elementCount - 1)) * dotSpacing
        return totalDotWidth + totalSpacing + (horizontalPadding * 2)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                if showsLeadingOverflow {
                    Circle()
                        .fill(StreamDotColor.inactive(colorScheme: colorScheme))
                        .frame(width: 4, height: 4)
                }
                ForEach(visibleDotIndices, id: \.self) { index in
                    let sessionKey = sessionKeys[index]
                    let isActive = index == activeIndex
                    let hasUnread = unreadSessionKeys.contains(sessionKey)
                    let hasUserTail = userTailSessionKeys.contains(sessionKey)
                    Circle()
                        .fill(
                            StreamDotColor.resolve(
                                isActive: isActive,
                                hasUnread: hasUnread,
                                hasUserTail: hasUserTail,
                                colorScheme: colorScheme
                            )
                        )
                        .frame(width: 7, height: 7)
                        .shadow(
                            color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                            radius: isActive ? StreamDotColor.activeOuterGlowRadius(colorScheme: colorScheme) : 0
                        )
                        .shadow(
                            color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                            radius: isActive ? StreamDotColor.activeInnerGlowRadius(colorScheme: colorScheme) : 0
                        )
                }
                if showsTrailingOverflow {
                    Circle()
                        .fill(StreamDotColor.inactive(colorScheme: colorScheme))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .frame(width: expandedMaxWidth)
#if !os(visionOS)
            .glassEffect(.regular.interactive(), in: Capsule())
#else
            .background(.regularMaterial, in: Capsule())
#endif
            .overlay {
                unreadEdgeBloomOverlay
                    .mask(Capsule())
                    .allowsHitTesting(false)
            }
#if os(visionOS)
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
            }
#endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage streams")
        .accessibilityValue("Stream \(activeIndex + 1) of \(sessionKeys.count)")
        .accessibilityHint("Opens stream manager")
    }

    private var unreadEdgeBloomOverlay: some View {
        ZStack {
            if hasHiddenUnreadLeading {
                edgeWarningBloom(edge: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasHiddenUnreadTrailing {
                edgeWarningBloom(edge: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func edgeWarningBloom(edge: HorizontalEdge) -> some View {
        ZStack {
            Circle()
                .fill(warningBloomColor)
                .frame(width: 18, height: 18)
            Circle()
                .fill(warningBloomColor.opacity(colorScheme == .dark ? 0.92 : 0.84))
                .frame(width: 32, height: 32)
                .blur(radius: colorScheme == .dark ? 8 : 10)
        }
        .frame(width: 30, height: 30)
        .offset(x: edge == .leading ? -8 : 8)
    }
}
