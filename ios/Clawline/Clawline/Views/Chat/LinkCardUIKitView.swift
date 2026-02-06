//
//  LinkCardUIKitView.swift
//  Clawline
//
//  Lightweight "link card" for message bubbles.
//

import UIKit

final class LinkCardUIKitView: UIControl {
    private let shadowHost = UIView()
    private let cardBackground = UIView()
    private let indicatorView = UIView()
    private let domainLabel = UILabel()
    private let titleLabel = UILabel()
    private let descLabel = UILabel()
    private let contentStack = UIStackView()
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        clipsToBounds = false

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.backgroundColor = .clear
        shadowHost.clipsToBounds = false
        addSubview(shadowHost)

        cardBackground.translatesAutoresizingMaskIntoConstraints = false
        cardBackground.layer.cornerRadius = 16
        cardBackground.layer.cornerCurve = .continuous
        cardBackground.clipsToBounds = true
        shadowHost.addSubview(cardBackground)

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.layer.cornerRadius = 3
        indicatorView.layer.cornerCurve = .continuous

        domainLabel.translatesAutoresizingMaskIntoConstraints = false
        domainLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        domainLabel.numberOfLines = 1
        domainLabel.lineBreakMode = .byTruncatingTail

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        descLabel.numberOfLines = 2
        descLabel.lineBreakMode = .byTruncatingTail

        let domainRow = UIStackView(arrangedSubviews: [indicatorView, domainLabel])
        domainRow.translatesAutoresizingMaskIntoConstraints = false
        domainRow.axis = .horizontal
        domainRow.alignment = .center
        domainRow.spacing = 8

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 0
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        contentStack.addArrangedSubview(domainRow)
        contentStack.setCustomSpacing(6, after: domainRow)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.setCustomSpacing(4, after: titleLabel)
        contentStack.addArrangedSubview(descLabel)
        cardBackground.addSubview(contentStack)

        NSLayoutConstraint.activate([
            // Keep shadow visible even though bubble content clips; reserve a small inset for blur.
            shadowHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            shadowHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            shadowHost.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            shadowHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            cardBackground.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            cardBackground.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            cardBackground.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            cardBackground.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),

            indicatorView.widthAnchor.constraint(equalToConstant: 6),
            indicatorView.heightAnchor.constraint(equalToConstant: 6),

            contentStack.leadingAnchor.constraint(equalTo: cardBackground.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: cardBackground.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: cardBackground.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(url: URL, palette: ChatFlowUIKitTheme.Palette) {
        self.url = url

        // Match design-system/chat-flow-organic: .link-preview-card
        cardBackground.backgroundColor = palette.isDark
            ? UIColor.black.withAlphaComponent(0.25)
            : UIColor.white.withAlphaComponent(0.7)

        shadowHost.layer.shadowOffset = CGSize(width: 0, height: 2)
        shadowHost.layer.shadowRadius = 4
        if palette.isDark {
            shadowHost.layer.shadowColor = UIColor.black.cgColor
            shadowHost.layer.shadowOpacity = 0.15
        } else {
            shadowHost.layer.shadowColor = UIColor(red: 60/255, green: 45/255, blue: 30/255, alpha: 1).cgColor
            shadowHost.layer.shadowOpacity = 0.06
        }

        indicatorView.backgroundColor = palette.terracotta

        let host = (url.host ?? url.absoluteString)
        let domainText = host.uppercased()
        domainLabel.attributedText = NSAttributedString(
            string: domainText,
            attributes: [
                .kern: 0.5,
                .foregroundColor: palette.warmBrown
            ]
        )

        // We don't have page metadata here. Use best-effort URL-derived title/description.
        let title: String = {
            let last = url.lastPathComponent
            if !last.isEmpty, last != "/" { return last }
            return host
        }()
        titleLabel.text = title

        var desc = url.path
        if let query = url.query, !query.isEmpty {
            desc += "?\(query)"
        }
        if desc.isEmpty || desc == "/" {
            desc = url.absoluteString
        }
        descLabel.text = desc

        domainLabel.textColor = palette.warmBrown
        titleLabel.textColor = palette.ink
        descLabel.textColor = palette.warmBrown

        accessibilityLabel = "Open link: \(host)"
    }

    override var isHighlighted: Bool {
        didSet {
            let alpha: CGFloat = isHighlighted ? 0.85 : 1.0
            shadowHost.alpha = alpha
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let target = CGSize(width: size.width, height: UIView.layoutFittingCompressedSize.height)
        return systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    @objc private func handleTap() {
        guard let url else { return }
        UIApplication.shared.open(url)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Update shadow path for better performance and correct shape.
        let cornerRadius = cardBackground.layer.cornerRadius
        let path = UIBezierPath(roundedRect: shadowHost.bounds, cornerRadius: cornerRadius).cgPath
        shadowHost.layer.shadowPath = path
    }
}
