//
//  TerminalBubbleUIKitView.swift
//  Clawline
//
//  Created by Codex on 2/7/26.
//

import UIKit
import OSLog
import SwiftTerm

/// Embedded terminal session view intended for use inside chat bubbles and expanded message sheets.
/// Policy decisions (Flynn / #46):
/// - Auto-connect on render (no tap-to-connect).
/// - No standard bubble chrome: this view is responsible for minimal title/status affordances.
/// - When offscreen for a while, tear down the WS and show a reconnect affordance.
final class TerminalBubbleUIKitView: UIView, TerminalViewDelegate {
    enum Style {
        case bubble(height: CGFloat)
        case expanded(height: CGFloat)

        var height: CGFloat {
            switch self {
            case .bubble(let h), .expanded(let h):
                return h
            }
        }
    }

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "TerminalBubble")

    var onRequestExpand: (() -> Void)?

    private let topBar = UIStackView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let expandButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    private let terminalView = TerminalView(frame: .zero)
    private var terminalHeightConstraint: NSLayoutConstraint?

    private let deadOverlay = UIView()
    private let deadLabel = UILabel()
    private let reconnectButton = UIButton(type: .system)

    private var sanitizer = TerminalInputSanitizer()

    private var descriptor: TerminalSessionDescriptor?
    private var style: Style = .bubble(height: 360)

    private var service: TerminalSessionService?
    private var outputTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    private var lastCols: Int = 80
    private var lastRows: Int = 24

    private var disconnectTimer: Timer?
    private var hasEverConnected = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        teardown()
    }

    func configure(descriptor: TerminalSessionDescriptor, style: Style) {
        self.descriptor = descriptor
        self.style = style

        titleLabel.text = descriptor.title?.isEmpty == false ? descriptor.title : "Terminal"
        statusLabel.text = "CONNECTING"

        terminalHeightConstraint?.constant = style.height

        // Auto-connect when we hit the window (didMoveToWindow), so cols/rows are not zero.
        showTerminal()
    }

    func prepareForReuse() {
        teardown()
        descriptor = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        // Offscreen: defer disconnect to avoid thrash during fast scroll.
        if window == nil {
            scheduleDisconnect()
            return
        }

        cancelScheduledDisconnect()
        connectIfNeeded()
    }

    // MARK: - UI

    private func buildUI() {
        translatesAutoresizingMaskIntoConstraints = false

        // Top bar (minimal; not message bubble chrome).
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 10
        topBar.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .tertiaryLabel
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        expandButton.setTitle("Expand", for: .normal)
        expandButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        expandButton.addTarget(self, action: #selector(handleExpandTap), for: .touchUpInside)

        closeButton.setTitle("Close", for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        closeButton.addTarget(self, action: #selector(handleCloseTap), for: .touchUpInside)

        let left = UIStackView(arrangedSubviews: [titleLabel, UIView()])
        left.axis = .horizontal
        left.alignment = .center

        topBar.addArrangedSubview(left)
        topBar.addArrangedSubview(statusLabel)
        topBar.addArrangedSubview(expandButton)
        topBar.addArrangedSubview(closeButton)

        // Terminal surface.
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.terminalDelegate = self
        terminalView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = .label
        terminalView.nativeBackgroundColor = UIColor.clear
        terminalView.backgroundColor = .clear
        terminalView.selectedTextBackgroundColor = UIColor.systemGray.withAlphaComponent(0.35)
        terminalView.setRenderingStrategy(.cached, resetCache: true)

        // No rounded corners (Flynn decision).
        terminalView.layer.cornerRadius = 0
        terminalView.layer.masksToBounds = true

        // Dead overlay (reconnect UX).
        deadOverlay.translatesAutoresizingMaskIntoConstraints = false
        deadOverlay.isHidden = true

        deadLabel.translatesAutoresizingMaskIntoConstraints = false
        deadLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        deadLabel.textColor = .secondaryLabel
        deadLabel.numberOfLines = 2
        deadLabel.textAlignment = .center

        reconnectButton.setTitle("Reconnect", for: .normal)
        reconnectButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        reconnectButton.addTarget(self, action: #selector(handleReconnectTap), for: .touchUpInside)

        let deadStack = UIStackView(arrangedSubviews: [deadLabel, reconnectButton])
        deadStack.axis = .vertical
        deadStack.alignment = .center
        deadStack.spacing = 10
        deadStack.translatesAutoresizingMaskIntoConstraints = false
        deadOverlay.addSubview(deadStack)
        NSLayoutConstraint.activate([
            deadStack.centerXAnchor.constraint(equalTo: deadOverlay.centerXAnchor),
            deadStack.centerYAnchor.constraint(equalTo: deadOverlay.centerYAnchor),
            deadStack.leadingAnchor.constraint(greaterThanOrEqualTo: deadOverlay.leadingAnchor, constant: 12),
            deadStack.trailingAnchor.constraint(lessThanOrEqualTo: deadOverlay.trailingAnchor, constant: -12)
        ])

        addSubview(topBar)
        addSubview(terminalView)
        addSubview(deadOverlay)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            terminalView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),

            deadOverlay.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            deadOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            deadOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            deadOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        terminalHeightConstraint = terminalView.heightAnchor.constraint(equalToConstant: style.height)
        terminalHeightConstraint?.isActive = true
    }

    @objc private func handleExpandTap() {
        onRequestExpand?()
    }

    @objc private func handleCloseTap() {
        service?.close()
        teardownConnectionOnly()
        showDeadState(reason: "Closed: \(titleLabel.text ?? "Terminal")")
    }

    @objc private func handleReconnectTap() {
        connectOrReconnect()
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        lastCols = max(newCols, 1)
        lastRows = max(newRows, 1)
        service?.resize(cols: lastCols, rows: lastRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let sanitized = sanitizer.sanitize(data) else { return }
        service?.sendInput(Data(sanitized))
    }

    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let string = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = string
        }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // MARK: - Connection

    private func connectIfNeeded() {
        guard descriptor != nil else { return }
        guard service == nil else { return }
        connectOrReconnect()
    }

    private func connectOrReconnect() {
        guard let descriptor else { return }

        hasEverConnected = true
        statusLabel.text = "CONNECTING"

        let service = TerminalSessionService(descriptor: descriptor)
        self.service = service
        bind(service)
        service.connect(initialCols: lastCols, initialRows: lastRows)
    }

    private func bind(_ service: TerminalSessionService) {
        outputTask?.cancel()
        stateTask?.cancel()

        outputTask = Task { [weak self] in
            guard let self else { return }
            for await data in service.output {
                let bytes = [UInt8](data)
                terminalView.feed(byteArray: bytes[...])
            }
        }

        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in service.state {
                switch state {
                case .disconnected:
                    statusLabel.text = hasEverConnected ? "DISCONNECTED" : "CONNECTING"
                    if hasEverConnected {
                        showDeadState(reason: titleLabel.text ?? "Terminal")
                    }
                case .connecting:
                    statusLabel.text = "CONNECTING"
                    showTerminal()
                case .ready:
                    statusLabel.text = "LIVE"
                    showTerminal()
                case .exited(let code):
                    if let code {
                        statusLabel.text = "EXIT \(code)"
                    } else {
                        statusLabel.text = "EXIT"
                    }
                    showDeadState(reason: titleLabel.text ?? "Terminal")
                case .failed:
                    statusLabel.text = "ERROR"
                    showDeadState(reason: titleLabel.text ?? "Terminal")
                }
            }
        }
    }

    private func showTerminal() {
        deadOverlay.isHidden = true
        terminalView.isHidden = false
    }

    private func showDeadState(reason: String) {
        deadLabel.text = reason
        deadOverlay.isHidden = false
        terminalView.isHidden = true
    }

    private func scheduleDisconnect() {
        cancelScheduledDisconnect()
        disconnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.teardownConnectionOnly()
            if let title = self.titleLabel.text {
                self.showDeadState(reason: title)
            }
        }
    }

    private func cancelScheduledDisconnect() {
        disconnectTimer?.invalidate()
        disconnectTimer = nil
    }

    private func teardownConnectionOnly() {
        cancelScheduledDisconnect()
        outputTask?.cancel()
        outputTask = nil
        stateTask?.cancel()
        stateTask = nil
        service?.disconnect()
        service = nil
    }

    private func teardown() {
        teardownConnectionOnly()
    }
}

