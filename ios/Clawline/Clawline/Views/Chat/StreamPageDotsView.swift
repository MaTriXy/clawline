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
    let dotStatesBySession: [String: StreamDotState]
    let maxWidth: CGFloat?
    let onTap: () -> Void
    let onScrubPreview: (String) -> Void
    let onScrubCommit: (String) -> Void
    let onScrubCancel: () -> Void

    @State private var scrubStartIndex: Int?
    @State private var scrubCandidateIndex: Int?
    @State private var scrubTapSuppressionExpiresAt = Date.distantPast

    private static let collapsedMaxVisibleDots = 11
    private static let dotDiameter: CGFloat = 7
    private static let overflowDotDiameter: CGFloat = 4
    private static let dotSpacing: CGFloat = 7
    private static let horizontalPadding: CGFloat = 12
    private static let minimumHitTargetHeight: CGFloat = 44
    private static let scrubTapSuppressionDuration: TimeInterval = 0.45
    static let controlHeight: CGFloat = 23
    static func unreadEdgeBloomBlurRadius(colorScheme: ColorScheme) -> CGFloat {
        colorScheme == .dark ? 4.5 : 4.0
    }
    static func unreadEdgeBloomOpacity(colorScheme: ColorScheme) -> Double {
        0.40
    }

    private var activeIndex: Int {
        sessionKeys.firstIndex(of: activeSessionKey) ?? 0
    }

    private var maxVisibleDots: Int {
        Self.fittingVisibleDotCount(totalSessionCount: sessionKeys.count, maxWidth: expandedWidthBudget)
    }

    private var expandedWidthBudget: CGFloat? {
        guard shouldExpandToMaxWidth else { return nil }
        return maxWidth
    }

    private var shouldExpandToMaxWidth: Bool {
        guard maxWidth != nil else { return false }
        return sessionKeys.count > Self.collapsedMaxVisibleDots
    }

    private var visibleDotIndices: [Int] {
        let centerIndex = scrubCandidateIndex ?? activeIndex
        guard sessionKeys.count > maxVisibleDots else {
            return Array(sessionKeys.indices)
        }
        let halfWindow = maxVisibleDots / 2
        let maxStart = sessionKeys.count - maxVisibleDots
        let start = min(max(0, centerIndex - halfWindow), maxStart)
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
        return sessionKeys[..<firstVisibleIndex].contains { dotStatesBySession[$0] == .unread }
    }

    private var hasHiddenUnreadTrailing: Bool {
        guard let lastVisibleIndex = visibleDotIndices.last, lastVisibleIndex < sessionKeys.count - 1 else {
            return false
        }
        return sessionKeys[(lastVisibleIndex + 1)...].contains { dotStatesBySession[$0] == .unread }
    }

    private var warningBloomColor: Color {
        ChatFlowTheme.unreadIndicator(colorScheme)
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

    static func targetControlWidth(totalSessionCount: Int, maxWidth: CGFloat?) -> CGFloat? {
        guard totalSessionCount > collapsedMaxVisibleDots, let maxWidth else { return nil }
        let collapsedWidth = requiredControlWidth(
            visibleDotCount: collapsedMaxVisibleDots,
            includesOverflowIndicators: true
        )
        let visibleDotCount = fittingVisibleDotCount(totalSessionCount: totalSessionCount, maxWidth: maxWidth)
        guard visibleDotCount > collapsedMaxVisibleDots else { return nil }
        guard maxWidth > collapsedWidth else { return nil }
        let requiredWidth = requiredControlWidth(
            visibleDotCount: visibleDotCount,
            includesOverflowIndicators: visibleDotCount < totalSessionCount
        )
        return min(maxWidth, requiredWidth)
    }

    static func renderedControlWidth(totalSessionCount: Int, maxWidth: CGFloat?) -> CGFloat {
        let visibleDotCount = fittingVisibleDotCount(totalSessionCount: totalSessionCount, maxWidth: maxWidth)
        let includesOverflowIndicators = visibleDotCount < totalSessionCount
        return targetControlWidth(totalSessionCount: totalSessionCount, maxWidth: maxWidth)
            ?? requiredControlWidth(
                visibleDotCount: visibleDotCount,
                includesOverflowIndicators: includesOverflowIndicators
            )
    }

    var body: some View {
        Button(action: handleTap) {
            controlBody
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(scrubGesture)
        .onDisappear {
            cancelScrubIfNeeded()
        }
        .onChange(of: activeSessionKey) { _, _ in
            resetScrubState()
        }
        .onChange(of: sessionKeys) { _, _ in
            resetScrubState()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open stream manager"), onTap)
        .accessibilityLabel("Manage streams")
        .accessibilityValue("Stream \(activeIndex + 1) of \(sessionKeys.count)")
        .accessibilityHint("Tap to open stream manager. Long press and drag to preview streams.")
    }

    private func handleTap() {
        guard Date() >= scrubTapSuppressionExpiresAt else { return }
        onTap()
    }

    private var controlBody: some View {
        let controlWidth = Self.renderedControlWidth(totalSessionCount: sessionKeys.count, maxWidth: expandedWidthBudget)
        return ZStack(alignment: .bottom) {
            dockChrome(controlWidth: controlWidth)
                .frame(maxHeight: .infinity, alignment: .bottom)

            dotRow
                .frame(width: controlWidth, height: Self.controlHeight, alignment: .center)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: controlWidth, height: Self.minimumHitTargetHeight, alignment: .bottom)
    }

    private func dockChrome(controlWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: controlWidth, height: Self.controlHeight)
            .background {
                unreadEdgeBloomOverlay
                    .mask(Capsule())
                    .blur(radius: Self.unreadEdgeBloomBlurRadius(colorScheme: colorScheme))
                    .allowsHitTesting(false)
            }
#if !os(visionOS)
            .glassEffect(.regular.interactive(), in: Capsule())
#else
            .background(.regularMaterial, in: Capsule())
#endif
#if os(visionOS)
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
            }
#endif
    }

    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.28, maximumDistance: 24)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginScrubIfNeeded(startIndex: activeIndex, capturesStart: false)
                case .second(true, let dragValue):
                    if let dragValue {
                        updateScrubCandidate(with: dragValue)
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                switch value {
                case .first(true):
                    commitScrub()
                case .second(true, let dragValue):
                    if let dragValue {
                        updateScrubCandidate(with: dragValue)
                    }
                    commitScrub()
                default:
                    cancelScrub()
                }
            }
    }

    private func beginScrubIfNeeded(startIndex: Int, capturesStart: Bool = true) {
        guard !sessionKeys.isEmpty else { return }
        scrubTapSuppressionExpiresAt = Date().addingTimeInterval(Self.scrubTapSuppressionDuration)
        if capturesStart, scrubStartIndex == nil {
            scrubStartIndex = startIndex
        }
        updateScrubCandidate(index: scrubCandidateIndex ?? startIndex)
    }

    private func updateScrubCandidate(with value: DragGesture.Value) {
        guard !sessionKeys.isEmpty else { return }
        let controlWidth = Self.renderedControlWidth(totalSessionCount: sessionKeys.count, maxWidth: expandedWidthBudget)
        let startIndex = scrubStartIndex ?? Self.scrubStartCandidateIndex(
            startLocationX: value.startLocation.x,
            controlWidth: controlWidth,
            visibleDotIndices: visibleDotIndices,
            fallbackIndex: activeIndex
        )
        beginScrubIfNeeded(startIndex: startIndex)
        let candidate = Self.scrubCandidateIndex(
            sessionCount: sessionKeys.count,
            startIndex: startIndex,
            translationWidth: value.translation.width
        )
        updateScrubCandidate(index: candidate)
    }

    private func updateScrubCandidate(index: Int) {
        guard sessionKeys.indices.contains(index) else { return }
        guard scrubCandidateIndex != index else { return }
        scrubCandidateIndex = index
        onScrubPreview(sessionKeys[index])
    }

    private func commitScrub() {
        guard let index = scrubCandidateIndex, sessionKeys.indices.contains(index) else {
            cancelScrub()
            return
        }
        let sessionKey = sessionKeys[index]
        resetScrubState()
        onScrubCommit(sessionKey)
    }

    private func cancelScrub() {
        resetScrubState()
        onScrubCancel()
    }

    private func cancelScrubIfNeeded() {
        guard scrubStartIndex != nil || scrubCandidateIndex != nil else { return }
        cancelScrub()
    }

    private func resetScrubState() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            scrubStartIndex = nil
            scrubCandidateIndex = nil
        }
    }

    private var dotRow: some View {
        HStack(spacing: 7) {
            if showsLeadingOverflow {
                Circle()
                    .fill(StreamDotColor.inactive(colorScheme: colorScheme))
                    .frame(width: 4, height: 4)
            }
            ForEach(visibleDotIndices, id: \.self) { index in
                let sessionKey = sessionKeys[index]
                let isActive = index == activeIndex
                let isCandidate = index == scrubCandidateIndex
                let dotState = dotStatesBySession[sessionKey] ?? .inactive
                let scale = Self.scrubMagnificationScale(
                    dotIndex: index,
                    candidateIndex: scrubCandidateIndex
                )
                let verticalOffset = Self.scrubMagnificationVerticalOffset(scale: scale)
                Circle()
                    .fill(
                        StreamDotColor.resolve(
                            isActive: isActive,
                            dotState: dotState,
                            colorScheme: colorScheme
                        )
                    )
                    .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                    .overlay {
                        if isCandidate && !isActive {
                            Circle()
                                .stroke(StreamDotColor.activeGlow(colorScheme: colorScheme).opacity(0.85), lineWidth: 1.2)
                                .scaleEffect(1.16)
                        }
                    }
                    .scaleEffect(scale)
                    .offset(y: verticalOffset)
                    .zIndex(scale)
                    .shadow(
                        color: (isActive || isCandidate) ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                        radius: (isActive || isCandidate) ? StreamDotColor.activeOuterGlowRadius(colorScheme: colorScheme) : 0
                    )
                    .shadow(
                        color: (isActive || isCandidate) ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                        radius: (isActive || isCandidate) ? StreamDotColor.activeInnerGlowRadius(colorScheme: colorScheme) : 0
                    )
            }
            if showsTrailingOverflow {
                Circle()
                    .fill(StreamDotColor.inactive(colorScheme: colorScheme))
                    .frame(width: 4, height: 4)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .center)
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(warningBloomColor.opacity(Self.unreadEdgeBloomOpacity(colorScheme: colorScheme)))
                .frame(width: 18, height: 16)
        }
        .frame(width: 20, height: 18)
        .offset(x: edge == .leading ? -4 : 4)
    }

    static func scrubStartCandidateIndex(
        startLocationX: CGFloat,
        controlWidth: CGFloat,
        visibleDotIndices: [Int],
        fallbackIndex: Int
    ) -> Int {
        guard let first = visibleDotIndices.first, !visibleDotIndices.isEmpty else {
            return fallbackIndex
        }
        guard visibleDotIndices.count > 1 else { return first }
        let usableWidth = max(1, controlWidth - (horizontalPadding * 2))
        let normalized = min(1, max(0, (startLocationX - horizontalPadding) / usableWidth))
        let visibleOffset = Int((normalized * CGFloat(visibleDotIndices.count - 1)).rounded())
        return visibleDotIndices[min(max(0, visibleOffset), visibleDotIndices.count - 1)]
    }

    static func scrubCandidateIndex(
        sessionCount: Int,
        startIndex: Int,
        translationWidth: CGFloat
    ) -> Int {
        guard sessionCount > 0 else { return 0 }
        let step = dotDiameter + dotSpacing
        let delta = Int((translationWidth / step).rounded())
        return min(max(0, startIndex + delta), sessionCount - 1)
    }

    static func scrubMagnificationScale(dotIndex: Int, candidateIndex: Int?) -> CGFloat {
        guard let candidateIndex else { return 1 }
        let distance = CGFloat(abs(dotIndex - candidateIndex))
        let radius: CGFloat = 3
        guard distance < radius else { return 1 }
        let falloff = exp(-pow(distance / 0.9, 2))
        return 1 + (1.55 * falloff)
    }

    static func scrubMagnificationVerticalOffset(scale: CGFloat) -> CGFloat {
        guard scale > 1 else { return 0 }
        return -(scale - 1) * 5
    }
}
