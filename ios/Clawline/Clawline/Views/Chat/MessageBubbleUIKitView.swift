//
//  MessageBubbleUIKitView.swift
//  Clawline
//
//  UIKit-only bubble view for layout debugging.
//

import HighlightSwift
import OSLog
import SwiftUI
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
    private let shadowContainerView = UIView()  // Separate view for shadow (masks clip shadows)
    private let bubbleBackgroundView = UIView()
    private let contentStack = UIStackView()
    private let headerStack = UIStackView()
    private let dynamicContentWrapper = UIView()  // Clips for truncation
    private let dynamicContentStack = UIStackView()  // Holds text + code blocks
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
    private var dynamicContentHeightConstraint: NSLayoutConstraint?
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
    private var dynamicContentViews: [UIView] = []
    private var isChromeless = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        // Shadow container (behind bubble, inset so white background is fully covered)
        shadowContainerView.translatesAutoresizingMaskIntoConstraints = false
        shadowContainerView.backgroundColor = .white  // Solid color needed for shadow to render
        shadowContainerView.layer.cornerRadius = 18
        shadowContainerView.layer.cornerCurve = .continuous
        addSubview(shadowContainerView)

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
            minWidthConstraint,
            // Shadow container inset so white background is fully covered by bubble
            shadowContainerView.leadingAnchor.constraint(equalTo: bubbleBackgroundView.leadingAnchor, constant: 6),
            shadowContainerView.topAnchor.constraint(equalTo: bubbleBackgroundView.topAnchor, constant: 6),
            shadowContainerView.trailingAnchor.constraint(equalTo: bubbleBackgroundView.trailingAnchor, constant: -6),
            shadowContainerView.bottomAnchor.constraint(equalTo: bubbleBackgroundView.bottomAnchor, constant: -6)
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
        contentStack.alignment = .fill
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

        // Dynamic content wrapper clips content for truncation
        dynamicContentWrapper.clipsToBounds = true
        dynamicContentStack.axis = .vertical
        dynamicContentStack.spacing = 10
        dynamicContentStack.translatesAutoresizingMaskIntoConstraints = false
        dynamicContentWrapper.addSubview(dynamicContentStack)
        NSLayoutConstraint.activate([
            dynamicContentStack.topAnchor.constraint(equalTo: dynamicContentWrapper.topAnchor),
            dynamicContentStack.leadingAnchor.constraint(equalTo: dynamicContentWrapper.leadingAnchor),
            dynamicContentStack.trailingAnchor.constraint(equalTo: dynamicContentWrapper.trailingAnchor),
            dynamicContentStack.bottomAnchor.constraint(lessThanOrEqualTo: dynamicContentWrapper.bottomAnchor)
        ])
        contentStack.addArrangedSubview(dynamicContentWrapper)

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

        // Shadow container: shadowPath for inset shadow view
        let shadowPath = UIBezierPath(roundedRect: shadowContainerView.bounds, cornerRadius: 18)
        shadowContainerView.layer.shadowPath = shadowPath.cgPath

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

        // Remove old dynamic content views
        for view in dynamicContentViews {
            dynamicContentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        dynamicContentViews.removeAll()

        // Check for chromeless emoji mode (1-3 emojis only, centered with double font)
        let isChromelessEmoji = presentation.chromelessStyle == .emoji

        // Set up bodyLabel with text content (excluding code blocks)
        if isChromelessEmoji, case .inlineEmoji(let value) = presentation.parts.first {
            // Chromeless emoji: double font size, centered
            let emojiFont = UIFont.systemFont(ofSize: (metrics.shortFontSize + 8) * 2)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            bodyLabel.attributedText = NSAttributedString(
                string: value,
                attributes: [
                    .font: emojiFont,
                    .paragraphStyle: paragraph
                ]
            )
        } else {
            bodyLabel.attributedText = MessageBubbleUIKitView.attributedBodyTextOnly(
                presentation: presentation,
                sizeClass: sizeClass,
                metrics: metrics,
                inkColor: palette.ink
            )
        }

        // Add bodyLabel to dynamicContentStack if it has content
        let hasTextContent = !(bodyLabel.attributedText?.string.isEmpty ?? true)
        if hasTextContent {
            dynamicContentStack.addArrangedSubview(bodyLabel)
            dynamicContentViews.append(bodyLabel)
        }

        // Add code block views to dynamicContentStack
        let codeBlocks = presentation.parts.compactMap { part -> (String?, String)? in
            if case .code(let lang, let code) = part { return (lang, code) }
            return nil
        }
        for (lang, code) in codeBlocks {
            let codeView = CodeBlockUIKitView()
            codeView.configure(language: lang, code: code)
            dynamicContentStack.addArrangedSubview(codeView)
            dynamicContentViews.append(codeView)
        }

        // Add table views to dynamicContentStack
        let tables = presentation.parts.compactMap { part -> TableModel? in
            if case .table(let model) = part { return model }
            return nil
        }
        for tableModel in tables {
            let tableView = TableUIKitWrapperView()
            tableView.configure(
                model: tableModel,
                role: message.role,
                metrics: metrics,
                maxLineWidth: ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize),
                onExpand: { [weak self] in self?.onRequestExpand?() }
            )
            dynamicContentStack.addArrangedSubview(tableView)
            dynamicContentViews.append(tableView)
        }

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

        dynamicContentHeightConstraint?.isActive = false
        shouldTruncate = false
        truncationContainer.isHidden = true
        fadeView.isHidden = true
        NSLayoutConstraint.deactivate(fadeConstraints)
        fadeConstraints.removeAll()

        if sizeClass == .long {
            let contentWidth = maxWidth - (metrics.bubblePaddingHorizontal * 2)
            let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
            let measureWidth = min(contentWidth, maxLineWidth)

            // Calculate total height of all dynamic content (text + code blocks)
            var totalHeight: CGFloat = 0
            let spacing = dynamicContentStack.spacing
            for (index, view) in dynamicContentViews.enumerated() {
                let viewHeight = view.sizeThatFits(CGSize(width: measureWidth, height: .greatestFiniteMagnitude)).height
                totalHeight += viewHeight
                if index > 0 {
                    totalHeight += spacing
                }
            }

            if totalHeight > metrics.truncationHeight {
                shouldTruncate = true
                // Simply constrain the wrapper height - it will clip the overflow
                let heightConstraint = dynamicContentWrapper.heightAnchor.constraint(equalToConstant: metrics.truncationHeight)
                heightConstraint.isActive = true
                dynamicContentHeightConstraint = heightConstraint

                truncationContainer.isHidden = false
                truncationLabel.textColor = (message.role == .user) ? palette.terracotta : palette.warmBrown
                fadeView.isHidden = false
                // Use bubble gradient end colors for seamless fade
                let bottomColor = message.role == .user ? palette.bubbleSelfGradient.last! : palette.bubbleOtherGradient.last!
                fadeView.updateColors(
                    top: bottomColor.withAlphaComponent(0),
                    bottom: bottomColor
                )
                let fadeHeight: CGFloat = 100
                fadeConstraints = [
                    fadeView.leadingAnchor.constraint(equalTo: dynamicContentWrapper.leadingAnchor),
                    fadeView.trailingAnchor.constraint(equalTo: dynamicContentWrapper.trailingAnchor),
                    fadeView.bottomAnchor.constraint(equalTo: dynamicContentWrapper.bottomAnchor),
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

        // Soft shadow
        shadowContainerView.layer.shadowColor = UIColor.black.cgColor
        shadowContainerView.layer.shadowRadius = 12
        shadowContainerView.layer.shadowOffset = CGSize(width: 0, height: 5)
        let shadowOpacity: Float = palette.isDark ? 0.50 : 0.40
        shadowContainerView.layer.shadowOpacity = shadowOpacity

        // Chromeless mode: hide bubble chrome but keep padding
        // Truncated content must keep chrome (provides container for "Show more")
        isChromeless = presentation.isChromeless && !shouldTruncate
        gradientLayer.isHidden = isChromeless
        borderGradientLayer.isHidden = isChromeless
        topHighlightLayer.isHidden = isChromeless
        shadowContainerView.isHidden = isChromeless
        shadowContainerView.layer.shadowOpacity = isChromeless ? 0 : shadowOpacity

        // Update border colors for light/dark mode
        updateBorderColors(isDark: palette.isDark)
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

        // Update shadow (on separate shadow container view)
        shadowContainerView.layer.shadowColor = UIColor.black.cgColor
        shadowContainerView.layer.shadowRadius = 12
        let shadowOpacity: Float = palette.isDark ? 0.50 : 0.40
        shadowContainerView.layer.shadowOpacity = isChromeless ? 0 : shadowOpacity

        // Update border colors for light/dark mode
        updateBorderColors(isDark: palette.isDark)

        // Update fade view - use bubble gradient end colors
        // Top color must match bottom color (just transparent) to avoid haze
        let bottomColor = currentMessageRole == .user ? palette.bubbleSelfGradient.last! : palette.bubbleOtherGradient.last!
        fadeView.updateColors(
            top: bottomColor.withAlphaComponent(0),
            bottom: bottomColor
        )
    }

    private func updateBorderColors(isDark: Bool) {
        if isDark {
            // Dark mode: white highlight at top fading down
            borderGradientLayer.colors = [
                UIColor.white.withAlphaComponent(0.14).cgColor,
                UIColor.white.withAlphaComponent(0.05).cgColor,
                UIColor.clear.cgColor,
                UIColor.clear.cgColor
            ]
            topHighlightLayer.colors = [
                UIColor.white.withAlphaComponent(0.12).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor
            ]
        } else {
            // Light mode: subtle dark border all around for definition
            let borderColor = UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 1)
            borderGradientLayer.colors = [
                borderColor.withAlphaComponent(0.10).cgColor,
                borderColor.withAlphaComponent(0.08).cgColor,
                borderColor.withAlphaComponent(0.06).cgColor,
                borderColor.withAlphaComponent(0.04).cgColor
            ]
            topHighlightLayer.colors = [
                borderColor.withAlphaComponent(0.05).cgColor,
                borderColor.withAlphaComponent(0.0).cgColor
            ]
        }
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

    /// Builds attributed string for text content only (excludes code blocks which are rendered separately)
    private static func attributedBodyTextOnly(presentation: MessagePresentation,
                                               sizeClass: MessageSizeClass,
                                               metrics: ChatFlowTheme.Metrics,
                                               inkColor: UIColor) -> NSAttributedString {
        let baseFont: UIFont
        let lineSpacing: CGFloat
        switch sizeClass {
        case .short:
            baseFont = UIFont.systemFont(ofSize: metrics.shortFontSize, weight: .semibold)
            lineSpacing = 0
        case .medium:
            baseFont = UIFont.systemFont(ofSize: metrics.mediumFontSize, weight: .medium)
            lineSpacing = 4
        case .long:
            baseFont = UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular)
            lineSpacing = 4
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: inkColor,
            .paragraphStyle: paragraph
        ]

        let result = NSMutableAttributedString()
        // Filter to only text parts (no code blocks or tables - those are rendered as separate views)
        let textParts = presentation.parts.filter {
            switch $0 {
            case .text, .markdown, .inlineEmoji:
                return true
            case .code, .table, .linkPreview, .image, .gallery:
                return false
            }
        }

        for (index, part) in textParts.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n", attributes: baseAttributes))
            }

            switch part {
            case .text(let value):
                result.append(NSAttributedString(string: value, attributes: baseAttributes))

            case .markdown(let value):
                // Parse markdown to attributed string
                if let parsed = parseMarkdown(value, baseFont: baseFont, inkColor: inkColor, lineSpacing: lineSpacing) {
                    result.append(parsed)
                } else {
                    result.append(NSAttributedString(string: value, attributes: baseAttributes))
                }

            case .inlineEmoji(let value):
                result.append(NSAttributedString(string: value, attributes: baseAttributes))

            case .code, .table, .linkPreview, .image, .gallery:
                break
            }
        }

        return result
    }

    /// Parse markdown string into NSAttributedString with proper formatting
    private static func parseMarkdown(_ markdown: String,
                                      baseFont: UIFont,
                                      inkColor: UIColor,
                                      lineSpacing: CGFloat) -> NSAttributedString? {
        // Use AttributedString for markdown parsing, then convert to NSAttributedString
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return nil
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left

        // Convert to NSAttributedString and apply base styling
        let nsAttributed = NSMutableAttributedString(attributed)

        // Apply base font and color to entire string first
        let fullRange = NSRange(location: 0, length: nsAttributed.length)
        nsAttributed.addAttribute(.foregroundColor, value: inkColor, range: fullRange)
        nsAttributed.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        // Walk through and update fonts while preserving traits
        nsAttributed.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let existingFont = value as? UIFont else {
                nsAttributed.addAttribute(.font, value: baseFont, range: range)
                return
            }

            let traits = existingFont.fontDescriptor.symbolicTraits
            var newFont = baseFont

            if traits.contains(.traitBold) && traits.contains(.traitItalic) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
                    newFont = UIFont(descriptor: descriptor, size: baseFont.pointSize)
                }
            } else if traits.contains(.traitBold) {
                newFont = UIFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
            } else if traits.contains(.traitItalic) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    newFont = UIFont(descriptor: descriptor, size: baseFont.pointSize)
                }
            } else if traits.contains(.traitMonoSpace) {
                newFont = UIFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .medium)
                // Add code-style background using system fill for proper appearance
                nsAttributed.addAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, range: range)
            }

            nsAttributed.addAttribute(.font, value: newFont, range: range)
        }

        return nsAttributed
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
            borderSubtle: UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 0.18),
            fadeTop: UIColor(red: 1, green: 1, blue: 1, alpha: 0),
            failureText: UIColor(red: 0.6, green: 0.12, blue: 0.12, alpha: 1),
            failureBackground: UIColor(red: 0.98, green: 0.92, blue: 0.92, alpha: 1),
            shadowNear: UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 0.30)
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

