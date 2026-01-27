//
//  MessageFlowCollectionView.swift
//  Clawline
//
//  Created by Codex on 1/18/26.
//

import OSLog
import SwiftUI
import UIKit

@MainActor
struct MessageFlowCollectionView: UIViewControllerRepresentable {
    var viewModel: ChatViewModel
    var topInset: CGFloat
    var bottomInset: CGFloat
    var isCompact: Bool
    var isKeyboardVisible: Bool
    var onExpand: ((Message) -> Void)?
    /// Optional channel override - if provided, shows messages for this channel instead of activeChannel
    var channel: ChatChannelType?
    @Environment(\.colorScheme) private var colorScheme

    func makeUIViewController(context: Context) -> MessageFlowCollectionViewController {
        let controller = MessageFlowCollectionViewController()
        controller.loadViewIfNeeded()
        let isDark = colorScheme == .dark
        controller.update(
            viewModel: viewModel,
            isCompact: isCompact,
            topInset: topInset,
            bottomInset: bottomInset,
            isKeyboardVisible: isKeyboardVisible,
            onExpand: onExpand,
            channel: channel,
            isDark: isDark
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: MessageFlowCollectionViewController, context: Context) {
        let isDark = colorScheme == .dark
        uiViewController.update(
            viewModel: viewModel,
            isCompact: isCompact,
            topInset: topInset,
            bottomInset: bottomInset,
            isKeyboardVisible: isKeyboardVisible,
            onExpand: onExpand,
            channel: channel,
            isDark: isDark
        )
    }
}

final class MessageFlowCollectionViewController: UIViewController, UICollectionViewDelegateFlowLayout {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
    private var collectionView: UICollectionView!
    private var channelOverride: ChatChannelType?
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var flowLayout: MessageFlowLayout!
    private let uiKitBubbleSizer = MessageBubbleUIKitView()
    private var currentIsDark: Bool = false

    private var messagesById: [String: Message] = [:]
    private var fingerprints: [String: Int] = [:]
    private var lastMeasuredSizes: [String: CGSize] = [:]
    private var sizeCache: [String: CGSize] = [:]
    private var truncationStates: [String: TruncationState] = [:]
    private var pendingReconfigureIds: Set<String> = []
    private var dirtySizeIds: Set<String> = []
    private var invalidationScheduled = false
    private var lastMessageId: String?
    private var viewModel: ChatViewModel?
    private var isCompact: Bool = true
    private var topInset: CGFloat = 0
    private var bottomInset: CGFloat = 0
    private var isKeyboardVisible: Bool = false
    private var lastBoundsSize: CGSize = .zero
    private var forceReconfigureAll = false
    private var wasShowingTypingIndicator = false
    private var onExpand: ((Message) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        configureCollectionView()
        configureDataSource()
        setupKeyboardTracking()

        // currentIsDark will be set by the first update() call from SwiftUI
        // which passes the colorScheme environment value
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Extend the collection view to fill the entire screen, ignoring safe areas.
        // SwiftUI's UIViewControllerRepresentable doesn't respect .ignoresSafeArea() for UIKit views,
        // so we manually extend the collection view to window bounds.
        if let window = view.window {
            let windowBounds = window.bounds
            let viewOriginInWindow = view.convert(CGPoint.zero, to: window)

            // Calculate frame that extends from top of screen to bottom
            let extendedFrame = CGRect(
                x: 0,
                y: -viewOriginInWindow.y,
                width: windowBounds.width,
                height: windowBounds.height
            )

            // Only update if significantly different to avoid layout loops
            if abs(collectionView.frame.minY - extendedFrame.minY) > 1 ||
               abs(collectionView.frame.height - extendedFrame.height) > 1 {
                collectionView.frame = extendedFrame
            }
        }

        // Handle bounds size changes
        let size = collectionView.bounds.size
        guard size != .zero, size != lastBoundsSize else { return }
        lastBoundsSize = size
        forceReconfigureAll = true
        updateLayout()
        if let viewModel {
            update(viewModel: viewModel, isCompact: isCompact, topInset: topInset, bottomInset: bottomInset, isKeyboardVisible: isKeyboardVisible)
        }
    }

