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
    private var pending: [() -> Void] = []
    var onActiveCountZero: (() -> Void)?

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

final class LinkPreviewView: UIView, WKNavigationDelegate, WKUIDelegate {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "LinkPreview")
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
        static let maxHeight: CGFloat = 360
        static let loadTimeout: TimeInterval = 12
        static let emptyBodyDelay: TimeInterval = 0.5
        static let maxRedirects = 5
    }

    private let stackView = UIStackView()
    private let webContainer = UIView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let overlayButton = UIButton(type: .custom)
    private let webView: WKWebView
    private var webViewHeightConstraint: NSLayoutConstraint!

    private var state: State = .idle
    private var currentURL: URL?
    private var currentHost: String?
    private var pinnedIPs: Set<String> = []
    private var redirectCount = 0

    private var loadToken = UUID()
    private var handlerName: String?
    private var handlerRegistered = false
    private var heightUpdates = 0

    private var timeoutTimer: Timer?
    private var fallbackTimer: Timer?

    private var hasSlot = false

    var onHeightChange: (() -> Void)?

    private var loadStartedAt: CFTimeInterval?
    private var lastFailureReason: FailureReason?

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

    func configure(url: URL) {
        if currentURL == url, state != .failed { return }
        resetState()
        currentURL = url
        let hostLabel = url.host ?? url.absoluteString
        overlayButton.isAccessibilityElement = true
        overlayButton.accessibilityLabel = "Link preview: \(hostLabel)"
        overlayButton.accessibilityTraits = .link
        requestSlotIfNeeded()
        logger.info("configure url=\(url.absoluteString, privacy: .public)")
    }

    func prepareForReuse() {
        logCancel(.reuse)
        cancelLoad(releaseSlot: true)
        currentURL = nil
        currentHost = nil
        pinnedIPs = []
        redirectCount = 0
        state = .idle
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
        stackView.addArrangedSubview(webContainer)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.clipsToBounds = true
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.showsVerticalScrollIndicator = false
        // Ensure the page starts at the top of the preview viewport and doesn't
        // apply safe-area based insets inside message bubbles.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.allowsLinkPreview = false
        webView.isUserInteractionEnabled = false
        webContainer.addSubview(webView)

        overlayButton.translatesAutoresizingMaskIntoConstraints = false
        overlayButton.backgroundColor = .clear
        overlayButton.addTarget(self, action: #selector(handleOverlayTap), for: .touchUpInside)
        webContainer.addSubview(overlayButton)

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

            overlayButton.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            overlayButton.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            overlayButton.topAnchor.constraint(equalTo: webContainer.topAnchor),
            overlayButton.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

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

        configureHeightObserver()
        scheduleTimeout()

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
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Constants.loadTimeout)
        webView.load(request)
    }

    private func resetState() {
        logCancel(.resetState)
        cancelLoad(releaseSlot: true)
        statusLabel.isHidden = true
        webContainer.isHidden = false
        state = .idle
        currentURL = nil
    }

    private func cancelLoad(releaseSlot: Bool) {
        timeoutTimer?.invalidate()
        fallbackTimer?.invalidate()
        timeoutTimer = nil
        fallbackTimer = nil
        webView.stopLoading()
        spinner.stopAnimating()
        removeHeightObserver()
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

    private func scheduleTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: Constants.loadTimeout, repeats: false) { [weak self] _ in
            self?.handleFailure(.timeout)
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
        let js = "(function(){try{return Math.max(document.body?.scrollHeight||0, document.documentElement?.scrollHeight||0);}catch(e){return null;}})();"
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
                self.handleFailure(.emptyBodyHeuristic)
            }
        }
    }

    private func applyMeasuredHeight(_ rawHeight: Double) {
        guard rawHeight.isFinite else { return }
        markLoadedIfNeeded()
        let clamped = max(Constants.minHeight, min(Constants.maxHeight, CGFloat(rawHeight)))
        let needsScroll = rawHeight > Double(Constants.maxHeight)
        webView.scrollView.isScrollEnabled = needsScroll
        if abs(webViewHeightConstraint.constant - clamped) <= 10 {
            return
        }
        webViewHeightConstraint.constant = clamped
        invalidateIntrinsicContentSize()
        onHeightChange?()
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
#if DEBUG
        if let urlString = currentURL?.absoluteString {
            statusLabel.text = "Preview unavailable (\(reason.rawValue))\n\(urlString)"
        } else {
            statusLabel.text = "Preview unavailable (\(reason.rawValue))"
        }
#endif
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    private func markLoadedIfNeeded() {
        guard state == .loading else { return }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
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
        if let mimeType = navigationResponse.response.mimeType?.lowercased() {
            let isHTML = mimeType.hasPrefix("text/html") || mimeType.hasPrefix("application/xhtml+xml")
            if !isHTML {
                decisionHandler(.cancel)
                logger.error("navigationResponse blocked mimeType=\(mimeType, privacy: .public) url=\(url.absoluteString, privacy: .public)")
                handleFailure(.nonHTMLMimeType, detail: mimeType)
                return
            }
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
          function postHeight(){
            try {
              var body = document.body;
              var html = document.documentElement;
              var height = Math.max(body ? body.scrollHeight : 0, html ? html.scrollHeight : 0);
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
        guard let host else { return false }
        return isPrivateIPAddress(host)
    }

    private enum HostResolutionResult {
        case allowed(Set<String>)
        case blocked
    }

    private func resolveHost(_ host: String) -> HostResolutionResult {
        if isPrivateIPAddress(host) {
            return .blocked
        }

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
                        if isPrivateIPAddress(ip) { return .blocked }
                        resolved.insert(ip)
                    }
                } else if current.pointee.ai_family == AF_INET6, let addr {
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var addr6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    if inet_ntop(AF_INET6, &addr6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buffer)
                        if isPrivateIPAddress(ip) { return .blocked }
                        resolved.insert(ip)
                    }
                }
                ptr = current.pointee.ai_next
            }
        }
        return .allowed(resolved)
    }

    private func isPrivateIPAddress(_ host: String) -> Bool {
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
