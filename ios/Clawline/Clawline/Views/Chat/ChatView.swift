//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ChatView")

// MARK: - ⚠️⚠️⚠️ CRITICAL: DO NOT MODIFY WITHOUT READING ⚠️⚠️⚠️
//
// This file contains a non-obvious keyboard positioning fix that took 7+ iterations to solve.
// If you are an AI agent or developer planning to modify keyboard/focus/state handling here,
// STOP and read this entire comment block first.
//
// CURRENT STRATEGY (2026-01)
// - Ignore SwiftUI keyboard safe area (.ignoresSafeArea(.keyboard)).
// - Place MessageInputBar in an overlay, not a .safeAreaInset.
// - Drive bar position + list bottom inset directly from keyboard height.
// - Keep input focus state in ChatView (stable parent).
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// THE PROBLEM
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// MessageInputBar needs to reposition when keyboard appears:
// - Keyboard HIDDEN: Concentric alignment with device corners (~26pt from edges)
// - Keyboard VISIBLE: Positioned above keyboard with smaller gap
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// WHY "OBVIOUS" SOLUTIONS FAIL
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// SwiftUI ties @State, @FocusState, and onChange to a view's IDENTITY. When identity changes,
// ALL state resets silently. Views inside .safeAreaInset get RECREATED when geometry changes
// (like keyboard appearing), which resets their state.
//
// THESE APPROACHES WERE TRIED AND FAILED:
//
// 1. @FocusState in MessageInputBar
//    → View recreated on keyboard appear → @FocusState resets → onChange never fires
//
// 2. @State in MessageInputBar for keyboard tracking
//    → Same problem: view recreation resets state
//
// 3. UIKit keyboard notifications in MessageInputBar
//    → onReceive fires, but @State mutation is lost when view recreates
//
// 4. Passing computed Bool from parent
//    → .safeAreaInset content doesn't re-render on parent state change
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// THE SOLUTION (DO NOT CHANGE WITHOUT UNDERSTANDING)
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// 1. @State isInputFocused lives HERE in ChatView (stable parent, survives geometry changes)
// 2. MessageInputBar reports focus via callback: onFocusChange: { isInputFocused = $0 }
// 3. Offset modifier applied HERE in ChatView (modifiers on .safeAreaInset content DO update)
//
// KEY INSIGHT: .safeAreaInset content body doesn't re-render on parent state change,
// BUT modifiers applied TO that content from the parent DO update.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// IF YOU MUST MODIFY THIS CODE
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// 1. Understand SwiftUI view identity and state lifetime
// 2. Understand why .safeAreaInset causes view recreation
// 3. Test on device with keyboard show/hide cycling
// 4. Verify concentric alignment visually (equal padding on all sides when keyboard hidden)
// 5. The working solution is tagged: `working-keyboard-behaviors`
//
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    let toastManager: ToastManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthManager.self) private var authManager

    // ⚠️ CRITICAL: This state MUST live here in ChatView, NOT in MessageInputBar.
    // MessageInputBar is inside .safeAreaInset and gets recreated on geometry changes.
    // State in recreated views resets silently. See header comment for full explanation.
    @State private var isInputFocused = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var lastNonZeroKeyboardHeight: CGFloat = 0
    @State private var keyboardAnimationDuration: TimeInterval = 0.3
    @State private var keyboardAnimationCurve: UIView.AnimationCurve = .easeInOut
    @State private var keyboardRefreshToken: Int = 0
    @State private var layoutCoordinator = ChatLayoutCoordinator()
    @State private var layoutRevision: Int = 0
    @State private var selectionRange = NSRange(location: 0, length: 0)
    @State private var pendingInputInsertions: [PendingAttachment] = []
    @State private var activeSheet: ChatSheet?
    @State private var isPhotosPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var focusRequestID = 0
    @State private var shouldRestoreFocusAfterPicker = false

    init(viewModel: ChatViewModel, toastManager: ToastManager) {
        self._viewModel = Bindable(wrappedValue: viewModel)
        self.toastManager = toastManager
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.settingsManager) private var settings

    @State private var inputBarHeight: CGFloat = 0
    @State private var streamToastManager = StreamToastManager()

    private var isKeyboardVisible: Bool {
        keyboardHeight > 0.5
    }

    private enum ChatSheet: Identifiable {
        case attachmentMenu
        case expandedMessage(Message)
        case camera

        var id: String {
            switch self {
            case .attachmentMenu:
                return "attachmentMenu"
            case .expandedMessage(let message):
                return "expandedMessage-\(message.id)"
            case .camera:
                return "camera"
            }
        }
    }


    var body: some View {
        chatBody
    }

    @ViewBuilder
    private var chatBody: some View {
        @Bindable var viewModel = viewModel
        @Bindable var toastManager = toastManager

        GeometryReader { geometry in
            chatContent(geometry: geometry, viewModel: viewModel, toastManager: toastManager)
        }
        .background {
            // Background extends edge-to-edge. Admin users with paged TabView have
            // per-page backgrounds for the gradient; regular users get background here.
#if os(visionOS)
            Color.clear
#else
            ChatFlowTheme.pageBackground(colorScheme)
                .ignoresSafeArea()
                .overlay(NoiseOverlayView().ignoresSafeArea())
#endif
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            viewModel.handleSceneDidBecomeActive()
            keyboardRefreshToken &+= 1
        }
        .background(
            KeyboardLayoutGuideReader(refreshToken: keyboardRefreshToken) { height, duration, curve in
                if abs(height - keyboardHeight) > 0.5 {
                    NSLog("[KBTIMING] keyboardHeight state set %.1f -> %.1f", keyboardHeight, height)
                    withAnimation(nil) {
                        keyboardHeight = height
                    }
                }
                if height > 0.5, lastNonZeroKeyboardHeight <= 0.5 {
                    lastNonZeroKeyboardHeight = height
                    layoutRevision &+= 1
                }
                if abs(duration - keyboardAnimationDuration) > 0.001 {
                    keyboardAnimationDuration = duration
                }
                if curve != keyboardAnimationCurve {
                    keyboardAnimationCurve = curve
                }
            }
        )
        .sheet(item: $activeSheet, content: sheetView)
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $photoPickerItems,
            matching: .images
        )
        .onChange(of: photoPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await handlePhotoPickerItems(newItems)
                await MainActor.run {
                    photoPickerItems = []
                    restoreFocusIfNeeded()
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await handleDocumentResults(urls)
                    await MainActor.run { restoreFocusIfNeeded() }
                }
            case .failure:
                restoreFocusIfNeeded()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toastManager.toast)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: streamToastManager.isVisible)
    }

    @ViewBuilder
    private func chatContent(geometry: GeometryProxy,
                             viewModel: ChatViewModel,
                             toastManager: ToastManager) -> some View {
        @Bindable var viewModel = viewModel
        let topInset: CGFloat = geometry.safeAreaInsets.top
        let metrics = ChatFlowTheme.Metrics(isCompact: horizontalSizeClass == .compact)
        let resolvedInputHeight = max(inputBarHeight, MessageInputBarMetrics.minInputBarHeight)
        let keyboardVisibleHeight = max(0, keyboardHeight - geometry.safeAreaInsets.bottom)
        let isKeyboardVisible = keyboardVisibleHeight > 0.5
        let keyboardInset: CGFloat = isKeyboardVisible ? keyboardHeight : 0
        // Gap below input bar: version label area (keyboard hidden) or minimal gap (keyboard up)
        let belowBarGap: CGFloat = isKeyboardVisible ? 12 : 24
        let effectiveFlowGap: CGFloat = {
#if os(visionOS)
            // #49: visionOS needs more breathing room between the message flow and the input bar.
            return metrics.flowGap * 2
#else
            return metrics.flowGap
#endif
        }()
        // The flow layout's sectionInset.bottom (containerPadding) already provides
        // padding below the last cell. Subtract it so the effective gap between the
        // last bubble and the input bar top equals exactly flowGap.
        let listBottomInset = keyboardInset + belowBarGap + resolvedInputHeight
            + effectiveFlowGap - metrics.containerPadding
        let cachedKeyboardHeight = max(keyboardHeight, lastNonZeroKeyboardHeight)
        let isLandscape = geometry.size.width > geometry.size.height
        let estimatedKeyboardHeight: CGFloat = {
            if horizontalSizeClass == .regular {
                return isLandscape ? 300 : 360
            }
            return isLandscape ? 216 : 300
        }()
        let truncationKeyboardHeight = cachedKeyboardHeight > 0.5 ? cachedKeyboardHeight : estimatedKeyboardHeight
        let truncationBottomInset = truncationKeyboardHeight + 12 + resolvedInputHeight
            + effectiveFlowGap - metrics.containerPadding
        let layoutInputs = ChatLayoutInputs(
            keyboardHeight: keyboardHeight,
            keyboardVisible: isKeyboardVisible,
            isInputFocused: isInputFocused,
            keyboardAnimationDuration: keyboardAnimationDuration,
            keyboardAnimationCurve: keyboardAnimationCurve,
            safeAreaBottom: geometry.safeAreaInsets.bottom,
            usesExternalKeyboardInsets: false
        )
        let layoutMetrics = ChatLayoutMetrics(
            belowBarGap: belowBarGap,
            flowGap: effectiveFlowGap,
            containerPadding: metrics.containerPadding
        )
        let layoutKey = ChatLayoutKey(
            revision: layoutRevision,
            keyboardHeight: keyboardHeight,
            inputHeight: resolvedInputHeight,
            safeAreaBottom: geometry.safeAreaInsets.bottom,
            isInputFocused: isInputFocused,
            keyboardVisible: isKeyboardVisible,
            belowBarGap: belowBarGap,
            flowGap: effectiveFlowGap,
            containerPadding: metrics.containerPadding
        )

        let messageLayer: AnyView = authManager.isAdmin
            ? AnyView(
                pagedStreamView(topInset: topInset, truncationBottomInset: truncationBottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
            )
            : AnyView(
                messageList(
                    topInset: topInset,
                    truncationBottomInset: truncationBottomInset,
                    channel: .personal
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
            )

        ZStack(alignment: .top) {
            // Paged stream view for admins, single stream for regular users
            messageLayer
                // #31: fade out message content behind the system status bar (mask, not overlay tint).
                .compositingGroup()
                .mask(statusBarFadeMask(topInset: topInset))

            streamToastView(
                geometry: geometry,
                belowBarGap: belowBarGap,
                resolvedInputHeight: resolvedInputHeight,
                keyboardHeight: keyboardHeight
            )
            errorBannerView(viewModel: viewModel, listBottomInset: listBottomInset)
            toastBannerView(geometry: geometry, toastManager: toastManager)
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: layoutInputs) { _, _ in
            layoutCoordinator.updateInputs(layoutInputs, metrics: layoutMetrics)
            layoutCoordinator.markInputsChanged()
        }
        .onChange(of: layoutMetrics) { _, _ in
            layoutCoordinator.updateInputs(layoutInputs, metrics: layoutMetrics)
            layoutCoordinator.markInputsChanged()
        }
        .onChange(of: viewModel.activeStream) { _, newValue in
            layoutCoordinator.setActiveStream(newValue)
        }
        .onAppear {
            layoutCoordinator.setActiveStream(viewModel.activeStream)
            layoutCoordinator.updateInputs(layoutInputs, metrics: layoutMetrics)
            layoutCoordinator.markInputsChanged()
        }
        .onChange(of: keyboardHeight) { _, _ in layoutRevision &+= 1 }
        .onChange(of: keyboardAnimationDuration) { _, _ in layoutRevision &+= 1 }
        .onChange(of: keyboardAnimationCurve) { _, _ in layoutRevision &+= 1 }
        .onChange(of: inputBarHeight) { _, _ in layoutRevision &+= 1 }
        .onChange(of: isInputFocused) { _, _ in layoutRevision &+= 1 }
        .onChange(of: geometry.safeAreaInsets.bottom) { _, _ in layoutRevision &+= 1 }
        .onChange(of: horizontalSizeClass) { _, _ in layoutRevision &+= 1 }
        .overlay(alignment: .bottom) {
            inputBarOverlay(
                geometry: geometry,
                viewModel: viewModel,
                belowBarGap: belowBarGap,
                isKeyboardVisible: isKeyboardVisible,
                layoutKey: layoutKey
            )
        }
    }

    private var appVersionLabel: AttributedString? {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        guard let version, !version.isEmpty else { return nil }
        if let build, !build.isEmpty {
            var green = AttributeContainer()
            green.foregroundColor = .green
            let buildText = AttributedString(build, attributes: green)
            return AttributedString("v\(version) (build ") + buildText + AttributedString(")")
        }
        return AttributedString("v\(version)")
    }

    @ViewBuilder
    private func streamToastView(geometry: GeometryProxy,
                                 belowBarGap: CGFloat,
                                 resolvedInputHeight: CGFloat,
                                 keyboardHeight: CGFloat) -> some View {
        if streamToastManager.isVisible {
            let inputBarTopFromScreenBottom = max(keyboardHeight, geometry.safeAreaInsets.bottom)
                + belowBarGap + resolvedInputHeight
            StreamToast(channelName: streamToastManager.channelName)
                .padding(.bottom, inputBarTopFromScreenBottom + 50)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.container, edges: .bottom)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    @ViewBuilder
    private func errorBannerView(viewModel: ChatViewModel,
                                 listBottomInset: CGFloat) -> some View {
        if let error = viewModel.error {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                errorBanner(error)
            }
            .padding(.bottom, listBottomInset)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func toastBannerView(geometry: GeometryProxy,
                                 toastManager: ToastManager) -> some View {
        if let toast = toastManager.toast {
            ToastBanner(message: toast.message) {
                toastManager.dismiss()
            }
            .padding(.top, geometry.safeAreaInsets.top + 12)
            .padding(.horizontal, 24)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func inputBarOverlay(geometry: GeometryProxy,
                                 viewModel: ChatViewModel,
                                 belowBarGap: CGFloat,
                                 isKeyboardVisible: Bool,
                                 layoutKey: ChatLayoutKey) -> some View {
        KeyboardPinnedContainer(
            desiredBottomGap: belowBarGap,
            isKeyboardVisible: isKeyboardVisible,
            measuredHeight: $inputBarHeight,
            versionText: appVersionLabel,
            layoutCoordinator: layoutCoordinator,
            layoutKey: layoutKey
        ) {
            MessageInputBar(
                content: $viewModel.inputContent,
                selectionRange: $selectionRange,
                pendingInsertions: $pendingInputInsertions,
                placeholderText: viewModel.serverSessionKey(for: viewModel.activeStream)
                    ?? viewModel.messageStorageKey(for: viewModel.activeStream),
                resetToken: viewModel.inputResetToken,
                canSend: viewModel.canSend,
                isSending: viewModel.isSending,
                connectionAlert: viewModel.connectionAlert,
                focusTrigger: focusRequestID,
                bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                isKeyboardVisible: isKeyboardVisible,
                onSend: {
                    viewModel.send()
                },
                onCancel: { viewModel.cancelSend() },
                onAdd: {
                    activeSheet = .attachmentMenu
                },
                // ⚠️ This callback is how focus state survives view recreation.
                // DO NOT replace with @Binding or try to use @FocusState directly.
                onFocusChange: { focused in isInputFocused = focused },
                onPasteImages: handlePastedImages,
                isCompact: horizontalSizeClass == .compact
            )
        }
        .visionOSInputBarDepthOffset()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    @ViewBuilder
    private func statusBarFadeMask(topInset: CGFloat) -> some View {
        // #31 follow-up: reduce strength + height. This is a mask (not an overlay), so lower alpha
        // means content remains partially visible behind the status bar instead of fully hidden.
        if topInset <= 0 {
            Rectangle().fill(Color.white)
        } else {
            let topAlpha: CGFloat = 0.25
            let fullyHiddenHeight = topInset + 9
            let fadeHeight: CGFloat = 46
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(topAlpha))
                    .frame(height: fullyHiddenHeight)
                LinearGradient(
                    colors: [Color.white.opacity(topAlpha), Color.white],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: fadeHeight)
                Rectangle().fill(Color.white)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func inputBarMaxWidth(bottomSafeAreaInset: CGFloat) -> CGFloat? {
        guard horizontalSizeClass != .compact else { return nil }
        let themeMetrics = ChatFlowTheme.Metrics(isCompact: false)
        let textWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: themeMetrics.bodyFontSize)
        let metrics = MessageInputBarMetrics(
            horizontalSizeClass: .regular,
            bottomSafeAreaInset: bottomSafeAreaInset,
            deviceCornerRadius: 0,
            isFieldFocused: isInputFocused
        )
        let chromeWidth = (themeMetrics.inputBarPaddingHorizontal * 2)
            + metrics.inputBarHeight
            + metrics.inputBarHeight
            + (MessageInputBarMetrics.elementSpacing * 2)
        return textWidth + chromeWidth
    }

    private func messageList(topInset: CGFloat,
                             truncationBottomInset: CGFloat,
                             channel: ChatStream) -> some View {
        let list = MessageFlowCollectionView(
            viewModel: viewModel,
            topInset: topInset,
            isCompact: horizontalSizeClass == .compact,
            truncationBottomInset: truncationBottomInset,
            onExpand: { message in
                activeSheet = .expandedMessage(message)
            },
            layoutCoordinator: layoutCoordinator,
            channel: channel
        )
        // We manage keyboard avoidance manually inside the collection view.
        // Prevent SwiftUI from shrinking the view and double-applying the keyboard height.
        .ignoresSafeArea(.keyboard, edges: .bottom)
#if os(visionOS)
        return list
#else
        return list
#endif
    }

    @ViewBuilder
    private func sheetView(_ sheet: ChatSheet) -> some View {
        switch sheet {
        case .attachmentMenu:
            AttachmentSourceSheet(
                onCamera: {
                    presentCamera()
                },
                onPhotos: {
                    presentPhotoPicker()
                },
                onFiles: {
                    presentFileImporter()
                }
            )
            .presentationDetents([.medium, .large])
        case .expandedMessage(let message):
            let metrics = ChatFlowTheme.Metrics(isCompact: horizontalSizeClass == .compact)
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            ExpandedMessageSheet(message: message, presentation: presentation)
        case .camera:
            #if os(visionOS)
            Color.clear
                .onAppear {
                    activeSheet = nil
                    restoreFocusIfNeeded()
                }
            #else
            CameraPicker(
                onImage: { image in
                    activeSheet = nil
                    Task {
                        await handleCapturedImage(image)
                        await MainActor.run { restoreFocusIfNeeded() }
                    }
                },
                onCancel: {
                    activeSheet = nil
                    restoreFocusIfNeeded()
                }
            )
            #endif
        }
    }

    /// Paged TabView for horizontal swipe between streams (admin only)
    @ViewBuilder
    private func pagedStreamView(topInset: CGFloat, truncationBottomInset: CGFloat) -> some View {
        TabView(selection: streamBinding) {
            messageList(
                topInset: topInset,
                truncationBottomInset: truncationBottomInset,
                channel: .personal
            )
                .background {
#if os(visionOS)
                    Color.clear
#else
                    ChatFlowTheme.pageBackground(colorScheme)
                        .ignoresSafeArea()
                        .overlay(NoiseOverlayView().ignoresSafeArea())
#endif
                }
                .tag(ChatStream.personal)

            messageList(
                topInset: topInset,
                truncationBottomInset: truncationBottomInset,
                channel: .admin
            )
                .background {
#if os(visionOS)
                    Color.clear
#else
                    ChatFlowTheme.pageBackground(colorScheme)
                        .ignoresSafeArea()
                        .overlay(NoiseOverlayView().ignoresSafeArea())
#endif
                }
                .tag(ChatStream.admin)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    /// Binding that syncs TabView selection with viewModel.activeStream
    private var streamBinding: Binding<ChatStream> {
        Binding(
            get: { viewModel.activeStream },
            set: { newStream in
                guard newStream != viewModel.activeStream else { return }

                // Haptic feedback
#if !os(visionOS)
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
#endif

                // Switch stream and show toast
                viewModel.setActiveStream(newStream)
                let sessionKey = viewModel.messageStorageKey(for: newStream)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    streamToastManager.show(sessionKey: sessionKey)
                }
            }
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .foregroundColor(.white)
            Spacer()
            Button("Dismiss") { viewModel.clearError() }
                .foregroundColor(.white)
        }
        .padding()
        .background(Color.red)
    }

    private func deviceCornerRadius() -> CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        return hasRoundedCorners ? 50 : 0
    }

    @MainActor
    private func prepareForAttachmentPicker() {
        shouldRestoreFocusAfterPicker = isInputFocused
    }

    @MainActor
    private func restoreFocusIfNeeded() {
        guard shouldRestoreFocusAfterPicker else { return }
        focusRequestID &+= 1
        shouldRestoreFocusAfterPicker = false
    }

    @MainActor
    private func presentCamera() {
        prepareForAttachmentPicker()
#if os(visionOS)
        toastManager.show(error: .cameraUnavailable)
        restoreFocusIfNeeded()
        return
#else
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            toastManager.show(error: .cameraUnavailable)
            restoreFocusIfNeeded()
            return
        }
        activeSheet = .camera
#endif
    }

    @MainActor
    private func presentPhotoPicker() {
        prepareForAttachmentPicker()
        activeSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            isPhotosPickerPresented = true
        }
    }

    @MainActor
    private func presentFileImporter() {
        prepareForAttachmentPicker()
        activeSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            isFileImporterPresented = true
        }
    }

    private func handleCapturedImage(_ image: UIImage) async {
        guard let attachment = Self.makeImageAttachment(from: image, suggestedFilename: "camera.jpg") else {
            await MainActor.run { toastManager.show(error: .invalidData) }
            return
        }
        await MainActor.run {
            insertAttachments([attachment])
        }
    }

    @MainActor
    private func handlePastedImages(_ images: [UIImage]) {
        logger.info("Pasted \(images.count) image(s) from clipboard")
        Task { @MainActor in
            let attachments = await Self.buildPastedAttachments(from: images)
            guard !attachments.isEmpty else {
                toastManager.show(error: .invalidData)
                return
            }
            insertAttachments(attachments)
        }
    }

    private func handlePhotoPickerItems(_ items: [PhotosPickerItem]) async {
        var attachments: [PendingAttachment] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data),
               let attachment = Self.makeImageAttachment(from: image, suggestedFilename: item.itemIdentifier) {
                attachments.append(attachment)
            }
        }
        if attachments.isEmpty {
            await MainActor.run { toastManager.show(error: .invalidData) }
            return
        }
        await MainActor.run {
            insertAttachments(attachments)
        }
    }

    private func handleDocumentResults(_ urls: [URL]) async {
        var attachments: [PendingAttachment] = []
        for url in urls {
            do {
                let attachment = try loadDocumentAttachment(from: url)
                attachments.append(attachment)
            } catch let attachmentError as AttachmentError {
                await MainActor.run { toastManager.show(error: attachmentError) }
            } catch {
                await MainActor.run { toastManager.show(error.localizedDescription) }
            }
        }
        guard !attachments.isEmpty else { return }
        await MainActor.run {
            insertAttachments(attachments)
        }
    }

    @MainActor
    private func insertAttachments(_ attachments: [PendingAttachment]) {
        guard !attachments.isEmpty else { return }
        viewModel.stageAttachments(attachments)
        pendingInputInsertions = attachments
    }

    private func loadDocumentAttachment(from url: URL) throws -> PendingAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw AttachmentError.invalidData }
        let mimeType = mimeType(for: url)
        let thumbnail = makeDocumentThumbnail()
        return PendingAttachment(
            id: UUID(),
            data: data,
            thumbnail: thumbnail,
            mimeType: mimeType,
            filename: url.lastPathComponent
        )
    }

    private static func makeImageAttachment(from image: UIImage, suggestedFilename: String?) -> PendingAttachment? {
        guard let (data, mimeType) = encodeImage(image) else { return nil }
        return PendingAttachment(
            id: UUID(),
            data: data,
            thumbnail: makeThumbnail(from: image),
            mimeType: mimeType,
            filename: suggestedFilename
        )
    }

    private static func encodeImage(_ image: UIImage) -> (Data, String)? {
        if let data = image.jpegData(compressionQuality: 0.85) {
            return (data, "image/jpeg")
        }
        if let data = image.pngData() {
            return (data, "image/png")
        }
        return nil
    }

    private static func makeThumbnail(from image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 120
        let scale = min(maxDimension / max(image.size.width, image.size.height), 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func buildPastedAttachments(from images: [UIImage]) async -> [PendingAttachment] {
        await withCheckedContinuation { continuation in
            let copiedImages = images
            DispatchQueue.global(qos: .userInitiated).async {
                var attachments: [PendingAttachment] = []
                attachments.reserveCapacity(copiedImages.count)
                for (index, image) in copiedImages.enumerated() {
                    let filename = copiedImages.count > 1 ? "pasted-\(index + 1).png" : "pasted.png"
                    if let attachment = makeImageAttachment(from: image, suggestedFilename: filename) {
                        attachments.append(attachment)
                    }
                }
                continuation.resume(returning: attachments)
            }
        }
    }

    private func makeDocumentThumbnail() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor.systemGray5.setFill()
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
            path.fill()

            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            let symbol = UIImage(systemName: "doc.fill", withConfiguration: symbolConfig)?
                .withRenderingMode(.alwaysTemplate)
            UIColor.systemBlue.setFill()
            symbol?.draw(in: rect.insetBy(dx: 16, dy: 16))
        }
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private struct ToastBanner: View {
        let message: String
        let dismiss: () -> Void

        var body: some View {
            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
#if os(visionOS)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                )
#else
                .glassEffect(.regular, in: Capsule())
#endif
                .onTapGesture(perform: dismiss)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { value in
                            if value.translation.height < -10 {
                                dismiss()
                            }
                        }
                )
                .accessibilityLabel(message)
                .accessibilityHint("Dismiss with tap or swipe up.")
                .accessibilityAddTraits(.isStaticText)
                .onAppear {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
        }
    }

}

