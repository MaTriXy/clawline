//
//  ChatLayoutCoordinator.swift
//  Clawline
//
//  Created by Codex on 2/1/26.
//

import Observation
import UIKit

struct ChatLayoutInputs: Equatable {
    let keyboardHeight: CGFloat
    let keyboardVisible: Bool
    let isInputFocused: Bool
    let keyboardAnimationDuration: TimeInterval
    let keyboardAnimationCurve: UIView.AnimationCurve
    let safeAreaBottom: CGFloat
    let usesExternalKeyboardInsets: Bool
}

struct ChatLayoutMetrics: Equatable {
    let belowBarGap: CGFloat
    let flowGap: CGFloat
    let containerPadding: CGFloat
}

struct ChatLayoutTransition: Equatable {
    let animationDuration: TimeInterval
    let animationOptions: UIView.AnimationOptions
    let animateInsets: Bool
    let animateBarPosition: Bool
    let scrollAction: ScrollAction
    let keyboardDelta: CGFloat
}

enum ScrollAction: Equatable {
    case none
    case scrollToBottom(animated: Bool)
    case adjustOffset(delta: CGFloat)
}

struct ChatLayoutKey: Equatable {
    let revision: Int
    let keyboardHeightBucket: Int
    let inputHeightBucket: Int
    let safeAreaBottomBucket: Int
    let isInputFocused: Bool
    let keyboardVisible: Bool
    let belowBarGapBucket: Int
    let flowGapBucket: Int
    let containerPaddingBucket: Int

    init(revision: Int,
         keyboardHeight: CGFloat,
         inputHeight: CGFloat,
         safeAreaBottom: CGFloat,
         isInputFocused: Bool,
         keyboardVisible: Bool,
         belowBarGap: CGFloat,
         flowGap: CGFloat,
         containerPadding: CGFloat) {
        func bucket(_ value: CGFloat) -> Int { Int((value / 0.5).rounded()) }
        self.revision = revision
        self.keyboardHeightBucket = bucket(keyboardHeight)
        self.inputHeightBucket = bucket(inputHeight)
        self.safeAreaBottomBucket = bucket(safeAreaBottom)
        self.isInputFocused = isInputFocused
        self.keyboardVisible = keyboardVisible
        self.belowBarGapBucket = bucket(belowBarGap)
        self.flowGapBucket = bucket(flowGap)
        self.containerPaddingBucket = bucket(containerPadding)
    }
}

protocol KeyboardPinnedContainerViewProtocol: AnyObject {
    var containerView: UIView { get }
    var barHeight: CGFloat { get }
    func setDesiredBottomGap(_ gap: CGFloat, isKeyboardVisible: Bool)
    func setOnBarHeightChange(_ handler: @escaping (CGFloat) -> Void)
}

@MainActor
@Observable
final class ChatLayoutCoordinator {
    @ObservationIgnored private var barView: KeyboardPinnedContainerViewProtocol?
    @ObservationIgnored private var listViews: [ChatStream: WeakBox<MessageFlowCollectionViewController>] = [:]
    @ObservationIgnored private var activeStream: ChatStream = .personal
    @ObservationIgnored private var latestInputs: ChatLayoutInputs?
    @ObservationIgnored private var latestMetrics: ChatLayoutMetrics?
    @ObservationIgnored private var previousInputs: ChatLayoutInputs?
    @ObservationIgnored private var lastAppliedInset: CGFloat = 0
    @ObservationIgnored private var lastAppliedBarHeight: CGFloat = 0
    @ObservationIgnored private var barHeightCache: CGFloat = 0
    @ObservationIgnored private var barHeightCandidate: CGFloat = 0
    @ObservationIgnored private var barHeightCandidateApplyIndex: Int = 0
    @ObservationIgnored private var hasStableBarHeight: Bool = false
    @ObservationIgnored private var applyIndex: Int = 0
    @ObservationIgnored private var isApplyingTransition: Bool = false
    @ObservationIgnored private var pendingInputs: (ChatLayoutInputs, ChatLayoutMetrics)?
    @ObservationIgnored private var didApplyThisTick: Bool = false
    @ObservationIgnored private var pendingFallback: Bool = false
    @ObservationIgnored private var generation: Int = 0

    func registerBarView(_ view: KeyboardPinnedContainerViewProtocol) {
        dispatchPrecondition(condition: .onQueue(.main))
        barView = view
        applyTransitionIfPossible(reason: "registerBarView")
    }

    func registerListView(_ view: MessageFlowCollectionViewController, channel: ChatStream) {
        dispatchPrecondition(condition: .onQueue(.main))
        listViews[channel] = WeakBox(view)
        applyLatestInset(to: view, isActive: channel == activeStream)
    }

