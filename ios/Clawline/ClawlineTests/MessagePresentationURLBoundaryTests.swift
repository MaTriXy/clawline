//
//  MessagePresentationURLBoundaryTests.swift
//  ClawlineTests
//

import Testing
import Foundation
@testable import Clawline

struct MessagePresentationURLBoundaryTests {
    @Test("Direct image URL content renders as remote image media")
    func directImageURLContentRendersAsRemoteImageMedia() {
        let imageURL = "http://tars.tail4105e8.ts.net:18800/www/ticker/latest.png"
        let presentation = buildPresentation(content: imageURL)

        #expect(presentation.parts.contains(where: { part in
            if case .remoteImage(let url) = part {
                return url.absoluteString == imageURL
            }
            return false
        }))
        #expect(!presentation.parts.contains(where: { part in
            if case .linkPreview = part { return true }
            return false
        }))
        #expect(presentation.detectedURLs.isEmpty)
        #expect(presentation.hasMediaOnly)
        #expect(!presentation.hasTextualContent)
        #expect(presentation.markdownRenderPlan.blocks.isEmpty)
    }

    @Test("Direct image URL preserves caption text without URL markdown")
    func directImageURLPreservesCaptionTextWithoutURLMarkdown() {
        let imageURL = "https://example.com/ticker/latest.png"
        let presentation = buildPresentation(content: "Ticker update\n\(imageURL)")

        #expect(presentation.parts.contains(where: { part in
            if case .remoteImage(let url) = part {
                return url.absoluteString == imageURL
            }
            return false
        }))
        #expect(presentation.parts.contains(where: { part in
            if case .markdown(let text) = part {
                return text == "Ticker update"
            }
            return false
        }))
        #expect(!presentation.parts.contains(where: { part in
            if case .markdown(let text) = part {
                return text.contains(imageURL)
            }
            return false
        }))
        #expect(!presentation.hasMediaOnly)
        #expect(presentation.hasTextualContent)
    }

    @Test("Non-image URLs still render as link previews")
    func nonImageURLsStillRenderAsLinkPreviews() {
        let url = "https://example.com/ticker/latest.html"
        let presentation = buildPresentation(content: url)

        #expect(presentation.parts.contains(where: { part in
            if case .linkPreview(let detected) = part {
                return detected.absoluteString == url
            }
            return false
        }))
        #expect(!presentation.parts.contains(where: { part in
            if case .remoteImage = part { return true }
            return false
        }))
        #expect(presentation.detectedURLs.map { $0.absoluteString } == [url])
    }

    @Test("Direct image URLs inside code blocks stay code")
    func directImageURLsInsideCodeBlocksStayCode() {
        let imageURL = "https://example.com/ticker/latest.png"
        let presentation = buildPresentation(content: "```text\n\(imageURL)\n```")

        #expect(presentation.parts.contains(where: { part in
            if case .code(_, let code) = part {
                return code.contains(imageURL)
            }
            return false
        }))
        #expect(!presentation.parts.contains(where: { part in
            if case .remoteImage = part { return true }
            return false
        }))
    }

    @Test("Typed image attachments still render through attachment media")
    func typedImageAttachmentsStillRenderThroughAttachmentMedia() {
        let attachment = Clawline.Attachment(
            id: "typed-image",
            type: .image,
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            assetId: nil
        )
        let presentation = buildPresentation(content: "", attachments: [attachment])

        #expect(presentation.parts.contains(where: { part in
            if case .image(let detected) = part {
                return detected.id == attachment.id
            }
            return false
        }))
        #expect(!presentation.parts.contains(where: { part in
            if case .remoteImage = part { return true }
            return false
        }))
    }

    @Test("Wrapped mark delimiters do not leak into link preview hrefs")
    func wrappedMarkDelimitersDoNotLeakIntoLinkPreviewHrefs() {
        let presentation = buildPresentation(content: "==https://example.com==")

        #expect(presentation.detectedURLs.map { $0.absoluteString } == ["https://example.com"])
        #expect(presentation.parts.contains(where: { part in
            if case .linkPreview(let url) = part {
                return url.absoluteString == "https://example.com"
            }
            return false
        }))
    }

    @Test("Wrapped mark delimiters preserve legitimate query values containing double equals")
    func wrappedMarkDelimitersPreserveLegitimateQueryValues() {
        let content = "==https://example.com/path?token=YWJjZA===="
        let expectedURL = "https://example.com/path?token=YWJjZA=="
        let presentation = buildPresentation(content: content)

        #expect(presentation.detectedURLs.map { $0.absoluteString } == [expectedURL])
        #expect(presentation.parts.contains(where: { part in
            if case .linkPreview(let url) = part {
                return url.absoluteString == expectedURL
            }
            return false
        }))
    }

    private func buildPresentation(content: String, attachments: [Clawline.Attachment] = []) -> MessagePresentation {
        let message = Message(
            id: "m_url_boundary",
            role: .assistant,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: attachments,
            deviceId: nil,
            sessionKey: "agent:main:clawline:user:main"
        )
        var state = StreamingTableParseState()
        return MessagePresentationBuilder.build(
            from: message,
            metrics: ChatFlowTheme.Metrics(isCompact: true),
            streamingState: &state
        )
    }
}