private struct VisionOSInputBarDepthOffset: ViewModifier {
    func body(content: Content) -> some View {
#if os(visionOS)
        // #49: subtle z-plane separation for spatial affordance (do not apply on iOS/iPadOS).
        content.offset(z: 12)
#else
        content
#endif
    }
}

private extension View {
    func visionOSInputBarDepthOffset() -> some View {
        modifier(VisionOSInputBarDepthOffset())
    }
}

private struct KeyboardLayoutGuideReader: UIViewRepresentable {
    typealias UIViewType = KeyboardLayoutGuideObserverView

    let refreshToken: Int
    let onChange: (CGFloat, TimeInterval, UIView.AnimationCurve) -> Void

    func makeUIView(context: Context) -> KeyboardLayoutGuideObserverView {
        let view = KeyboardLayoutGuideObserverView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: KeyboardLayoutGuideObserverView, context: Context) {
        uiView.onChange = onChange
        uiView.refreshIfNeeded(refreshToken)
    }
}

private final class KeyboardLayoutGuideObserverView: UIView {
    var onChange: ((CGFloat, TimeInterval, UIView.AnimationCurve) -> Void)?
    private var lastHeight: CGFloat = 0
    private var lastDuration: TimeInterval = 0
    private var lastCurve: UIView.AnimationCurve = .easeInOut
    private var lastRefreshToken: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refreshIfNeeded(_ token: Int) {
        guard token != lastRefreshToken else { return }
        lastRefreshToken = token
        refreshFromLayoutGuide()
    }

