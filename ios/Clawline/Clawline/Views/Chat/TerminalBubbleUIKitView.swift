//
//  TerminalBubbleUIKitView.swift
//  Clawline
//
//  Created by Codex on 2/7/26.
//

import UIKit
import OSLog
import SwiftTerm

#if DEBUG
private let terminalGlyphDiagnosticScalars: [UnicodeScalar] = [
    "\u{E0B0}", // powerline separator
    "\u{E0B6}", // rounded powerline cap
    "\u{F0E7}"  // common Nerd Font icon
]
#endif

/// A TerminalView that reliably focuses itself when touched so keyboard input routes correctly.
final class FocusableTerminalView: TerminalView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        _ = becomeFirstResponder()
        super.touchesBegan(touches, with: event)
    }
}

/// Embedded terminal session view intended for use inside chat bubbles and expanded message sheets.
/// Policy decisions (Flynn / #46):
/// - Auto-connect on render (no tap-to-connect).
/// - No standard bubble chrome: this view renders the terminal surface directly.
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
    // Match Floatty's current terminal wrapper:
    // - theme base colors come from Floatty's Catppuccin Mocha terminal theme
    // - font comes from Floatty's bundled BlexMono Nerd Font Mono faces
    private let terminalSurfaceBackgroundColor = UIColor(red: 30 / 255, green: 30 / 255, blue: 46 / 255, alpha: 1)
    private let terminalSurfaceForegroundColor = UIColor(red: 205 / 255, green: 214 / 255, blue: 244 / 255, alpha: 1)
    private let terminalSelectionColor = UIColor(red: 69 / 255, green: 71 / 255, blue: 90 / 255, alpha: 1)
    private let terminalRegularFontName = "BlexMonoNFM"
    private let terminalBoldFontName = "BlexMonoNFM-Bold"
    private let terminalItalicFontName = "BlexMonoNFM-Italic"
    private let terminalBoldItalicFontName = "BlexMonoNFM-BoldItalic"

    var onRequestExpand: (() -> Void)?

    private let terminalView = FocusableTerminalView(frame: .zero)
    private var bubbleHeightConstraint: NSLayoutConstraint?

    private let deadOverlay = UIView()
    private let deadLabel = UILabel()
    private let reconnectButton = UIButton(type: .system)

    private var sanitizer = TerminalInputSanitizer()

    private var descriptor: TerminalSessionDescriptor?
    private var style: Style = .bubble(height: 360)
    private var displayTitle: String = "Terminal"

    private var service: TerminalSessionService?
    private var outputTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    private var lastCols: Int = 80
    private var lastRows: Int = 24

    private var disconnectTimer: Timer?
    private var hasAttemptedConnection = false
    private var hasEverBeenLive = false
    private var requiresUserReconnect = false
    private var scrollCaptureWired = false

    static func visibleRows(forReportedRows reportedRows: Int) -> Int {
        // SwiftTerm reports one extra row for this pinned, full-bleed bubble surface,
        // which leaves a small internal scroll range at the bottom.
        max(reportedRows - 1, 1)
    }

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
        self.requiresUserReconnect = false
        self.hasAttemptedConnection = false
        self.hasEverBeenLive = false

        if let title = descriptor.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            displayTitle = title
        } else {
            displayTitle = "Terminal"
        }

        bubbleHeightConstraint?.constant = style.height

        // Auto-connect when we hit the window (didMoveToWindow), so cols/rows are not zero.
        showTerminal()

        // Cells are often configured after they're already on-screen; don't rely solely on didMoveToWindow.
        if window != nil {
            wireScrollCaptureIfNeeded()
            connectIfNeeded()
        }
    }

    func prepareForReuse() {
        teardown()
        descriptor = nil
        requiresUserReconnect = false
        hasAttemptedConnection = false
        hasEverBeenLive = false
        scrollCaptureWired = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        // Offscreen: defer disconnect to avoid thrash during fast scroll.
        if window == nil {
            scheduleDisconnect()
            return
        }

        cancelScheduledDisconnect()
        wireScrollCaptureIfNeeded()
        if requiresUserReconnect {
            showDeadState(reason: displayTitle)
            return
        }
        connectIfNeeded()
    }

    // Terminal focus is handled by FocusableTerminalView.touchesBegan.

    // MARK: - UI

    private func buildUI() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = terminalSurfaceBackgroundColor

        // Terminal surface.
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.terminalDelegate = self
        installTerminalFonts()
        terminalView.nativeForegroundColor = terminalSurfaceForegroundColor
        terminalView.nativeBackgroundColor = terminalSurfaceBackgroundColor
        terminalView.backgroundColor = terminalSurfaceBackgroundColor
        terminalView.selectedTextBackgroundColor = terminalSelectionColor
        terminalView.isAccessibilityElement = true
        terminalView.accessibilityLabel = "Terminal session"
        terminalView.accessibilityHint = "Terminal output; double tap to focus; swipe to scroll."

        // Focus is handled by FocusableTerminalView.touchesBegan.

        // No rounded corners (Flynn decision).
        terminalView.layer.cornerRadius = 0
        terminalView.layer.masksToBounds = true

        // Dead overlay (reconnect UX).
        deadOverlay.translatesAutoresizingMaskIntoConstraints = false
        deadOverlay.backgroundColor = terminalSurfaceBackgroundColor
        deadOverlay.isHidden = true

        deadLabel.translatesAutoresizingMaskIntoConstraints = false
        deadLabel.font = UIFont.clawline(.secondaryLabel, weight: .semibold)
        deadLabel.adjustsFontForContentSizeCategory = true
        deadLabel.textColor = terminalSurfaceForegroundColor
        deadLabel.numberOfLines = 2
        deadLabel.textAlignment = .center

        reconnectButton.setTitle("Reconnect", for: .normal)
        reconnectButton.titleLabel?.font = UIFont.clawline(.secondaryLabel, weight: .semibold)
        reconnectButton.titleLabel?.adjustsFontForContentSizeCategory = true
        reconnectButton.setTitleColor(terminalSurfaceForegroundColor, for: .normal)
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

        addSubview(terminalView)
        addSubview(deadOverlay)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),

            deadOverlay.topAnchor.constraint(equalTo: topAnchor),
            deadOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            deadOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            deadOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        bubbleHeightConstraint = heightAnchor.constraint(equalToConstant: style.height)
        bubbleHeightConstraint?.isActive = true
    }

    @objc private func handleReconnectTap() {
        requiresUserReconnect = false
        connectOrReconnect()
    }

    // Focus is handled by FocusableTerminalView.touchesBegan.

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        lastCols = max(newCols, 1)
        lastRows = Self.visibleRows(forReportedRows: newRows)
        service?.resize(cols: lastCols, rows: lastRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let sanitized = sanitizer.sanitize(data) else { return }
        logger.debug("terminal_input bytes=\(sanitized.count, privacy: .public)")
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
        if requiresUserReconnect { return }
        connectOrReconnect()
    }

    private func connectOrReconnect() {
        guard let descriptor else { return }

        hasAttemptedConnection = true

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
                await MainActor.run {
                    self.terminalView.feed(byteArray: bytes[...])
                }
            }
        }

        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in service.state {
                await MainActor.run {
                    switch state {
                    case .disconnected:
                        if self.hasAttemptedConnection {
                            self.requiresUserReconnect = true
                            self.showDeadState(reason: self.displayTitle)
                        }
                    case .connecting:
                        self.showTerminal()
                    case .ready:
                        self.hasEverBeenLive = true
                        self.showTerminal()
                    case .exited(let code):
                        self.requiresUserReconnect = true
                        if let code {
                            self.showDeadState(reason: "Exited (\(code))")
                        } else {
                            self.showDeadState(reason: self.displayTitle)
                        }
                    case .failed(let message):
                        self.requiresUserReconnect = true
                        self.showDeadState(reason: message)
                    }
                }
            }
        }
    }

    private func showTerminal() {
        deadOverlay.isHidden = true
        terminalView.isHidden = false
    }

    private func showDeadState(reason: String) {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        deadLabel.text = trimmed.isEmpty ? displayTitle : trimmed
        deadOverlay.isHidden = false
        terminalView.isHidden = true
    }

    private func scheduleDisconnect() {
        cancelScheduledDisconnect()
        disconnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.teardownConnectionOnly()
            self.requiresUserReconnect = true
            self.showDeadState(reason: self.displayTitle)
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

    private func wireScrollCaptureIfNeeded() {
        guard !scrollCaptureWired else { return }
        guard let terminalPan = terminalView.gestureRecognizers?.compactMap({ $0 as? UIPanGestureRecognizer }).first else {
            return
        }

        // Ensure the terminal's scrollback pan wins against any ancestor scroll views (collection view, sheet scroll view).
        var ancestor: UIView? = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollView.panGestureRecognizer.require(toFail: terminalPan)
            }
            ancestor = view.superview
        }

        scrollCaptureWired = true
    }

    private func installTerminalFonts() {
        let normal = loadTerminalFont(named: terminalRegularFontName)
        let bold = loadTerminalFont(named: terminalBoldFontName)
        let italic = loadTerminalFont(named: terminalItalicFontName)
        let boldItalic = loadTerminalFont(named: terminalBoldItalicFontName)

        #if DEBUG
        print(terminalGlyphDiagnosticLine(label: "normal", font: normal))
        print(terminalGlyphDiagnosticLine(label: "bold", font: bold))
        print(terminalGlyphDiagnosticLine(label: "italic", font: italic))
        print(terminalGlyphDiagnosticLine(label: "boldItalic", font: boldItalic))
        #endif

        if let normal, let bold, let italic, let boldItalic {
            terminalView.setFonts(normal: normal, bold: bold, italic: italic, boldItalic: boldItalic)
            return
        }

        terminalView.font = normal ?? UIFont.monospacedSystemFont(
            ofSize: UIFont.clawlineMonospaced(.secondaryLabel).pointSize,
            weight: .regular
        )
    }

    private func loadTerminalFont(named name: String) -> UIFont? {
        let fontSize = UIFont.clawlineMonospaced(.secondaryLabel).pointSize
        return UIFont(name: name, size: fontSize)
    }

    #if DEBUG
    private func terminalGlyphDiagnosticLine(label: String, font: UIFont?) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        guard let font else {
            return "[TERM_GLYPH_DIAG] \(ts) install label=\(label) status=missing"
        }

        let ctFont = font as CTFont
        let scalarStatus = terminalGlyphDiagnosticScalars.map { scalar -> String in
            let value = scalar.value
            var utf16 = [UniChar(scalar.utf16.first ?? 0)]
            var glyph = CGGlyph()
            let hasGlyph = CTFontGetGlyphsForCharacters(ctFont, &utf16, &glyph, 1)
            return String(format: "U+%04X:%@:%d", value, hasGlyph ? "glyph" : "missing", glyph)
        }.joined(separator: ",")

        return "[TERM_GLYPH_DIAG] \(ts) install label=\(label) postscript=\(font.fontName) family=\(font.familyName) pointSize=\(font.pointSize) scalars=\(scalarStatus)"
    }
    #endif
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
