//
//  LinkPreviewView.swift
//  Clawline
//
//  Created by Codex on 2/4/26.
//

import Darwin
import Foundation
import OSLog
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
    private var nextSeq: Int64 = 0
    private var pending: [(id: UUID, priority: Int, seq: Int64, onGranted: () -> Void)] = []
    var onActiveCountZero: (() -> Void)?

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    @discardableResult
    func acquireSlot(priority: Int, _ onGranted: @escaping () -> Void) -> UUID {
        let id = UUID()
        queue.async {
            if self.activeCount < self.maxConcurrent {
                self.activeCount += 1
                DispatchQueue.main.async { onGranted() }
            } else {
                self.nextSeq += 1
                self.pending.append((id: id, priority: priority, seq: self.nextSeq, onGranted: onGranted))
            }
        }
        return id
    }

    func cancelPending(_ id: UUID) {
        queue.async {
            self.pending.removeAll(where: { $0.id == id })
        }
    }

    func releaseSlot() {
        queue.async {
            if self.activeCount > 0 {
                self.activeCount -= 1
            }
            if !self.pending.isEmpty {
                // Prefer on-screen (high priority) previews so scroll-back doesn't starve.
                var bestIndex = 0
                for i in 1..<self.pending.count {
                    let a = self.pending[i]
                    let b = self.pending[bestIndex]
                    if a.priority > b.priority || (a.priority == b.priority && a.seq < b.seq) {
                        bestIndex = i
                    }
                }
                let next = self.pending.remove(at: bestIndex).onGranted
                self.activeCount += 1
                DispatchQueue.main.async { next() }
            }
            if self.activeCount == 0 {
                let callback = self.onActiveCountZero
                DispatchQueue.main.async { callback?() }
            }
        }
    }

    func isIdle() -> Bool {
        queue.sync { activeCount == 0 }
    }
}

final class LinkPreviewSharedResources {
    static let shared = LinkPreviewSharedResources()

    private(set) var processPool: WKProcessPool = WKProcessPool()
    private var pendingReset = false

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        LinkPreviewLoadCoordinator.shared.onActiveCountZero = { [weak self] in
            self?.handleActiveCountZero()
        }
    }

    @objc private func handleMemoryWarning() {
        pendingReset = true
        if LinkPreviewLoadCoordinator.shared.isIdle() {
            resetProcessPool()
        }
    }

    private func handleActiveCountZero() {
        if pendingReset {
            resetProcessPool()
        }
    }

    private func resetProcessPool() {
        processPool = WKProcessPool()
        pendingReset = false
    }
}