    private func refreshFromLayoutGuide() {
        guard let window else { return }
        window.layoutIfNeeded()
        layoutIfNeeded()
        let guideFrame = keyboardLayoutGuide.layoutFrame
        let frameInWindow = convert(guideFrame, to: window)
        let windowBounds = window.bounds
        let result = heightFromFrame(frameInWindow, windowBounds: windowBounds)
        let height = result.height
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
        }
        NSLog(
            "[KBTIMING] keyboardFrameChanged foreground frame=%@ win=%@ floating=%d",
            NSCoder.string(for: frameInWindow),
            NSCoder.string(for: windowBounds),
            result.isFloating ? 1 : 0
        )
        onChange?(height, lastDuration, lastCurve)
    }

    private func heightFromFrame(
        _ frameInWindow: CGRect,
        windowBounds: CGRect
    ) -> (height: CGFloat, isFloating: Bool) {
        let widthDelta = windowBounds.width - frameInWindow.width
        let isFloating = widthDelta > 1
            || frameInWindow.minX > 1
            || frameInWindow.maxX < windowBounds.maxX - 1
        let height: CGFloat
        if isFloating {
            height = 0
        } else {
            height = max(0, windowBounds.maxY - frameInWindow.minY)
        }
        return (height, isFloating)
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.3
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut
#if os(visionOS)
        let screenHeight = window?.bounds.height ?? endFrame.maxY
        let height = max(0, screenHeight - endFrame.origin.y)
#else
        let height: CGFloat
        if let window {
            let frameInWindow = window.convert(endFrame, from: nil)
            let windowBounds = window.bounds
            let result = heightFromFrame(frameInWindow, windowBounds: windowBounds)
            height = result.height
            NSLog(
                "[KBTIMING] keyboardFrameChanged frame=%@ win=%@ floating=%d",
                NSCoder.string(for: frameInWindow),
                NSCoder.string(for: windowBounds),
                result.isFloating ? 1 : 0
            )
        } else {
            let screenHeight = window?.windowScene?.screen.bounds.height
                ?? UIScreen.main.bounds.height
            height = max(0, screenHeight - endFrame.origin.y)
        }
#endif
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
        }
        if abs(duration - lastDuration) > 0.001 {
            lastDuration = duration
        }
        if curve != lastCurve {
            lastCurve = curve
        }
        onChange?(height, duration, curve)
        NSLog("[KBTIMING] keyboardFrameChanged h=%.1f dur=%.2f curve=%d dt=%.4f", height, duration, curve.rawValue, CFAbsoluteTimeGetCurrent() - t0)
    }
}