    func setActiveStream(_ channel: ChatStream) {
        dispatchPrecondition(condition: .onQueue(.main))
        activeStream = channel
    }

    func updateInputs(_ inputs: ChatLayoutInputs, metrics: ChatLayoutMetrics) {
        dispatchPrecondition(condition: .onQueue(.main))
        latestInputs = inputs
        latestMetrics = metrics
    }

    func markInputsChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
        didApplyThisTick = false
        guard !pendingFallback else { return }
        pendingFallback = true
        RunLoop.main.perform { [weak self] in
            guard let self else { return }
            self.pendingFallback = false
            if !self.didApplyThisTick {
                self.applyTransitionIfPossible(reason: "fallback")
            }
        }
    }

    func applyTransitionIfPossible(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        didApplyThisTick = true
        cleanupListRefs()
        guard let barView, let inputs = latestInputs, let metrics = latestMetrics else {
            if let inputs = latestInputs, let metrics = latestMetrics {
                pendingInputs = (inputs, metrics)
            }
            return
        }
        if isApplyingTransition {
            pendingInputs = (inputs, metrics)
            DispatchQueue.main.async { [weak self] in
                self?.applyTransitionIfPossible(reason: "reentrant")
            }
            return
        }
        applyIndex += 1
        let wasUsingBootstrap = !hasStableBarHeight
        let currentBarHeight = currentInsetBarHeight(for: inputs, metrics: metrics)
        let isUsingBootstrap = !hasStableBarHeight
        let didJustStabilize = wasUsingBootstrap && !isUsingBootstrap
        let targetInset = targetBottomInset(for: inputs, metrics: metrics, barHeight: currentBarHeight)
        let previousInset = lastAppliedInset
        let list = activeListView()
        let wasNearBottom = list?.isNearBottom(extraMargin: max(24, previousInset)) ?? false
        let keyboardJustAppeared = inputs.isInputFocused && !(previousInputs?.isInputFocused ?? false)
        let transition = computeTransition(
            inputs: inputs,
            previousInputs: previousInputs,
            previousInset: previousInset,
            targetInset: targetInset,
            barHeight: currentBarHeight,
            previousBarHeight: lastAppliedBarHeight,
            isUserInteracting: list?.isUserInteracting ?? false,
            didJustStabilize: didJustStabilize,
            wasNearBottom: wasNearBottom,
            keyboardJustAppeared: keyboardJustAppeared
        )
        previousInputs = inputs
        lastAppliedBarHeight = currentBarHeight
        isApplyingTransition = transition.animateInsets || transition.animateBarPosition
        lastAppliedInset = targetInset
        generation += 1
        let currentGeneration = generation

        let applyChanges = { [weak self] in
            guard let self else { return }
            barView.setDesiredBottomGap(metrics.belowBarGap, isKeyboardVisible: inputs.keyboardVisible)
            barView.containerView.layoutIfNeeded()
            for list in self.listViews.values.compactMap({ $0.value }) {
                list.setBottomInset(targetInset)
            }
        }

        if transition.animateInsets || transition.animateBarPosition {
            UIView.animate(
                withDuration: transition.animationDuration,
                delay: 0,
                options: [transition.animationOptions, .beginFromCurrentState]
            ) {
                applyChanges()
            } completion: { [weak self] _ in
                guard let self else { return }
                guard self.generation == currentGeneration else { return }
                self.isApplyingTransition = false
                self.performScrollAction(transition.scrollAction)
                if let pending = self.pendingInputs {
                    self.pendingInputs = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.updateInputs(pending.0, metrics: pending.1)
                        self?.applyTransitionIfPossible(reason: "pendingCompletion")
                    }
                }
            }
        } else {
            applyChanges()
            performScrollAction(transition.scrollAction)
            isApplyingTransition = false
        }
    }

    func computeTransition(
        inputs: ChatLayoutInputs,
        previousInputs: ChatLayoutInputs?,
        previousInset: CGFloat,
        targetInset: CGFloat,
        barHeight: CGFloat,
        previousBarHeight: CGFloat,
        isUserInteracting: Bool,
        didJustStabilize: Bool,
        wasNearBottom: Bool,
        keyboardJustAppeared: Bool
    ) -> ChatLayoutTransition {
        let keyboardDelta = inputs.keyboardHeight - (previousInputs?.keyboardHeight ?? 0)
        let keyboardChanged = abs(keyboardDelta) > 0.5
        let barHeightDelta = barHeight - previousBarHeight
        let barHeightChanged = abs(barHeightDelta) > 0.5
        let duration: TimeInterval
        let options = animationOptions(from: inputs.keyboardAnimationCurve)
        if didJustStabilize {
            duration = inputs.keyboardVisible
                ? (inputs.keyboardAnimationDuration > 0 ? inputs.keyboardAnimationDuration : 0.3)
                : 0
        } else if keyboardChanged {
            duration = inputs.keyboardAnimationDuration > 0 ? inputs.keyboardAnimationDuration : 0.3
        } else if barHeightChanged {
            duration = 0.3
        } else {
            duration = 0
        }
        let animate = duration > 0
        let isInsetDecreasing = targetInset < previousInset
        let insetDelta = targetInset - previousInset
        let scrollAction: ScrollAction
        if isUserInteracting {
            scrollAction = .none
        } else if keyboardJustAppeared && wasNearBottom {
            scrollAction = .scrollToBottom(animated: false)
        } else if !isInsetDecreasing {
            if wasNearBottom {
                scrollAction = .scrollToBottom(animated: false)
            } else if abs(insetDelta) > 0.5 {
                scrollAction = .adjustOffset(delta: insetDelta)
            } else {
                scrollAction = .none
            }
        } else {
            // #15: When the input bar shrinks (multi-line -> single-line) the bottom inset decreases.
            // If we were pinned near the bottom, keep the bottom anchored by adjusting contentOffset
            // by the inset delta; otherwise the scroll view can appear to have extra "bottom padding".
            if wasNearBottom && abs(insetDelta) > 0.5 {
                scrollAction = .adjustOffset(delta: insetDelta)
            } else {
                scrollAction = .none
            }
        }
        return ChatLayoutTransition(
            animationDuration: duration,
            animationOptions: options,
            animateInsets: animate,
            animateBarPosition: animate,
            scrollAction: scrollAction,
            keyboardDelta: keyboardDelta
        )
    }

    func updateBarHeight(_ height: CGFloat) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard abs(barHeightCache - height) > 0.5 else { return }
        barHeightCache = height
    }

    private func currentInsetBarHeight(for inputs: ChatLayoutInputs, metrics: ChatLayoutMetrics) -> CGFloat {
        let candidate = barHeightCache
        if candidate > 0.5 {
            if abs(candidate - barHeightCandidate) < 0.5 {
                if applyIndex - barHeightCandidateApplyIndex >= 1 {
                    hasStableBarHeight = true
                }
            } else {
                barHeightCandidate = candidate
                barHeightCandidateApplyIndex = applyIndex
            }
        }
        if hasStableBarHeight {
            return barHeightCache
        }
        return MessageInputBarMetrics.minInputBarHeight
    }

    private func targetBottomInset(for inputs: ChatLayoutInputs, metrics: ChatLayoutMetrics, barHeight: CGFloat) -> CGFloat {
        let baseInset = metrics.belowBarGap + barHeight + metrics.flowGap - metrics.containerPadding
        guard !inputs.usesExternalKeyboardInsets else { return baseInset }
        return baseInset + inputs.keyboardHeight
    }

    private func animationOptions(from curve: UIView.AnimationCurve) -> UIView.AnimationOptions {
        switch curve {
        case .easeInOut: return .curveEaseInOut
        case .easeIn: return .curveEaseIn
        case .easeOut: return .curveEaseOut
        case .linear: return .curveLinear
        @unknown default: return .curveEaseInOut
        }
    }

    private func activeListView() -> MessageFlowCollectionViewController? {
        listViews[activeStream]?.value
    }

    private func applyLatestInset(to view: MessageFlowCollectionViewController, isActive: Bool) {
        guard let inputs = latestInputs, let metrics = latestMetrics, let barView else { return }
        let barHeight = currentInsetBarHeight(for: inputs, metrics: metrics)
        let targetInset = targetBottomInset(for: inputs, metrics: metrics, barHeight: barHeight)
        let previousInset = view.currentBottomInset
        view.setBottomInset(targetInset)
        if isActive {
            let delta = targetInset - previousInset
            if abs(delta) > 0.5 {
                view.adjustContentOffsetForBottomInsetChange(delta: delta)
            }
        }
        barView.setDesiredBottomGap(metrics.belowBarGap, isKeyboardVisible: inputs.keyboardVisible)
        barView.containerView.layoutIfNeeded()
        lastAppliedInset = targetInset
        lastAppliedBarHeight = barHeight
    }

    private func performScrollAction(_ action: ScrollAction) {
        guard let list = activeListView() else { return }
        switch action {
        case .none:
            break
        case .scrollToBottom(let animated):
            list.scheduleScrollToBottom(animated: animated)
        case .adjustOffset(let delta):
            list.adjustContentOffsetForBottomInsetChange(delta: delta)
        }
    }

    private func cleanupListRefs() {
        listViews = listViews.filter { $0.value.value != nil }
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) {
        self.value = value
    }
}
