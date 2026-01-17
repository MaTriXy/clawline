import SwiftUI
import UIKit

struct TableKeyCommandBridge: UIViewRepresentable {
    enum Direction {
        case up
        case down
        case left
        case right
    }

    @Binding var isFirstResponder: Bool
    var onDirection: (Direction) -> Void
    var onTab: (Bool) -> Void
    var onEscape: () -> Void
    var onCopy: () -> Void

    func makeUIView(context: Context) -> KeyCommandView {
        let view = KeyCommandView()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: KeyCommandView, context: Context) {
        uiView.delegate = context.coordinator
        if isFirstResponder && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isFirstResponder: $isFirstResponder, onDirection: onDirection, onTab: onTab, onEscape: onEscape, onCopy: onCopy)
    }

    final class Coordinator {
        @Binding var isFirstResponder: Bool
        let onDirection: (Direction) -> Void
        let onTab: (Bool) -> Void
        let onEscape: () -> Void
        let onCopy: () -> Void

        init(isFirstResponder: Binding<Bool>, onDirection: @escaping (Direction) -> Void, onTab: @escaping (Bool) -> Void, onEscape: @escaping () -> Void, onCopy: @escaping () -> Void) {
            _isFirstResponder = isFirstResponder
            self.onDirection = onDirection
            self.onTab = onTab
            self.onEscape = onEscape
            self.onCopy = onCopy
        }
        func resignFocus() {
            isFirstResponder = false
        }
    }

    final class KeyCommandView: UIView {
        weak var delegate: Coordinator?

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUp)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDown)),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)),
                UIKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(handleShiftTab)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)),
                UIKeyCommand(input: "c", modifierFlags: [.command], action: #selector(handleCopy))
            ]
        }

        @objc private func handleUp() { delegate?.onDirection(.up) }
        @objc private func handleDown() { delegate?.onDirection(.down) }
        @objc private func handleLeft() { delegate?.onDirection(.left) }
        @objc private func handleRight() { delegate?.onDirection(.right) }
        @objc private func handleTab() { delegate?.onTab(false) }
        @objc private func handleShiftTab() { delegate?.onTab(true) }
        @objc private func handleEscape() {
            delegate?.onEscape()
            delegate?.resignFocus()
            resignFirstResponder()
        }

        @objc private func handleCopy() {
            delegate?.onCopy()
        }
    }
}