private struct KeyboardPinnedContainer<Content: View>: UIViewRepresentable {
    typealias UIViewType = KeyboardPinnedContainerView<Content>

    let desiredBottomGap: CGFloat
    let isKeyboardVisible: Bool
    @Binding var measuredHeight: CGFloat
    let versionText: AttributedString?
    let layoutCoordinator: ChatLayoutCoordinator
    let layoutKey: ChatLayoutKey
    let content: Content

    init(
        desiredBottomGap: CGFloat,
        isKeyboardVisible: Bool,
        measuredHeight: Binding<CGFloat>,
        versionText: AttributedString? = nil,
        layoutCoordinator: ChatLayoutCoordinator,
        layoutKey: ChatLayoutKey,
        @ViewBuilder content: () -> Content
    ) {
        self.desiredBottomGap = desiredBottomGap
        self.isKeyboardVisible = isKeyboardVisible
        self._measuredHeight = measuredHeight
        self.versionText = versionText
        self.layoutCoordinator = layoutCoordinator
        self.layoutKey = layoutKey
        self.content = content()
    }

    func makeUIView(context: Context) -> KeyboardPinnedContainerView<Content> {
        let container = KeyboardPinnedContainerView(rootView: content, versionText: versionText)
        return container
    }

    func updateUIView(_ uiView: KeyboardPinnedContainerView<Content>, context: Context) {
        let t0 = CFAbsoluteTimeGetCurrent()
        uiView.hostingController.rootView = content
        uiView.updateVersionText(versionText)
        uiView.setOnBarHeightChange { [weak layoutCoordinator] height in
            if abs(measuredHeight - height) > 0.5 {
                DispatchQueue.main.async {
                    _measuredHeight.wrappedValue = height
                }
            }
            layoutCoordinator?.updateBarHeight(height)
        }
        layoutCoordinator.registerBarView(uiView)
        layoutCoordinator.applyTransitionIfPossible(reason: "KeyboardPinnedContainer.updateUIView")
        _ = layoutKey
        NSLog("[KBTIMING] KBPinnedContainer.updateUIView gap=%.1f kbVis=%d dt=%.4f", desiredBottomGap, isKeyboardVisible ? 1 : 0, CFAbsoluteTimeGetCurrent() - t0)
    }
}