final class LinkPreviewView: UIView, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "LinkPreview")
    private static let heightCache = NSCache<NSString, NSNumber>()

    enum State {
        case idle
        case loading
        case loaded
        case failed
    }

    enum FailureReason: String {
        case timeout
        case missingHost
        case hostBlocked
        case blockedIPAddressHost
        case redirectLimitExceeded
        case redirectHostBlocked
        case pinnedHostValidationFailed
        case nonHTMLMimeType
        case navigationError
        case provisionalNavigationError
        case emptyBodyHeuristic
        case unknown
    }

    enum CancelReason: String {
        case deinitCancel
        case removedFromWindow
        case reuse
        case resetState
        case failureCleanup
    }

    private enum Constants {
        static let minHeight: CGFloat = 140
        static let defaultMaxHeight: CGFloat = 360
        static let loadTimeout: TimeInterval = 12
        static let slotWaitTimeout: TimeInterval = 60
        static let emptyBodyDelay: TimeInterval = 0.5
        static let maxRedirects = 5
        static let mediaCornerRadius: CGFloat = 12
    }

    private let stackView = UIStackView()
    private let webContainer = UIView()
    private let statusLabel = UILabel()
    private let reloadButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let overlayButton = UIButton(type: .custom)
    private let webView: WKWebView
    private var webViewHeightConstraint: NSLayoutConstraint!
    private var maxHeight: CGFloat = Constants.defaultMaxHeight

    private var state: State = .idle
    private var currentURL: URL?
    private var configuredURLKey: String?
    private var currentHost: String?
    private var pinnedIPs: Set<String> = []
    private var redirectCount = 0

    private var loadToken = UUID()
    private var handlerName: String?
    private var handlerRegistered = false
    private var heightUpdates = 0

    private var slotWaitTimer: Timer?
    private var loadTimeoutTimer: Timer?
    private var fallbackTimer: Timer?

    private var hasSlot = false
    private var slotWaitStarted = false
    private var pendingSlotRequestId: UUID?

    private var canLockHeight = false
    private var isHeightLocked = false

    var onHeightChange: (() -> Void)?

    private var loadStartedAt: CFTimeInterval?
    private var lastFailureReason: FailureReason?
    private var didShowEmptyBodyWarning = false

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        configuration.processPool = LinkPreviewSharedResources.shared.processPool
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView

        super.init(frame: frame)

        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        logCancel(.deinitCancel)
        cancelLoad(releaseSlot: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            requestSlotIfNeeded()
        } else {
            logCancel(.removedFromWindow)
            cancelLoad(releaseSlot: true)
        }
    }

    override var intrinsicContentSize: CGSize {
        let height = webViewHeightConstraint?.constant ?? Constants.minHeight
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    func configure(url: URL, maxHeight: CGFloat? = nil) {
        if currentURL == url, state != .failed { return }
        resetState()
        if let maxHeight {
            self.maxHeight = max(Constants.minHeight, maxHeight)
        } else {
            self.maxHeight = Constants.defaultMaxHeight
        }
        configuredURLKey = url.absoluteString
        // Flynn directive: keep link preview height stable once determined. Use cached height
        // on scroll-back; only re-measure after explicit reload.
        if let cached = Self.heightCache.object(forKey: url.absoluteString as NSString) {
            isHeightLocked = true
            canLockHeight = false
            webViewHeightConstraint.constant = max(Constants.minHeight, min(self.maxHeight, CGFloat(truncating: cached)))
            invalidateIntrinsicContentSize()
            onHeightChange?()
        } else if abs(webViewHeightConstraint.constant - Constants.minHeight) > 1 {
            webViewHeightConstraint.constant = Constants.minHeight
            invalidateIntrinsicContentSize()
            onHeightChange?()
        }
        currentURL = url
        let hostLabel = url.host ?? url.absoluteString
        isAccessibilityElement = true
        accessibilityLabel = "Link preview: \(hostLabel)"
        accessibilityTraits = .link
        requestSlotIfNeeded()
        logger.info("configure url=\(url.absoluteString, privacy: .public)")
    }

    func prepareForReuse() {
        logCancel(.reuse)
        cancelLoad(releaseSlot: true)
        currentURL = nil
        configuredURLKey = nil
        currentHost = nil
        pinnedIPs = []
        redirectCount = 0
        state = .idle
        pendingSlotRequestId = nil
        canLockHeight = false
        isHeightLocked = false
    }

    private func setupViews() {
        backgroundColor = .clear
        // Prevent the web content from painting outside the preview bounds, which can
        // visually overlap adjacent arranged subviews (message text above/below).
        clipsToBounds = true

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

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = .clear
        webContainer.clipsToBounds = true
        // Match other embedded media (images/tables) with continuous rounded corners.
        webContainer.layer.cornerRadius = Constants.mediaCornerRadius
        webContainer.layer.cornerCurve = .continuous
        webContainer.layer.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner
        ]
        stackView.addArrangedSubview(webContainer)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.clipsToBounds = true
        // Apply the same continuous corner mask to WKWebView internals to ensure the
        // bottom corners clip correctly (WKWebView uses internal tiled layers).
        webView.layer.cornerRadius = Constants.mediaCornerRadius
        webView.layer.cornerCurve = .continuous
        webView.layer.maskedCorners = webContainer.layer.maskedCorners
        webView.scrollView.clipsToBounds = true
        webView.scrollView.layer.cornerRadius = Constants.mediaCornerRadius
        webView.scrollView.layer.cornerCurve = .continuous
        webView.scrollView.layer.maskedCorners = webContainer.layer.maskedCorners
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.alwaysBounceVertical = false
        // Ensure the page starts at the top of the preview viewport and doesn't
        // apply safe-area based insets inside message bubbles.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.allowsLinkPreview = false
        webView.isUserInteractionEnabled = true
        webContainer.addSubview(webView)

        // Tap anywhere on the preview to open in the browser, but allow scrolling.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleOverlayTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delegate = self
        webContainer.addGestureRecognizer(tap)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        webContainer.addSubview(spinner)

        webViewHeightConstraint = webView.heightAnchor.constraint(equalToConstant: Constants.minHeight)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            webViewHeightConstraint,

            spinner.centerXAnchor.constraint(equalTo: webContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: webContainer.centerYAnchor)
        ])

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Preview unavailable"
        statusLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        stackView.addArrangedSubview(statusLabel)

        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.setTitle("Reload preview", for: .normal)
        reloadButton.addTarget(self, action: #selector(handleReloadTap), for: .touchUpInside)
        reloadButton.contentHorizontalAlignment = .leading
        reloadButton.isHidden = true
        stackView.addArrangedSubview(reloadButton)
    }

    private func requestSlotIfNeeded() {
        guard window != nil else { return }
        guard !hasSlot, let currentURL else { return }
        guard state == .idle else { return }

        // If we're queued behind other previews, keep a long watchdog so we don't
        // spin forever waiting for a slot. The actual "load timeout" starts when
        // WKWebView load begins (see startLoad).
        setLoadingState()
        if !slotWaitStarted {
            slotWaitStarted = true
            loadStartedAt = CACurrentMediaTime()
            scheduleSlotWaitTimeout()
        }
        let priority = isActuallyVisible() ? 10 : 0
        pendingSlotRequestId = LinkPreviewLoadCoordinator.shared.acquireSlot(priority: priority) { [weak self] in
            guard let self else { return }
            self.pendingSlotRequestId = nil
            // acquireSlot() increments activeCount before calling us. If we can't use
            // the slot, we must release it explicitly.
            guard self.window != nil, self.state == .loading, self.currentURL == currentURL else {
                LinkPreviewLoadCoordinator.shared.releaseSlot()
                return
            }
            self.hasSlot = true
            self.slotWaitStarted = false
            self.slotWaitTimer?.invalidate()
            self.slotWaitTimer = nil
            self.startLoad(url: currentURL)
        }
    }

    private func setLoadingState() {
        state = .loading
        statusLabel.isHidden = true
        reloadButton.isHidden = true
        webContainer.isHidden = false
        spinner.startAnimating()
    }

    private func startLoad(url: URL) {
        setLoadingState()
        redirectCount = 0
        currentHost = url.host
        pinnedIPs = []
        loadToken = UUID()
        heightUpdates = 0
        loadStartedAt = CACurrentMediaTime()
        lastFailureReason = nil
        slotWaitStarted = false
        canLockHeight = false

        if !isHeightLocked {
            configureHeightObserver()
        }
        scheduleLoadTimeout()

        resolveHostAndLoad(url: url)
    }

    private func resolveHostAndLoad(url: URL) {
        guard let host = url.host else {
            logger.error("resolveHostAndLoad failed: missing host for url=\(url.absoluteString, privacy: .public)")
            handleFailure(.missingHost)
            return
        }
        currentURL = url
        currentHost = host

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let resolution = self.resolveHost(host)
            DispatchQueue.main.async {
                guard self.currentURL == url else { return }
                switch resolution {
                case .allowed(let ipSet):
                    self.logger.info("host resolved host=\(host, privacy: .public) ips=\(ipSet.joined(separator: ","), privacy: .public)")
                    self.pinnedIPs = ipSet
                    self.loadURL(url)
                case .blocked:
                    self.logger.error("host blocked host=\(host, privacy: .public)")
                    self.handleFailure(.hostBlocked)
                }
            }
        }
    }

    private func loadURL(_ url: URL) {
        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: Constants.loadTimeout)
        webView.load(request)
    }

    private func resetState(keepURL: Bool = false) {
        logCancel(.resetState)
        cancelLoad(releaseSlot: true)
        statusLabel.isHidden = true
        reloadButton.isHidden = true
        webContainer.isHidden = false
        state = .idle
        canLockHeight = false
        isHeightLocked = false
        didShowEmptyBodyWarning = false
        if !keepURL {
            currentURL = nil
            configuredURLKey = nil
        }
        currentHost = nil
        pinnedIPs = []
        redirectCount = 0
        slotWaitStarted = false
    }

    private func cancelLoad(releaseSlot: Bool) {
        cancelPendingSlotRequestIfNeeded()
        slotWaitTimer?.invalidate()
        loadTimeoutTimer?.invalidate()
        fallbackTimer?.invalidate()
        slotWaitTimer = nil
        loadTimeoutTimer = nil
        fallbackTimer = nil
        webView.stopLoading()
        spinner.stopAnimating()
        removeHeightObserver()
        if releaseSlot {
            releaseSlotIfNeeded()
        }
    }

    private func cancelPendingSlotRequestIfNeeded() {
        guard let id = pendingSlotRequestId else { return }
        pendingSlotRequestId = nil
        LinkPreviewLoadCoordinator.shared.cancelPending(id)
    }

    private func releaseSlotIfNeeded() {
        if hasSlot {
            hasSlot = false
            LinkPreviewLoadCoordinator.shared.releaseSlot()
        }
    }

    private func scheduleSlotWaitTimeout() {
        slotWaitTimer?.invalidate()
        slotWaitTimer = Timer.scheduledTimer(withTimeInterval: Constants.slotWaitTimeout, repeats: false) { [weak self] _ in
            self?.handleFailure(.timeout, detail: "slot_wait")
        }
    }

    private func scheduleLoadTimeout() {
        loadTimeoutTimer?.invalidate()
        loadTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Constants.loadTimeout, repeats: false) { [weak self] _ in
            self?.handleFailure(.timeout, detail: "load")
        }
    }

    private func scheduleFallbackMeasurement() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: Constants.emptyBodyDelay, repeats: false) { [weak self] _ in
            if self?.heightUpdates == 0 {
                self?.evaluateHeightFallback()
            }
            self?.evaluateEmptyBodyFallback()
        }
    }

    private func evaluateHeightFallback() {
        // document.*.scrollHeight bottoms out at viewport height, so small pages can appear "tall"
        // if we start the preview at a large height. Use rendered content extents instead.
        let js = """
        (function(){
          try {
            var body = document.body;
            if (!body) { return null; }
            var maxBottom = 0;
            // 4 == NodeFilter.SHOW_TEXT
            var textWalker = document.createTreeWalker(body, 4, null);
            var textCount = 0;
            while (textWalker.nextNode()) {
              var node = textWalker.currentNode;
              if (!node || !node.textContent) { continue; }
              if (!node.textContent.trim()) { continue; }
              var r = document.createRange();
              r.selectNodeContents(node);
              var rect = r.getBoundingClientRect();
              var bottom = (rect && rect.bottom) ? rect.bottom : 0;
              if (bottom > maxBottom) { maxBottom = bottom; }
              textCount++;
              if (textCount > 4000) { break; }
            }

            // 1 == NodeFilter.SHOW_ELEMENT
            var elementWalker = document.createTreeWalker(body, 1, null);
            var elementCount = 0;
            while (elementWalker.nextNode()) {
              var el = elementWalker.currentNode;
              if (!el || !el.getBoundingClientRect) { continue; }
              var tag = (el.tagName || '').toUpperCase();
              if (tag === 'IMG' || tag === 'VIDEO' || tag === 'IFRAME' || tag === 'CANVAS' || tag === 'SVG') {
                var eRect = el.getBoundingClientRect();
                var eBottom = (eRect && eRect.bottom) ? eRect.bottom : 0;
                if (eBottom > maxBottom) { maxBottom = eBottom; }
              }
              elementCount++;
              if (elementCount > 2500) { break; }
            }

            var scrollY = (window.scrollY || 0);
            return Math.max(0, maxBottom + scrollY);
          } catch(e) { return null; }
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            guard let heightNumber = result as? NSNumber else { return }
            self.applyMeasuredHeight(heightNumber.doubleValue)
        }
    }

    private func evaluateEmptyBodyFallback() {
        let js = "(function(){try{return {textLength:(document.body?.innerText||'').trim().length, childCount:(document.body?.childElementCount||0)};}catch(e){return {textLength:0, childCount:0};}})();"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            guard let dict = result as? [String: Any],
                  let textLength = dict["textLength"] as? Int,
                  let childCount = dict["childCount"] as? Int else { return }
            if textLength < 16 && childCount < 1 {
                // #39: Do not treat "empty body" as terminal failure. Many JS-heavy pages
                // render late, use canvas/shadow DOM, or populate after initial load.
                guard !self.didShowEmptyBodyWarning else { return }
                self.didShowEmptyBodyWarning = true
                self.logger.warning("page appears empty (non-fatal) url=\(self.currentURL?.absoluteString ?? "nil", privacy: .public)")
                self.statusLabel.text = "Page appears empty. You can reload to try again."
                self.statusLabel.isHidden = false
                self.reloadButton.isHidden = false
            }
        }
    }

    private func applyMeasuredHeight(_ rawHeight: Double) {
        guard rawHeight.isFinite else { return }
        markLoadedIfNeeded()
        let clamped = max(Constants.minHeight, min(maxHeight, CGFloat(rawHeight)))
        let needsScroll = rawHeight > Double(maxHeight)
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.showsVerticalScrollIndicator = needsScroll
        webView.scrollView.alwaysBounceVertical = needsScroll
        if isHeightLocked {
            return
        }
        if abs(webViewHeightConstraint.constant - clamped) <= 10 {
            return
        }
        webViewHeightConstraint.constant = clamped
        invalidateIntrinsicContentSize()
        onHeightChange?()

        // Flynn directive: lock and cache preview height once it's determined post-load.
        if canLockHeight {
            isHeightLocked = true
            canLockHeight = false
            if let configuredURLKey {
                Self.heightCache.setObject(NSNumber(value: Double(clamped)), forKey: configuredURLKey as NSString)
            }
        }
    }

    private func handleFailure(_ reason: FailureReason, detail: String? = nil) {
        guard state != .failed else { return }
        state = .failed
        lastFailureReason = reason
        logFailure(reason, detail: detail)
        logCancel(.failureCleanup)
        cancelLoad(releaseSlot: true)
        webContainer.isHidden = true
        statusLabel.isHidden = false
        reloadButton.isHidden = false

        // Always show the failure reason so users (and Flynn) can understand what happened.
        var lines: [String] = ["Preview unavailable (\(reason.rawValue))"]
        if let detail, !detail.isEmpty {
            lines.append(detail)
        }
        if let urlString = currentURL?.absoluteString {
            lines.append(urlString)
        }
        statusLabel.text = lines.joined(separator: "\n")
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    @objc private func handleReloadTap() {
        guard currentURL != nil else { return }
        logger.info("reload tapped url=\(self.currentURL?.absoluteString ?? "nil", privacy: .public)")
        if let configuredURLKey {
            Self.heightCache.removeObject(forKey: configuredURLKey as NSString)
        }
        resetState(keepURL: true)
        requestSlotIfNeeded()
    }

    private func markLoadedIfNeeded() {
        guard state == .loading else { return }
        slotWaitTimer?.invalidate()
        loadTimeoutTimer?.invalidate()
        slotWaitTimer = nil
        loadTimeoutTimer = nil
        spinner.stopAnimating()
        state = .loaded
        releaseSlotIfNeeded()
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

    override func accessibilityActivate() -> Bool {
        handleOverlayTap()
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        logger.info("didStartProvisionalNavigation url=\(self.currentURL?.absoluteString ?? "nil", privacy: .public)")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        markLoadedIfNeeded()
        scheduleFallbackMeasurement()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            logger.info("navigationAction cancelled: missing url token=\(self.loadToken.uuidString, privacy: .public)")
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        guard isAllowedScheme(url) else {
            logger.info("navigationAction cancelled: blocked scheme scheme=\(url.scheme ?? "nil", privacy: .public) url=\(url.absoluteString, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public)")
            decisionHandler(.cancel)
            return
        }
        if isBlockedIPAddressHost(url.host) {
            decisionHandler(.cancel)
            logger.error("navigationAction blocked host=\(url.host ?? "nil", privacy: .public) url=\(url.absoluteString, privacy: .public)")
            handleFailure(.blockedIPAddressHost, detail: "navAction")
            return
        }
        if let host = url.host, host == currentHost, navigationAction.targetFrame?.isMainFrame == true {
            validatePinnedHost(host) { [weak self] allowed in
                guard let self else {
                    decisionHandler(.cancel)
                    return
                }
                guard allowed else {
                    decisionHandler(.cancel)
                    self.logger.error("pinned host validation failed host=\(host, privacy: .public) url=\(url.absoluteString, privacy: .public)")
                    self.handleFailure(.pinnedHostValidationFailed, detail: host)
                    return
                }
                decisionHandler(.allow)
            }
            return
        }
        if let host = url.host, host != currentHost {
            redirectCount += 1
            guard redirectCount <= Constants.maxRedirects else {
                decisionHandler(.cancel)
                logger.error("redirect limit exceeded host=\(host, privacy: .public) url=\(url.absoluteString, privacy: .public)")
                handleFailure(.redirectLimitExceeded, detail: host)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    DispatchQueue.main.async { decisionHandler(.cancel) }
                    return
                }
                let resolution = self.resolveHost(host)
                DispatchQueue.main.async {
                    guard self.state == .loading else {
                        decisionHandler(.cancel)
                        return
                    }
                    switch resolution {
                    case .blocked:
                        decisionHandler(.cancel)
                        self.logger.error("redirect host blocked host=\(host, privacy: .public) url=\(url.absoluteString, privacy: .public)")
                        self.handleFailure(.redirectHostBlocked, detail: host)
                    case .allowed(let ipSet):
                        self.currentURL = url
                        self.currentHost = host
                        self.pinnedIPs = ipSet
                        decisionHandler(.allow)
                    }
                }
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url else {
            logger.info("navigationResponse cancelled: missing url token=\(self.loadToken.uuidString, privacy: .public)")
            decisionHandler(.cancel)
            return
        }
        guard isAllowedScheme(url) else {
            logger.info("navigationResponse cancelled: blocked scheme scheme=\(url.scheme ?? "nil", privacy: .public) url=\(url.absoluteString, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public)")
            decisionHandler(.cancel)
            return
        }
        if isBlockedIPAddressHost(url.host) {
            decisionHandler(.cancel)
            logger.error("navigationResponse blocked host=\(url.host ?? "nil", privacy: .public) url=\(url.absoluteString, privacy: .public)")
            handleFailure(.blockedIPAddressHost, detail: "navResponse")
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard state == .loading else { return }
        markLoadedIfNeeded()
        canLockHeight = !isHeightLocked
        if heightUpdates == 0 {
            evaluateHeightFallback()
        }
        scheduleFallbackMeasurement()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isIgnorableNavigationError(error) {
            logger.info("didFail navigation ignored error=\(error.localizedDescription, privacy: .public)")
            return
        }
        logger.error("didFail navigation error=\(error.localizedDescription, privacy: .public)")
        let nsError = error as NSError
        handleFailure(.navigationError, detail: "\(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isIgnorableNavigationError(error) {
            logger.info("didFailProvisionalNavigation ignored error=\(error.localizedDescription, privacy: .public)")
            return
        }
        logger.error("didFailProvisionalNavigation error=\(error.localizedDescription, privacy: .public)")
        let nsError = error as NSError
        handleFailure(.provisionalNavigationError, detail: "\(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)")
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer == webView.scrollView.panGestureRecognizer
    }

    // MARK: - Height Observer

    private func configureHeightObserver() {
        removeHeightObserver()
        let token = loadToken.uuidString
        let handler = "linkPreviewHeight_\(token)"
        handlerName = handler
        handlerRegistered = true
        webView.configuration.userContentController.add(self, name: handler)

        let scriptSource = """
        (function(){
          var handler = '\(handler)';
          var token = '\(token)';
          var store = window.__clawlineLinkPreviewObservers || (window.__clawlineLinkPreviewObservers = {});
          function contentBottom(){
            try {
              var body = document.body;
              if (!body) { return 0; }
              var maxBottom = 0;

              // Prefer measuring real rendered content (text nodes / replaced elements) rather than
              // container boxes, because many pages set full-height wrappers that would force
              // element.getBoundingClientRect().bottom to be viewport-height even for short pages.

              // 4 == NodeFilter.SHOW_TEXT
              var textWalker = document.createTreeWalker(body, 4, null);
              var textCount = 0;
              while (textWalker.nextNode()) {
                var node = textWalker.currentNode;
                if (!node || !node.textContent) { continue; }
                if (!node.textContent.trim()) { continue; }
                var r = document.createRange();
                r.selectNodeContents(node);
                var rect = r.getBoundingClientRect();
                var bottom = (rect && rect.bottom) ? rect.bottom : 0;
                if (bottom > maxBottom) { maxBottom = bottom; }
                textCount++;
                if (textCount > 4000) { break; }
              }

              // 1 == NodeFilter.SHOW_ELEMENT
              var elementWalker = document.createTreeWalker(body, 1, null);
              var elementCount = 0;
              while (elementWalker.nextNode()) {
                var el = elementWalker.currentNode;
                if (!el || !el.getBoundingClientRect) { continue; }
                var tag = (el.tagName || '').toUpperCase();
                if (tag === 'IMG' || tag === 'VIDEO' || tag === 'IFRAME' || tag === 'CANVAS' || tag === 'SVG') {
                  var eRect = el.getBoundingClientRect();
                  var eBottom = (eRect && eRect.bottom) ? eRect.bottom : 0;
                  if (eBottom > maxBottom) { maxBottom = eBottom; }
                }
                elementCount++;
                if (elementCount > 2500) { break; }
              }

              // Convert viewport-relative bottom to a document-height estimate.
              var scrollY = (window.scrollY || 0);
              return Math.max(0, maxBottom + scrollY);
            } catch(e) {
              return 0;
            }
          }
          function postHeight(){
            try {
              var body = document.body;
              if (!body) { return; }
              // scrollHeight bottoms out at viewport height; measure rendered content extents first,
              // then fall back to scrollHeight if the document has no measurable content.
              var bottom = contentBottom();
              var scrollH = Math.max(body.scrollHeight || 0, (document.documentElement && document.documentElement.scrollHeight) || 0);
              var height = bottom > 0 ? bottom : scrollH;
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
                window.webkit.messageHandlers[handler].postMessage({token: token, height: height});
              }
            } catch(e) {}
          }
          function attach(){
            if (typeof ResizeObserver !== 'undefined') {
              var target = document.body || document.documentElement;
              if (!target) { return; }
              var obs = new ResizeObserver(function(){ postHeight(); });
              obs.observe(target);
              store[handler] = obs;
              postHeight();
            } else {
              postHeight();
            }
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', attach);
          } else {
            attach();
          }
        })();
        """
        let script = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)
    }

    private func removeHeightObserver() {
        disconnectHeightObserver()
        webView.configuration.userContentController.removeAllUserScripts()
        if let handlerName, handlerRegistered {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        }
        handlerRegistered = false
        handlerName = nil
    }

    private func disconnectHeightObserver() {
        guard let handlerName else { return }
        let js = """
        (function(){
          var store = window.__clawlineLinkPreviewObservers;
          if (store && store['\(handlerName)']) {
            store['\(handlerName)'].disconnect();
            delete store['\(handlerName)'];
          }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Helpers

    private func isAllowedScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func isBlockedIPAddressHost(_ host: String?) -> Bool {
        // Policy: show everything (match browser behavior). Do not block local/LAN/Tailscale hosts.
        return false
    }

    private enum HostResolutionResult {
        case allowed(Set<String>)
        case blocked
    }

    private func resolveHost(_ host: String) -> HostResolutionResult {
        var resolved: Set<String> = []
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, nil, &hints, &res) == 0, let res {
            defer { freeaddrinfo(res) }
            var ptr: UnsafeMutablePointer<addrinfo>? = res
            while let current = ptr {
                let addr = current.pointee.ai_addr
                if current.pointee.ai_family == AF_INET, let addr {
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var addr4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    if inet_ntop(AF_INET, &addr4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buffer)
                        resolved.insert(ip)
                    }
                } else if current.pointee.ai_family == AF_INET6, let addr {
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var addr6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    if inet_ntop(AF_INET6, &addr6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buffer)
                        resolved.insert(ip)
                    }
                }
                ptr = current.pointee.ai_next
            }
        }
        return .allowed(resolved)
    }

    private func isActuallyVisible() -> Bool {
        guard let window else { return false }
        if isHidden || alpha < 0.01 { return false }
        let frameInWindow = convert(bounds, to: window)
        return frameInWindow.intersects(window.bounds)
    }

    private func isPrivateIPAddress(_ host: String) -> Bool {
        // Policy: show everything (match browser behavior). Do not treat private IPs / localhost as blocked.
        return false

        var addr4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 {
            let ip = UInt32(bigEndian: addr4.s_addr)
            return isPrivateIPv4(ip)
        }

        var addr6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 {
            let bytes = withUnsafeBytes(of: addr6) { Array($0) }
            if bytes.count >= 16 {
                if bytes.allSatisfy({ $0 == 0 }) { return true }                 // ::
                if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true } // fe80::/10
                if (bytes[0] & 0xFE) == 0xFC { return true }                     // fc00::/7
                if bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0 &&
                    bytes[4] == 0 && bytes[5] == 0 && bytes[6] == 0 && bytes[7] == 0 &&
                    bytes[8] == 0 && bytes[9] == 0 && bytes[10] == 0xFF && bytes[11] == 0xFF {
                    let ip = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
                    return isPrivateIPv4(ip)
                }
                if bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0 &&
                   bytes[4] == 0 && bytes[5] == 0 && bytes[6] == 0 && bytes[7] == 0 &&
                   bytes[8] == 0 && bytes[9] == 0 && bytes[10] == 0 && bytes[11] == 0 &&
                   bytes[12] == 0 && bytes[13] == 0 && bytes[14] == 0 && bytes[15] == 1 { // ::1
                    return true
                }
            }
            return false
        }

        return host == "localhost"
    }

    private func isPrivateIPv4(_ ip: UInt32) -> Bool {
        if (ip & 0xFF000000) == 0x0A000000 { return true }          // 10.0.0.0/8
        if (ip & 0xFFF00000) == 0xAC100000 { return true }          // 172.16.0.0/12
        if (ip & 0xFFFF0000) == 0xC0A80000 { return true }          // 192.168.0.0/16
        if (ip & 0xFF000000) == 0x7F000000 { return true }          // 127.0.0.0/8
        if (ip & 0xFFFF0000) == 0xA9FE0000 { return true }          // 169.254.0.0/16
        if (ip & 0xFF000000) == 0x00000000 { return true }          // 0.0.0.0/8
        if (ip & 0xFFC00000) == 0x64400000 { return true }          // 100.64.0.0/10
        return false
    }

    private func validatePinnedHost(_ host: String, completion: @escaping (Bool) -> Void) {
        guard !pinnedIPs.isEmpty else {
            completion(true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let resolution = self.resolveHost(host)
            DispatchQueue.main.async {
                switch resolution {
                case .blocked:
                    completion(false)
                case .allowed(let ipSet):
                    if ipSet.isEmpty {
                        completion(true)
                        return
                    }
                    completion(ipSet.isSubset(of: self.pinnedIPs))
                }
            }
        }
    }

    private func isIgnorableNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        if (nsError.domain == WKErrorDomain || nsError.domain == "WebKitErrorDomain"),
           nsError.code == 102 {
            return true
        }
        return false
    }
}