// MARK: - Code Block View

/// UIKit view for rendering code blocks with proper container styling and syntax highlighting.
/// Matches the SwiftUI CodeBlockView in the design system.
final class CodeBlockUIKitView: UIView {
    private let languageLabel = UILabel()
    private let codeScrollView = UIScrollView()
    private let codeLabel = UILabel()
    private var currentCode: String = ""
    private var currentLanguage: String?
    private static let highlight = Highlight()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        // Configure scroll view for horizontal scrolling
        codeScrollView.showsHorizontalScrollIndicator = true
        codeScrollView.showsVerticalScrollIndicator = false
        codeScrollView.alwaysBounceHorizontal = false
        codeScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Add code label to scroll view
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeScrollView.addSubview(codeLabel)

        let stack = UIStackView(arrangedSubviews: [languageLabel, codeScrollView])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            // Code label fills scroll view content
            codeLabel.topAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.topAnchor),
            codeLabel.leadingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.leadingAnchor),
            codeLabel.trailingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.trailingAnchor),
            codeLabel.bottomAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.bottomAnchor),

            // Scroll view height matches content (no vertical scrolling)
            codeScrollView.contentLayoutGuide.heightAnchor.constraint(equalTo: codeScrollView.frameLayoutGuide.heightAnchor)
        ])

        languageLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        codeLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        codeLabel.numberOfLines = 0

        updateColors()
    }

    private func updateColors() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        if isDark {
            backgroundColor = UIColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1)
            languageLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        } else {
            backgroundColor = UIColor(red: 0.945, green: 0.933, blue: 0.910, alpha: 1)
            languageLabel.textColor = UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 0.6)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            updateColors()
            applyHighlightedCode()
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        // Use systemLayoutSizeFitting to respect Auto Layout constraints
        let targetSize = CGSize(width: size.width, height: UIView.layoutFittingCompressedSize.height)
        return systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    }

    func configure(language: String?, code: String) {
        currentLanguage = language
        currentCode = code

        if let lang = language, !lang.isEmpty {
            languageLabel.text = lang.uppercased()
            languageLabel.isHidden = false
        } else {
            languageLabel.isHidden = true
        }

        // Show plain text immediately, then apply highlighting async
        applyPlainCode()
        updateColors()
        applyHighlightedCode()
    }

    private func applyHighlightedCode() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let colors: HighlightColors = isDark ? .dark(.atomOne) : .light(.atomOne)

        Task { @MainActor in
            do {
                // Map common language names to HighlightSwift language strings
                let langString = Self.mapLanguageString(currentLanguage)
                let highlighted: AttributedString
                if let lang = langString {
                    highlighted = try await Self.highlight.attributedText(currentCode, language: lang, colors: colors)
                } else {
                    highlighted = try await Self.highlight.attributedText(currentCode, colors: colors)
                }

                // Convert to NSAttributedString and apply our font
                let mutable = NSMutableAttributedString(highlighted)
                let fullRange = NSRange(location: 0, length: mutable.length)

                // Apply monospace font while preserving colors
                mutable.enumerateAttribute(.font, in: fullRange, options: []) { _, range, _ in
                    mutable.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: range)
                }

                // Apply line spacing
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 4
                mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

                self.codeLabel.attributedText = mutable
            } catch {
                // Fallback to plain text on error
                self.applyPlainCode()
            }
        }
    }

    private func applyPlainCode() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let textColor = isDark
            ? UIColor.white.withAlphaComponent(0.9)
            : UIColor(red: 0.239, green: 0.204, blue: 0.161, alpha: 1)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributed = NSAttributedString(
            string: currentCode,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]
        )
        codeLabel.attributedText = attributed
    }

    /// Maps common language identifiers to highlight.js language names
    private static func mapLanguageString(_ language: String?) -> String? {
        guard let lang = language?.lowercased() else { return nil }
        switch lang {
        case "swift": return "swift"
        case "python", "py": return "python"
        case "javascript", "js": return "javascript"
        case "typescript", "ts": return "typescript"
        case "java": return "java"
        case "kotlin", "kt": return "kotlin"
        case "c": return "c"
        case "cpp", "c++": return "cpp"
        case "csharp", "c#", "cs": return "csharp"
        case "go", "golang": return "go"
        case "rust", "rs": return "rust"
        case "ruby", "rb": return "ruby"
        case "php": return "php"
        case "sql": return "sql"
        case "bash", "sh", "shell", "zsh": return "bash"
        case "html": return "html"
        case "css": return "css"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "xml": return "xml"
        case "markdown", "md": return "markdown"
        case "objectivec", "objc", "objective-c": return "objectivec"
        case "dart": return "dart"
        case "scala": return "scala"
        case "r": return "r"
        case "perl": return "perl"
        case "lua": return "lua"
        case "haskell", "hs": return "haskell"
        case "elixir", "ex": return "elixir"
        case "clojure", "clj": return "clojure"
        case "fsharp", "f#", "fs": return "fsharp"
        case "ocaml", "ml": return "ocaml"
        case "erlang", "erl": return "erlang"
        case "julia", "jl": return "julia"
        case "groovy": return "groovy"
        case "powershell", "ps1": return "powershell"
        case "dockerfile", "docker": return "dockerfile"
        case "makefile", "make": return "makefile"
        case "diff": return "diff"
        case "ini": return "ini"
        default: return lang // Try using the provided language directly
        }
    }
}