private final class KeyboardPinnedContainerView<Content: View>: UIView, KeyboardPinnedContainerViewProtocol {
    let hostingController: UIHostingController<Content>
    let versionLabel: UILabel
    private var minHeightConstraint: NSLayoutConstraint?
    private var hostingBottomToKeyboard: NSLayoutConstraint?
    private var versionLabelBottomToKeyboard: NSLayoutConstraint?
    private var versionLabelBottomToContainer: NSLayoutConstraint?
    private var bottomToContainerConstraint: NSLayoutConstraint?
    private var onBarHeightChange: ((CGFloat) -> Void)?
    private var lastMeasuredHeight: CGFloat = 0

    init(rootView: Content, versionText: AttributedString?) {
        hostingController = UIHostingController(rootView: rootView)
        versionLabel = UILabel()
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        if #available(iOS 16.0, visionOS 1.0, *) {
            hostingController.sizingOptions = [.intrinsicContentSize]
            hostingController.safeAreaRegions = []
        }
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false

        versionLabel.font = .preferredFont(forTextStyle: .caption2)
        versionLabel.textColor = .secondaryLabel
        versionLabel.textAlignment = .right
        if let versionText {
            versionLabel.attributedText = NSAttributedString(versionText)
        }
        versionLabel.isHidden = versionText == nil

#if !os(visionOS)
        // When keyboard is hidden the layout guide defaults to the safe-area
        // bottom, which already accounts for the home indicator. Setting this
        // to false makes the guide collapse to the view's own bottom edge so
        // desiredBottomGap is measured from the physical screen edge (needed
        // for concentric alignment with device corners).
        keyboardLayoutGuide.usesBottomSafeArea = false
#endif
    }

    var containerView: UIView { self }

    var barHeight: CGFloat {
        hostingController.view?.bounds.height ?? 0
    }

    func setOnBarHeightChange(_ handler: @escaping (CGFloat) -> Void) {
        onBarHeightChange = handler
    }

    func updateVersionText(_ text: AttributedString?) {
        if let text {
            versionLabel.attributedText = NSAttributedString(text)
        } else {
            versionLabel.attributedText = nil
        }
        // Only hide for nil text; keyboard-driven hiding is handled by the coordinator
        if text == nil {
            versionLabel.isHidden = true
        }
    }

    func setDesiredBottomGap(_ gap: CGFloat, isKeyboardVisible: Bool) {
        ensureConstraints(desiredBottomGap: gap)
#if os(visionOS)
        bottomToContainerConstraint?.constant = -gap
#else
        hostingBottomToKeyboard?.constant = -gap
        let hasVersionText = versionLabel.attributedText != nil && !versionLabel.attributedText!.string.isEmpty
        versionLabel.isHidden = isKeyboardVisible || !hasVersionText
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if let hitView = hostingController.view, hitView.frame.contains(point) {
            return true
        }
        if !versionLabel.isHidden && versionLabel.frame.contains(point) {
            return true
        }
        return false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = barHeight
        guard abs(height - lastMeasuredHeight) > 0.5 else { return }
        lastMeasuredHeight = height
        onBarHeightChange?(height)
    }

    private func ensureConstraints(desiredBottomGap: CGFloat) {
        guard let hostingView = hostingController.view else { return }
#if os(visionOS)
        if bottomToContainerConstraint == nil {
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setContentHuggingPriority(.required, for: .vertical)
            hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
            addSubview(hostingView)

            versionLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(versionLabel)

            let bottomToContainerConstraint = hostingView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -desiredBottomGap
            )
            let topConstraint = hostingView.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor
            )
            topConstraint.priority = .defaultLow

            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                bottomToContainerConstraint,
                topConstraint,
                versionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                versionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                versionLabel.bottomAnchor.constraint(equalTo: hostingView.topAnchor, constant: -4),
            ])
            self.bottomToContainerConstraint = bottomToContainerConstraint
        }
