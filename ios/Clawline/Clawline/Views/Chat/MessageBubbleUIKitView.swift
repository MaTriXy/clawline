//
//  MessageBubbleUIKitView.swift
//  Clawline
//
//  UIKit-only bubble view for layout debugging.
//

import OSLog
import UIKit

final class MessageBubbleUIKitContainerView: UIView {
    private let bubbleView = MessageBubbleUIKitView()
    private let badgeView = MessageFailureBadgeView()
    private var bubbleBottomConstraint: NSLayoutConstraint!
    private var badgeBottomConstraint: NSLayoutConstraint!
    private var badgeLeadingConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubbleView)

        bubbleBottomConstraint = bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubbleView.topAnchor.constraint(equalTo: topAnchor),
            bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubbleBottomConstraint
        ])

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeView)
        badgeLeadingConstraint = badgeView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor)
        badgeBottomConstraint = badgeView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor)
        NSLayoutConstraint.activate([
            badgeLeadingConstraint,
            badgeBottomConstraint
        ])
        badgeView.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   failureReason: String?,
                   isCompact: Bool,
                   maxWidth: CGFloat,
                   onRequestExpand: (() -> Void)?) {
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        bubbleView.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth,
            onRequestExpand: onRequestExpand
        )

        if let reason = failureReason {
            badgeView.isHidden = false
            badgeView.configure(reason: reason)
            bubbleBottomConstraint.constant = -32
            badgeBottomConstraint.constant = 18
            badgeLeadingConstraint.constant = 0
        } else {
            badgeView.isHidden = true
            bubbleBottomConstraint.constant = 0
            badgeBottomConstraint.constant = 0
        }
    }

    func bubbleFrameInContainer() -> CGRect {
        bubbleView.frame
    }
}

final class MessageBubbleUIKitView: UIView {
    private let bubbleBackgroundView = UIView()
    private let contentStack = UIStackView()
    private let headerStack = UIStackView()
    private let avatarView = AvatarCircleView()
    private let senderLabel = UILabel()
    private let bodyLabel = UILabel()
    private let truncationContainer = UIView()
    private let truncationLabel = UILabel()
    private let truncationBorder = UIView()
    private let fadeView = TruncationFadeView()

    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private let borderGradientLayer = CAGradientLayer()
    private let borderMaskLayer = CAShapeLayer()
    private let topHighlightLayer = CAGradientLayer()
    private let topHighlightMask = CAShapeLayer()

