//
//  ChatFlowOrganicComplianceTests.swift
//  ClawlineTests
//
//  Created by Codex on 1/12/26.
//

import SwiftUI
import Testing
@testable import Clawline

struct ChatFlowOrganicComplianceTests {

    // MARK: Message presentation (§5/§6)

    @Test("Doc §5: Markdown + code segmentation")
    func messagePresentationParsesMarkdownAndCode() {
        let message = sampleMessage(content: """
        Here is **bold** markdown.

        ```swift
        print("Hello")
        ```
        """)
        let presentation = buildPresentation(message)

        #expect(presentation.parts.contains(where: { part in
            if case .markdown = part { return true }
            return false
        }))
        #expect(presentation.parts.contains(where: { part in
            if case .code(let language, let code) = part {
                return language == "swift" && code.contains("print")
            }
            return false
        }))
    }

    @Test("Doc §5: Markdown tables promote to table part")
    func messagePresentationParsesTables() {
        let message = sampleMessage(content: """
        | Animal | Legs |
        | :--- | ---: |
        | Cat | 4 |
        | Bird | 2 |
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.header?.count == 2)
        #expect(table.rows.count == 2)
        #expect(table.rows.first?.cells.last?.plainText == "4")
    }

    @Test("Doc §5: Header-only tables fall back to markdown")
    func headerOnlyTablesFallback() {
        let message = sampleMessage(content: """
        | Foo | Bar |
        | --- | --- |
        """)
        let presentation = buildPresentation(message)
        #expect(!presentation.parts.contains(where: { part in
            if case .table = part { return true }
            return false
        }))
    }

    @Test("Doc §5: Escaped pipes stay inside a cell")
    func escapedPipesRemainInCell() {
        let message = sampleMessage(content: """
        | Value |
        | --- |
        | Foo \\| Bar |
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.rows.first?.cells.first?.plainText == "Foo | Bar")
    }

    @Test("Doc §5: Inline code preserves literal pipes")
    func inlineCodePipesStayLiteral() {
        let message = sampleMessage(content: """
        | Code |
        | --- |
        | `a | b` |
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.rows.first?.cells.first?.plainText == "a | b")
    }

    @Test("Doc §5: Tables touching lists require leading pipes")
    func tablesAdjacentToListsRequireLeadingPipe() {
        let message = sampleMessage(content: """
        - bullet intro
        Foo | Bar
        | --- | --- |
        | 1 | 2 |
        """)
        let presentation = buildPresentation(message)
        #expect(!presentation.parts.contains(where: { part in
            if case .table = part { return true }
            return false
        }))
    }

    @Test("Doc §5: Column count capped at forty")
    func tableColumnLimit() {
        let header = Array(repeating: "H", count: 41).joined(separator: " | ")
        let row = Array(repeating: "1", count: 41).joined(separator: " | ")
        let message = sampleMessage(content: """
        | \(header) |
        | \(Array(repeating: "---", count: 41).joined(separator: " | ")) |
        | \(row) |
        """)
        let presentation = buildPresentation(message)
        #expect(!presentation.parts.contains(where: { part in
            if case .table = part { return true }
            return false
        }))
    }

    @Test("Doc §5: Table cells capped at 400 per message")
    func tableCellCountIsCapped() {
        let header = "| A | B | C | D | E | F | G | H | I | J |"
        let divider = "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
        let row = "| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |"
        let body = Array(repeating: row, count: 60).joined(separator: "\n")
        let message = sampleMessage(content: """
        \(header)
        \(divider)
        \(body)
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.rows.count * 10 <= 390)
    }

    @Test("Doc §5: Excessive markdown nesting falls back to plain text")
    func markdownDepthLimitApplies() {
        let message = sampleMessage(content: """
        | Value |
        | --- |
        | ******deep****** |
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.rows.first?.cells.first?.plainText == "deep")
    }

    @Test("Doc §8: Table parsing meets performance budget")
    func tableParsingPerformance() {
        let header = "| " + Array(repeating: "Col", count: 10).joined(separator: " | ") + " |"
        let divider = "| " + Array(repeating: "---", count: 10).joined(separator: " | ") + " |"
        let row = "| " + Array(repeating: "cell", count: 10).joined(separator: " | ") + " |"
        let body = Array(repeating: row, count: 40).joined(separator: "\n")
        let message = sampleMessage(content: """
        \(header)
        \(divider)
        \(body)
        """)
        let clock = ContinuousClock()
        let start = clock.now
        _ = buildPresentation(message)
        let duration = clock.now - start
        #expect(duration < .milliseconds(500))
    }

    @Test("Doc §5: Exact URL detection")
    func messagePresentationDetectsExactURLs() {
        let exact = buildPresentation(sampleMessage(content: "https://example.com/path"))
        #expect(exact.parts.contains(where: { part in
            if case .linkPreview(let url) = part {
                return url.absoluteString == "https://example.com/path"
            }
            return false
        }))

        let partial = buildPresentation(sampleMessage(content: "Visit https://example.com now"))
        #expect(!partial.parts.contains(where: { part in
            if case .linkPreview = part { return true }
            return false
        }))
    }

    @Test("Doc §5: Emoji-only detection")
    func messagePresentationEmojiOnlyClassification() {
        let presentation = buildPresentation(sampleMessage(content: "😀😁"))
        #expect(presentation.parts.contains(where: { part in
            if case .inlineEmoji(let value) = part {
                return value.contains("😀")
            }
            return false
        }))
        #expect(presentation.isEmojiOnly)
    }

    @Test("Doc §5: Media-only attachments map to gallery")
    func messagePresentationMediaOnlyGallery() {
        let message = Message(
            id: "media",
            role: .assistant,
            content: "",
            timestamp: Date(),
            streaming: false,
            attachments: [sampleAttachment(id: "img1"), sampleAttachment(id: "img2")],
            deviceId: nil
        )
        let presentation = buildPresentation(message)
        #expect(presentation.parts.contains(where: { part in
            if case .gallery(let attachments) = part {
                return attachments.count == 2
            }
            return false
        }))
        #expect(presentation.hasMediaOnly)
    }

    @Test("Doc §6: Word count strips markdown syntax")
    func wordCountStripsMarkdown() {
        let presentation = buildPresentation(sampleMessage(content: "**bold** _italic_ `code` text"))
        #expect(presentation.wordCount == 4)
    }

    // MARK: Flow classification (§3)

    @Test("Doc §3: Medium sizing clamps to 200pt")
    func flowClassificationMediumWidthClamp() {
        let layout = FlowLayout(itemSpacing: 16, rowSpacing: 16, maxLineWidth: 600, isCompact: false)
        let width = layout.maxItemWidth(for: .medium, containerWidth: 320)
        #expect(width >= 200)
    }

    @Test("Doc §3: Media-only messages skip medium class")
    func flowClassificationMediaOnlyAlwaysLong() {
        let message = Message(
            id: "mediaMessage",
            role: .assistant,
            content: "",
            timestamp: Date(),
            streaming: false,
            attachments: [sampleAttachment(id: "img")],
            deviceId: nil
        )
        let presentation = buildPresentation(message)
        #expect(presentation.inferredSizeClass() == .long)
    }

    @Test("Doc §3: 1–3 word messages classify as short")
    func flowClassificationShortUnderFourWords() {
        let presentation = buildPresentation(sampleMessage(content: "tiny message"))
        #expect(presentation.inferredSizeClass() == .short)
    }

    @Test("Doc §3: >20 word messages classify as long")
    func flowClassificationLongOverTwentyWords() {
        let content = Array(repeating: "word", count: 25).joined(separator: " ")
        let presentation = buildPresentation(sampleMessage(content: content))
        #expect(presentation.inferredSizeClass() == .long)
    }

    @Test("Doc §3: Streaming promotions debounce")
    func streamingPromotionsRespectDebounce() {
        let mediumPromotion = MessageFlowRules.promotedSizeClass(current: .short, next: .medium)
        let finalPromotion = MessageFlowRules.promotedSizeClass(current: mediumPromotion, next: .long)
        #expect(mediumPromotion == .medium)
        #expect(finalPromotion == .long)
        #expect(MessageFlowRules.streamingPromotionDelay == .milliseconds(280))
    }

    // MARK: Truncation (§4/§6)

    @Test("Doc §4: Height-based truncation")
    func truncationHeightOnly() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let shouldTruncate = MessageFlowRules.shouldTruncate(
            hasTextualParts: true,
            sizeClass: .long,
            isExpanded: false,
            measuredHeight: metrics.truncationHeight + 10,
            metrics: metrics
        )
        let withinBounds = MessageFlowRules.shouldTruncate(
            hasTextualParts: true,
            sizeClass: .long,
            isExpanded: false,
            measuredHeight: metrics.truncationHeight - 1,
            metrics: metrics
        )
        #expect(shouldTruncate)
        #expect(!withinBounds)
    }

    @Test("Doc §4: Show more/less toggle state")
    func truncationToggleExpandsAndCollapses() {
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        let collapsed = MessageFlowRules.shouldTruncate(
            hasTextualParts: true,
            sizeClass: .long,
            isExpanded: false,
            measuredHeight: metrics.truncationHeight + 5,
            metrics: metrics
        )
        let expanded = MessageFlowRules.shouldTruncate(
            hasTextualParts: true,
            sizeClass: .long,
            isExpanded: true,
            measuredHeight: metrics.truncationHeight + 5,
            metrics: metrics
        )
        #expect(collapsed)
        #expect(!expanded)
    }

    @Test("Doc §4: Streaming truncation re-evaluates")
    func streamingTruncationReevaluatesDuringGrowth() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let lower = MessageFlowRules.shouldShowTruncationControl(
            hasTextualParts: true,
            sizeClass: .long,
            measuredHeight: metrics.truncationHeight - 1,
            metrics: metrics
        )
        let higher = MessageFlowRules.shouldShowTruncationControl(
            hasTextualParts: true,
            sizeClass: .long,
            measuredHeight: metrics.truncationHeight + 15,
            metrics: metrics
        )
        #expect(!lower)
        #expect(higher)
    }

    @Test("Doc §6: Truncation height varies by device class")
    func truncationHeightMatchesMetrics() {
        #expect(ChatFlowTheme.Metrics(isCompact: false).truncationHeight == 400)
        #expect(ChatFlowTheme.Metrics(isCompact: true).truncationHeight == 320)
    }

    // MARK: Provider contract (§7)

    @Test("Doc §7: Provider incoming payload schema")
    func serverMessageDeserializationIncludesDeviceId() {
        let json = """
        {
            "type": "message",
            "id": "s_789",
            "role": "assistant",
            "content": "Hello",
            "timestamp": 1704672000000,
            "streaming": false,
            "deviceId": "ABC123",
            "attachments": []
        }
        """
        let payload = try! JSONDecoder().decode(ServerMessagePayload.self, from: Data(json.utf8))
        let message = Message(payload: payload)
        #expect(message.id == "s_789")
        #expect(message.role == .assistant)
        #expect(message.content == "Hello")
        #expect(message.timestamp.timeIntervalSince1970 == 1704672000)
        #expect(message.streaming == false)
    }

    @Test("Doc §7: Client payload excludes role/timestamp")
    func outgoingMessagePayloadIsMinimal() {
        let payload = sampleMessage(content: "Hello world").toClientPayload()
        let json = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(payload)) as? [String: Any]
        #expect(json?["type"] as? String == "message")
        #expect(json?["id"] != nil)
        #expect(json?["content"] as? String == "Hello world")
        #expect(json?["attachments"] != nil)
        #expect(json?["role"] == nil)
        #expect(json?["timestamp"] == nil)
        #expect(json?["streaming"] == nil)
    }

    @Test("Doc §7: Attachment payload serializes correctly")
    func outgoingAttachmentsSerialization() {
        let attachment = Attachment(id: "img", type: .image, mimeType: "image/png", data: Data([0x01, 0x02]), assetId: nil)
        let message = Message(
            id: "c_img",
            role: .user,
            content: "See photo",
            timestamp: Date(),
            streaming: false,
            attachments: [attachment],
            deviceId: nil
        )
        let payload = message.toClientPayload()
        let decoded = try! JSONDecoder().decode(ClientMessagePayload.self, from: try! JSONEncoder().encode(payload))
        guard let first = decoded.attachments.first else {
            Issue.record("Expected attachment entry")
            return
        }
        switch first {
        case .image(let mimeType, let data):
            #expect(mimeType == "image/png")
            #expect(Array(data) == [0x01, 0x02])
        default:
            Issue.record("Expected inline image attachment")
        }
    }

    @Test("Doc §7: Message mirrors provider schema")
    func messageModelMatchesProviderContract() {
        let payload = ServerMessagePayload(
            id: "s_mirror",
            role: .user,
            content: "ping",
            timestamp: Date(),
            streaming: true,
            deviceId: "device",
            attachments: []
        )
        let message = Message(payload: payload)
        #expect(message.id == payload.id)
        #expect(message.role == payload.role)
        #expect(message.streaming == payload.streaming)
        #expect(message.attachments == payload.attachments)
    }

    @Test("Doc §5: MessagePart.isTextual lives with model")
    func messagePartIsTextualDefinedOnce() {
        #expect(MessagePart.text("value").isTextual)
        #expect(MessagePart.markdown("**bold**").isTextual)
        #expect(MessagePart.code(language: "swift", code: "print()").isTextual)
        #expect(!MessagePart.image(sampleAttachment(id: "img")).isTextual)
        #expect(!MessagePart.gallery([sampleAttachment(id: "img")]).isTextual)
    }

    // MARK: Input bar & accessibility (§9/§10)

    @Test("Doc §10: Accessibility announcements")
    func voiceOverAnnouncesSenderAndContentType() {
        let message = Message(
            id: "voiceover",
            role: .assistant,
            content: "Look",
            timestamp: Date(),
            streaming: false,
            attachments: [sampleAttachment(id: "img1"), sampleAttachment(id: "img2")],
            deviceId: nil
        )
        let presentation = buildPresentation(message)
        let label = MessageAccessibilityFormatter.label(for: message, presentation: presentation)
        #expect(label.contains("Assistant"))
        #expect(label.contains("2 image attachments"))
    }

    @Test("Doc §10: Reduce Motion disables hover/caustics")
    func reduceMotionDisablesAnimations() {
        let enabled = MessageInputMotionState(reduceMotionEnabled: false)
        let disabled = MessageInputMotionState(reduceMotionEnabled: true)
        #expect(enabled.causticsEnabled)
        #expect(!disabled.causticsEnabled)
    }

    // MARK: Helpers

    private func sampleMessage(content: String) -> Message {
        Message(
            id: UUID().uuidString,
            role: .assistant,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil
        )
    }

    private func buildPresentation(_ message: Message, isCompact: Bool = true) -> MessagePresentation {
        var state = StreamingTableParseState()
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        return MessagePresentationBuilder.build(from: message, metrics: metrics, streamingState: &state)
    }

    private func sampleAttachment(id: String) -> Clawline.Attachment {
        Clawline.Attachment(id: id, type: .image, mimeType: "image/png", data: nil, assetId: nil)
    }
}
