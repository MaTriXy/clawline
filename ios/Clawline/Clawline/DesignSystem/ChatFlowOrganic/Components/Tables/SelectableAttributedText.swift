import SwiftUI
import UIKit

struct SelectableAttributedText: UIViewRepresentable {
    var attributedString: NSAttributedString
    var alignment: NSTextAlignment
    var onSelectionChange: (Bool) -> Void
    var onLinkTap: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange, onLinkTap: onLinkTap)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.linkTextAttributes = [:]
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = attributedString
        uiView.textAlignment = alignment
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let onSelectionChange: (Bool) -> Void
        private let onLinkTap: (URL) -> Void

        init(onSelectionChange: @escaping (Bool) -> Void, onLinkTap: @escaping (URL) -> Void) {
            self.onSelectionChange = onSelectionChange
            self.onLinkTap = onLinkTap
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let hasSelection = textView.selectedRange.length > 0
            onSelectionChange(hasSelection)
        }

        @available(iOS 17.0, *)
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                onLinkTap(url)
                return nil
            }
            return defaultAction
        }
    }
}
