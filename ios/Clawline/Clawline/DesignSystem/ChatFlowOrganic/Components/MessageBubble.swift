//
//  MessageBubble.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit
import LinkPresentation
import HighlightSwift

struct MessageBubble: View {
    let message: Message
    let presentation: MessagePresentation
    let onLayoutInvalidation: ((String) -> Void)?
    let truncationState: TruncationState

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showExpandedSheet = false

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var metrics: ChatFlowTheme.Metrics { ChatFlowTheme.Metrics(isCompact: isCompact) }
    private var textualParts: [MessagePart] { presentation.parts.filter { $0.isTextual }}
    private var nonTextParts: [MessagePart] { presentation.parts.filter { !$0.isTextual }}
    private var hasTextualParts: Bool { !textualParts.isEmpty }
    private var derivedSizeClass: MessageSizeClass { presentation.inferredSizeClass() }
    private var maxLineWidth: CGFloat { ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize) }

    private var sizeClass: MessageSizeClass {
        derivedSizeClass
    }

    var body: some View {
        sizedBubble
            .layoutValue(key: MessageSizeClassKey.self, value: sizeClass)
            .sheet(isPresented: $showExpandedSheet) {
                ExpandedMessageSheet(message: message, presentation: presentation)
            }
    }

    @ViewBuilder
    private var sizedBubble: some View {
        if sizeClass == .short {
            bubble
                .fixedSize(horizontal: true, vertical: true)
        } else {
            bubble
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            bubbleContent
                .clipShape(bubbleContentShape)

            if shouldShowTruncationControl {
                truncationIndicator
                    .padding(.horizontal, bubblePaddingHorizontal)
                    .padding(.bottom, bubblePaddingVertical)
                    .background(bubbleBackground)
                    .clipShape(truncationIndicatorShape)
                    .offset(y: -1) // Overlap by 1pt to hide seam
            }
        }
        .shadow(color: bubbleShadowNear, radius: 2, x: 0, y: 2)
        .shadow(color: bubbleShadowMid, radius: 12, x: 0, y: 8)
        .shadow(color: bubbleShadowFar, radius: 20, x: 0, y: 16)
        .overlay(adminOutline)
        .accessibilityLabel(MessageAccessibilityFormatter.label(for: message, presentation: presentation))
    }

    /// Shape for bubble content - flat bottom when truncation indicator is shown
    private var bubbleContentShape: UnevenRoundedRectangle {
        let radii = bubbleCornerRadii()
        if shouldShowTruncationControl {
            return UnevenRoundedRectangle(
                topLeadingRadius: radii.topLeading,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: radii.topTrailing
            )
        }
        return bubbleShape
    }

    /// Shape for truncation indicator - flat top, rounded bottom matching bubble
    private var truncationIndicatorShape: UnevenRoundedRectangle {
        let radii = bubbleCornerRadii()
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: 0
        )
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            messageBody

            if message.streaming {
                ProgressView()
                    .scaleEffect(0.75)
            }
        }
        .padding(.vertical, bubblePaddingVertical)
        .padding(.horizontal, bubblePaddingHorizontal)
        .background(bubbleBackground)
        .overlay(innerHighlightOverlay)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(role: message.role)
            Text(senderName)
                .font(.system(size: metrics.senderFontSize, weight: .semibold))
                .foregroundColor(message.channelType == .admin ? ChatFlowTheme.adminAccent(colorScheme) : ChatFlowTheme.warmBrown(colorScheme))
                .opacity(message.channelType == .admin ? 1 : 0.7)
                .tracking(0.3)
        }
    }

    private var messageBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasTextualParts {
                textContainer
            }
            ForEach(Array(nonTextParts.enumerated()), id: \.offset) { item in
                partView(item.element)
            }
        }
    }

    private var textContainer: some View {
        Group {
            if sizeClass == .long {
                textualContent
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxLineWidth, alignment: .leading)
                    .mask(truncationFadeMask)
            } else if sizeClass == .short {
                textualContent
                    .fixedSize(horizontal: true, vertical: true)
            } else {
                textualContent
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxLineWidth, alignment: .leading)
            }
        }
    }

    private var textualContent: some View {
        MessageBubbleTextContentView(
            message: message,
            presentation: presentation,
            metrics: metrics,
            colorScheme: colorScheme,
            sizeClass: sizeClass,
            onLayoutInvalidation: { invalidateLayout() },
            onRequestExpand: { showExpandedSheet = true }
        )
    }

    @ViewBuilder
    private func partView(_ part: MessagePart) -> some View {
        switch part {
        case .text(let value):
            Text(value)
                .lineLimit(nil)
        case .markdown(let value):
            if let attributed = try? AttributedString(markdown: value) {
                Text(attributed)
                    .lineLimit(nil)
            } else {
                Text(value)
                    .lineLimit(nil)
            }
        case .inlineEmoji(let value):
            Text(value)
                .font(.system(size: metrics.shortFontSize + 8))
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .table(let model):
            MarkdownTableView(
                model: model,
                role: message.role,
                metrics: metrics,
                maxLineWidth: maxLineWidth,
                colorScheme: colorScheme,
                isExpanded: false,
                onExpand: { showExpandedSheet = true },
                onCollapse: { }
            )
        case .linkPreview(let url):
            LinkPreviewCard(url: url, onLayoutInvalidation: invalidateLayout)
        case .image(let attachment):
            AttachmentImageView(
                attachment: attachment,
                isMediaOnly: presentation.hasMediaOnly,
                onLayoutInvalidation: invalidateLayout
            )
        case .gallery(let attachments):
            MessageAttachmentView(
                attachments: attachments,
                isMediaOnly: presentation.hasMediaOnly,
                onLayoutInvalidation: invalidateLayout
            )
        }
    }

    private var truncationIndicator: some View {
        Button(action: { showExpandedSheet = true }) {
            VStack(spacing: 0) {
                // Top border separator
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(borderSubtleColor)

                // Indicator content with padding
                HStack(spacing: 6) {
                    Text("Show more")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(truncationIndicatorColor)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .contentShape(Rectangle())
        }
        .padding(.top, 8) // margin-top per design system
        .accessibilityLabel("Expand message")
        .accessibilityAddTraits(.isButton)
    }

    /// Mask that fades text to transparent at the bottom when truncated.
    /// White = visible, clear = invisible. The bubble background shows through.
    @ViewBuilder
    private var truncationFadeMask: some View {
        if shouldTruncate {
            // Single gradient covering the full height - only fades in bottom 20%
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.75),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.white
        }
    }

    private var bubbleBackground: some View {
        Group {
            if message.role == .user {
                ChatFlowTheme.bubbleSelfGradient(colorScheme)
            } else {
                ChatFlowTheme.bubbleOtherGradient(colorScheme)
            }
        }
    }

    private var innerHighlightOverlay: some View {
        // 3D border effect - bright stroke at top that fades down sides
        // Simulates CSS: inset 0 1px 1px rgba(255, 255, 255, 0.15)
        bubbleShape
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.35), location: 0),
                        .init(color: Color.white.opacity(0.15), location: 0.3),
                        .init(color: Color.clear, location: 0.6)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1.5
            )
    }

    @ViewBuilder
    private var adminOutline: some View {
        if message.channelType == .admin {
            bubbleShape
                .stroke(ChatFlowTheme.adminAccent(colorScheme).opacity(0.6), lineWidth: 1.5)
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let radii = bubbleCornerRadii()
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing
        )
    }

    private struct CornerRadii {
        let topLeading: CGFloat
        let topTrailing: CGFloat
        let bottomLeading: CGFloat
        let bottomTrailing: CGFloat
    }

    private func bubbleCornerRadii() -> CornerRadii {
        let base: CGFloat = 28
        let sharp: CGFloat = 4
        let variationsSelf: [CornerRadii] = [
            .init(topLeading: base, topTrailing: base, bottomLeading: base, bottomTrailing: sharp),
            .init(topLeading: 32, topTrailing: 24, bottomLeading: 26, bottomTrailing: sharp),
            .init(topLeading: 24, topTrailing: 32, bottomLeading: 28, bottomTrailing: sharp),
            .init(topLeading: 26, topTrailing: 30, bottomLeading: 28, bottomTrailing: sharp)
        ]
        let variationsOther: [CornerRadii] = [
            .init(topLeading: base, topTrailing: base, bottomLeading: sharp, bottomTrailing: base),
            .init(topLeading: 32, topTrailing: 24, bottomLeading: sharp, bottomTrailing: 26),
            .init(topLeading: 24, topTrailing: 32, bottomLeading: sharp, bottomTrailing: 28),
            .init(topLeading: 26, topTrailing: 30, bottomLeading: sharp, bottomTrailing: 28)
        ]
        let index = abs(message.id.hashValue) % variationsSelf.count
        return message.role == .user ? variationsSelf[index] : variationsOther[index]
    }

    private func fontForSizeClass() -> Font {
        switch sizeClass {
        case .short:
            return .system(size: metrics.shortFontSize, weight: .semibold)
        case .medium:
            return .system(size: metrics.mediumFontSize, weight: .medium)
        case .long:
            return .system(size: metrics.bodyFontSize, weight: .regular)
        }
    }

    private var shouldTruncate: Bool {
        truncationState.shouldTruncate
    }

    private var shouldShowTruncationControl: Bool {
        false
    }

    private var senderName: String {
        message.role == .user ? "You" : "Assistant"
    }

    private var bubbleShadowNear: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.15)
            : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.06)
    }

    private var bubbleShadowMid: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.25)
            : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.10)
    }

    private var bubbleShadowFar: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.20)
            : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.08)
    }

    private var borderSubtleColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.10)
    }

    private var truncationIndicatorColor: Color {
        message.role == .user ? ChatFlowTheme.terracotta(colorScheme) : ChatFlowTheme.warmBrown(colorScheme)
    }

    private var bubblePaddingVertical: CGFloat {
        presentation.hasMediaOnly ? 8 : metrics.bubblePaddingVertical
    }

    private var bubblePaddingHorizontal: CGFloat {
        presentation.hasMediaOnly ? 8 : metrics.bubblePaddingHorizontal
    }

    private func invalidateLayout() {
        onLayoutInvalidation?(message.id)
    }
}

