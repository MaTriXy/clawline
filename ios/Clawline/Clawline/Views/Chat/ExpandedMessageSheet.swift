//
//  ExpandedMessageSheet.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit

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