// MARK: - WKScriptMessageHandler

extension LinkPreviewView: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handlerName else { return }
        guard message.name == handlerName else { return }
        guard let body = message.body as? [String: Any],
              let token = body["token"] as? String,
              token == loadToken.uuidString else { return }
        guard let heightValue = body["height"] as? Double, heightValue.isFinite else { return }
        guard heightValue >= 1 && heightValue <= 10000 else { return }

        heightUpdates += 1
        applyMeasuredHeight(heightValue)
        if heightUpdates >= 2 {
            removeHeightObserver()
        }
    }
}

private extension UIView {
    var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

private extension LinkPreviewView {
    func logCancel(_ reason: CancelReason) {
        let urlString = self.currentURL?.absoluteString ?? "nil"
        let elapsed = loadElapsedMsString()
        self.logger.info("cancel reason=\(reason.rawValue, privacy: .public) url=\(urlString, privacy: .public) elapsedMs=\(elapsed, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public)")
    }

    func logFailure(_ reason: FailureReason, detail: String?) {
        let urlString = self.currentURL?.absoluteString ?? "nil"
        let elapsed = loadElapsedMsString()
        if let detail, !detail.isEmpty {
            self.logger.error("failure reason=\(reason.rawValue, privacy: .public) url=\(urlString, privacy: .public) elapsedMs=\(elapsed, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public) detail=\(detail, privacy: .public)")
        } else {
            self.logger.error("failure reason=\(reason.rawValue, privacy: .public) url=\(urlString, privacy: .public) elapsedMs=\(elapsed, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public)")
        }
    }

    func loadElapsedMsString() -> String {
        guard let loadStartedAt = self.loadStartedAt else { return "nil" }
        let elapsedMs = Int(((CACurrentMediaTime() - loadStartedAt) * 1000.0).rounded())
        return String(elapsedMs)
    }
}

#if canImport(SwiftUI)
struct LinkPreviewRepresentable: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LinkPreviewView {
        let view = LinkPreviewView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: LinkPreviewView, context: Context) {
        uiView.configure(url: url)
    }
}
#endif