struct TruncationState: Equatable {
    var contentHeight: CGFloat?
    var shouldTruncate: Bool
    var showsControl: Bool

    static let none = TruncationState(contentHeight: nil, shouldTruncate: false, showsControl: false)
}

struct MessageBubbleTextContentView: View {
    let message: Message
    let presentation: MessagePresentation
    let metrics: ChatFlowTheme.Metrics
    let colorScheme: ColorScheme
    let sizeClass: MessageSizeClass
    let onLayoutInvalidation: (() -> Void)?
    let onRequestExpand: () -> Void

    private var textualParts: [MessagePart] {
        presentation.parts.filter { $0.isTextual }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(textualParts.enumerated()), id: \.offset) { item in
                textPartView(item.element)
            }
        }
        .font(fontForSizeClass())
        .foregroundColor(ChatFlowTheme.ink(colorScheme))
        .lineSpacing(sizeClass == .short ? 0 : 4)
    }

    @ViewBuilder
    private func textPartView(_ part: MessagePart) -> some View {
        switch part {
        case .text(let value):
            Text(value)
                .lineLimit(nil)
        case .markdown(let value):
            if let attributed = try? AttributedString(markdown: value) {
                Text(attributed)
                    .lineLimit(nil)
            } else {
                Text(value)
                    .lineLimit(nil)
            }
        case .inlineEmoji(let value):
            Text(value)
                .font(.system(size: metrics.shortFontSize + 8))
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .table(let model):
            MarkdownTableView(
                model: model,
                role: message.role,
                metrics: metrics,
                maxLineWidth: ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize),
                colorScheme: colorScheme,
                isExpanded: false,
                onExpand: onRequestExpand,
                onCollapse: { }
            )
        case .linkPreview, .image, .gallery:
            EmptyView()
        }
    }

    private func fontForSizeClass() -> Font {
        switch sizeClass {
        case .short:
            return .system(size: metrics.shortFontSize, weight: .semibold)
        case .medium:
            return .system(size: metrics.mediumFontSize, weight: .medium)
        case .long:
            return .system(size: metrics.bodyFontSize, weight: .regular)
        }
    }
}

