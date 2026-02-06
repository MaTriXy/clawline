//
//  LinkCardUIKitView.swift
//  Clawline
//
//  Lightweight "link card" for message bubbles.
//

import UIKit

final class LinkCardUIKitView: UIControl {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevronView = UIImageView()
    private let stack = UIStackView()
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.image = UIImage(systemName: "link")

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevronView.image = UIImage(systemName: "chevron.right")

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.axis = .vertical
        labels.spacing = 2

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(labels)
        stack.addArrangedSubview(chevronView)
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 14),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(url: URL, palette: ChatFlowUIKitTheme.Palette) {
        self.url = url

        // Subtle fill distinct from bubble background.
        backgroundColor = palette.isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.04)
        layer.borderWidth = 1
        layer.borderColor = ChatFlowUIKitTheme.borderSubtle(isDark: palette.isDark).cgColor

        let host = url.host ?? url.absoluteString
        titleLabel.text = host

        var subtitle = url.path
        if let query = url.query, !query.isEmpty {
            subtitle += "?\(query)"
        }
        if subtitle.isEmpty { subtitle = url.absoluteString }
        subtitleLabel.text = subtitle

        let textColor = palette.ink
        titleLabel.textColor = textColor
        subtitleLabel.textColor = textColor.withAlphaComponent(0.8)
        iconView.tintColor = textColor.withAlphaComponent(0.85)
        chevronView.tintColor = textColor.withAlphaComponent(0.55)

        accessibilityLabel = "Open link: \(host)"
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
}

