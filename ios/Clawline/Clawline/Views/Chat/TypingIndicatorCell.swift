//
//  TypingIndicatorCell.swift
//  Clawline
//
//  Typing indicator shown while CLU is processing a message.
//

import UIKit

final class TypingIndicatorCell: UICollectionViewCell {
    static let reuseIdentifier = "TypingIndicatorCell"
    /// Fixed ID used in the diffable data source for the typing indicator item.
    static let itemId = "__typing_indicator__"

    private let bubbleView = TypingIndicatorBubbleView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubbleView)
        NSLayoutConstraint.activate([
            bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor),
            bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(isCompact: Bool) {
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        bubbleView.configure(metrics: metrics)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        bubbleView.stopAnimating()
    }

    func startAnimating() {
        bubbleView.startAnimating()
    }

    func stopAnimating() {
        bubbleView.stopAnimating()
    }
}

final class TypingIndicatorBubbleView: UIView {
    private let backgroundView = UIView()
    private let shapeLayer = CAShapeLayer()
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
    private var animationTimer: Timer?

    // 1.5x the original size
    private let dotSize: CGFloat = 10
    private let dotSpacing: CGFloat = 8
    private let dotCount = 3

    // Corner radii matching assistant bubble style (sharp bottom-left)
    private let cornerRadiusLarge: CGFloat = 28
    private let cornerRadiusSharp: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .clear

        // Background bubble with custom shape
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.clipsToBounds = true
        backgroundView.layer.addSublayer(shapeLayer)
        addSubview(backgroundView)

        // Dots container
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.axis = .horizontal
        dotsStack.spacing = dotSpacing
        dotsStack.alignment = .center
        dotsStack.distribution = .equalSpacing
        addSubview(dotsStack)

        // Create dots
        for _ in 0..<dotCount {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = dotSize / 2
            dot.alpha = 0.4
            dotsStack.addArrangedSubview(dot)
            dotViews.append(dot)

            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: dotSize),
                dot.heightAnchor.constraint(equalToConstant: dotSize)
            ])
        }

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            dotsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotsStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(metrics: ChatFlowTheme.Metrics) {
        // Use assistant bubble colors (bubbleOther gradient approximation)
        let isDark = traitCollection.userInterfaceStyle == .dark
        let bubbleColor = isDark
            ? UIColor(red: 0.157, green: 0.141, blue: 0.133, alpha: 1.0)
            : UIColor(red: 0.969, green: 0.953, blue: 0.922, alpha: 1.0)
        let dotColor = isDark
            ? UIColor(red: 0.831, green: 0.769, blue: 0.690, alpha: 1.0)
            : UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 1.0)

        shapeLayer.fillColor = bubbleColor.cgColor
        dotViews.forEach { $0.backgroundColor = dotColor }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBubbleShape()
    }

    private func updateBubbleShape() {
        let rect = backgroundView.bounds
        guard rect.width > 0, rect.height > 0 else { return }

        // Create path with assistant bubble corner radii (sharp bottom-left)
        let path = UIBezierPath()
        let topLeft = cornerRadiusLarge
        let topRight = cornerRadiusLarge
        let bottomLeft = cornerRadiusSharp  // Sharp corner like assistant bubbles
        let bottomRight = cornerRadiusLarge

        path.move(to: CGPoint(x: topLeft, y: 0))
        path.addLine(to: CGPoint(x: rect.width - topRight, y: 0))
        path.addArc(withCenter: CGPoint(x: rect.width - topRight, y: topRight),
                    radius: topRight, startAngle: -.pi/2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - bottomRight))
        path.addArc(withCenter: CGPoint(x: rect.width - bottomRight, y: rect.height - bottomRight),
                    radius: bottomRight, startAngle: 0, endAngle: .pi/2, clockwise: true)
        path.addLine(to: CGPoint(x: bottomLeft, y: rect.height))
        path.addArc(withCenter: CGPoint(x: bottomLeft, y: rect.height - bottomLeft),
                    radius: bottomLeft, startAngle: .pi/2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: topLeft))
        path.addArc(withCenter: CGPoint(x: topLeft, y: topLeft),
                    radius: topLeft, startAngle: .pi, endAngle: -.pi/2, clockwise: true)
        path.close()

        shapeLayer.frame = rect
        shapeLayer.path = path.cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            configure(metrics: ChatFlowTheme.Metrics(isCompact: true))
        }
    }

    func startAnimating() {
        stopAnimating()

        // Reset all dots to base state
        dotViews.forEach { $0.alpha = 0.4; $0.transform = .identity }

        var currentDot = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.animateDot(at: currentDot)
            currentDot = (currentDot + 1) % self.dotCount
        }
        // Trigger first animation immediately
        animateDot(at: 0)
    }

    private func animateDot(at index: Int) {
        guard index < dotViews.count else { return }
        let dot = dotViews[index]

        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
            dot.alpha = 1.0
            dot.transform = CGAffineTransform(translationX: 0, y: -6)  // 1.5x the bounce
        } completion: { _ in
            UIView.animate(withDuration: 0.2, delay: 0.1, options: [.curveEaseIn]) {
                dot.alpha = 0.4
                dot.transform = .identity
            }
        }
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        dotViews.forEach { $0.alpha = 0.4; $0.transform = .identity }
    }

    override var intrinsicContentSize: CGSize {
        // 1.5x the original size (was 68x44, now ~94x66)
        let width = CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * dotSpacing + 48
        let height: CGFloat = 66
        return CGSize(width: width, height: height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }
}