private struct AvatarView: View {
    let role: Message.Role

    var body: some View {
        // TEST: Bright pink to confirm this code is running
        Circle()
            .fill(Color.pink)
            .overlay {
                Circle()
                    .strokeBorder(Color.yellow, lineWidth: 4)
            }
            .overlay {
                Text(initial)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
    }

    private var initial: String {
        role == .user ? "Y" : "A"
    }

    private var avatarGradient: RadialGradient {
        if role == .user {
            // RIDICULOUS gradient - bright green center, very dark edges
            return RadialGradient(
                stops: [
                    .init(color: Color(red: 0.6, green: 0.9, blue: 0.6), location: 0),     // Very bright green
                    .init(color: Color(red: 0.42, green: 0.61, blue: 0.42), location: 0.3), // #6B9B6A
                    .init(color: Color(red: 0.18, green: 0.35, blue: 0.20), location: 0.7), // #2D5A32
                    .init(color: Color(red: 0.1, green: 0.2, blue: 0.1), location: 1.0)    // Very dark green
                ],
                center: UnitPoint(x: 0.4, y: 0.3),
                startRadius: 0,
                endRadius: 20
            )
        }
        // RIDICULOUS terracotta gradient
        return RadialGradient(
            stops: [
                .init(color: Color(red: 1.0, green: 0.8, blue: 0.7), location: 0),     // Very bright coral
                .init(color: Color(red: 0.91, green: 0.66, blue: 0.61), location: 0.3), // soft-coral
                .init(color: Color(red: 0.66, green: 0.35, blue: 0.26), location: 0.7), // #A85A42
                .init(color: Color(red: 0.4, green: 0.2, blue: 0.15), location: 1.0)   // Very dark
            ],
            center: UnitPoint(x: 0.4, y: 0.3),
            startRadius: 0,
            endRadius: 20
        )
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightedCode: AttributedString?

    private var isDark: Bool { colorScheme == .dark }

    private var backgroundColor: Color {
        isDark
            ? Color(red: 0.118, green: 0.118, blue: 0.118)
            : Color(red: 0.945, green: 0.933, blue: 0.910)
    }

    private var labelColor: Color {
        isDark
            ? Color.white.opacity(0.6)
            : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.6)
    }

    private var plainTextColor: Color {
        isDark
            ? Color.white.opacity(0.9)
            : Color(red: 0.2, green: 0.2, blue: 0.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(labelColor)
                    .tracking(0.5)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                if let highlighted = highlightedCode {
                    Text(highlighted)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .lineSpacing(4)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(code)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(plainTextColor)
                        .lineSpacing(4)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: "\(code)\(colorScheme)") {
            await highlightCode()
        }
    }

    private func highlightCode() async {
        let colors: HighlightColors = isDark ? .dark(.atomOne) : .light(.atomOne)
        let highlight = Highlight()

        do {
            let langString = mapLanguageString(language)
            let attributed: AttributedString
            if let lang = langString {
                attributed = try await highlight.attributedText(code, language: lang, colors: colors)
            } else {
                attributed = try await highlight.attributedText(code, colors: colors)
            }
            highlightedCode = attributed
        } catch {
            highlightedCode = nil
        }
    }

    private func mapLanguageString(_ lang: String?) -> String? {
        guard let lang = lang?.lowercased() else { return nil }
        let mapping: [String: String] = [
            "swift": "swift", "python": "python", "py": "python",
            "javascript": "javascript", "js": "javascript",
            "typescript": "typescript", "ts": "typescript",
            "java": "java", "kotlin": "kotlin", "kt": "kotlin",
            "c": "c", "cpp": "cpp", "c++": "cpp",
            "csharp": "csharp", "c#": "csharp", "cs": "csharp",
            "go": "go", "golang": "go",
            "rust": "rust", "rs": "rust",
            "ruby": "ruby", "rb": "ruby",
            "php": "php", "html": "xml", "xml": "xml",
            "css": "css", "scss": "scss", "sass": "scss",
            "json": "json", "yaml": "yaml", "yml": "yaml",
            "sql": "sql", "bash": "bash", "sh": "bash", "shell": "bash", "zsh": "bash",
            "markdown": "markdown", "md": "markdown",
            "objective-c": "objectivec", "objc": "objectivec",
            "r": "r", "perl": "perl", "lua": "lua",
            "scala": "scala", "haskell": "haskell", "elixir": "elixir",
            "clojure": "clojure", "erlang": "erlang",
            "dockerfile": "dockerfile", "docker": "dockerfile",
            "makefile": "makefile", "make": "makefile",
            "graphql": "graphql", "gql": "graphql",
            "dart": "dart", "vue": "xml", "jsx": "javascript", "tsx": "typescript"
        ]
        return mapping[lang] ?? lang
    }
}

private struct MessageAttachmentView: View {
    let attachments: [Attachment]
    let isMediaOnly: Bool
    let onLayoutInvalidation: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentImageView(
                    attachment: attachment,
                    isMediaOnly: isMediaOnly,
                    onLayoutInvalidation: onLayoutInvalidation
                )
            }
        }
    }
}

