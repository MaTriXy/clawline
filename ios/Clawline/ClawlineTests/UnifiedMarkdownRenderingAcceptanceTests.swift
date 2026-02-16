import Testing
import UIKit
@testable import Clawline

struct UnifiedMarkdownRenderingAcceptanceTests {
    private let metrics = ChatFlowTheme.Metrics(isCompact: true)

    @Test("R48-01: mixed text/code/table preserves source order for bubble and expanded")
    func r48_01_orderPreserved() {
        let markdown = """
        Intro text.

        ```swift
        print(\"one\")
        ```

        Middle text.

        | A | B |
        | --- | --- |
        | 1 | 2 |

        Tail text.
        """

        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r48_01", metrics: metrics)
        #expect(sequence(for: plan.blocks) == [.richText, .code, .richText, .table, .richText])

        let bubble = UnifiedMarkdownRenderer.render(plan: plan, options: bubbleOptions())
        let expanded = UnifiedMarkdownRenderer.render(plan: plan, options: expandedOptions())
        #expect(sequence(for: bubble) == [.attributedText, .code, .attributedText, .table, .attributedText])
        #expect(sequence(for: expanded) == [.attributedText, .code, .attributedText, .table, .attributedText])
    }

    @Test("R48-02: expanded path keeps all markdown blocks")
    func r48_02_noDroppedExpandedBlocks() {
        let markdown = (1...80)
            .map { "Paragraph \($0) with **markdown** and https://example.com/\($0)" }
            .joined(separator: "\n\n")
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r48_02", metrics: metrics)

        let bubble = UnifiedMarkdownRenderer.render(plan: plan, options: bubbleOptions())
        let expanded = UnifiedMarkdownRenderer.render(plan: plan, options: expandedOptions())
        #expect(bubble.count == expanded.count)
        #expect(expanded.count == plan.blocks.count)
    }

    @Test("R48-03: bubble and expanded share one plan; options-only divergence")
    func r48_03_surfaceDifferenceIsOptionsOnly() {
        let markdown = """
        # Heading

        Intro with https://one.example

        > quoted `inline`

        - list item

        ```python
        print("code")
        ```

        | K | V |
        | --- | --- |
        | a | b |
        """
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r48_03", metrics: metrics)

        let bubble = UnifiedMarkdownRenderer.render(plan: plan, options: bubbleOptions())
        let expanded = UnifiedMarkdownRenderer.render(plan: plan, options: expandedOptions())
        #expect(sequence(for: bubble) == sequence(for: expanded))

        let bubbleText = joinedText(from: bubble)
        let expandedText = joinedText(from: expanded)
        #expect(!bubbleText.contains("https://one.example"))
        #expect(expandedText.contains("https://one.example"))
    }

    @Test("R50-01: fenced code with language does not regress to plain text")
    func r50_01_standardFence() {
        let markdown = """
        ```swift
        print("hello")
        ```

        trailing prose
        """
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r50_01", metrics: metrics)
        #expect(sequence(for: plan.blocks) == [.code, .richText])
    }

    @Test("R50-02: colon-prefixed line before fence keeps stable classification")
    func r50_02_colonPrefixBeforeFence() {
        let markdown = """
        Here is output:
        ```js
        console.log('x')
        console.log('y')
        ```
        done
        """
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r50_02", metrics: metrics)
        #expect(sequence(for: plan.blocks) == [.richText, .code, .richText])
    }

    @Test("R50-03: valid weird fence is code; malformed fence falls back to rich text")
    func r50_03_whitespaceAndMalformedFence() {
        let valid = """
        ```   
        alpha
        ```
        """
        let invalid = """
        ```
        alpha
        """

        let validPlan = UnifiedMarkdownParser.parse(markdown: valid, messageID: "r50_03_valid", metrics: metrics)
        let invalidPlan = UnifiedMarkdownParser.parse(markdown: invalid, messageID: "r50_03_invalid", metrics: metrics)
        #expect(sequence(for: validPlan.blocks) == [.code])
        #expect(sequence(for: invalidPlan.blocks) == [.richText])
    }

    @Test("R50-04: multiple fenced blocks remain ordered")
    func r50_04_multipleCodeBlocks() {
        let markdown = """
        text

        ```swift
        print(1)
        ```

        middle

        ```python
        print(2)
        ```

        end
        """
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r50_04", metrics: metrics)
        #expect(sequence(for: plan.blocks) == [.richText, .code, .richText, .code, .richText])
    }

    @Test("HL-01: mark highlight applies to rich text only")
    func hl_01_markHighlightScoping() {
        let markdown = """
        Alpha ==focus== and `==literal==`.

        ```swift
        // ==code==
        print("ok")
        ```
        """
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "hl_01", metrics: metrics)
        let rendered = UnifiedMarkdownRenderer.render(
            plan: plan,
            options: MarkdownRenderOptions(
                baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
                inkColor: .black,
                lineSpacing: 4,
                stripDetectedURLs: false,
                markHighlightColor: SalientHighlightApplier.highlightColor(isDark: false)
            )
        )

        guard case .attributedText(let richText)? = rendered.first else {
            Issue.record("Expected first block to be attributed text")
            return
        }
        #expect(richText.string.contains("focus"))
        #expect(richText.string.contains("==literal=="))

        let codeBlocks = rendered.compactMap { block -> String? in
            if case .code(_, let code) = block { return code }
            return nil
        }
        #expect(codeBlocks.count == 1)
        #expect(codeBlocks[0].contains("==code=="))
    }

    @Test("TB-01: broken table input falls back to rich text without dropping content")
    func tb_01_brokenTableFallback() {
        let markdown = """
        | A | B |
        | --- |
        | 1 | 2 |
        """
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "tb_01", metrics: metrics)
        #expect(!plan.blocks.contains(where: { if case .table = $0 { return true }; return false }))
        let combined = plan.blocks.compactMap { block -> String? in
            if case .richText(let source) = block { return source }
            return nil
        }.joined(separator: "\n")
        #expect(combined.contains("| A | B |"))
        #expect(combined.contains("| 1 | 2 |"))
    }

    private enum BlockType: Equatable {
        case richText
        case code
        case table
    }

    private enum RenderedType: Equatable {
        case attributedText
        case code
        case table
    }

    private func sequence(for blocks: [MarkdownRenderBlock]) -> [BlockType] {
        blocks.map { block in
            switch block {
            case .richText:
                return .richText
            case .code:
                return .code
            case .table:
                return .table
            }
        }
    }

    private func sequence(for blocks: [RenderedMarkdownBlock]) -> [RenderedType] {
        blocks.map { block in
            switch block {
            case .attributedText:
                return .attributedText
            case .code:
                return .code
            case .table:
                return .table
            }
        }
    }

    private func bubbleOptions() -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            baseFont: UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            stripDetectedURLs: true,
            markHighlightColor: nil
        )
    }

    private func expandedOptions() -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            baseFont: UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            stripDetectedURLs: false,
            markHighlightColor: nil
        )
    }

    private func joinedText(from blocks: [RenderedMarkdownBlock]) -> String {
        blocks.compactMap { block -> String? in
            if case .attributedText(let attributed) = block {
                return attributed.string
            }
            return nil
        }
        .joined(separator: "\n\n")
    }
}