    private var maxWidthConstraint: NSLayoutConstraint!
    private var minWidthConstraint: NSLayoutConstraint!
    private var fixedWidthConstraint: NSLayoutConstraint?
    private var bodyMaxWidthConstraint: NSLayoutConstraint?
    private var bodyHeightConstraint: NSLayoutConstraint?
    private var shouldTruncate = false
    private var onRequestExpand: (() -> Void)?
    private var currentMetrics = ChatFlowTheme.Metrics(isCompact: true)
    private var currentMessageRole: Message.Role = .assistant
    private var currentChannelType: ChatChannelType = .personal
    private var contentLeadingConstraint: NSLayoutConstraint!
    private var contentTrailingConstraint: NSLayoutConstraint!
    private var contentTopConstraint: NSLayoutConstraint!
    private var contentBottomConstraint: NSLayoutConstraint!
    private var truncationHeightConstraint: NSLayoutConstraint?
    private var fadeConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        bubbleBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        bubbleBackgroundView.isUserInteractionEnabled = true
        let bubbleTap = UITapGestureRecognizer(target: self, action: #selector(handleBubbleTap))
        bubbleBackgroundView.addGestureRecognizer(bubbleTap)
        addSubview(bubbleBackgroundView)
        maxWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        minWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        NSLayoutConstraint.activate([
            bubbleBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubbleBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            bubbleBackgroundView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            bubbleBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            maxWidthConstraint,
            minWidthConstraint
        ])
        bubbleBackgroundView.setContentHuggingPriority(.required, for: .horizontal)
        bubbleBackgroundView.setContentCompressionResistancePriority(.required, for: .horizontal)

        bubbleBackgroundView.layer.insertSublayer(gradientLayer, at: 0)
        bubbleBackgroundView.layer.mask = maskLayer

        // 3D border rim - subtle highlight at top
        borderGradientLayer.colors = [
            UIColor.white.withAlphaComponent(0.14).cgColor,
            UIColor.white.withAlphaComponent(0.05).cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor
        ]
        borderGradientLayer.locations = [0.0, 0.25, 0.55, 1.0]
        borderGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        borderGradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        borderMaskLayer.fillColor = nil
        borderMaskLayer.strokeColor = UIColor.white.cgColor
        borderMaskLayer.lineWidth = 1.0
        borderGradientLayer.mask = borderMaskLayer
        layer.addSublayer(borderGradientLayer)

        // 1pt inner highlight at top edge
        topHighlightLayer.colors = [
            UIColor.white.withAlphaComponent(0.12).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor
        ]
        topHighlightLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        topHighlightLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        topHighlightMask.fillColor = UIColor.white.cgColor
        topHighlightLayer.mask = topHighlightMask
        layer.addSublayer(topHighlightLayer)

        contentStack.axis = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        bubbleBackgroundView.addSubview(contentStack)

        headerStack.axis = .horizontal
        headerStack.spacing = 10
        headerStack.alignment = .center

        senderLabel.numberOfLines = 1
        senderLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        headerStack.addArrangedSubview(avatarView)
        headerStack.addArrangedSubview(senderLabel)

        bodyLabel.numberOfLines = 0

        contentStack.addArrangedSubview(headerStack)
        contentStack.addArrangedSubview(bodyLabel)
        contentStack.addArrangedSubview(truncationContainer)

        truncationContainer.translatesAutoresizingMaskIntoConstraints = false
        truncationContainer.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTruncationTap))
        truncationContainer.addGestureRecognizer(tap)
        truncationContainer.addSubview(truncationBorder)
        truncationContainer.addSubview(truncationLabel)
        truncationBorder.translatesAutoresizingMaskIntoConstraints = false
        truncationLabel.translatesAutoresizingMaskIntoConstraints = false
        truncationBorder.backgroundColor = ChatFlowUIKitTheme.borderSubtle(isDark: traitCollection.userInterfaceStyle == .dark)
        truncationLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        truncationLabel.text = "Show more"
        truncationLabel.numberOfLines = 1

        NSLayoutConstraint.activate([
            truncationBorder.leadingAnchor.constraint(equalTo: truncationContainer.leadingAnchor),
            truncationBorder.trailingAnchor.constraint(equalTo: truncationContainer.trailingAnchor),
            truncationBorder.topAnchor.constraint(equalTo: truncationContainer.topAnchor),
            truncationBorder.heightAnchor.constraint(equalToConstant: 1),

            // Center label horizontally; top padding from hrule, no bottom padding (bubble has its own)
            truncationLabel.centerXAnchor.constraint(equalTo: truncationContainer.centerXAnchor),
            truncationLabel.topAnchor.constraint(equalTo: truncationBorder.bottomAnchor, constant: 12),
            truncationLabel.bottomAnchor.constraint(equalTo: truncationContainer.bottomAnchor)
        ])
        truncationHeightConstraint = truncationContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        truncationHeightConstraint?.isActive = true

        truncationContainer.isHidden = true

        fadeView.translatesAutoresizingMaskIntoConstraints = false
        bubbleBackgroundView.addSubview(fadeView)
        fadeView.isHidden = true

        contentLeadingConstraint = contentStack.leadingAnchor.constraint(equalTo: bubbleBackgroundView.leadingAnchor, constant: 16)
        contentTrailingConstraint = contentStack.trailingAnchor.constraint(equalTo: bubbleBackgroundView.trailingAnchor, constant: -16)
        contentTopConstraint = contentStack.topAnchor.constraint(equalTo: bubbleBackgroundView.topAnchor, constant: 14)
        contentBottomConstraint = contentStack.bottomAnchor.constraint(equalTo: bubbleBackgroundView.bottomAnchor, constant: -14)
        NSLayoutConstraint.activate([
            contentLeadingConstraint,
            contentTrailingConstraint,
            contentTopConstraint,
            contentBottomConstraint
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bubbleBackgroundView.bounds
        maskLayer.frame = bubbleBackgroundView.bounds
        let path = bubblePath(in: bubbleBackgroundView.bounds)
        maskLayer.path = path.cgPath

        // Update border to match bubble shape
        borderGradientLayer.frame = bubbleBackgroundView.frame
        borderMaskLayer.frame = bubbleBackgroundView.bounds
        borderMaskLayer.path = path.cgPath

        // Top highlight - 1pt band at top, clipped to bubble shape
        let highlightHeight: CGFloat = 1.5
        topHighlightLayer.frame = CGRect(
            x: bubbleBackgroundView.frame.minX,
            y: bubbleBackgroundView.frame.minY,
            width: bubbleBackgroundView.bounds.width,
            height: highlightHeight
        )
        // Mask to bubble shape (offset to align with highlight frame)
        let highlightMaskPath = bubblePath(in: CGRect(
            x: 0,
            y: 0,
            width: bubbleBackgroundView.bounds.width,
            height: bubbleBackgroundView.bounds.height
        ))
        topHighlightMask.frame = CGRect(x: 0, y: 0, width: bubbleBackgroundView.bounds.width, height: highlightHeight)
        topHighlightMask.path = highlightMaskPath.cgPath
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   sizeClass: MessageSizeClass,
                   metrics: ChatFlowTheme.Metrics,
                   maxWidth: CGFloat,
                   onRequestExpand: (() -> Void)?) {
        // Store for trait collection updates
        currentMessageRole = message.role
        currentChannelType = message.channelType
        // Reset width constraints per size class.
        currentMetrics = metrics
        minWidthConstraint.constant = 120
        maxWidthConstraint.constant = maxWidth
        fixedWidthConstraint?.isActive = false
        fixedWidthConstraint = nil
        self.onRequestExpand = onRequestExpand

        let palette = ChatFlowUIKitTheme.palette(isDark: traitCollection.userInterfaceStyle == .dark)
        let senderColor = (message.channelType == .admin) ? palette.adminAccent : palette.warmBrown
        senderLabel.font = UIFont.systemFont(ofSize: metrics.senderFontSize, weight: .semibold)
        senderLabel.textColor = senderColor.withAlphaComponent(message.channelType == .admin ? 1.0 : 0.7)
        senderLabel.text = (message.role == .user) ? "You" : "Assistant"

        truncationBorder.backgroundColor = palette.borderSubtle

        avatarView.configure(role: message.role, isDark: palette.isDark)

        let text = MessageBubbleUIKitView.textContent(from: presentation)
        bodyLabel.attributedText = MessageBubbleUIKitView.attributedBody(
            text: text,
            sizeClass: sizeClass,
            metrics: metrics,
            inkColor: palette.ink
        )
        contentLeadingConstraint.constant = metrics.bubblePaddingHorizontal
        contentTrailingConstraint.constant = -metrics.bubblePaddingHorizontal
        contentTopConstraint.constant = metrics.bubblePaddingVertical
        contentBottomConstraint.constant = -metrics.bubblePaddingVertical

        switch sizeClass {
        case .short:
            bodyLabel.numberOfLines = 0
            bodyMaxWidthConstraint?.isActive = false
            // Set fixed width to match measured preferredWidth for consistent sizing
            fixedWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(equalToConstant: maxWidth)
            fixedWidthConstraint?.isActive = true
        case .medium:
            bodyLabel.numberOfLines = 0
            bodyMaxWidthConstraint?.isActive = false
            fixedWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(equalToConstant: maxWidth)
            fixedWidthConstraint?.isActive = true
        case .long:
            bodyLabel.numberOfLines = 0
            let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
            bodyMaxWidthConstraint?.isActive = false
            let constraint = bodyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: maxLineWidth)
            constraint.isActive = true
            bodyMaxWidthConstraint = constraint
            fixedWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(equalToConstant: maxWidth)
            fixedWidthConstraint?.isActive = true
        }

        bodyHeightConstraint?.isActive = false
        shouldTruncate = false
        truncationContainer.isHidden = true
        fadeView.isHidden = true
        NSLayoutConstraint.deactivate(fadeConstraints)
        fadeConstraints.removeAll()

        if sizeClass == .long {
            let contentWidth = maxWidth - (metrics.bubblePaddingHorizontal * 2)
            let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
            let bodyWidth = min(contentWidth, maxLineWidth)
            let measuredHeight = bodyLabel.sizeThatFits(CGSize(width: bodyWidth, height: .greatestFiniteMagnitude)).height
            if measuredHeight > metrics.truncationHeight {
                shouldTruncate = true
                let heightConstraint = bodyLabel.heightAnchor.constraint(lessThanOrEqualToConstant: metrics.truncationHeight)
                heightConstraint.isActive = true
                bodyHeightConstraint = heightConstraint
                truncationContainer.isHidden = false
                truncationLabel.textColor = (message.role == .user) ? palette.terracotta : palette.warmBrown
                fadeView.isHidden = false
                // Use bubble gradient end colors for seamless fade
                // Top color must match bottom color (just transparent) to avoid haze
                let bottomColor = message.role == .user ? palette.bubbleSelfGradient.last! : palette.bubbleOtherGradient.last!
                fadeView.updateColors(
                    top: bottomColor.withAlphaComponent(0),
                    bottom: bottomColor
                )
                let fadeHeight: CGFloat = 100
                fadeConstraints = [
                    fadeView.leadingAnchor.constraint(equalTo: bodyLabel.leadingAnchor),
                    fadeView.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor),
                    fadeView.bottomAnchor.constraint(equalTo: bodyLabel.bottomAnchor),
                    fadeView.heightAnchor.constraint(equalToConstant: fadeHeight)
                ]
                NSLayoutConstraint.activate(fadeConstraints)
                truncationContainer.isUserInteractionEnabled = true
            } else {
                truncationContainer.isUserInteractionEnabled = false
            }
        }

        let gradientColors = message.role == .user ? palette.bubbleSelfGradient : palette.bubbleOtherGradient
        gradientLayer.colors = gradientColors.map { $0.cgColor }
        gradientLayer.startPoint = message.role == .user ? CGPoint(x: 0.0, y: 0.0) : CGPoint(x: 0.5, y: 0.0)
        gradientLayer.endPoint = message.role == .user ? CGPoint(x: 1.0, y: 1.0) : CGPoint(x: 0.5, y: 1.0)

        bubbleBackgroundView.layer.shadowColor = palette.shadowNear.cgColor
        bubbleBackgroundView.layer.shadowOpacity = 0.10
        bubbleBackgroundView.layer.shadowRadius = 14
        bubbleBackgroundView.layer.shadowOffset = CGSize(width: 0, height: 4)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            updateAppearanceColors()
        }
    }

    private func updateAppearanceColors() {
        let palette = ChatFlowUIKitTheme.palette(isDark: traitCollection.userInterfaceStyle == .dark)

        // Update sender label color
        let senderColor = (currentChannelType == .admin) ? palette.adminAccent : palette.warmBrown
        senderLabel.textColor = senderColor.withAlphaComponent(currentChannelType == .admin ? 1.0 : 0.7)

        // Update body text color
        bodyLabel.textColor = palette.ink

        // Update truncation border
        truncationBorder.backgroundColor = palette.borderSubtle

        // Update avatar
        avatarView.configure(role: currentMessageRole, isDark: palette.isDark)

        // Update gradient colors
        let gradientColors = currentMessageRole == .user ? palette.bubbleSelfGradient : palette.bubbleOtherGradient
        gradientLayer.colors = gradientColors.map { $0.cgColor }

        // Update shadow
        bubbleBackgroundView.layer.shadowColor = palette.shadowNear.cgColor

        // Update fade view - use bubble gradient end colors
        // Top color must match bottom color (just transparent) to avoid haze
        let bottomColor = currentMessageRole == .user ? palette.bubbleSelfGradient.last! : palette.bubbleOtherGradient.last!
        fadeView.updateColors(
            top: bottomColor.withAlphaComponent(0),
            bottom: bottomColor
        )
    }

    func preferredWidth(maxWidth: CGFloat) -> CGFloat {
        let headerWidth = 32 + 10 + senderLabel.intrinsicContentSize.width
        let contentWidth = maxWidth - (currentMetrics.bubblePaddingHorizontal * 2)
        let bodySize = bodyLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let contentMax = max(headerWidth, bodySize.width)
        return min(maxWidth, max(120, contentMax + (currentMetrics.bubblePaddingHorizontal * 2)))
    }

    @objc private func handleTruncationTap() {
        onRequestExpand?()
    }

    @objc private func handleBubbleTap() {
        guard shouldTruncate else { return }
        onRequestExpand?()
    }

    private static func textContent(from presentation: MessagePresentation) -> String {
        let parts = presentation.parts.filter { $0.isTextual }
        return parts.map { part in
            switch part {
            case .text(let value):
                return value
            case .markdown(let value):
                return value
            case .inlineEmoji(let value):
                return value
            case .code(_, let value):
                return value
            case .table(let model):
                return "Table (\(model.rows.count) rows)"
            case .linkPreview, .image, .gallery:
                return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func attributedBody(text: String,
                                       sizeClass: MessageSizeClass,
                                       metrics: ChatFlowTheme.Metrics,
                                       inkColor: UIColor) -> NSAttributedString {
        let font: UIFont
        let lineSpacing: CGFloat
        switch sizeClass {
        case .short:
            font = UIFont.systemFont(ofSize: metrics.shortFontSize, weight: .semibold)
            lineSpacing = 0
        case .medium:
            font = UIFont.systemFont(ofSize: metrics.mediumFontSize, weight: .medium)
            lineSpacing = 4
        case .long:
            font = UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular)
            lineSpacing = 4
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: inkColor,
            .paragraphStyle: paragraph
        ])
    }

    // MARK: - UIKit-Native Text Measurement

    /// Measure the natural single-line width of text content (no wrapping).
    /// Used for line balancing to determine minimum width needed.
    static func measureSingleLineWidth(
        for presentation: MessagePresentation,
        metrics: ChatFlowTheme.Metrics
    ) -> CGFloat {
        let text = textContent(from: presentation)
        guard !text.isEmpty else { return 0 }

        // Use short size class font for single-line measurement (natural width)
        let font = UIFont.systemFont(ofSize: metrics.shortFontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )
        return ceil(size.width)
    }

    /// Measure the height of text content at a given width.
    /// Used to estimate line count for layout decisions.
    static func measureTextHeight(
        for presentation: MessagePresentation,
        sizeClass: MessageSizeClass,
        metrics: ChatFlowTheme.Metrics,
        maxWidth: CGFloat
    ) -> CGFloat? {
        guard presentation.hasTextualContent else { return nil }
        let text = textContent(from: presentation)
        guard !text.isEmpty else { return nil }

        let font: UIFont
        let lineSpacing: CGFloat
        switch sizeClass {
        case .short:
            font = UIFont.systemFont(ofSize: metrics.shortFontSize, weight: .semibold)
            lineSpacing = 0
        case .medium:
            font = UIFont.systemFont(ofSize: metrics.mediumFontSize, weight: .medium)
            lineSpacing = 4
        case .long:
            font = UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular)
            lineSpacing = 4
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]

        let size = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return ceil(size.height)
    }

    /// Estimate line count for text at a given bubble width.
    /// contentWidth = bubbleWidth - horizontal padding
    static func estimatedLineCount(
        for presentation: MessagePresentation,
        metrics: ChatFlowTheme.Metrics,
        atBubbleWidth bubbleWidth: CGFloat
    ) -> Int {
        let contentWidth = bubbleWidth - (metrics.bubblePaddingHorizontal * 2)
        guard let textHeight = measureTextHeight(
            for: presentation,
            sizeClass: .medium,
            metrics: metrics,
            maxWidth: contentWidth
        ) else {
            return 1
        }

        let lineSpacing: CGFloat = 4
        let font = UIFont.systemFont(ofSize: metrics.mediumFontSize, weight: .medium)
        let lineHeight = font.lineHeight
        return Int(ceil((textHeight + lineSpacing) / (lineHeight + lineSpacing)))
    }

    private func bubblePath(in rect: CGRect) -> UIBezierPath {
        let radii = bubbleCornerRadii(messageId: messageIdForCorners())
        return roundedRectPath(
            rect: rect,
            topLeft: radii.topLeft,
            topRight: radii.topRight,
            bottomRight: radii.bottomRight,
            bottomLeft: radii.bottomLeft
        )
    }

    private func messageIdForCorners() -> String {
        "\(bodyLabel.text ?? "")_\(senderLabel.text ?? "")"
    }

    private func bubbleCornerRadii(messageId: String) -> (topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) {
        let base: CGFloat = 24
        let sharp: CGFloat = 4
        let variationsSelf: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (32, 24, sharp, 24),
            (24, 32, sharp, 28),
            (26, 30, sharp, 28)
        ]
        let variationsOther: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (32, 24, 28, sharp),
            (24, 32, 28, sharp),
            (26, 30, 28, sharp)
        ]
        let index = abs(messageId.hashValue) % variationsSelf.count
        if senderLabel.text == "You" {
            let v = variationsSelf[index]
            return (v.0, v.1, v.2, v.3)
        }
        let v = variationsOther[index]
        return (v.0, v.1, v.2, v.3)
    }

    private func roundedRectPath(rect: CGRect,
                                 topLeft: CGFloat,
                                 topRight: CGFloat,
                                 bottomRight: CGFloat,
                                 bottomLeft: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let tl = min(topLeft, min(rect.width, rect.height) / 2)
        let tr = min(topRight, min(rect.width, rect.height) / 2)
        let br = min(bottomRight, min(rect.width, rect.height) / 2)
        let bl = min(bottomLeft, min(rect.width, rect.height) / 2)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(withCenter: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(withCenter: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        path.close()
        return path
    }
}

final class AvatarCircleView: UIView {
    private let label = UILabel()
    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32)
        ])

        // Radial gradient for spherical/marble look
        layer.insertSublayer(gradientLayer, at: 0)
        gradientLayer.type = .radial
        // Tighter highlight - center upper-left for "lit from above-left" look
        gradientLayer.startPoint = CGPoint(x: 0.35, y: 0.25)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        label.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.layer.shadowOpacity = 0.3
        label.layer.shadowRadius = 1

        layer.cornerRadius = 16
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    func configure(role: Message.Role, isDark: Bool) {
        label.text = role == .user ? "Y" : "A"

        // Role-specific gradient - subtle spherical highlight
        if role == .user {
            // Sage green - subtle gradient from design system
            gradientLayer.colors = [
                UIColor(red: 0.48, green: 0.68, blue: 0.48, alpha: 1).cgColor,  // Subtle highlight
                UIColor(red: 0.42, green: 0.61, blue: 0.42, alpha: 1).cgColor,  // #6B9B6A
                UIColor(red: 0.32, green: 0.52, blue: 0.34, alpha: 1).cgColor,  // mid
                UIColor(red: 0.24, green: 0.42, blue: 0.26, alpha: 1).cgColor   // edge
            ]
            gradientLayer.locations = [0.0, 0.3, 0.65, 1.0]
        } else {
            // Terracotta - subtle gradient
            gradientLayer.colors = [
                UIColor(red: 0.94, green: 0.70, blue: 0.65, alpha: 1).cgColor,  // Subtle highlight
                UIColor(red: 0.91, green: 0.66, blue: 0.61, alpha: 1).cgColor,  // soft-coral
                UIColor(red: 0.80, green: 0.52, blue: 0.42, alpha: 1).cgColor,  // mid
                UIColor(red: 0.70, green: 0.42, blue: 0.32, alpha: 1).cgColor   // edge
            ]
            gradientLayer.locations = [0.0, 0.3, 0.65, 1.0]
        }
    }
}

