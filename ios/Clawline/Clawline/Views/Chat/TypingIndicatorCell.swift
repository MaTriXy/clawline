//
//  TypingIndicatorCell.swift
//  Clawline
//
//  Typing indicator shown while CLU is processing a message.
//

import Foundation
import UIKit

final class TypingIndicatorCell: UICollectionViewCell {
    static let reuseIdentifier = "TypingIndicatorCell"
    /// Fixed ID used in the diffable data source for the typing indicator item.
    static let itemId = "__typing_indicator__"

    private static let indicatorText = "..."
    private let containerView = MessageBubbleUIKitContainerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   isCompact: Bool,
                   maxWidth: CGFloat,
                   isDark: Bool? = nil) {
        containerView.configure(
            message: message,
            presentation: presentation,
            failureReason: nil,
            isCompact: isCompact,
            maxWidth: maxWidth,
            isDark: isDark,
            onRequestExpand: nil,
            onRetry: nil
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
    }

    func startAnimating() {}

    func stopAnimating() {}

    static func makeMessage(channelType: ChatChannelType) -> Message {
        Message(
            id: itemId,
            role: .assistant,
            content: indicatorText,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            channelType: channelType
        )
    }

    static func makePresentation(metrics: ChatFlowTheme.Metrics) -> MessagePresentation {
        let text = indicatorText
        let wordCount = max(1, text.split(whereSeparator: { $0.isWhitespace || $0 == "." }).count)
        return MessagePresentation(
            parts: [.text(text)],
            wordCount: wordCount,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false
        )
    }
}