    private func setupKeyboardTracking() {
        // Observe keyboard frame changes to adjust content inset.
        // This is the standard UIKit pattern for scroll view keyboard avoidance.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let windowHeight = view.window?.windowScene?.screen.bounds.height
            ?? view.window?.bounds.height
            ?? frame.maxY
        let keyboardHeight = max(0, windowHeight - frame.minY)
        let keyboardJustAppeared = keyboardHeight > 0 && currentKeyboardHeight == 0
        let previousKeyboardHeight = currentKeyboardHeight
        currentKeyboardHeight = keyboardHeight

        // Update content inset to account for keyboard
        applyBottomContentInset()

        // Adjust scroll position when keyboard height changes
        let delta = keyboardHeight - previousKeyboardHeight
        if abs(delta) > 1 {
            adjustContentOffsetForBottomInsetChange(delta: delta)
        }

        // Scroll to keep content visible when keyboard appears
        if keyboardJustAppeared && isNearBottom(extraMargin: max(24, baseBottomInset)) {
            scrollToBottom(animated: true)
        }
    }

    private var baseBottomInset: CGFloat = 0
    private var currentKeyboardHeight: CGFloat = 0
    private var pendingScrollToBottomAttempts: Int = 0
    private var pendingScrollToBottomAnimated: Bool = false

    private func syncKeyboardHeightIfNeeded(isKeyboardVisible: Bool) {
        guard isKeyboardVisible, currentKeyboardHeight == 0 else { return }
        let height = view.keyboardLayoutGuide.layoutFrame.height
        guard height > 0.5 else { return }
        let previous = currentKeyboardHeight
        currentKeyboardHeight = height
        applyBottomContentInset()
        let delta = height - previous
        if abs(delta) > 1 {
            adjustContentOffsetForBottomInsetChange(delta: delta)
        }
    }

    /// Single source of truth for setting bottom content inset.
    /// Combines baseBottomInset (input bar) with currentKeyboardHeight when keyboard is visible.
    private func applyBottomContentInset() {
        let totalBottomInset = baseBottomInset + currentKeyboardHeight
        collectionView.contentInset.bottom = totalBottomInset
        collectionView.verticalScrollIndicatorInsets.bottom = totalBottomInset
    }

    private func scheduleScrollToBottom(animated: Bool, attempts: Int = 2) {
        pendingScrollToBottomAttempts = max(pendingScrollToBottomAttempts, attempts)
        pendingScrollToBottomAnimated = pendingScrollToBottomAnimated || animated
        performPendingScrollToBottomIfNeeded()
    }

