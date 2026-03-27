import UIKit
import SwiftTerm
import Testing
@testable import Clawline

@MainActor
struct TerminalBubbleUIKitViewTests {
    @Test("T001: terminal bubble reserves one row less than SwiftTerm reports")
    func terminalBubbleVisibleRowsClampReportedRowsByOne() {
        #expect(TerminalBubbleUIKitView.visibleRows(forReportedRows: 24) == 23)
        #expect(TerminalBubbleUIKitView.visibleRows(forReportedRows: 2) == 1)
        #expect(TerminalBubbleUIKitView.visibleRows(forReportedRows: 1) == 1)
    }

    @Test("T001: terminal bubble renders without close or expand buttons and fills its bubble height")
    func terminalBubbleHasNoChromeButtonsAndTerminalMatchesBounds() {
        let view = TerminalBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.configure(descriptor: sampleDescriptor(), style: .bubble(height: 240))
        view.layoutIfNeeded()

        let buttonTitles = allSubviews(in: view).compactMap { ($0 as? UIButton)?.currentTitle }
        #expect(!buttonTitles.contains("Expand"))
        #expect(!buttonTitles.contains("Close"))

        let terminalView = allSubviews(in: view).compactMap { $0 as? FocusableTerminalView }.first
        #expect(terminalView != nil)
        if let terminalView {
            #expect(terminalView.frame.integral == view.bounds.integral)
            #expect(terminalView.backgroundColor?.cgColor.alpha == 1)
            #expect(terminalView.backgroundColor != .clear)
            let foreground = terminalView.nativeForegroundColor
            let background = terminalView.nativeBackgroundColor
            #expect(relativeLuminance(foreground) > relativeLuminance(background))
            #expect(
                terminalView.font.fontName == "BlexMonoNFM"
                    || terminalView.font.fontName == ".AppleSystemUIFontMonospaced-Regular"
            )
        }
        #expect(view.backgroundColor?.cgColor.alpha == 1)
        #expect(view.backgroundColor != .clear)
    }

    private func sampleDescriptor() -> TerminalSessionDescriptor {
        TerminalSessionDescriptor(
            version: 1,
            terminalSessionId: "ts_test",
            title: "Terminal Bubble Test",
            provider: .init(baseUrl: "https://example.com", wsPath: "/ws/terminal"),
            capabilities: .init(
                interactive: true,
                supportsBinaryFrames: true,
                supportsResize: true,
                supportsDetach: true
            ),
            auth: .init(mode: .chatToken, terminalAccessToken: nil),
            expiresAtMs: nil
        )
    }

    private func allSubviews(in view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { self.allSubviews(in: $0) }
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }
}