/// Filters potentially dangerous control bytes during paste/keyboard input so tmux sessions don't pause.
private struct TerminalInputSanitizer {
    private var bracketedPasteDepth = 0
    private var scratch: [UInt8] = []

    mutating func sanitize(_ data: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        guard !data.isEmpty else { return data }

        if data.elementsEqual([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) { // ESC[200~
            bracketedPasteDepth += 1
            return data
        }

        if data.elementsEqual([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) { // ESC[201~
            bracketedPasteDepth = max(bracketedPasteDepth - 1, 0)
            return data
        }

        guard shouldFilter(data) else { return data }

        scratch.removeAll(keepingCapacity: true)
        for byte in data where !isDisallowedPasteByte(byte) {
            scratch.append(byte)
        }

        return scratch.isEmpty ? nil : scratch[...]
    }

    private func shouldFilter(_ data: ArraySlice<UInt8>) -> Bool {
        guard bracketedPasteDepth > 0 || data.count > 1 else { return false }
        return data.contains(where: isDisallowedPasteByte)
    }

    private func isDisallowedPasteByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x09, 0x0A, 0x0D:
            return false
        case 0x11, 0x13:
            return true // XON/XOFF
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x10, 0x12, 0x14...0x1A, 0x1C...0x1F, 0x7F:
            return true
        default:
            return false
        }
    }
}

