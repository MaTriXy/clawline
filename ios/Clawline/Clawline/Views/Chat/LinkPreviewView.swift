//
//  LinkPreviewView.swift
//  Clawline
//
//  Created by Codex on 2/4/26.
//

import Foundation
import LinkPresentation
import SafariServices
import UIKit
import WebKit
#if canImport(SwiftUI)
import SwiftUI
#endif

final class LinkPreviewLoadCoordinator {
    static let shared = LinkPreviewLoadCoordinator(maxConcurrent: 3)

    private let maxConcurrent: Int
    private let queue = DispatchQueue(label: "co.clicketyclacks.Clawline.LinkPreviewLoadCoordinator")
    private var activeCount: Int = 0
    private var pending: [() -> Void] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquireSlot(_ onGranted: @escaping () -> Void) {
        queue.async {
            if self.activeCount < self.maxConcurrent {
                self.activeCount += 1
                DispatchQueue.main.async { onGranted() }
            } else {
                self.pending.append(onGranted)
            }
        }
    }

    func releaseSlot() {
        queue.async {
            if self.activeCount > 0 {
                self.activeCount -= 1
            }
            if !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                self.activeCount += 1
                DispatchQueue.main.async { next() }
            }
        }
    }
}

final class LinkPreviewView: UIView {
    enum State {
        case idle
        case loading
        case loaded
        case failed
    }

    private enum Constants {
        static let minHeight: CGFloat = 140
        static let maxHeight: CGFloat = 360
        static let loadTimeout: TimeInterval = 12
    }

    private let stackView = UIStackView()
    private let previewContainer = UIView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let overlayButton = UIButton(type: .custom)

    private var linkView: LPLinkView?
    private var webView: WKWebView?
    private var webViewHeightConstraint: NSLayoutConstraint?
    private var metadataProvider: LPMetadataProvider?
    private var state: State = .idle
    private var currentURL: URL?
    private var loadToken = UUID()
    private var timeoutTimer: Timer?
    private var hasSlot = false