// MARK: - Table Wrapper View

/// UIKit wrapper for the SwiftUI MarkdownTableView.
/// Embeds the SwiftUI table using UIHostingController for consistent rendering.
final class TableUIKitWrapperView: UIView {
    private var hostingController: UIHostingController<AnyView>?
    private var currentModel: TableModel?
    private var currentRole: Message.Role = .assistant
    private var currentMetrics: ChatFlowTheme.Metrics?
    private var onExpandAction: (() -> Void)?
    private var cachedHeight: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        model: TableModel,
        role: Message.Role,
        metrics: ChatFlowTheme.Metrics,
        maxLineWidth: CGFloat,
        onExpand: @escaping () -> Void
    ) {
        currentModel = model
        currentRole = role
        currentMetrics = metrics
        onExpandAction = onExpand
        cachedHeight = nil

        // Remove existing hosting controller
        hostingController?.view.removeFromSuperview()
        hostingController = nil

        // Create SwiftUI table view
        let tableView = MarkdownTableView(
            model: model,
            role: role,
            metrics: metrics,
            maxLineWidth: maxLineWidth,
            colorScheme: traitCollection.userInterfaceStyle == .dark ? .dark : .light,
            isExpanded: false,
            onExpand: onExpand,
            onCollapse: { }
        )

        let hostingController = UIHostingController(rootView: AnyView(tableView))
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        // Disable safe area insets to prevent layout issues
        hostingController._disableSafeArea = true
        addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        self.hostingController = hostingController

        // Force layout to get accurate size
        hostingController.view.layoutIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle,
           let model = currentModel,
           let metrics = currentMetrics,
           let onExpand = onExpandAction {
            // Reconfigure to update color scheme
            configure(
                model: model,
                role: currentRole,
                metrics: metrics,
                maxLineWidth: ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize),
                onExpand: onExpand
            )
        }
    }

    override var intrinsicContentSize: CGSize {
        guard let hostingView = hostingController?.view else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 44)
        }
        let size = hostingView.intrinsicContentSize
        if size.height > 0 {
            return size
        }
        // Fallback: calculate based on fitting size
        let fittingSize = hostingView.systemLayoutSizeFitting(
            CGSize(width: bounds.width > 0 ? bounds.width : 300, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return fittingSize
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard let hostingView = hostingController?.view else {
            return CGSize(width: size.width, height: 44)
        }

        // Force layout pass to ensure accurate measurement
        hostingView.setNeedsLayout()
        hostingView.layoutIfNeeded()

        let targetSize = CGSize(width: size.width, height: UIView.layoutFittingCompressedSize.height)
        let fittingSize = hostingView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        // Cache and return
        cachedHeight = fittingSize.height
        return fittingSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Invalidate intrinsic content size when layout changes
        invalidateIntrinsicContentSize()
    }
}
