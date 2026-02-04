//
//  LinkPreviewView.swift
//  Clawline
//
//  Created by Codex on 2/4/26.
//

import Darwin
import Foundation
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

    func configure(url: URL) {
        if currentURL == url, state != .failed { return }
        resetState()
        currentURL = url
        requestSlotIfNeeded()
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

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = .clear
        stackView.addArrangedSubview(webContainer)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.showsVerticalScrollIndicator = false
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
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        stackView.addArrangedSubview(statusLabel)
    }

    private func requestSlotIfNeeded() {
        guard window != nil else { return }
        guard !hasSlot, let currentURL else { return }
        guard state == .idle else { return }

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

    private func startLoad(url: URL) {
        state = .loading
        statusLabel.isHidden = true
        webContainer.isHidden = false
        spinner.startAnimating()
        redirectCount = 0
        currentHost = url.host
        pinnedIPs = []
        loadToken = UUID()
        heightUpdates = 0

        configureHeightObserver()
        scheduleTimeout()

        resolveHostAndLoad(url: url)
    }

    private func resolveHostAndLoad(url: URL) {
        guard let host = url.host else {
            handleFailure()
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
                    self.pinnedIPs = ipSet
                    self.loadURL(url)
                case .blocked:
                    self.handleFailure()
                }
            }
        }
    }

    private func loadURL(_ url: URL) {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Constants.loadTimeout)
        webView.load(request)
    }

    private func resetState() {
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
            self?.handleFailure()
        }
    }

    private func scheduleFallbackMeasurement() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: Constants.emptyBodyDelay, repeats: false) { [weak self] _ in
            self?.evaluateHeightFallback()
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
                self.handleFailure()
            }
        }
    }

    private func applyMeasuredHeight(_ rawHeight: Double) {
        guard rawHeight.isFinite else { return }
        let clamped = max(Constants.minHeight, min(Constants.maxHeight, CGFloat(rawHeight)))
        webViewHeightConstraint.constant = clamped
        let needsScroll = rawHeight > Double(Constants.maxHeight)
        webView.scrollView.isScrollEnabled = needsScroll
        onHeightChange?()
    }

    private func handleFailure() {
        guard state != .failed else { return }
        state = .failed
        cancelLoad(releaseSlot: true)
        webContainer.isHidden = true
        statusLabel.isHidden = false
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

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        guard isAllowedScheme(url) else {
            decisionHandler(.cancel)
            return
        }
        if isBlockedIPAddressHost(url.host) {
            decisionHandler(.cancel)
            handleFailure()
            return
        }
        if let host = url.host, host != currentHost {
            redirectCount += 1
            guard redirectCount <= Constants.maxRedirects else {
                decisionHandler(.cancel)
                handleFailure()
                return
            }
            decisionHandler(.cancel)
            resolveHostAndLoad(url: url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url else {
            decisionHandler(.cancel)
            return
        }
        guard isAllowedScheme(url) else {
            decisionHandler(.cancel)
            return
        }
        if isBlockedIPAddressHost(url.host) {
            decisionHandler(.cancel)
            handleFailure()
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard state == .loading else { return }
        spinner.stopAnimating()
        state = .loaded
        scheduleFallbackMeasurement()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure()
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
        webView.configuration.userContentController.removeAllUserScripts()
        if let handlerName, handlerRegistered {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        }
        handlerRegistered = false
        handlerName = nil
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
            if (ip & 0xFF000000) == 0x0A000000 { return true }          // 10.0.0.0/8
            if (ip & 0xFFF00000) == 0xAC100000 { return true }          // 172.16.0.0/12
            if (ip & 0xFFFF0000) == 0xC0A80000 { return true }          // 192.168.0.0/16
            if (ip & 0xFF000000) == 0x7F000000 { return true }          // 127.0.0.0/8
            return false
        }

        var addr6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 {
            let bytes = withUnsafeBytes(of: addr6) { Array($0) }
            if bytes.count >= 16 {
                if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true } // fe80::/10
                if (bytes[0] & 0xFE) == 0xFC { return true }                     // fc00::/7
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