private struct AttachmentImageView: View {
    let attachment: Attachment
    let isMediaOnly: Bool
    let onLayoutInvalidation: (() -> Void)?

    var body: some View {
        Group {
            if let data = attachment.data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if let remoteURL = remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .onAppear(perform: onLayoutInvalidation)
                    case .failure:
                        placeholder
                            .onAppear(perform: onLayoutInvalidation)
                    case .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: isMediaOnly ? 280 : 360)
        .frame(height: isMediaOnly ? 200 : 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var remoteURL: URL? {
        guard let assetId = attachment.assetId else { return nil }
        guard let baseURL = ProviderBaseURLStore.baseURL else { return nil }
        return baseURL
            .appendingPathComponent("download")
            .appendingPathComponent(assetId)
    }

    private var placeholder: some View {
        ZStack {
            Color.black.opacity(0.05)
            Image(systemName: "photo")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.gray)
        }
    }
}

private struct LinkPreviewCard: View {
    let url: URL
    let onLayoutInvalidation: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var metadata: LPLinkMetadata? = nil
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ChatFlowTheme.terracotta(colorScheme))
                    .frame(width: 6, height: 6)
                Text(domain.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ChatFlowTheme.warmBrown(colorScheme))
                    .tracking(0.5)
            }
            Text(primaryText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ChatFlowTheme.ink(colorScheme))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(linkBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: shadowColor, radius: 6, x: 0, y: 2)
        .onAppear(perform: fetchMetadataIfNeeded)
    }

    private var domain: String {
        url.host ?? url.absoluteString
    }

    private var primaryText: String {
        if let title = metadata?.title, !title.isEmpty {
            return title
        }
        return url.absoluteString
    }

    private func fetchMetadataIfNeeded() {
        guard metadata == nil, !isLoading else { return }
        isLoading = true
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { fetched, _ in
            DispatchQueue.main.async {
                self.metadata = fetched
                self.isLoading = false
                self.onLayoutInvalidation?()
            }
        }
    }

    private var linkBackground: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.25)
            : Color.white.opacity(0.7)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.15) : Color(red: 0.235, green: 0.176, blue: 0.118).opacity(0.06)
    }
}

