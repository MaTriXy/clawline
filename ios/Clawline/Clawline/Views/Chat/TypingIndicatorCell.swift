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

    private static let indicatorText = "Typing..."
    private let containerView = MessageBubbleUIKitContainerView()
    private let dotsView = TypingDotsView()
    private var currentMetrics = ChatFlowTheme.Metrics(isCompact: true)

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

        dotsView.translatesAutoresizingMaskIntoConstraints = true
        dotsView.isUserInteractionEnabled = false
        containerView.addSubview(dotsView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   isCompact: Bool,
                   maxWidth: CGFloat,
                   isDark: Bool? = nil) {
        currentMetrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let effectiveIsDark = isDark ?? (traitCollection.userInterfaceStyle == .dark)
        dotsView.updateColor(ChatFlowUIKitTheme.palette(isDark: effectiveIsDark).ink)
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
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopAnimating()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bubbleFrame = containerView.bubbleFrameInContainer()
        let headerHeight: CGFloat = 32
        let headerSpacing: CGFloat = 10
        let contentTop = bubbleFrame.minY + currentMetrics.bubblePaddingVertical + headerHeight + headerSpacing
        let contentBottom = bubbleFrame.maxY - currentMetrics.bubblePaddingVertical
        let contentHeight = max(0, contentBottom - contentTop)
        let contentWidth = max(0, bubbleFrame.width - (currentMetrics.bubblePaddingHorizontal * 2))
        let indicatorSize = dotsView.intrinsicContentSize
        let centeredX = bubbleFrame.minX + currentMetrics.bubblePaddingHorizontal + (contentWidth - indicatorSize.width) / 2
        let centeredY = contentTop + (contentHeight - indicatorSize.height) / 2
        dotsView.frame = CGRect(x: centeredX, y: centeredY, width: indicatorSize.width, height: indicatorSize.height)
    }

    func startAnimating() {
        dotsView.startAnimating()
    }

    func stopAnimating() {
        dotsView.stopAnimating()
    }

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

private final class TypingDotsView: UIView {
    private let label = UILabel()
    private let bounceHeight: CGFloat = 6
    private let duration: CFTimeInterval = 0.9
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Typing..."
        label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        label.intrinsicContentSize
    }

    func updateColor(_ color: UIColor) {
        label.textColor = color
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        let baseTime = CACurrentMediaTime()
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = [0, -bounceHeight, 0]
        animation.keyTimes = [0, 0.4, 1]
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        animation.beginTime = baseTime
        animation.isRemovedOnCompletion = false
        label.layer.add(animation, forKey: "typingBounce")
    }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        label.layer.removeAnimation(forKey: "typingBounce")
        label.transform = .identity
    }
}