    var onHeightChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancelLoad(releaseSlot: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            requestSlotIfNeeded()
        } else {
            cancelLoad(releaseSlot: true)
        }
    }

    override var intrinsicContentSize: CGSize {
        let height = linkView?.intrinsicContentSize.height ?? Constants.minHeight
        let clamped = max(Constants.minHeight, min(Constants.maxHeight, height))
        return CGSize(width: UIView.noIntrinsicMetric, height: clamped)
    }

    func configure(url: URL) {
        if currentURL == url, state != .failed { return }
        resetState()
        currentURL = url
        let hostLabel = url.host ?? url.absoluteString
        overlayButton.isAccessibilityElement = true
        overlayButton.accessibilityLabel = "Link preview: \(hostLabel)"
        overlayButton.accessibilityTraits = .link
        requestSlotIfNeeded()
    }

    func prepareForReuse() {
        cancelLoad(releaseSlot: true)
        currentURL = nil
        state = .idle
    }

    private func setupViews() {
        backgroundColor = .clear

        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = .clear
        stackView.addArrangedSubview(previewContainer)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        previewContainer.addSubview(spinner)

        overlayButton.translatesAutoresizingMaskIntoConstraints = false
        overlayButton.backgroundColor = .clear
        overlayButton.addTarget(self, action: #selector(handleOverlayTap), for: .touchUpInside)
        previewContainer.addSubview(overlayButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            overlayButton.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            overlayButton.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            overlayButton.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            overlayButton.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
        ])

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Preview unavailable"
        statusLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        stackView.addArrangedSubview(statusLabel)
    }

    private func requestSlotIfNeeded() {
        guard window != nil else { return }
        guard !hasSlot, let currentURL else { return }
        guard state == .idle else { return }

        setLoadingState()
        LinkPreviewLoadCoordinator.shared.acquireSlot { [weak self] in
            guard let self else { return }
            guard self.window != nil else {
                self.releaseSlotIfNeeded()
                return
            }
            self.hasSlot = true
            self.startLoad(url: currentURL)
        }
    }

    private func setLoadingState() {
        state = .loading
        statusLabel.isHidden = true
        previewContainer.isHidden = false
        spinner.startAnimating()
    }

    private func startLoad(url: URL) {
        setLoadingState()
        loadToken = UUID()
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: Constants.loadTimeout, repeats: false) { [weak self] _ in
            self?.handleFailure()
        }

        let provider = LPMetadataProvider()
        provider.timeout = Constants.loadTimeout
        metadataProvider = provider

        let token = loadToken
        provider.startFetchingMetadata(for: url) { [weak self] metadata, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.loadToken == token else { return }
                if let error {
                    _ = error
                    self.handleFailure()
                    return
                }
                guard let metadata else {
                    self.handleFailure()
                    return
                }
                self.applyMetadata(metadata)
            }
        }
    }

    private func applyMetadata(_ metadata: LPLinkMetadata) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        spinner.stopAnimating()

        if shouldFallbackToWebView(metadata: metadata) {
            showWebView()
            return
        }

        let linkView = linkView ?? LPLinkView(metadata: metadata)
        linkView.metadata = metadata
        linkView.translatesAutoresizingMaskIntoConstraints = false
        linkView.isUserInteractionEnabled = false
        linkView.backgroundColor = .clear

        if self.linkView == nil {
            previewContainer.addSubview(linkView)
            NSLayoutConstraint.activate([
                linkView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                linkView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                linkView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                linkView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
                linkView.heightAnchor.constraint(greaterThanOrEqualToConstant: Constants.minHeight),
                linkView.heightAnchor.constraint(lessThanOrEqualToConstant: Constants.maxHeight)
            ])
            self.linkView = linkView
        }

        state = .loaded
        releaseSlotIfNeeded()
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    private func resetState() {
        cancelLoad(releaseSlot: true)
        statusLabel.isHidden = true
        previewContainer.isHidden = false
        state = .idle
        currentURL = nil
    }

    private func cancelLoad(releaseSlot: Bool) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        metadataProvider?.cancel()
        metadataProvider = nil
        spinner.stopAnimating()
        webView?.stopLoading()
        if releaseSlot {
            releaseSlotIfNeeded()
        }
    }

    private func releaseSlotIfNeeded() {
        if hasSlot {
            hasSlot = false
            LinkPreviewLoadCoordinator.shared.releaseSlot()
        }
    }

    private func handleFailure() {
        guard state != .failed else { return }
        state = .failed
        cancelLoad(releaseSlot: true)
        previewContainer.isHidden = true
        statusLabel.isHidden = false
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    @objc private func handleOverlayTap() {
        guard let url = currentURL else { return }
#if os(visionOS)
        UIApplication.shared.open(url)
#else
        let safari = SFSafariViewController(url: url)
        parentViewController?.present(safari, animated: true)
#endif
    }

    private func shouldFallbackToWebView(metadata: LPLinkMetadata) -> Bool {
        looksLikeErrorJSON(metadata.title)
    }

    private func looksLikeErrorJSON(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return false }
        return trimmed.contains("\"type\"") && trimmed.contains("\"error\"")
    }

    private func showWebView() {
        guard let url = currentURL else {
            handleFailure()
            return
        }

        if linkView != nil {
            linkView?.removeFromSuperview()
            linkView = nil
        }

        let webView = webView ?? {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.isScrollEnabled = true
            view.scrollView.showsVerticalScrollIndicator = true
            view.allowsLinkPreview = false
            view.isUserInteractionEnabled = false
            return view
        }()

        if self.webView == nil {
            previewContainer.addSubview(webView)
            webViewHeightConstraint = webView.heightAnchor.constraint(greaterThanOrEqualToConstant: Constants.minHeight)
            let maxHeight = webView.heightAnchor.constraint(lessThanOrEqualToConstant: Constants.maxHeight)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                webView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                webView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
                webViewHeightConstraint!,
                maxHeight
            ])
            self.webView = webView
        }

        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Constants.loadTimeout))

        state = .loaded
        releaseSlotIfNeeded()
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }
}

struct LinkPreviewRepresentable: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LinkPreviewView {
        LinkPreviewView()
    }

    func updateUIView(_ uiView: LinkPreviewView, context: Context) {
        uiView.configure(url: url)
    }
}

private extension UIView {
    var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let viewController = next as? UIViewController {
                return viewController
            }
            responder = next
        }
        return nil
    }
}
