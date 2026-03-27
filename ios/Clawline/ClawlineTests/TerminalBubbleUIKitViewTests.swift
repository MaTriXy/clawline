import UIKit
import SwiftTerm
import Testing
@testable import Clawline

@MainActor
struct TerminalBubbleUIKitViewTests {
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
}
