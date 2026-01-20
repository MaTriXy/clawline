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

    func makeUIViewController(context: Context) -> MessageFlowCollectionViewController {
        let controller = MessageFlowCollectionViewController()
        controller.loadViewIfNeeded()
        controller.update(viewModel: viewModel, isCompact: isCompact, topInset: topInset, bottomInset: bottomInset)
        return controller
    }

    func updateUIViewController(_ uiViewController: MessageFlowCollectionViewController, context: Context) {
        uiViewController.update(viewModel: viewModel, isCompact: isCompact, topInset: topInset, bottomInset: bottomInset)
    }
}

final class MessageFlowCollectionViewController: UIViewController, UICollectionViewDelegateFlowLayout {
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var flowLayout: UICollectionViewFlowLayout!

    private var messagesById: [String: Message] = [:]
    private var fingerprints: [String: Int] = [:]
    private var sizeCache: [String: CGSize] = [:]
    private var lastMessageId: String?
    private var viewModel: ChatViewModel?
    private var isCompact: Bool = true
    private var topInset: CGFloat = 0
    private var bottomInset: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private lazy var sizingHost = UIHostingController(
        rootView: MessageBubbleSizingView(
            message: Message(
                id: "",
                role: .assistant,
                content: "",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                channelType: .personal
            ),
            presentation: MessagePresentation(
                parts: [],
                wordCount: 0,
                hasTextualContent: false,
                isEmojiOnly: false,
                hasMediaOnly: false
            ),
            failureReason: nil,
            isCompact: true
        )
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        configureCollectionView()
        configureDataSource()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        guard size != .zero, size != lastBoundsSize else { return }
        lastBoundsSize = size
        updateLayout()
        if let viewModel {
            update(viewModel: viewModel, isCompact: isCompact, topInset: topInset, bottomInset: bottomInset)
        }
    }

    func update(viewModel: ChatViewModel, isCompact: Bool, topInset: CGFloat, bottomInset: CGFloat) {
        loadViewIfNeeded()
        self.viewModel = viewModel
        let needsLayoutUpdate = self.isCompact != isCompact || self.topInset != topInset || self.bottomInset != bottomInset
        self.isCompact = isCompact
        self.topInset = topInset
        self.bottomInset = bottomInset

        if needsLayoutUpdate {
            updateLayout()
        }

        let messages = viewModel.messages
        messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let newFingerprints = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, fingerprint(for: $0)) })
        let removedIds = Set(fingerprints.keys).subtracting(newFingerprints.keys)
        removedIds.forEach { sizeCache.removeValue(forKey: $0) }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(messages.map(\.id))

        let changedIds = needsLayoutUpdate
            ? messages.map(\.id)
            : newFingerprints.compactMap { id, fingerprint in
                fingerprints[id] == fingerprint ? nil : id
            }
        if !changedIds.isEmpty {
            changedIds.forEach { sizeCache.removeValue(forKey: $0) }
            snapshot.reconfigureItems(changedIds)
            flowLayout.invalidateLayout()
        }

        dataSource.apply(snapshot, animatingDifferences: false)
        fingerprints = newFingerprints

        if lastMessageId != messages.last?.id {
            lastMessageId = messages.last?.id
            scrollToBottom(animated: true)
        }
    }

    private func configureCollectionView() {
        flowLayout = UICollectionViewFlowLayout()
        flowLayout.sectionInset = .zero
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.minimumLineSpacing = 0
        flowLayout.estimatedItemSize = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.register(MessageBubbleCell.self, forCellWithReuseIdentifier: MessageBubbleCell.reuseIdentifier)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { [weak self] (collectionView: UICollectionView, indexPath: IndexPath, id: String) in
            guard let self,
                  let viewModel = self.viewModel,
                  let message = self.messagesById[id] else {
                return nil
            }
            let metrics = ChatFlowTheme.Metrics(isCompact: self.isCompact)
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MessageBubbleCell.reuseIdentifier,
                for: indexPath
            ) as? MessageBubbleCell
            cell?.configure(
                message: message,
                presentation: presentation,
                failureReason: viewModel.failureMessage(for: message.id),
                isCompact: self.isCompact,
                onLayoutInvalidation: { [weak self] messageId in
                    self?.invalidateLayout(for: messageId)
                },
                onLayoutOverflow: { [weak self] messageId, measuredSize in
                    self?.applyMeasuredSize(measuredSize, for: messageId)
                }
            )
            return cell
        }
    }

    private func updateLayout() {
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        flowLayout.minimumInteritemSpacing = metrics.flowGap
        flowLayout.minimumLineSpacing = metrics.flowGap
        flowLayout.sectionInset = UIEdgeInsets(
            top: metrics.containerPadding + topInset,
            left: metrics.containerPadding,
            bottom: metrics.containerPadding,
            right: metrics.containerPadding
        )
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        collectionView.scrollIndicatorInsets = collectionView.contentInset
        sizeCache.removeAll()
        flowLayout.invalidateLayout()
    }

    private func availableContentWidth() -> CGFloat {
        collectionView.bounds.width - flowLayout.sectionInset.left - flowLayout.sectionInset.right
    }

    private func maxItemWidth(for sizeClass: MessageSizeClass, containerWidth: CGFloat) -> CGFloat {
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: ChatFlowTheme.Metrics(isCompact: isCompact).bodyFontSize)
        switch sizeClass {
        case .short:
            return min(containerWidth, maxLineWidth)
        case .medium:
            if isCompact {
                return containerWidth
            }
            return min(containerWidth, max(containerWidth * 0.45, 200))
        case .long:
            return min(containerWidth, maxLineWidth)
        }
    }

    private func sizeForItem(at indexPath: IndexPath) -> CGSize {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let viewModel,
              let message = messagesById[id] else {
            return .zero
        }
        if let cached = sizeCache[id] {
            return cached
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let presentation = viewModel.presentation(for: message, metrics: metrics)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let availableWidth = availableContentWidth()
        let maxWidth = maxItemWidth(for: sizeClass, containerWidth: availableWidth)

        sizingHost.rootView = MessageBubbleSizingView(
            message: message,
            presentation: presentation,
            failureReason: viewModel.failureMessage(for: message.id),
            isCompact: isCompact
        )
        let targetSize = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
        let measured = sizingHost.sizeThatFits(in: targetSize)
        let clamped = CGSize(
            width: min(maxWidth, max(1, measured.width)),
            height: max(1, measured.height)
        )
        let snapped = snapToPixel(clamped)
        sizeCache[id] = snapped
        return snapped
    }

    private func scrollToBottom(animated: Bool) {
        guard let lastMessageId,
              let indexPath = dataSource.indexPath(for: lastMessageId) else {
            return
        }
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
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
        guard sizeCache[messageId] != nil else { return }
        sizeCache.removeValue(forKey: messageId)
        flowLayout.invalidateLayout()
    }

    private func applyMeasuredSize(_ measuredSize: CGSize, for messageId: String) {
        let current = sizeCache[messageId]
        let heightDelta = abs((current?.height ?? 0) - measuredSize.height)
        let widthDelta = abs((current?.width ?? 0) - measuredSize.width)
        guard heightDelta > 1 || widthDelta > 1 else { return }
        guard let viewModel, let message = messagesById[messageId] else { return }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let presentation = viewModel.presentation(for: message, metrics: metrics)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let maxWidth = maxItemWidth(for: sizeClass, containerWidth: availableContentWidth())
        let clamped = CGSize(
            width: min(maxWidth, measuredSize.width),
            height: measuredSize.height
        )
        sizeCache[messageId] = snapToPixel(clamped)
        flowLayout.invalidateLayout()
    }

    private func snapToPixel(_ size: CGSize) -> CGSize {
        let scale = UIScreen.main.scale
        func snap(_ value: CGFloat) -> CGFloat {
            ceil(value * scale) / scale
        }
        return CGSize(width: snap(size.width), height: snap(size.height))
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        sizeForItem(at: indexPath)
    }
}

