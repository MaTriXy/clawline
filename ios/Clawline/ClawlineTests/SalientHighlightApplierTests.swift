//
//  SalientHighlightApplierTests.swift
//  ClawlineTests
//

import Testing
import UIKit
@testable import Clawline

struct SalientHighlightApplierTests {
    private struct FontRun: Equatable {
        let location: Int
        let length: Int
        let traits: UInt32
        let size: CGFloat
    }

    private struct RGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    @Test("Salient highlight uses rust color in light mode without changing fonts")
    func appliesLightModeColorOnly() {
        let base = makeBaseAttributedText()
        let highlights = makeHighlights(for: base.string)

        let result = SalientHighlightApplier.apply(highlights, to: base, isDark: false)

        #expect(fontRuns(result) == fontRuns(base))
        #expect(rgb(result, at: 0) == RGB(red: 158, green: 62, blue: 28))
        #expect(rgb(result, at: 8) == RGB(red: 158, green: 62, blue: 28))
        #expect(rgb(result, at: 15) != RGB(red: 158, green: 62, blue: 28))
    }

    @Test("Salient highlight uses amber color in dark mode without changing fonts")
    func appliesDarkModeColorOnly() {
        let base = makeBaseAttributedText()
        let highlights = makeHighlights(for: base.string)

        let result = SalientHighlightApplier.apply(highlights, to: base, isDark: true)

        #expect(fontRuns(result) == fontRuns(base))
        #expect(rgb(result, at: 0) == RGB(red: 217, green: 175, blue: 98))
        #expect(rgb(result, at: 8) == RGB(red: 217, green: 175, blue: 98))
        #expect(rgb(result, at: 15) != RGB(red: 217, green: 175, blue: 98))
    }

    private func makeHighlights(for text: String) -> SalientHighlights {
        SalientHighlights(
            messageId: "msg-1",
            renderedTextHash: SalientHighlightService.sha256Hex(text),
            renderedTextLengthUTF16: (text as NSString).length,
            algorithmVersion: 2,
            spans: [
                SalientSpan(startUTF16: 0, lengthUTF16: 10, style: .bold, kind: .fact, confidence: 0.9)
            ]
        )
    }

    private func makeBaseAttributedText() -> NSAttributedString {
        let text = "alpha beta gamma"
        let mutable = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: UIColor.black
            ]
        )
        if let italicDescriptor = UIFont.systemFont(ofSize: 16).fontDescriptor.withSymbolicTraits(.traitItalic) {
            mutable.addAttribute(.font, value: UIFont(descriptor: italicDescriptor, size: 16), range: NSRange(location: 6, length: 4))
        }
        return mutable
    }

    private func fontRuns(_ attributed: NSAttributedString) -> [FontRun] {
        let range = NSRange(location: 0, length: attributed.length)
        var runs: [FontRun] = []
        attributed.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            guard let font = value as? UIFont else { return }
            runs.append(FontRun(
                location: subRange.location,
                length: subRange.length,
                traits: font.fontDescriptor.symbolicTraits.rawValue,
                size: font.pointSize
            ))
        }
        return runs
    }

    private func rgb(_ attributed: NSAttributedString, at index: Int) -> RGB? {
        guard let color = attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor else {
            return nil
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return RGB(
            red: Int((red * 255).rounded()),
            green: Int((green * 255).rounded()),
            blue: Int((blue * 255).rounded())
        )
    }
}