    private func performPendingScrollToBottomIfNeeded() {
        guard pendingScrollToBottomAttempts > 0 else { return }
        let animated = pendingScrollToBottomAnimated
        pendingScrollToBottomAttempts -= 1
        collectionView.layoutIfNeeded()
        scrollToBottom(animated: animated)
        if pendingScrollToBottomAttempts > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.performPendingScrollToBottomIfNeeded()
            }
        } else {
            pendingScrollToBottomAnimated = false
        }
    }

    func update(viewModel: ChatViewModel, isCompact: Bool, topInset: CGFloat, bottomInset: CGFloat, isKeyboardVisible: Bool, onExpand: ((Message) -> Void)? = nil, channel: ChatChannelType? = nil, isDark: Bool? = nil) {
        loadViewIfNeeded()
        self.viewModel = viewModel
        self.channelOverride = channel
        self.onExpand = onExpand

        // Handle appearance change from SwiftUI colorScheme
        if let isDark = isDark, currentIsDark != isDark {
            logger.info("update: appearance changed isDark=\(isDark, privacy: .public)")
            currentIsDark = isDark
            sizeCache.removeAll()
            lastMeasuredSizes.removeAll()
            forceReconfigureAll = true
        }

        let previousBottomInset = self.bottomInset
        let wasNearBottom = isNearBottom(extraMargin: max(24, previousBottomInset))
        let keyboardJustAppeared = isKeyboardVisible && !self.isKeyboardVisible
        let needsLayoutUpdate = forceReconfigureAll
            || self.isCompact != isCompact
            || self.topInset != topInset
            || self.bottomInset != bottomInset
        self.isCompact = isCompact
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.isKeyboardVisible = isKeyboardVisible
        syncKeyboardHeightIfNeeded(isKeyboardVisible: isKeyboardVisible)

        if needsLayoutUpdate {
            updateLayout()
        }

        // Use channel override if provided, otherwise use activeChannel messages
        let messages = channel.map { viewModel.messages(for: $0) } ?? viewModel.messages
        let messageCount = messages.count
        if Set(messages.map(\.id)).count != messageCount {
            logger.info("diffing duplicate ids in viewModel.messages count=\(messageCount, privacy: .public)")
        }
        messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let newFingerprints = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, fingerprint(for: $0)) })
        let removedIds = Set(fingerprints.keys).subtracting(newFingerprints.keys)
        removedIds.forEach { truncationStates.removeValue(forKey: $0) }
        removedIds.forEach { lastMeasuredSizes.removeValue(forKey: $0) }
        removedIds.forEach { sizeCache.removeValue(forKey: $0) }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(messages.map(\.id))

        // Add typing indicator when assistant is typing (server-controlled)
        // Only show on the matching channel page (for paged TabView)
        let effectiveChannel = channel ?? viewModel.activeChannel
        let showTypingIndicator = viewModel.isAssistantTyping && viewModel.typingChannel == effectiveChannel
        let typingIndicatorJustAppeared = showTypingIndicator && !wasShowingTypingIndicator
        let shouldMorph = viewModel.shouldMorphTypingIndicator && wasShowingTypingIndicator
        if showTypingIndicator != wasShowingTypingIndicator {
            logger.info("typing indicator state changed: show=\(showTypingIndicator, privacy: .public) wasShowing=\(self.wasShowingTypingIndicator, privacy: .public)")
        }
        wasShowingTypingIndicator = showTypingIndicator
        if showTypingIndicator {
            snapshot.appendItems([TypingIndicatorCell.itemId])
        }

        let changedIds = needsLayoutUpdate
            ? messages.map(\.id)
            : newFingerprints.compactMap { id, fingerprint in
                fingerprints[id] == fingerprint ? nil : id
            }
        if !changedIds.isEmpty {
            snapshot.reconfigureItems(changedIds)
            flowLayout.invalidateLayout()
            changedIds.forEach { sizeCache.removeValue(forKey: $0) }
            changedIds.forEach { lastMeasuredSizes.removeValue(forKey: $0) }
        }
        forceReconfigureAll = false

        // Animate when morphing from typing indicator to message for smooth transition
        dataSource.apply(snapshot, animatingDifferences: shouldMorph)
        logger.info(
            "diffing apply snapshot count=\(messageCount, privacy: .public) changed=\(changedIds.count, privacy: .public) needsLayout=\(needsLayoutUpdate, privacy: .public) morph=\(shouldMorph, privacy: .public)"
        )
        fingerprints = newFingerprints

        if lastMessageId != messages.last?.id {
            lastMessageId = messages.last?.id
            scheduleScrollToBottom(animated: true)
        } else if typingIndicatorJustAppeared {
            // Scroll to show typing indicator when it appears
            scheduleScrollToBottom(animated: true)
        } else if keyboardJustAppeared && wasNearBottom {
            // When keyboard appears and user was near bottom, scroll to keep bottom visible
            scheduleScrollToBottom(animated: false)
        } else if needsLayoutUpdate {
            if wasNearBottom {
                scheduleScrollToBottom(animated: false)
            } else if previousBottomInset != bottomInset {
                adjustContentOffsetForBottomInsetChange(delta: bottomInset - previousBottomInset)
            }
        }
    }

    private func configureCollectionView() {
        flowLayout = MessageFlowLayout()
        flowLayout.sectionInset = .zero
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.minimumLineSpacing = 0
        flowLayout.estimatedItemSize = .zero

        // Use frame-based layout - we extend to window bounds in viewDidLayoutSubviews
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: flowLayout)
        collectionView.translatesAutoresizingMaskIntoConstraints = true
        collectionView.autoresizingMask = []
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.clipsToBounds = false  // Allow content to render past bounds during scroll
        collectionView.delegate = self
        collectionView.register(MessageBubbleUIKitCell.self, forCellWithReuseIdentifier: MessageBubbleUIKitCell.reuseIdentifier)
        collectionView.register(TypingIndicatorCell.self, forCellWithReuseIdentifier: TypingIndicatorCell.reuseIdentifier)

        view.addSubview(collectionView)
        // Frame will be set in viewDidLayoutSubviews to extend to window bounds
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { [weak self] (collectionView: UICollectionView, indexPath: IndexPath, id: String) in
            guard let self, let viewModel = self.viewModel else { return nil }

            // Handle typing indicator
            if id == TypingIndicatorCell.itemId {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: TypingIndicatorCell.reuseIdentifier,
                    for: indexPath
                ) as? TypingIndicatorCell
                let metrics = ChatFlowTheme.Metrics(isCompact: self.isCompact)
                let channel = viewModel.typingChannel ?? viewModel.activeChannel
                let message = TypingIndicatorCell.makeMessage(channelType: channel)
                let presentation = TypingIndicatorCell.makePresentation(metrics: metrics)
                let sizeClass = MessageFlowRules.sizeClass(for: presentation)
                let maxWidth = self.maxItemWidth(
                    for: sizeClass,
                    message: message,
                    presentation: presentation,
                    metrics: metrics,
                    containerWidth: self.availableContentWidth()
                )
                cell?.configure(
                    message: message,
                    presentation: presentation,
                    isCompact: self.isCompact,
                    maxWidth: maxWidth,
                    isDark: self.currentIsDark
                )
                cell?.startAnimating()
                return cell
            }

            guard let message = self.messagesById[id] else { return nil }
            let metrics = ChatFlowTheme.Metrics(isCompact: self.isCompact)
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MessageBubbleUIKitCell.reuseIdentifier,
                for: indexPath
            ) as? MessageBubbleUIKitCell
            let sizeClass = MessageFlowRules.sizeClass(for: presentation)
            let maxWidth = self.maxItemWidth(
                for: sizeClass,
                message: message,
                presentation: presentation,
                metrics: metrics,
                containerWidth: self.availableContentWidth()
            )
            // Use cached size width for consistent sizing with measurement
            let configureWidth = self.sizeCache[id]?.width ?? maxWidth
            cell?.configure(
                message: message,
                presentation: presentation,
                failureReason: viewModel.failureMessage(for: message.id),
                isCompact: self.isCompact,
                maxWidth: configureWidth,
                isDark: self.currentIsDark,
                onRequestExpand: { [weak self] in
                    guard let self else { return }
                    self.onExpand?(message)
                },
                onRetry: { [weak self] in
                    self?.viewModel?.retryMessage(messageId: message.id)
                }
            )
            return cell
        }
    }

    private func updateLayout() {
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        flowLayout.minimumInteritemSpacing = metrics.flowGap
        flowLayout.minimumLineSpacing = metrics.flowGap
        // Section inset is just for padding - content insets handle safe areas
        flowLayout.sectionInset = UIEdgeInsets(
            top: metrics.containerPadding,
            left: metrics.containerPadding,
            bottom: metrics.containerPadding,
            right: metrics.containerPadding
        )
        // Content insets allow scrolling under safe areas while resting below them
        // Top inset = safe area (status bar) so content can scroll under it
        // Bottom inset = input bar height
        collectionView.contentInset.top = topInset
        collectionView.verticalScrollIndicatorInsets.top = topInset
        baseBottomInset = bottomInset
        applyBottomContentInset()
        lastMeasuredSizes.removeAll()
        sizeCache.removeAll()
        flowLayout.invalidateLayout()
    }

    private func availableContentWidth() -> CGFloat {
        collectionView.bounds.width - flowLayout.sectionInset.left - flowLayout.sectionInset.right
    }

    private func maxItemWidth(for sizeClass: MessageSizeClass,
                              message: Message,
                              presentation: MessagePresentation,
                              metrics: ChatFlowTheme.Metrics,
                              containerWidth: CGFloat) -> CGFloat {
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        let paddedLineWidth = maxLineWidth + metrics.bubblePaddingHorizontal * 2
        let result: CGFloat
        switch sizeClass {
        case .short:
            result = min(containerWidth, paddedLineWidth)
        case .medium:
            result = mediumMaxWidth(
                message: message,
                presentation: presentation,
                metrics: metrics,
                containerWidth: containerWidth
            )
        case .long:
            result = min(containerWidth, paddedLineWidth)
        }
        return result
    }

    private func sizeForItem(at indexPath: IndexPath) -> CGSize {
        guard let id = dataSource.itemIdentifier(for: indexPath), let viewModel else {
            return .zero
        }

        // Handle typing indicator size
        if id == TypingIndicatorCell.itemId {
            let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
            let channel = viewModel.typingChannel ?? viewModel.activeChannel
            let message = TypingIndicatorCell.makeMessage(channelType: channel)
            let presentation = TypingIndicatorCell.makePresentation(metrics: metrics)
            let sizeClass = MessageFlowRules.sizeClass(for: presentation)
            let availableWidth = availableContentWidth()
            let maxWidth = maxItemWidth(
                for: sizeClass,
                message: message,
                presentation: presentation,
                metrics: metrics,
                containerWidth: availableWidth
            )
            let maxWidthOverride = round(maxWidth * 0.0592592)
            return measureUIKitBubbleSize(
                message: message,
                presentation: presentation,
                failureReason: nil,
                maxWidth: maxWidth,
                showsHeader: false,
                paddingScale: 0.0533333,
                minWidthOverride: 4,
                maxWidthOverride: maxWidthOverride,
                minHeightOverride: round(maxWidthOverride * 1.2)
            )
        }

        guard let message = messagesById[id] else {
            return .zero
        }
        if let cached = sizeCache[id] {
            lastMeasuredSizes[id] = cached
            return cached
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let presentation = viewModel.presentation(for: message, metrics: metrics)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let availableWidth = availableContentWidth()
        let maxWidth = maxItemWidth(
            for: sizeClass,
            message: message,
            presentation: presentation,
            metrics: metrics,
            containerWidth: availableWidth
        )
        let failureReason = viewModel.failureMessage(for: message.id)
        let measuredSize = measureUIKitBubbleSize(
            message: message,
            presentation: presentation,
            failureReason: failureReason,
            maxWidth: maxWidth
        )
        sizeCache[id] = measuredSize
        lastMeasuredSizes[id] = measuredSize
        return measuredSize
    }

    private func measureUIKitBubbleSize(message: Message,
                                        presentation: MessagePresentation,
                                        failureReason: String?,
                                        maxWidth: CGFloat,
                                        showsHeader: Bool = true,
                                        paddingScale: CGFloat = 1,
                                        minWidthOverride: CGFloat? = nil,
                                        maxWidthOverride: CGFloat? = nil,
                                        minHeightOverride: CGFloat? = nil) -> CGSize {
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        uiKitBubbleSizer.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth,
            showsHeader: showsHeader,
            paddingScale: paddingScale,
            minWidthOverride: minWidthOverride,
            maxWidthOverride: maxWidthOverride,
            onRequestExpand: nil
        )
        let effectiveMaxWidth = maxWidthOverride ?? maxWidth
        let preferredWidth: CGFloat
        if sizeClass == .short {
            preferredWidth = uiKitBubbleSizer.preferredWidth(maxWidth: effectiveMaxWidth)
        } else {
            preferredWidth = effectiveMaxWidth
        }
        let target = CGSize(width: preferredWidth, height: UIView.layoutFittingCompressedSize.height)
        let measured = uiKitBubbleSizer.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let minWidth: CGFloat = minWidthOverride ?? 120
        var height = max(1, measured.height)
        if let minHeight = minHeightOverride {
            height = max(height, minHeight)
        }
        if failureReason != nil {
            height += 32
        }
        let clamped = CGSize(
            width: min(effectiveMaxWidth, max(minWidth, measured.width)),
            height: height
        )
        return snapToPixel(clamped)
    }

    private func mediumMaxWidth(message: Message,
                                presentation: MessagePresentation,
                                metrics: ChatFlowTheme.Metrics,
                                containerWidth: CGFloat) -> CGFloat {
        // Max width same as .long (typography-based)
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        let maxAllowedWidth = min(containerWidth, maxLineWidth + metrics.bubblePaddingHorizontal * 2)
        // Min width is 1/4 of the effective max (containerWidth on iPhone, typography-based on iPad)
        let minWidth = containerWidth / 4

        // Strategy: minimize width (prefer more lines), only use fewer lines if width < minWidth

        // 1. Try 3 lines - find minimum width
        if let width = findMinimumWidthForLines(
            targetLines: 3,
            message: message,
            presentation: presentation,
            metrics: metrics,
            minWidth: minWidth,
            maxWidth: maxAllowedWidth
        ), width >= minWidth {
            return width
        }

        // 2. Try 2 lines - find minimum width
        if let width = findMinimumWidthForLines(
            targetLines: 2,
            message: message,
            presentation: presentation,
            metrics: metrics,
            minWidth: minWidth,
            maxWidth: maxAllowedWidth
        ), width >= minWidth {
            return width
        }

        // 3. Try single line
        let singleLineWidth = measureSingleLineWidth(
            for: message,
            presentation: presentation,
            metrics: metrics
        )
        if singleLineWidth <= maxAllowedWidth {
            return max(minWidth, singleLineWidth)
        }

        // 4. Fallback - use max allowed width
        return maxAllowedWidth
    }

    private func measureSingleLineWidth(for message: Message,
                                        presentation: MessagePresentation,
                                        metrics: ChatFlowTheme.Metrics) -> CGFloat {
        // UIKit-native single-line width measurement
        let textWidth = MessageBubbleUIKitView.measureSingleLineWidth(
            for: presentation,
            metrics: metrics
        )
        // Add bubble padding
        return textWidth + (metrics.bubblePaddingHorizontal * 2)
    }

    private func findMinimumWidthForLines(targetLines: Int,
                                          message: Message,
                                          presentation: MessagePresentation,
                                          metrics: ChatFlowTheme.Metrics,
                                          minWidth: CGFloat,
                                          maxWidth: CGFloat) -> CGFloat? {
        // Check if target line count is achievable at max width
        let linesAtMax = estimatedLineCount(
            for: message,
            presentation: presentation,
            metrics: metrics,
            atWidth: maxWidth
        )
        guard linesAtMax <= targetLines else {
            return nil  // Can't fit in targetLines even at max width
        }

        // Binary search for minimum width where text fits in targetLines
        var low = minWidth
        var high = maxWidth
        var bestWidth = maxWidth

        while high - low > 4 {  // 4pt precision is sufficient
            let mid = floor((low + high) / 2)
            let lines = estimatedLineCount(
                for: message,
                presentation: presentation,
                metrics: metrics,
                atWidth: mid
            )
            if lines <= targetLines {
                bestWidth = mid
                high = mid
            } else {
                low = mid
            }
        }

        return bestWidth
    }

    private func estimatedLineCount(for message: Message,
                                    presentation: MessagePresentation,
                                    metrics: ChatFlowTheme.Metrics,
                                    atWidth bubbleWidth: CGFloat) -> Int {
        // UIKit-native line count estimation
        MessageBubbleUIKitView.estimatedLineCount(
            for: presentation,
            metrics: metrics,
            atBubbleWidth: bubbleWidth
        )
    }

    private func measureTextHeight(for message: Message,
                                   presentation: MessagePresentation,
                                   sizeClass: MessageSizeClass,
                                   metrics: ChatFlowTheme.Metrics,
                                   maxWidth: CGFloat) -> CGFloat? {
        // UIKit-native text height measurement
        MessageBubbleUIKitView.measureTextHeight(
            for: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth
        )
    }

    private func makeTruncationState(presentation: MessagePresentation,
                                     sizeClass: MessageSizeClass,
                                     textHeight: CGFloat?,
                                     metrics: ChatFlowTheme.Metrics) -> TruncationState {
        guard let textHeight,
              presentation.hasTextualContent else {
            return .none
        }
        let shouldTruncate = MessageFlowRules.shouldTruncate(
            hasTextualParts: true,
            sizeClass: sizeClass,
            isExpanded: false,
            measuredHeight: textHeight,
            metrics: metrics
        )
        let showsControl = MessageFlowRules.shouldShowTruncationControl(
            hasTextualParts: true,
            sizeClass: sizeClass,
            measuredHeight: textHeight,
            metrics: metrics
        )
        guard shouldTruncate || showsControl else {
            return .none
        }
        return TruncationState(
            contentHeight: textHeight,
            shouldTruncate: shouldTruncate,
            showsControl: showsControl
        )
    }

    private func scrollToBottom(animated: Bool) {
        guard let lastMessageId,
              dataSource.indexPath(for: lastMessageId) != nil else {
            return
        }
        collectionView.layoutIfNeeded()
        let contentInset = collectionView.contentInset
        // Scroll to the bottom of the content (includes section insets/padding).
        // Using contentSize avoids under-scrolling when sectionInset.bottom is non-zero.
        let targetY = collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom
        let minY = -contentInset.top
        let maxY = collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom
        let clampedY = max(minY, min(targetY, maxY))
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: animated)
    }

    private func isNearBottom(extraMargin: CGFloat) -> Bool {
        let contentInset = collectionView.contentInset
        let visibleHeight = collectionView.bounds.height - contentInset.top - contentInset.bottom
        guard visibleHeight > 0 else { return true }
        let currentBottom = collectionView.contentOffset.y + visibleHeight
        return collectionView.contentSize.height - currentBottom < extraMargin
    }

    private func adjustContentOffsetForBottomInsetChange(delta: CGFloat) {
        guard abs(delta) > 0.5 else { return }
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom
        let targetY = collectionView.contentOffset.y + delta
        let clampedY = max(minY, min(targetY, maxY))
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
    }

    private func fingerprint(for message: Message) -> Int {
        var hasher = Hasher()
        hasher.combine(message.content)
        hasher.combine(message.streaming)
        hasher.combine(message.attachments.count)
        for attachment in message.attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.type.rawValue)
            hasher.combine(attachment.mimeType ?? "")
            hasher.combine(attachment.assetId ?? "")
        }
        return hasher.finalize()
    }

    private func invalidateLayout(for messageId: String) {
        dirtySizeIds.insert(messageId)
        scheduleLayoutInvalidation()
    }

    private func scheduleReconfigure(for messageId: String) {
        pendingReconfigureIds.insert(messageId)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ids = Array(self.pendingReconfigureIds)
            self.pendingReconfigureIds.removeAll()
            var snapshot = self.dataSource.snapshot()
            let existing = ids.filter { snapshot.indexOfItem($0) != nil }
            guard !existing.isEmpty else { return }
            snapshot.reconfigureItems(existing)
            self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func applyMeasuredSize(_ measuredSize: CGSize, for messageId: String) {
        guard let viewModel, let message = messagesById[messageId] else {
            scheduleLayoutInvalidation()
            return
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let presentation = viewModel.presentation(for: message, metrics: metrics)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let maxWidth = maxItemWidth(
            for: sizeClass,
            message: message,
            presentation: presentation,
            metrics: metrics,
            containerWidth: availableContentWidth()
        )
        let clamped = CGSize(
            width: min(maxWidth, measuredSize.width),
            height: measuredSize.height
        )
        let snapped = snapToPixel(clamped)
        if let previous = lastMeasuredSizes[messageId] {
            let heightDelta = abs(previous.height - snapped.height)
            let widthDelta = abs(previous.width - snapped.width)
            guard heightDelta > 8 || widthDelta > 4 else { return }
        }
        lastMeasuredSizes[messageId] = snapped
        sizeCache[messageId] = snapped
        scheduleLayoutInvalidation()
        if messageId == lastMessageId {
            scheduleScrollToBottom(animated: false, attempts: 1)
        }
    }

    private func snapToPixel(_ size: CGSize) -> CGSize {
        let scale = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
        func snap(_ value: CGFloat) -> CGFloat {
            ceil(value * scale) / scale
        }
        return CGSize(width: snap(size.width), height: snap(size.height))
    }

    private func scheduleLayoutInvalidation() {
        guard !invalidationScheduled else { return }
        invalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidationScheduled = false
            if !self.dirtySizeIds.isEmpty {
                let ids = self.dirtySizeIds
                self.dirtySizeIds.removeAll()
                ids.forEach { id in
                    self.sizeCache.removeValue(forKey: id)
                    self.lastMeasuredSizes.removeValue(forKey: id)
                }
            }
            self.flowLayout.invalidateLayout()
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        sizeForItem(at: indexPath)
    }
}

private final class MessageFlowLayout: UICollectionViewFlowLayout {
    private var cachedAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var cachedContentSize: CGSize = .zero

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        cachedAttributes.removeAll(keepingCapacity: true)

        let itemCount = collectionView.numberOfItems(inSection: 0)
        let contentWidth = collectionView.bounds.width
        guard itemCount > 0, contentWidth > 0 else {
            cachedContentSize = .zero
            return
        }

        let maxX = contentWidth - sectionInset.right
        var x = sectionInset.left
        var y = sectionInset.top
        var rowHeight: CGFloat = 0

        for item in 0..<itemCount {
            let indexPath = IndexPath(item: item, section: 0)
            let size = (collectionView.delegate as? UICollectionViewDelegateFlowLayout)?
                .collectionView?(collectionView, layout: self, sizeForItemAt: indexPath) ?? itemSize

            if x + size.width > maxX, x > sectionInset.left {
                x = sectionInset.left
                y += rowHeight + minimumLineSpacing
                rowHeight = 0
            }

            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = frame
            cachedAttributes[indexPath] = attributes

            x += size.width + minimumInteritemSpacing
            rowHeight = max(rowHeight, size.height)
        }

        cachedContentSize = CGSize(width: contentWidth, height: y + rowHeight + sectionInset.bottom)
    }

    override var collectionViewContentSize: CGSize {
        cachedContentSize
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        cachedAttributes.values.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cachedAttributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }
}