private struct MessageBubbleDisplayView: View {
    let message: Message
    let presentation: MessagePresentation
    let failureReason: String?
    let isCompact: Bool
    let onLayoutInvalidation: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MessageBubble(
                message: message,
                presentation: presentation,
                onLayoutInvalidation: onLayoutInvalidation
            )
            .id(message.id)
                .messageFailureIndicator(failureReason)
            Spacer(minLength: 0)
        }
        .environment(\.horizontalSizeClass, isCompact ? .compact : .regular)
    }
}

private struct MessageBubbleSizingView: View {
    let message: Message
    let presentation: MessagePresentation
    let failureReason: String?
    let isCompact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MessageBubble(
                message: message,
                presentation: presentation,
                onLayoutInvalidation: nil
            )
            .id(message.id)
                .messageFailureIndicator(failureReason)
            Spacer(minLength: 0)
        }
        .environment(\.horizontalSizeClass, isCompact ? .compact : .regular)
    }
}

private final class MessageBubbleCell: UICollectionViewCell {
    static let reuseIdentifier = "MessageBubbleCell"
    private static let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "FlowLayout")

    private var hostingController: UIHostingController<MessageBubbleDisplayView>?
    private var messageId: String?
    private var onLayoutOverflow: ((String, CGSize) -> Void)?
    private var lastMismatch: (messageId: String, bounds: CGSize, measured: CGSize)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        message: Message,
        presentation: MessagePresentation,
        failureReason: String?,
        isCompact: Bool,
        onLayoutInvalidation: ((String) -> Void)?,
        onLayoutOverflow: ((String, CGSize) -> Void)?
    ) {
        messageId = message.id
        self.onLayoutOverflow = onLayoutOverflow
        lastMismatch = nil
        let rootView = MessageBubbleDisplayView(
            message: message,
            presentation: presentation,
            failureReason: failureReason,
            isCompact: isCompact,
            onLayoutInvalidation: onLayoutInvalidation
        )

        if let hostingController {
            hostingController.rootView = rootView
            return
        }

        let hostingController = UIHostingController(rootView: rootView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear

        contentView.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        self.hostingController = hostingController
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageId = nil
        onLayoutOverflow = nil
        lastMismatch = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let hostingController,
              let messageId else { return }
        let boundsSize = contentView.bounds.size
        let targetSize = CGSize(width: boundsSize.width, height: CGFloat.greatestFiniteMagnitude)
        let measured = hostingController.sizeThatFits(in: targetSize)
        let heightDelta = abs(measured.height - contentView.bounds.height)
        let widthDelta = abs(measured.width - contentView.bounds.width)
        if heightDelta > 1 || widthDelta > 1 {
            if let lastMismatch,
               lastMismatch.messageId == messageId,
               abs(lastMismatch.bounds.width - boundsSize.width) < 1,
               abs(lastMismatch.bounds.height - boundsSize.height) < 1,
               abs(lastMismatch.measured.width - measured.width) < 1,
               abs(lastMismatch.measured.height - measured.height) < 1 {
                return
            }
            lastMismatch = (messageId: messageId, bounds: boundsSize, measured: measured)
            Self.logger.info(
                "Layout mismatch \(messageId, privacy: .public) layout=\(self.contentView.bounds.debugDescription, privacy: .public) measured=\(String(describing: measured), privacy: .public)"
            )
            onLayoutOverflow?(messageId, measured)
        } else {
            lastMismatch = nil
        }
    }
}
