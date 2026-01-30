//
//  RichTextEditor.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import OSLog
import SwiftUI
import UIKit

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "RichTextEditor")

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var calculatedHeight: CGFloat
    @Binding var selectionRange: NSRange
    @Binding var pendingInsertions: [PendingAttachment]
    var resetToken: Int
    var focusTrigger: Int
    var isEditable: Bool
    var onFocusChange: (Bool) -> Void
    var onSubmit: (() -> Void)?
    var onPasteImages: (([UIImage]) -> Void)?
    var trailingPadding: CGFloat = 20

    func makeUIView(context: Context) -> PastableTextView {
        let textView = PastableTextView()
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onPasteImages = { images in
            coordinator.parent.onPasteImages?(images)
        }
        textView.onLayout = { _ in
            coordinator.updateHeight(for: textView)
        }
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: trailingPadding)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.allowsEditingTextAttributes = true
#if !os(visionOS)
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []
        textView.keyboardDismissMode = .interactive
#endif
        textView.returnKeyType = .send
        textView.tintColor = UIColor.label
        textView.autocorrectionType = .yes
        textView.smartQuotesType = .yes
        textView.smartDashesType = .yes
        textView.smartInsertDeleteType = .yes
        textView.attributedText = attributedText
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: PastableTextView, context: Context) {
        context.coordinator.parent = self

        // Update paste callback
        let coordinator = context.coordinator
        textView.onPasteImages = { images in
            coordinator.parent.onPasteImages?(images)
        }
        textView.onLayout = { _ in
            coordinator.updateHeight(for: textView)
        }

        let isComposing = textView.markedTextRange != nil
        if resetToken != context.coordinator.lastResetToken, !isComposing {
            context.coordinator.lastResetToken = resetToken
            textView.attributedText = attributedText
            context.coordinator.enforceBaseAttributes(on: textView)
            if selectionRange.location != NSNotFound {
                textView.selectedRange = selectionRange
            }
            logger.info("[trace] updateUIView applied reset len=\(attributedText.length)")
        }
        context.coordinator.isApplyingLocalEdit = false

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

#if !os(visionOS)
        if !textView.inputAssistantItem.leadingBarButtonGroups.isEmpty {
            textView.inputAssistantItem.leadingBarButtonGroups = []
        }
        if !textView.inputAssistantItem.trailingBarButtonGroups.isEmpty {
            textView.inputAssistantItem.trailingBarButtonGroups = []
        }
#endif

        let currentInset = textView.textContainerInset
        if abs(currentInset.right - trailingPadding) > 0.5 {
            textView.textContainerInset = UIEdgeInsets(top: currentInset.top,
                                                       left: currentInset.left,
                                                       bottom: currentInset.bottom,
                                                       right: trailingPadding)
        }

        context.coordinator.applyFocusIfNeeded(on: textView, trigger: focusTrigger)
        context.coordinator.updateHeight(for: textView)
        context.coordinator.ensureTypingAttributes(on: textView)

        if !pendingInsertions.isEmpty, !isComposing {
            let attachments = pendingInsertions
            context.coordinator.insertAttachments(attachments, into: textView)
            DispatchQueue.main.async {
                self.pendingInsertions = []
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        private var lastFocusTrigger: Int = 0
        var isApplyingLocalEdit = false
        var lastResetToken: Int = 0

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            isApplyingLocalEdit = true
            parent.attributedText = textView.attributedText
            parent.selectionRange = textView.selectedRange
            updateHeight(for: textView)
            ensureCaretVisible(in: textView)
            ensureTypingAttributes(on: textView)
            let length = textView.attributedText?.length ?? 0
            logger.info("[trace] textViewDidChange len=\(length) sel=\(textView.selectedRange.location),\(textView.selectedRange.length)")
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.selectedRange.location != NSNotFound else { return }
            parent.selectionRange = textView.selectedRange
            ensureCaretVisible(in: textView)
            ensureTypingAttributes(on: textView)
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onSubmit?()
                return false
            }
            return true
        }

        func updateHeight(for textView: UITextView) {
            let targetWidth = textView.bounds.width
            guard targetWidth > 1 else {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.updateHeight(for: textView)
                }
                return
            }
            let referenceWidth = targetWidth
            let fittingSize = CGSize(width: referenceWidth,
                                     height: .greatestFiniteMagnitude)
            let size = textView.sizeThatFits(fittingSize)
            let minHeight: CGFloat = 48
            let maxHeight: CGFloat = 120
            let clamped = min(max(size.height, minHeight), maxHeight)
            if abs(parent.calculatedHeight - clamped) > 0.5 {
                parent.calculatedHeight = clamped
            }
            textView.isScrollEnabled = size.height > maxHeight
            if textView.isScrollEnabled {
                ensureCaretVisible(in: textView)
            }
        }

        func applyFocusIfNeeded(on textView: UITextView, trigger: Int) {
            guard trigger != lastFocusTrigger else { return }
            lastFocusTrigger = trigger
            guard trigger > 0 else { return }
            guard parent.isEditable else { return }
            textView.becomeFirstResponder()
        }

        private func ensureCaretVisible(in textView: UITextView) {
            guard textView.isScrollEnabled else { return }
            let range = textView.selectedRange
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(range)
            }
        }

        func ensureTypingAttributes(on textView: UITextView) {
            var attributes = textView.typingAttributes
            attributes[.font] = UIFont.preferredFont(forTextStyle: .body)
            attributes[.foregroundColor] = UIColor.label
            textView.typingAttributes = attributes
        }

        func enforceBaseAttributes(on textView: UITextView) {
            let baseFont = UIFont.preferredFont(forTextStyle: .body)
            let baseColor = UIColor.label
            let fullRange = NSRange(location: 0, length: textView.textStorage.length)
            guard fullRange.length > 0 else { return }

            textView.textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
                guard value == nil else { return }
                textView.textStorage.addAttributes([.font: baseFont, .foregroundColor: baseColor], range: range)
            }
        }

        func insertAttachments(_ attachments: [PendingAttachment], into textView: UITextView) {
            guard !attachments.isEmpty else { return }
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
            let safeRange = clamp(textView.selectedRange, length: mutable.length)
            mutable.replaceCharacters(in: safeRange, with: NSAttributedString(string: ""))
            var insertionLocation = safeRange.location
            for attachment in attachments {
                let textAttachment = PendingTextAttachment(
                    id: attachment.id,
                    thumbnail: attachment.thumbnail,
                    accessibilityLabel: attachment.accessibilityLabel
                )
                let attachmentString = NSAttributedString(attachment: textAttachment)
                mutable.insert(attachmentString, at: insertionLocation)
                insertionLocation += attachmentString.length
            }
            textView.attributedText = mutable
            let newRange = NSRange(location: insertionLocation, length: 0)
            textView.selectedRange = newRange
            parent.attributedText = mutable
            parent.selectionRange = newRange
            updateHeight(for: textView)
        }

        private func clamp(_ range: NSRange, length: Int) -> NSRange {
            guard range.location != NSNotFound else {
                return NSRange(location: length, length: 0)
            }
            let safeLocation = min(max(range.location, 0), length)
            let maxLength = max(0, min(range.length, length - safeLocation))
            return NSRange(location: safeLocation, length: maxLength)
        }
    }
}

// MARK: - Custom UITextView with image paste support

/// A UITextView subclass that supports pasting images from the clipboard.
final class PastableTextView: UITextView {
    var onPasteImages: (([UIImage]) -> Void)?
    var onLayout: ((CGFloat) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.width)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            // Allow paste if there's text or images in pasteboard
            let pasteboard = UIPasteboard.general
            if pasteboard.hasImages || pasteboard.hasStrings {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general

        // Check for images first
        if pasteboard.hasImages, let images = pasteboard.images, !images.isEmpty {
            onPasteImages?(images)
            return
        }

        // Fall back to default paste for text
        super.paste(sender)
    }
}
