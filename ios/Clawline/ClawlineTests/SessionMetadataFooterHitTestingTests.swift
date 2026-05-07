import Testing
import UIKit
@testable import Clawline

@MainActor
struct SessionMetadataFooterHitTestingTests {
    @Test("Model action hit target includes padded region outside compact label")
    func modelActionHitTargetIncludesPaddedRegionOutsideCompactLabel() throws {
        let status = SessionStatus(
            sessionKey: "agent:main:clawline:user:s_test",
            display: .init(
                model: "gpt-5.5",
                fallbackModels: ["gpt-5.5", "claude-sonnet-4.6"],
                provider: "openai",
                harness: nil,
                reasoningLevel: nil,
                thinkingLevel: "high",
                fastMode: true,
                mode: nil,
                verbosity: nil
            ),
            run: .init(
                state: .idle,
                runId: nil,
                messageId: nil,
                startedAt: nil,
                queueDepth: nil
            ),
            context: nil,
            approval: nil,
            capabilities: .init(
                cancelCurrentRun: nil,
                setModel: .init(supported: true, reason: nil),
                setThinking: .init(supported: true, reason: nil),
                setReasoning: nil,
                setFastMode: .init(supported: true, reason: nil),
                setMode: nil,
                setVerbosity: nil,
                canCancelCurrentRun: nil,
                canChangeModel: nil,
                canChangeReasoning: nil,
                canChangeFastMode: nil,
                canChangeVerbosity: nil,
                readOnlyStatus: nil
            ),
            modelCatalog: nil
        )
        let cell = SessionMetadataFooterCell(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 320,
                height: SessionMetadataFooterCell.height(for: status)
            )
        )

        cell.configure(status: status, isDark: false, onSelect: { _, _, _, _ in })
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        let modelButton = allSubviews(in: cell)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "gpt-5.5" }
        let button = try #require(modelButton)
        let buttonFrame = button.convert(button.bounds, to: cell)
        let verticalExpansion = max(0, (44 - button.bounds.height) / 2)
        let offset = max(1, min(8, verticalExpansion - 1))
        let paddedPoint = CGPoint(x: buttonFrame.midX, y: buttonFrame.maxY + offset)

        #expect(buttonFrame.contains(paddedPoint) == false)
        #expect(cell.bounds.contains(paddedPoint))
        #expect(cell.hitTest(paddedPoint, with: nil) === button)
    }
}

private func allSubviews(in view: UIView) -> [UIView] {
    view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
}