final class MessageFailureBadgeView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.cornerRadius = 12
        layer.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        label.numberOfLines = 2
        label.textColor = ChatFlowUIKitTheme.failureText(isDark: traitCollection.userInterfaceStyle == .dark)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(reason: String) {
        label.text = reason
        let isDark = traitCollection.userInterfaceStyle == .dark
        backgroundColor = ChatFlowUIKitTheme.failureBackground(isDark: isDark)
        label.textColor = ChatFlowUIKitTheme.failureText(isDark: isDark)
    }
}

enum ChatFlowUIKitTheme {
    struct Palette {
        let isDark: Bool
        let sage: UIColor
        let cream: UIColor
        let warmBrown: UIColor
        let adminAccent: UIColor
        let ink: UIColor
        let bubbleSelfGradient: [UIColor]
        let bubbleOtherGradient: [UIColor]
        let avatarGradient: [UIColor]
        let terracotta: UIColor
        let borderSubtle: UIColor
        let fadeTop: UIColor
        let failureText: UIColor
        let failureBackground: UIColor
        let shadowNear: UIColor
    }

    static func palette(isDark: Bool) -> Palette {
        if isDark {
            return Palette(
                isDark: true,
                sage: UIColor(red: 0.482, green: 0.639, blue: 0.463, alpha: 1),
                cream: UIColor(red: 0.110, green: 0.098, blue: 0.090, alpha: 1),
                warmBrown: UIColor(red: 0.831, green: 0.769, blue: 0.690, alpha: 1),
                adminAccent: UIColor(red: 0.549, green: 0.756, blue: 0.996, alpha: 1),
                ink: UIColor(red: 0.910, green: 0.894, blue: 0.878, alpha: 1),
                bubbleSelfGradient: [
                    UIColor(red: 0.176, green: 0.231, blue: 0.165, alpha: 1),
                    UIColor(red: 0.141, green: 0.200, blue: 0.133, alpha: 1)
                ],
                bubbleOtherGradient: [
                    UIColor(red: 0.161, green: 0.145, blue: 0.141, alpha: 1),
                    UIColor(red: 0.161, green: 0.145, blue: 0.141, alpha: 1)
                ],
                avatarGradient: [
                    UIColor(red: 0.55, green: 0.34, blue: 0.30, alpha: 1),
                    UIColor(red: 0.64, green: 0.40, blue: 0.36, alpha: 1)
                ],
                terracotta: UIColor(red: 0.878, green: 0.478, blue: 0.373, alpha: 1),
                borderSubtle: UIColor(red: 0.910, green: 0.894, blue: 0.878, alpha: 0.12),
                fadeTop: UIColor(red: 0, green: 0, blue: 0, alpha: 0),
                failureText: UIColor(red: 0.95, green: 0.62, blue: 0.62, alpha: 1),
                failureBackground: UIColor(red: 0.30, green: 0.14, blue: 0.14, alpha: 1),
                shadowNear: UIColor.black.withAlphaComponent(0.35)
            )
        }
        return Palette(
            isDark: false,
            sage: UIColor(red: 0.561, green: 0.651, blue: 0.541, alpha: 1),
            cream: UIColor(red: 0.969, green: 0.953, blue: 0.922, alpha: 1),
            warmBrown: UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 1),
            adminAccent: UIColor(red: 0.141, green: 0.420, blue: 0.831, alpha: 1),
            ink: UIColor(red: 0.239, green: 0.204, blue: 0.161, alpha: 1),
            bubbleSelfGradient: [
                UIColor(red: 0.722, green: 0.808, blue: 0.686, alpha: 1),
                UIColor(red: 0.784, green: 0.851, blue: 0.753, alpha: 1)
            ],
            bubbleOtherGradient: [
                UIColor(red: 1.0, green: 0.992, blue: 0.976, alpha: 1),
                UIColor(red: 0.992, green: 0.965, blue: 0.933, alpha: 1)
            ],
            avatarGradient: [
                UIColor(red: 0.62, green: 0.36, blue: 0.30, alpha: 1),
                UIColor(red: 0.72, green: 0.45, blue: 0.39, alpha: 1)
            ],
            terracotta: UIColor(red: 0.769, green: 0.471, blue: 0.361, alpha: 1),
            borderSubtle: UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 0.1),
            fadeTop: UIColor(red: 1, green: 1, blue: 1, alpha: 0),
            failureText: UIColor(red: 0.6, green: 0.12, blue: 0.12, alpha: 1),
            failureBackground: UIColor(red: 0.98, green: 0.92, blue: 0.92, alpha: 1),
            shadowNear: UIColor.black.withAlphaComponent(0.15)
        )
    }

    static func borderSubtle(isDark: Bool) -> UIColor {
        palette(isDark: isDark).borderSubtle
    }

    static func avatarGradient(isDark: Bool) -> [UIColor] {
        palette(isDark: isDark).avatarGradient
    }

    static func failureText(isDark: Bool) -> UIColor {
        palette(isDark: isDark).failureText
    }

    static func failureBackground(isDark: Bool) -> UIColor {
        palette(isDark: isDark).failureBackground
    }
}

