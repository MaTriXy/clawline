//
//  StreamPageDotsViewTests.swift
//  ClawlineTests
//
//  Created by Codex on 4/1/26.
//

import Testing
import CoreGraphics
import SwiftUI
import UIKit
@testable import Clawline

@MainActor
struct StreamPageDotsViewTests {

    @Test("Expanded indicator width allows more visible dots than the collapsed cap")
    func expandedIndicatorShowsMoreDots() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )

        #expect(visibleCount > 11)
    }

    @Test("Expanded indicator fills the available width envelope when it can reveal more dots")
    func expandedIndicatorUsesAvailableWidthEnvelope() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )
        let targetWidth = StreamPageDotsView.targetControlWidth(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )
        let expectedWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: visibleCount,
            includesOverflowIndicators: visibleCount < 40
        )

        #expect(targetWidth != nil)
        #expect(targetWidth == expectedWidth)
    }

    @Test("Expanded indicator stays collapsed when the width budget cannot reveal more dots")
    func expandedIndicatorSkipsWidthExpansionWithoutAdditionalCapacity() {
        let collapsedWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: 11,
            includesOverflowIndicators: true
        )
        let targetWidth = StreamPageDotsView.targetControlWidth(
            totalSessionCount: 40,
            maxWidth: collapsedWidth
        )

        #expect(targetWidth == nil)
    }

    @Test("Collapsed indicator keeps the legacy visible-dot cap")
    func collapsedIndicatorKeepsLegacyCap() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: nil
        )

        #expect(visibleCount == 11)
    }

    @Test("Rendered indicator width matches the visible control width")
    func renderedControlWidthMatchesVisibleControlWidth() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )
        let expectedWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: visibleCount,
            includesOverflowIndicators: visibleCount < 40
        )

        #expect(
            StreamPageDotsView.renderedControlWidth(
                totalSessionCount: 40,
                maxWidth: CGFloat(640)
            ) == expectedWidth
        )
    }

    @Test("T257: scrub start maps touch position through the visible dot window")
    func scrubStartMapsTouchPositionThroughVisibleWindow() {
        let startIndex = StreamPageDotsView.scrubStartCandidateIndex(
            startLocationX: 95,
            controlWidth: 190,
            visibleDotIndices: Array(15...25),
            fallbackIndex: 20
        )
        let virtualIndex = StreamPageDotsView.scrubStartVirtualIndex(
            startLocationX: 95,
            controlWidth: 190,
            visibleDotIndices: Array(15...25),
            fallbackIndex: 20
        )

        #expect(startIndex == 20)
        #expect(abs(virtualIndex - 20) < 0.001)
    }

    @Test("T257: scrub translation can reach dots truncated beyond both edges")
    func scrubTranslationCanReachTruncatedEdges() {
        let rightEdge = StreamPageDotsView.scrubCandidateIndex(
            sessionCount: 40,
            startIndex: 20,
            translationWidth: 19 * 14
        )
        let leftEdge = StreamPageDotsView.scrubCandidateIndex(
            sessionCount: 40,
            startIndex: 20,
            translationWidth: -20 * 14
        )
        let rightVirtualEdge = StreamPageDotsView.scrubVirtualIndex(
            sessionCount: 40,
            startVirtualIndex: 20,
            startLocationX: 95,
            currentLocationX: 95 + (19 * 14)
        )
        let leftVirtualEdge = StreamPageDotsView.scrubVirtualIndex(
            sessionCount: 40,
            startVirtualIndex: 20,
            startLocationX: 95,
            currentLocationX: 95 - (20 * 14)
        )

        #expect(rightEdge == 39)
        #expect(leftEdge == 0)
        #expect(rightVirtualEdge == 39)
        #expect(leftVirtualEdge == 0)
    }

    @Test("T257: scrub haptic fires only when candidate changes after initial highlight")
    func scrubHapticFiresOnlyForCandidateChangesAfterInitialHighlight() {
        #expect(StreamPageDotsView.shouldEmitScrubCandidateHaptic(previousIndex: nil, candidateIndex: 10) == false)
        #expect(StreamPageDotsView.shouldEmitScrubCandidateHaptic(previousIndex: 10, candidateIndex: 10) == false)
        #expect(StreamPageDotsView.shouldEmitScrubCandidateHaptic(previousIndex: 10, candidateIndex: 11) == true)
    }

    @Test("T257: scrub candidate haptic strength follows existing dot visual state")
    func scrubCandidateHapticStrengthFollowsDotVisualState() {
        #expect(StreamPageDotsView.scrubCandidateHapticStyle(isActive: false, dotState: .inactive) == .light)
        #expect(StreamPageDotsView.scrubCandidateHapticStyle(isActive: true, dotState: .inactive) == .strong)
        #expect(StreamPageDotsView.scrubCandidateHapticStyle(isActive: false, dotState: .unread) == .strong)
        #expect(StreamPageDotsView.scrubCandidateHapticStyle(isActive: false, dotState: .userTail) == .strong)
    }

    @Test("T257: scrub metrics temporarily widen dense dot lists")
    func scrubMetricsTemporarilyWidenDenseDotLists() {
        let rest = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: false
        )
        let active = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: true
        )

        #expect(rest.scrubFieldWidth == 190)
        #expect(active.scrubFieldWidth > rest.scrubFieldWidth)
        #expect(active.magnificationRadius > rest.magnificationRadius)
        #expect(active.magnificationRadius > 9)
        #expect(active.maximumScale > rest.maximumScale)
    }

    @Test("T257: scrub magnification falls off smoothly across doubled side area")
    func scrubMagnificationFallsOffWithDistance() {
        let metrics = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: true
        )
        let primary = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10, metrics: metrics)
        let neighbor = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10, metrics: metrics)
        let outer = StreamPageDotsView.scrubMagnificationScale(dotIndex: 12, virtualIndex: 10, metrics: metrics)
        let farParticipant = StreamPageDotsView.scrubMagnificationScale(dotIndex: 18, virtualIndex: 10, metrics: metrics)
        let outside = StreamPageDotsView.scrubMagnificationScale(dotIndex: 20, virtualIndex: 10, metrics: metrics)

        #expect(primary > neighbor)
        #expect(neighbor > outer)
        #expect(outer > farParticipant)
        #expect(farParticipant > outside)
        #expect(outside == 1)
        #expect(primary > 3.0)
        #expect(neighbor > 2.8)
        #expect(outer > 2.4)
        #expect(primary - neighbor > 0.15)
    }

    @Test("T257: scrub magnification tracks continuous finger position")
    func scrubMagnificationTracksContinuousFingerPosition() {
        let metrics = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: true
        )
        let leftBiasDot = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10.25, metrics: metrics)
        let leftBiasNeighbor = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10.25, metrics: metrics)
        let midpointLeft = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10.5, metrics: metrics)
        let midpointRight = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10.5, metrics: metrics)
        let rightBiasDot = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10.75, metrics: metrics)
        let rightBiasNeighbor = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10.75, metrics: metrics)

        #expect(leftBiasDot > leftBiasNeighbor)
        #expect(abs(midpointLeft - midpointRight) < 0.001)
        #expect(rightBiasNeighbor > rightBiasDot)
    }

    @Test("T257: scrub magnification lifts large dots out of the dock")
    func scrubMagnificationLiftsLargeDotsOutOfDock() {
        let metrics = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: true
        )
        let primary = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10, metrics: metrics)
        let neighbor = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10, metrics: metrics)

        #expect(StreamPageDotsView.scrubMagnificationVerticalOffset(scale: primary) < -15)
        #expect(StreamPageDotsView.scrubMagnificationVerticalOffset(scale: neighbor) < 0)
        #expect(StreamPageDotsView.scrubMagnificationVerticalOffset(scale: 1) == 0)
    }

    @Test("T257: scrub lifts the dot group above the finger")
    func scrubLiftsDotGroupAboveFinger() {
        #expect(StreamPageDotsView.scrubGroupVerticalOffset(isScrubbing: true) == -20)
        #expect(StreamPageDotsView.scrubGroupVerticalOffset(isScrubbing: false) == 0)
    }

    @Test("Popup route controller owns popup search and track picker surfaces")
    func popupRouteControllerOwnsPopupAndTrackPickerSurfaces() {
        let routeController = StreamPopupRouteController()

        #expect(routeController.route == .closed)
        #expect(routeController.isPopupPresented == false)
        #expect(routeController.isTrackPickerPresented == false)

        routeController.openPopup(focusSearch: false)

        #expect(routeController.route == .popup(searchFocus: .none))
        #expect(routeController.isPopupPresented)
        #expect(routeController.popupSearchFocusRequestID == nil)

        routeController.openPopup(focusSearch: true)
        let initialSearchFocusRequestID = routeController.popupSearchFocusRequestID

        #expect(initialSearchFocusRequestID != nil)
        if let initialSearchFocusRequestID {
            #expect(routeController.route == .popup(searchFocus: .request(id: initialSearchFocusRequestID)))
        }

        routeController.consumeSearchFocusRequest()

        #expect(routeController.route == .popup(searchFocus: .none))
        #expect(routeController.popupSearchFocusRequestID == nil)

        routeController.presentTrackPicker()

        #expect(routeController.route == .trackPicker)
        #expect(routeController.isPopupPresented == false)
        #expect(routeController.isTrackPickerPresented)

        routeController.dismissTrackPicker()

        #expect(routeController.route == .closed)
    }

    @Test("Active dots override unread styling")
    func activeKindWinsPrecedence() {
        let kind = StreamDotColor.kind(
            isActive: true,
            dotState: .unread
        )

        #expect(kind == .active)
    }

    @Test("User-tail dots use the dedicated gold state when not active or unread")
    func userTailKindIsDistinct() {
        let kind = StreamDotColor.kind(
            isActive: false,
            dotState: .userTail
        )

        #expect(kind == .userTail)
    }

    @Test("Active dots use the brighter avatar highlight green")
    func activeDotsUseAvatarHighlightGreen() {
        let color = StreamDotColor.resolve(
            isActive: true,
            dotState: .inactive,
            colorScheme: .light
        )

        #expect(Self.rgb(color) == RGB(red: 0.48, green: 0.68, blue: 0.48))
    }

    @Test("Unread dots keep the unread indicator color")
    func unreadDotsUseUnreadIndicatorColor() {
        let color = StreamDotColor.resolve(
            isActive: false,
            dotState: .unread,
            colorScheme: .light
        )

        #expect(Self.rgb(color) == Self.rgb(ChatFlowTheme.unreadIndicator(.light)))
    }

    @Test("Offscreen unread edge bloom is blurred behind the glass")
    func offscreenUnreadEdgeBloomUsesBlur() {
        #expect(StreamPageDotsView.unreadEdgeBloomOpacity(colorScheme: .light) == 0.40)
        #expect(StreamPageDotsView.unreadEdgeBloomOpacity(colorScheme: .dark) == 0.40)
        #expect(StreamPageDotsView.unreadEdgeBloomBlurRadius(colorScheme: .light) == 4.0)
        #expect(StreamPageDotsView.unreadEdgeBloomBlurRadius(colorScheme: .dark) == 4.5)
    }

    private struct RGB: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    private static func rgb(_ color: Color) -> RGB {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(
            red: rounded(red),
            green: rounded(green),
            blue: rounded(blue)
        )
    }

    private static func rounded(_ value: CGFloat) -> CGFloat {
        (value * 100).rounded() / 100
    }
}
