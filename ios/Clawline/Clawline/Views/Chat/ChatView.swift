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

    @State private var inputBarHeight: CGFloat = 0
    @State private var channelToastManager = ChannelToastManager()

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
        }
        .background(
            KeyboardLayoutGuideReader { height in
                if abs(height - keyboardHeight) > 0.5 {
                    withAnimation(nil) {
                        keyboardHeight = height
                    }
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
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: channelToastManager.isVisible)
    }

    @ViewBuilder
    private func chatContent(geometry: GeometryProxy,
                             viewModel: ChatViewModel,
                             toastManager: ToastManager) -> some View {
        @Bindable var viewModel = viewModel
        let topInset: CGFloat = geometry.safeAreaInsets.top
        let metrics = ChatFlowTheme.Metrics(isCompact: horizontalSizeClass == .compact)
        let inputBarBaseHeight: CGFloat = 44
        let resolvedInputHeight = max(inputBarHeight, inputBarBaseHeight)
        let keyboardVisibleHeight = max(0, keyboardHeight - geometry.safeAreaInsets.bottom)
        let isKeyboardVisible = keyboardVisibleHeight > 0.5
        let keyboardInset: CGFloat = isKeyboardVisible ? keyboardHeight : 0
        // Gap below input bar: version label area (keyboard hidden) or minimal gap (keyboard up)
        let belowBarGap: CGFloat = isKeyboardVisible ? 12 : 24
        // The flow layout's sectionInset.bottom (containerPadding) already provides
        // padding below the last cell. Subtract it so the effective gap between the
        // last bubble and the input bar top equals exactly flowGap.
        let listBottomInset = keyboardInset + belowBarGap + resolvedInputHeight
            + metrics.flowGap - metrics.containerPadding

        ZStack(alignment: .top) {
            // Paged channel view for admins, single channel for regular users
            if authManager.isAdmin {
                pagedChannelView(topInset: topInset, bottomInset: listBottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
            } else {
                messageList(topInset: topInset, bottomInset: listBottomInset, channel: .personal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
            }

            // Channel toast (centered)
            if channelToastManager.isVisible {
                ChannelToast(channelName: channelToastManager.channelName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if let error = viewModel.error {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    errorBanner(error)
                }
                .padding(.bottom, listBottomInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let toast = toastManager.toast {
                ToastBanner(message: toast.message) {
                    toastManager.dismiss()
                }
                .padding(.top, geometry.safeAreaInsets.top + 12)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .bottom) {
            KeyboardPinnedContainer(
                desiredBottomGap: belowBarGap,
                isKeyboardVisible: isKeyboardVisible,
                measuredHeight: $inputBarHeight,
                height: resolvedInputHeight,
                versionText: appVersionLabel
            ) {
                MessageInputBar(
                    content: $viewModel.inputContent,
                    selectionRange: $selectionRange,
                    pendingInsertions: $pendingInputInsertions,
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private var appVersionLabel: String? {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        guard let version, !version.isEmpty else { return nil }
        if let build, !build.isEmpty {
            return "v\(version) (build \(build))"
        }
        return "v\(version)"
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

    private func messageList(topInset: CGFloat, bottomInset: CGFloat, channel: ChatChannelType) -> some View {
        let list = MessageFlowCollectionView(
            viewModel: viewModel,
            topInset: topInset,
            bottomInset: bottomInset,
            isCompact: horizontalSizeClass == .compact,
            isKeyboardVisible: isInputFocused,
            usesExternalKeyboardInsets: true,
            onExpand: { message in
                activeSheet = .expandedMessage(message)
            },
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

    /// Paged TabView for horizontal swipe between channels (admin only)
    @ViewBuilder
    private func pagedChannelView(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        TabView(selection: channelBinding) {
            messageList(topInset: topInset, bottomInset: bottomInset, channel: .personal)
                .background {
#if os(visionOS)
                    Color.clear
#else
                    ChatFlowTheme.pageBackground(colorScheme)
                        .ignoresSafeArea()
                        .overlay(NoiseOverlayView().ignoresSafeArea())
#endif
                }
                .tag(ChatChannelType.personal)

            messageList(topInset: topInset, bottomInset: bottomInset, channel: .admin)
                .background {
#if os(visionOS)
                    Color.clear
#else
                    ChatFlowTheme.pageBackground(colorScheme)
                        .ignoresSafeArea()
                        .overlay(NoiseOverlayView().ignoresSafeArea())
#endif
                }
                .tag(ChatChannelType.admin)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    /// Binding that syncs TabView selection with viewModel.activeChannel
    private var channelBinding: Binding<ChatChannelType> {
        Binding(
            get: { viewModel.activeChannel },
            set: { newChannel in
                guard newChannel != viewModel.activeChannel else { return }

                // Haptic feedback
#if !os(visionOS)
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
#endif

                // Switch channel and show toast
                viewModel.setActiveChannel(newChannel)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    channelToastManager.show(channel: newChannel)
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

private struct KeyboardLayoutGuideReader: UIViewRepresentable {
    typealias UIViewType = KeyboardLayoutGuideObserverView

    let onHeightChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> KeyboardLayoutGuideObserverView {
        let view = KeyboardLayoutGuideObserverView()
        view.onHeightChange = onHeightChange
        return view
    }

    func updateUIView(_ uiView: KeyboardLayoutGuideObserverView, context: Context) {
        uiView.onHeightChange = onHeightChange
    }
}

private final class KeyboardLayoutGuideObserverView: UIView {
    var onHeightChange: ((CGFloat) -> Void)?
    private var lastHeight: CGFloat = 0

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

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
#if os(visionOS)
        let screenHeight = window?.bounds.height ?? endFrame.maxY
#else
        let screenHeight = window?.windowScene?.screen.bounds.height
            ?? UIScreen.main.bounds.height
#endif
        let height = max(0, screenHeight - endFrame.origin.y)
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            onHeightChange?(height)
        }
    }
}

private struct KeyboardPinnedContainer<Content: View>: UIViewRepresentable {
    typealias UIViewType = KeyboardPinnedContainerView<Content>

    let desiredBottomGap: CGFloat
    let isKeyboardVisible: Bool
    @Binding var measuredHeight: CGFloat
    let height: CGFloat
    let versionText: String?
    let content: Content

    init(
        desiredBottomGap: CGFloat,
        isKeyboardVisible: Bool,
        measuredHeight: Binding<CGFloat>,
        height: CGFloat,
        versionText: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.desiredBottomGap = desiredBottomGap
        self.isKeyboardVisible = isKeyboardVisible
        self._measuredHeight = measuredHeight
        self.height = height
        self.versionText = versionText
        self.content = content()
    }

    func makeUIView(context: Context) -> KeyboardPinnedContainerView<Content> {
        let container = KeyboardPinnedContainerView(rootView: content, versionText: versionText)
        context.coordinator.container = container
        return container
    }

    func updateUIView(_ uiView: KeyboardPinnedContainerView<Content>, context: Context) {
        uiView.hostingController.rootView = content
        uiView.updateVersionText(versionText)
        context.coordinator.updateConstraints(
            in: uiView,
            height: height,
            desiredBottomGap: desiredBottomGap,
            isKeyboardVisible: isKeyboardVisible,
            measuredHeight: $measuredHeight
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var container: KeyboardPinnedContainerView<Content>?
        private var minHeightConstraint: NSLayoutConstraint?
        private var hostingBottomToKeyboard: NSLayoutConstraint?
        private var versionLabelBottomToKeyboard: NSLayoutConstraint?
        private var versionLabelBottomToContainer: NSLayoutConstraint?
        // visionOS fallback
        private var bottomToContainerConstraint: NSLayoutConstraint?

        func updateConstraints(
            in container: KeyboardPinnedContainerView<Content>,
            height: CGFloat,
            desiredBottomGap: CGFloat,
            isKeyboardVisible: Bool,
            measuredHeight: Binding<CGFloat>
        ) {
            guard let hostingView = container.hostingController.view else { return }
            let versionLabel = container.versionLabel
#if os(visionOS)
            if bottomToContainerConstraint == nil {
                hostingView.translatesAutoresizingMaskIntoConstraints = false
                hostingView.setContentHuggingPriority(.required, for: .vertical)
                hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
                container.addSubview(hostingView)

                let bottomToContainerConstraint = hostingView.bottomAnchor.constraint(
                    equalTo: container.bottomAnchor,
                    constant: -desiredBottomGap
                )
                let topConstraint = hostingView.topAnchor.constraint(
                    greaterThanOrEqualTo: container.topAnchor
                )
                topConstraint.priority = .defaultLow

                NSLayoutConstraint.activate([
                    hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    bottomToContainerConstraint,
                    topConstraint,
                ])

                self.bottomToContainerConstraint = bottomToContainerConstraint
            } else {
                bottomToContainerConstraint?.constant = -desiredBottomGap
            }
#else
            if minHeightConstraint == nil {
                hostingView.translatesAutoresizingMaskIntoConstraints = false
                hostingView.setContentHuggingPriority(.defaultHigh, for: .vertical)
                hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
                container.addSubview(hostingView)

                versionLabel.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(versionLabel)

                let minHeight = hostingView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
                let topConstraint = hostingView.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor)
                topConstraint.priority = .defaultLow

                // Input bar: always pinned directly to keyboard layout guide.
                // Never deactivate this constraint — switching constraint sets
                // during interactive keyboard dismiss causes the bar to jump.
                let hostingToKeyboard = hostingView.bottomAnchor.constraint(
                    equalTo: container.keyboardLayoutGuide.topAnchor,
                    constant: -desiredBottomGap
                )

                // Version label: independently positioned near keyboard guide
                let versionToKeyboard = versionLabel.bottomAnchor.constraint(
                    equalTo: container.keyboardLayoutGuide.topAnchor,
                    constant: -4
                )
                let versionToContainer = versionLabel.bottomAnchor.constraint(
                    equalTo: container.bottomAnchor,
                    constant: -4
                )
                versionToContainer.priority = .defaultLow

                // All constraints always active — no switching needed
                NSLayoutConstraint.activate([
                    hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    minHeight,
                    topConstraint,
                    hostingToKeyboard,
                    versionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
                    versionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
                    versionToKeyboard,
                    versionToContainer,
                ])

                self.minHeightConstraint = minHeight
                self.hostingBottomToKeyboard = hostingToKeyboard
                self.versionLabelBottomToKeyboard = versionToKeyboard
                self.versionLabelBottomToContainer = versionToContainer
            }

            // Update gap constant and version label visibility — no constraint
            // activation/deactivation needed.
            let previousGap = hostingBottomToKeyboard?.constant ?? 0
            let newGap = -desiredBottomGap
            let gapChanged = abs(previousGap - newGap) > 0.5
            hostingBottomToKeyboard?.constant = newGap
            let hasVersionText = versionLabel.text != nil && !versionLabel.text!.isEmpty
            versionLabel.isHidden = isKeyboardVisible || !hasVersionText
#endif

            #if os(visionOS)
            let gapChanged = false
            #endif

            // Skip layoutIfNeeded() when the below-bar gap just changed.
            // Forcing layout at that moment captures ALL pending constraint
            // changes — including the keyboardLayoutGuide position — and
            // resolves them to the model-layer (final) values instantly,
            // overriding the system's keyboard spring animation and causing
            // a sluggish pause on interactive dismiss release. Letting the
            // system drive layout naturally preserves the native keyboard
            // animation feel.
            if container.bounds.width > 0, !gapChanged {
                container.layoutIfNeeded()
                let currentHeight = hostingView.bounds.height
                if abs(measuredHeight.wrappedValue - currentHeight) > 0.5 {
                    DispatchQueue.main.async {
                        measuredHeight.wrappedValue = currentHeight
                    }
                }
            }

        }
    }
}

private final class KeyboardPinnedContainerView<Content: View>: UIView {
    let hostingController: UIHostingController<Content>
    let versionLabel: UILabel

    init(rootView: Content, versionText: String?) {
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
        versionLabel.text = versionText
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

    func updateVersionText(_ text: String?) {
        versionLabel.text = text
        // Only hide for nil text; keyboard-driven hiding is handled by the coordinator
        if text == nil {
            versionLabel.isHidden = true
        }
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
}

private struct ChannelSwitcherHeightPreferenceKey: PreferenceKey {
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
    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String) async throws {}
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