struct ExpandedMessageSheet: View {
    let message: Message
    let presentation: MessagePresentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var dragOffset: CGFloat = 0
    private let dismissThreshold: CGFloat = 100

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var metrics: ChatFlowTheme.Metrics { ChatFlowTheme.Metrics(isCompact: isCompact) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    content
                }
                .padding()
            }
            .background(sheetBackground)
            .navigationTitle(message.role == .user ? "Your Message" : "Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .offset(x: dragOffset)
        .opacity(1.0 - Double(abs(dragOffset)) / 300.0)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    if abs(value.translation.width) > dismissThreshold {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(message.role == .user ? ChatFlowTheme.sage(colorScheme) : ChatFlowTheme.softCoral(colorScheme))
                .frame(width: 8, height: 8)
            Text(message.role == .user ? "You" : "Assistant")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ChatFlowTheme.warmBrown(colorScheme))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(presentation.parts.enumerated()), id: \.offset) { item in
                partView(item.element)
            }
        }
        .font(.system(size: metrics.bodyFontSize, weight: .regular))
        .foregroundColor(ChatFlowTheme.ink(colorScheme))
        .lineSpacing(4)
    }

    @ViewBuilder
    private func partView(_ part: MessagePart) -> some View {
        switch part {
        case .text(let value):
            Text(value)
        case .markdown(let value):
            if let attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(value)
            }
        case .inlineEmoji(let value):
            Text(value)
                .font(.system(size: 32))
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .linkPreview(let url):
            Link(destination: url) {
                Text(url.absoluteString)
                    .foregroundColor(.blue)
                    .underline()
            }
        case .table(let model):
            MarkdownTableView(
                model: model,
                role: message.role,
                metrics: metrics,
                maxLineWidth: ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize),
                colorScheme: colorScheme,
                isExpanded: true,
                onExpand: {},
                onCollapse: { dismiss() }
            )
        case .image(let attachment):
            if let data = attachment.data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .gallery(let attachments):
            ForEach(attachments) { attachment in
                if let data = attachment.data, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var sheetBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.1, green: 0.1, blue: 0.1)
            : ChatFlowTheme.cream(colorScheme)
    }
}
