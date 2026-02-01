//
//  MessageInputBar.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit
import OSLog

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessageInputBar")

// MARK: - ⚠️⚠️⚠️ CRITICAL: READ ChatView.swift HEADER BEFORE MODIFYING ⚠️⚠️⚠️
//
// This view is used inside .safeAreaInset in ChatView. That context has special behavior:
//
// 1. THIS VIEW GETS RECREATED when geometry changes (e.g., keyboard appears)
// 2. Any @State defined HERE will be RESET when that happens
// 3. onChange handlers HERE may NEVER FIRE because the view recreates before they trigger
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// WHAT THIS MEANS FOR YOU
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// ❌ DO NOT add @State here for keyboard/focus tracking - it will reset
// ❌ DO NOT expect onChange to fire reliably - view may recreate first
// ❌ DO NOT apply positioning offsets here - they won't update on parent state change
//
// ✅ DO use callbacks (like onFocusChange) to report state to parent
// ✅ DO let parent (ChatView) own state that needs to survive geometry changes
// ✅ DO let parent apply offset/positioning modifiers
//
// The @FocusState here was replaced by RichTextEditor focus callbacks that update parent state.
// The parent's @State survives; ours does not.
//
// See ChatView.swift header comment for the full explanation and rescue tag: `working-keyboard-behaviors`.
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct MessageInputBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings
    @Binding var content: NSAttributedString
    @Binding var selectionRange: NSRange
    @Binding var pendingInsertions: [PendingAttachment]
    var resetToken: Int
    let canSend: Bool
    let isSending: Bool
    let connectionAlert: ConnectionAlertSeverity?
    let focusTrigger: Int
    /// Pass geometry.safeAreaInsets.bottom directly - DO NOT pass a computed Bool.
    let bottomSafeAreaInset: CGFloat
    /// Keyboard visibility state owned by parent view to survive geometry changes.
    let isKeyboardVisible: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onAdd: () -> Void
    let onFocusChange: (Bool) -> Void
    var onPasteImages: (([UIImage]) -> Void)?

    @State private var editorHeight: CGFloat = 44
    let isCompact: Bool

    private var metrics: MessageInputBarMetrics {
        MessageInputBarMetrics(
            horizontalSizeClass: isCompact ? .compact : .regular,
            bottomSafeAreaInset: bottomSafeAreaInset,
            deviceCornerRadius: deviceCornerRadius,
            isFieldFocused: isKeyboardVisible
        )
    }

    private var deviceCornerRadius: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        return hasRoundedCorners ? 50 : 0
    }

    private var inputHeight: CGFloat {
        if content.length == 0 {
            return metrics.inputBarHeight
        }
        return max(editorHeight, metrics.inputBarHeight)
    }

    private var connectionAlertColor: Color? {
        switch connectionAlert {
        case .caution:
            return Color.yellow
        case .critical:
            return Color.red
        case nil:
            return nil
        }
    }

    private var connectionAlertMessage: String? {
        switch connectionAlert {
        case .caution:
            return "Reconnecting…"
        case .critical:
            return "Disconnected"
        case nil:
            return nil
        }
    }

    private var isSingleLine: Bool {
        editorHeight <= metrics.inputBarHeight + 0.5
    }

    private var inputShape: AnyShape {
        if isSingleLine {
            return AnyShape(Capsule())
        } else {
            return AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var connectionAlertHint: String? {
        switch connectionAlert {
        case .caution:
            return "Waiting for connection to return."
        case .critical:
            return "Connection lost. Try again soon."
        case nil:
            return nil
        }
    }

    private var sendButtonWidth: CGFloat {
        metrics.inputBarHeight
    }

    private var containerPadding: CGFloat {
        ChatFlowTheme.Metrics(isCompact: isCompact).inputBarPaddingHorizontal
    }

    private var maxBarWidth: CGFloat? {
        guard !isCompact else { return nil }
        let themeMetrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let textWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: themeMetrics.bodyFontSize)
        let chromeWidth = (themeMetrics.inputBarPaddingHorizontal * 2)
            + sendButtonWidth
            + metrics.inputBarHeight
            + (MessageInputBarMetrics.elementSpacing * 2)
        return textWidth + chromeWidth
    }

    private var addButtonForeground: Color {
#if os(visionOS)
        return settings.appearanceMode == .dark ? .white : .black
#else
        return .primary
#endif
    }

    private var appearanceIconColor: Color { addButtonForeground }

    private var appearanceIconName: String {
        settings.appearanceMode == .dark ? "moon.stars" : "sun.max"
    }

    private var isLightMode: Bool {
        settings.appearanceMode == .light
    }

    private var visionOSBorderColor: Color {
        isLightMode
            ? ChatFlowTheme.ink(.light).opacity(0.80)
            : Color.white.opacity(0.5)
    }

    private var sendIconColor: Color { .white }

    private var sendBackgroundColor: Color { ChatFlowTheme.sageAdaptive }

    private var placeholderColor: Color {
#if os(visionOS)
        return isLightMode
            ? ChatFlowTheme.ink(.light).opacity(0.6)
            : ChatFlowTheme.ink(.dark).opacity(0.6)
#else
        return .secondary
#endif
    }

    private var inputTintColor: Color {
#if os(visionOS)
        return isLightMode ? ChatFlowTheme.ink(.light) : ChatFlowTheme.ink(.dark)
#else
        return .primary
#endif
    }

    private var inputTintUIColor: UIColor {
        UIColor(inputTintColor)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: MessageInputBarMetrics.elementSpacing) {
#if os(visionOS)
            // Appearance toggle button
            Button(action: {
                settings.toggleAppearanceMode()
            }) {
                Image(systemName: appearanceIconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(appearanceIconColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: metrics.inputBarHeight, height: metrics.inputBarHeight)
#if os(visionOS)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(visionOSBorderColor, lineWidth: 1)
            }
#else
            .glassEffect(.regular.interactive(), in: Circle())
            .background {
                if isLightMode {
                    Circle()
                        .fill(Color.primary.opacity(0.15))
                }
            }
#endif
            .accessibilityLabel("Toggle appearance")
#endif

            // Add button - send-style for reliable hit testing (left side)
            Button(action: {
                onAdd()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(addButtonForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: metrics.inputBarHeight, height: metrics.inputBarHeight)
#if os(visionOS)
            .background(.regularMaterial, in: Circle())
            .overlay(
                Circle()
                    .stroke(visionOSBorderColor, lineWidth: 1)
            )
#else
            .glassEffect(.regular.interactive(), in: Circle())
#endif
            .accessibilityLabel("Add attachment")
            .disabled(isSending)

            // Text field - glass capsule/rounded rect
            ZStack(alignment: .leading) {
                RichTextEditor(
                    attributedText: $content,
                    calculatedHeight: $editorHeight,
                    selectionRange: $selectionRange,
                    pendingInsertions: $pendingInsertions,
                    resetToken: resetToken,
                    focusTrigger: focusTrigger,
                    isEditable: true,
                    tintColor: inputTintUIColor,
                    onFocusChange: onFocusChange,
                    onSubmit: {
                        guard !isSending, canSend else { return }
                        onSend()
                    },
                    onPasteImages: onPasteImages,
                    trailingPadding: 20
                )
                .opacity(isSending ? 0.5 : 1)

                if content.length == 0 {
                    Text("Message")
                        .foregroundColor(placeholderColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, 20)
                        .padding(.trailing, 20)
                }

                if let alertMessage = connectionAlertMessage,
                   let alertColor = connectionAlertColor {
                    RoundedRectangle(cornerRadius: isSingleLine ? inputHeight / 2 : 22, style: .continuous)
                        .fill(alertColor.opacity(0.08))
                        .allowsHitTesting(false)

                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 14, weight: .semibold))
                        Text(alertMessage)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .foregroundColor(alertColor)
                    .allowsHitTesting(false)
                }
            }
            .tint(inputTintColor)
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity, alignment: .bottom)
#if os(visionOS)
            .background(.regularMaterial, in: inputShape)
#else
            .glassEffect(.regular, in: inputShape)
#endif
            .overlay {
                ZStack {
#if os(visionOS)
                    inputShape
                        .stroke(visionOSBorderColor, lineWidth: 1)
#endif
                    if let alertColor = connectionAlertColor {
                        inputShape
                            .stroke(alertColor.opacity(0.4), lineWidth: 1)
                    }
                }
            }

            // Send button - stable container + stable glass background
            let isSendEnabled = isSending || canSend
            let sendIconOpacity = (connectionAlertColor == nil ? 1 : 0.65) * (isSendEnabled ? 1 : 0.4)
            Button(action: isSending ? onCancel : onSend) {
                ZStack {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(sendIconColor)
                        .opacity(isSending ? 1 : 0)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(sendIconColor)
                        .opacity(isSending ? 0 : 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .frame(width: sendButtonWidth, height: metrics.inputBarHeight)
#if os(visionOS)
            .background(Circle().fill(sendBackgroundColor.opacity(isSendEnabled ? 1 : 0.35)))
            .overlay(Circle().stroke(visionOSBorderColor, lineWidth: 1))
#else
            .background(Capsule().fill(sendBackgroundColor.opacity(isSendEnabled ? 1 : 0.35)))
#endif
            .buttonStyle(.plain)
            .allowsHitTesting(isSendEnabled)
            .opacity(sendIconOpacity)
            .accessibilityHint(connectionAlertHint ?? "")
            .id("send-button")
            .transaction { $0.animation = nil }
            .animation(nil, value: isSending)
            .animation(nil, value: canSend)
        }
        .padding(.horizontal, containerPadding)
        .padding(.bottom, metrics.bottomPadding)
        .frame(maxWidth: maxBarWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .simultaneousGesture(TapGesture().onEnded {
            logger.info("Input bar tap gesture")
            NSLog("DIAG: Input bar tap gesture")
        })
        .onChange(of: content.length) { _, newValue in
            guard newValue == 0 else { return }
            editorHeight = metrics.inputBarHeight
        }
    }
}

#Preview("Message Input") {
    @Previewable @State var content = NSAttributedString(string: "Hello")
    @Previewable @State var selection = NSRange(location: 5, length: 0)
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                content: $content,
                selectionRange: $selection,
                pendingInsertions: .constant([]),
                resetToken: 0,
                canSend: true,
                isSending: false,
                connectionAlert: nil,
                focusTrigger: 0,
                bottomSafeAreaInset: 34,
                isKeyboardVisible: false,
                onSend: {},
                onCancel: {},
                onAdd: {},
                onFocusChange: { _ in },
                isCompact: true
            )
        }
}
