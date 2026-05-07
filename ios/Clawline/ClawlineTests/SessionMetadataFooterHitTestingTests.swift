import Testing
import UIKit
@testable import Clawline

@MainActor
struct SessionMetadataFooterHitTestingTests {
    @Test("Model action hit target includes padded region outside compact label")
    func modelActionHitTargetIncludesPaddedRegionOutsideCompactLabel() throws {
        let cell = makeConfiguredCell()

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

    @Test("Thinking action hit target includes off-glyph segment around compact label")
    func thinkingActionHitTargetIncludesOffGlyphSegmentAroundCompactLabel() throws {
        let cell = makeConfiguredCell()
        let buttons = allSubviews(in: cell).compactMap { $0 as? UIButton }
        let thinkingButton = try #require(buttons.first { $0.accessibilityLabel == "Thinking high" })
        let thinkingFrame = thinkingButton.convert(thinkingButton.bounds, to: cell)
        let thinkingRegion = try #require(
            FooterActionHitTesting.actionRegions(for: buttons, in: cell)
                .first { $0.view === thinkingButton }?.rect
        )
        let offGlyphX = max(thinkingRegion.minX + 1, thinkingFrame.minX - 1)
        let offGlyphPoint = CGPoint(x: offGlyphX, y: thinkingRegion.midY)

        #expect(thinkingRegion.width >= 44)
        #expect(thinkingFrame.contains(offGlyphPoint) == false)
        #expect(thinkingRegion.contains(offGlyphPoint))
        #expect(cell.hitTest(offGlyphPoint, with: nil) === thinkingButton)
    }
}

private func makeConfiguredCell() -> SessionMetadataFooterCell {
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
    return cell
}

private func allSubviews(in view: UIView) -> [UIView] {
    view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
}