#else
        if minHeightConstraint == nil {
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setContentHuggingPriority(.defaultHigh, for: .vertical)
            hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
            addSubview(hostingView)

            versionLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(versionLabel)

            let minHeight = hostingView.heightAnchor.constraint(greaterThanOrEqualToConstant: MessageInputBarMetrics.minInputBarHeight)
            let topConstraint = hostingView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor)
            topConstraint.priority = .defaultLow

            let hostingToKeyboard = hostingView.bottomAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor,
                constant: -desiredBottomGap
            )

            let versionToKeyboard = versionLabel.bottomAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor,
                constant: -4
            )
            let versionToContainer = versionLabel.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -4
            )
            versionToContainer.priority = .defaultLow

            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                minHeight,
                topConstraint,
                hostingToKeyboard,
                versionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                versionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                versionToKeyboard,
                versionToContainer,
            ])

            minHeightConstraint = minHeight
            hostingBottomToKeyboard = hostingToKeyboard
            versionLabelBottomToKeyboard = versionToKeyboard
            versionLabelBottomToContainer = versionToContainer
        }
#endif
    }
}

private struct StreamSwitcherHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct InputBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


// MARK: - Previews

private struct PreviewDevice: DeviceIdentifying {
    let deviceId = "preview-device"
}

private final class PreviewChatService: ChatServicing {
    var incomingMessages: AsyncStream<Message> {
        AsyncStream { _ in }
    }
    var connectionState: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.connected)
        }
    }
    var serviceEvents: AsyncStream<ChatServiceEvent> {
        AsyncStream { _ in }
    }
    func connect(token: String, lastMessageId: String?) async throws {}
    func disconnect() {}
    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String?) async throws {}
}