final class TruncationFadeView: UIView {
    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(gradientLayer)
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    func updateColors(top: UIColor, bottom: UIColor) {
        gradientLayer.colors = [top.cgColor, bottom.cgColor]
    }
}

final class MessageBubbleUIKitCell: UICollectionViewCell {
    static let reuseIdentifier = "MessageBubbleUIKitCell"
    private static let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "FlowLayout")

    private let containerView = MessageBubbleUIKitContainerView()
    private var messageId: String = ""
    private var messageSnippet: String = ""
    private var lastMismatch: (bounds: CGRect, bubble: CGRect)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   failureReason: String?,
                   isCompact: Bool,
                   maxWidth: CGFloat,
                   onRequestExpand: (() -> Void)?) {
        messageId = message.id
        messageSnippet = String(message.content.prefix(80))
        containerView.configure(
            message: message,
            presentation: presentation,
            failureReason: failureReason,
            isCompact: isCompact,
            maxWidth: maxWidth,
            onRequestExpand: onRequestExpand
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageId = ""
        messageSnippet = ""
        lastMismatch = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bubbleFrame = containerView.bubbleFrameInContainer()
        let bubbleInCell = containerView.convert(bubbleFrame, to: contentView)
        let bounds = contentView.bounds
        let heightDelta = abs(bounds.height - bubbleInCell.height)
        let widthDelta = abs(bounds.width - bubbleInCell.width)
        let yDelta = abs(bubbleInCell.minY - bounds.minY)
        let xDelta = abs(bubbleInCell.minX - bounds.minX)
        guard heightDelta > 1 || widthDelta > 1 || yDelta > 1 || xDelta > 1 else {
            lastMismatch = nil
            return
        }
        if let lastMismatch,
           abs(lastMismatch.bounds.width - bounds.width) < 1,
           abs(lastMismatch.bounds.height - bounds.height) < 1,
           abs(lastMismatch.bubble.width - bubbleInCell.width) < 1,
           abs(lastMismatch.bubble.height - bubbleInCell.height) < 1,
           abs(lastMismatch.bubble.minX - bubbleInCell.minX) < 1,
           abs(lastMismatch.bubble.minY - bubbleInCell.minY) < 1 {
            return
        }
        lastMismatch = (bounds: bounds, bubble: bubbleInCell)
        let boundsDesc = String(describing: bounds)
        let bubbleDesc = String(describing: bubbleInCell)
        let id = messageId
        let snippet = messageSnippet
        Self.logger.info("UIKit bubble mismatch id=\(id) snippet=\"\(snippet)\"")
        Self.logger.info("UIKit bubble mismatch bounds=\(boundsDesc)")
        Self.logger.info("UIKit bubble mismatch bubble=\(bubbleDesc)")
    }
}
