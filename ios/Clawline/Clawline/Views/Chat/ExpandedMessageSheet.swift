//
//  ExpandedMessageSheet.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import SwiftUI
import UIKit

struct ExpandedMessageSheet: View {
    let message: Message
    let presentation: MessagePresentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var dragOffset: CGFloat = 0
    private let dismissThreshold: CGFloat = 100

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var metrics: ChatFlowTheme.Metrics { ChatFlowTheme.Metrics(isCompact: isCompact) }
    private var effectiveColorScheme: ColorScheme {
#if os(visionOS)
        return settings.appearanceMode == .dark ? .dark : .light
#else
        return colorScheme
#endif
    }

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
            .navigationTitle(message.role == .user ? "Your Message" : message.displayName)
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
                .fill(message.role == .user ? ChatFlowTheme.sage(effectiveColorScheme) : ChatFlowTheme.softCoral(effectiveColorScheme))
                .frame(width: 8, height: 8)
            Text(message.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ChatFlowTheme.warmBrown(effectiveColorScheme))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(presentation.parts.enumerated()), id: \.offset) { item in
                partView(item.element)
            }
        }
        .font(.system(size: metrics.bodyFontSize, weight: .regular))
        .foregroundColor(ChatFlowTheme.ink(effectiveColorScheme))
        .lineSpacing(4)
    }

    @ViewBuilder
    private func partView(_ part: MessagePart) -> some View {
        switch part {
        case .text(let value):
            Text(value)
        case .markdown(let value):
            let baseFont = UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular)
            let ink = UIColor(ChatFlowTheme.ink(effectiveColorScheme))
            if let attributed = ChatMarkdownRenderer.renderAttributedString(
                markdown: value,
                baseFont: baseFont,
                inkColor: ink,
                lineSpacing: 4
            ) {
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
            LinkPreviewRepresentable(url: url)
                .frame(maxWidth: .infinity)
        case .table(let model):
            MarkdownTableView(
                model: model,
                role: message.role,
                metrics: metrics,
                maxLineWidth: ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize),
                colorScheme: effectiveColorScheme,
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
        case .file(let attachment):
            FileAttachmentRow(
                filename: attachment.filename ?? attachment.assetId ?? attachment.mimeType ?? "Attachment",
                sizeText: attachment.size.map(Self.formatFileSize),
                colorScheme: effectiveColorScheme
            )
        }
    }

    private static func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var sheetBackground: Color {
        effectiveColorScheme == .dark
            ? Color(red: 0.1, green: 0.1, blue: 0.1)
            : ChatFlowTheme.cream(effectiveColorScheme)
    }
}

private struct FileAttachmentRow: View {
    let filename: String
    let sizeText: String?
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(ChatFlowTheme.ink(colorScheme).opacity(0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ChatFlowTheme.ink(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sizeText {
                    Text(sizeText)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(ChatFlowTheme.ink(colorScheme).opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(ChatFlowTheme.ink(colorScheme).opacity(colorScheme == .dark ? 0.08 : 0.06))
        )
    }
}