private struct AttachmentSourceSheet: View {
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void

    @Environment(\.colorScheme) private var colorScheme
#if os(visionOS)
    @Environment(\.settingsManager) private var settings
    @Environment(\.dismiss) private var dismiss
#endif

    private var effectiveColorScheme: ColorScheme {
#if os(visionOS)
        return settings.appearanceMode == .dark ? .dark : .light
#else
        return colorScheme
#endif
    }
    var body: some View {
        VStack(spacing: 24) {
#if os(visionOS)
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
#endif
            Capsule()
                .fill(.secondary.opacity(0.4))
                .frame(width: 40, height: 4)
                .padding(.top, 12)

            Text("Add Attachment")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(ChatFlowTheme.warmBrown(effectiveColorScheme))

            VStack(spacing: 12) {
#if !os(visionOS)
                AttachmentActionButton(
                    title: "Camera",
                    icon: "camera.fill",
                    action: onCamera
                )
#endif

                AttachmentActionButton(
                    title: "Photos",
                    icon: "photo.on.rectangle",
                    action: onPhotos
                )

                AttachmentActionButton(
                    title: "Files",
                    icon: "doc.fill",
                    action: onFiles
                )
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .background {
            ChatFlowTheme.pageBackground(effectiveColorScheme)
                .ignoresSafeArea()
        }
        .presentationDragIndicator(.visible)
    }
}

private struct AttachmentActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings
    @State private var isPressed = false

    private var effectiveColorScheme: ColorScheme {
#if os(visionOS)
        return settings.appearanceMode == .dark ? .dark : .light
#else
        return colorScheme
#endif
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ChatFlowTheme.sage(effectiveColorScheme))
                    .frame(width: 28)

                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ChatFlowTheme.warmBrown(effectiveColorScheme))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ChatFlowTheme.warmBrown(effectiveColorScheme).opacity(0.4))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
#if os(visionOS)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(effectiveColorScheme == .dark ? 0.08 : 0.3))
            )
#else
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
#endif
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

private final class PreviewUploadService: UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String { "preview-asset" }
    func download(assetId: String) async throws -> Data { Data() }
}

#Preview("Empty Chat") {
    let device = PreviewDevice()
    let auth = AuthManager()
    auth.storeCredentials(token: "preview-token", userId: "preview-user")
    let toastManager = ToastManager()
    let viewModel = ChatViewModel(
        auth: auth,
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device,
        uploadService: PreviewUploadService(),
        toastManager: toastManager
    )
    return ChatView(
        viewModel: viewModel,
        toastManager: toastManager
    )
    .environment(auth)
}

#Preview("With Messages") {
    let device = PreviewDevice()
    let auth = AuthManager()
    auth.storeCredentials(token: "preview-token", userId: "preview-user")
    auth.updateAdminStatus(true)
    let toastManager = ToastManager()
    let viewModel = ChatViewModel(
        auth: auth,
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device,
        uploadService: PreviewUploadService(),
        toastManager: toastManager
    )
    return ChatView(
        viewModel: viewModel,
        toastManager: toastManager
    )
    .environment(auth)
}
