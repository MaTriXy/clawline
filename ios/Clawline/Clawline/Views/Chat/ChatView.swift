//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

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
    @State private var viewModel: ChatViewModel
    @State private var toastManager: ToastManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthManager.self) private var authManager

    // ⚠️ CRITICAL: This state MUST live here in ChatView, NOT in MessageInputBar.
    // MessageInputBar is inside .safeAreaInset and gets recreated on geometry changes.
    // State in recreated views resets silently. See header comment for full explanation.
    @State private var isInputFocused = false
    @State private var selectionRange = NSRange(location: 0, length: 0)
    @State private var showAttachmentMenu = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var focusRequestID = 0
    @State private var shouldRestoreFocusAfterPicker = false

    init(auth: any AuthManaging,
         chatService: any ChatServicing,
         settings: SettingsManager,
         device: any DeviceIdentifying,
         uploadService: any UploadServicing,
         toastManager: ToastManager) {
        _toastManager = State(initialValue: toastManager)
        _viewModel = State(initialValue: ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: settings,
            device: device,
            uploadService: uploadService,
            toastManager: toastManager
        ))
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var inputBarHeight: CGFloat = 0
    @State private var channelToastManager = ChannelToastManager()


    var body: some View {
        @Bindable var viewModel = viewModel
        @Bindable var toastManager = toastManager

        GeometryReader { geometry in
            let topInset: CGFloat = geometry.safeAreaInsets.top
            let inputBarBaseHeight: CGFloat = 48
            let resolvedInputHeight = max(inputBarHeight, inputBarBaseHeight)
            // Base bottom inset for input bar: height + spacing + safe area (for home indicator).
            // When keyboard is visible, SwiftUI shrinks the view so safe area isn't needed.
            // When keyboard is hidden, safe area ensures content clears the input bar.
            let bottomSafeArea = isInputFocused ? 0 : geometry.safeAreaInsets.bottom
            let bottomInset: CGFloat = resolvedInputHeight + MessageInputBarMetrics.elementSpacing + bottomSafeArea

            ZStack(alignment: .top) {
                messageList(topInset: topInset, bottomInset: bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])

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
                    .padding(.bottom, bottomInset)
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
            .onPreferenceChange(InputBarHeightPreferenceKey.self) { height in
                inputBarHeight = height
            }
            // ═══════════════════════════════════════════════════════════════════════════════
            // ⚠️ CRITICAL SECTION - READ HEADER COMMENT BEFORE MODIFYING ⚠️
            // ═══════════════════════════════════════════════════════════════════════════════
            //
            // This .safeAreaInset block is where the keyboard positioning fix is implemented.
            // The content inside gets RECREATED when geometry changes (keyboard show/hide).
            //
            // WHY THE OFFSET IS APPLIED HERE (not in MessageInputBar):
            // - MessageInputBar's body won't re-render when parent state changes
            // - BUT modifiers applied TO MessageInputBar from here DO update
            // - So we calculate offset here using parent's @State isInputFocused
            //
            // WHY onFocusChange CALLBACK (not @FocusState in MessageInputBar):
            // - @FocusState in MessageInputBar resets when view recreates
            // - Callback allows MessageInputBar to report focus to stable parent
            // - Parent's @State survives the geometry change
            //
            .safeAreaInset(edge: .bottom) {
                // Positive offset pushes bar DOWN into safe area for concentric alignment.
                // When focused (keyboard visible), offset is 0 (bar sits above keyboard).
                let rawOffset = calculateConcentricOffset(bottomInset: geometry.safeAreaInsets.bottom)
                let concentricOffset = isInputFocused ? 0 : rawOffset

                MessageInputBar(
                    content: $viewModel.inputContent,
                    selectionRange: $selectionRange,
                    canSend: viewModel.canSend,
                    isSending: viewModel.isSending,
                    connectionAlert: viewModel.connectionAlert,
                    focusTrigger: focusRequestID,
                    bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                    isKeyboardVisible: isInputFocused,
                    onSend: {
                        viewModel.send()
                    },
                    onCancel: { viewModel.cancelSend() },
                    onAdd: {
                        logger.info("Attachment menu requested")
                        showAttachmentMenu = true
                    },
                    // ⚠️ This callback is how focus state survives view recreation.
                    // DO NOT replace with @Binding or try to use @FocusState directly.
                    onFocusChange: { focused in isInputFocused = focused },
                    onPasteImages: handlePastedImages
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: InputBarHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                // ⚠️ Offset MUST be applied here, not inside MessageInputBar.
                // See header comment for why.
                .offset(y: concentricOffset)
                .animation(.easeOut(duration: 0.25), value: concentricOffset)
            }
        }
        .background {
            ChatFlowTheme.pageBackground(colorScheme)
                .ignoresSafeArea()
                .overlay(adminBackgroundOverlay)
                .overlay(NoiseOverlayView().ignoresSafeArea())
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            viewModel.handleSceneDidBecomeActive()
        }
        .sheet(isPresented: $showAttachmentMenu) {
            AttachmentSourceSheet(
                onCamera: {
                    showAttachmentMenu = false
                    presentCamera()
                },
                onPhotos: {
                    showAttachmentMenu = false
                    prepareForAttachmentPicker()
                    showPhotoPicker = true
                },
                onFiles: {
                    showAttachmentMenu = false
                    prepareForAttachmentPicker()
                    showFilePicker = true
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(
                onImage: { image in
                    showCamera = false
                    Task {
                        await handleCapturedImage(image)
                        await MainActor.run { restoreFocusIfNeeded() }
                    }
                },
                onCancel: {
                    showCamera = false
                    restoreFocusIfNeeded()
                }
            )
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(
                selectionLimit: 0,
                onPick: { results in
                    showPhotoPicker = false
                    Task {
                        await handlePhotoResults(results)
                        await MainActor.run { restoreFocusIfNeeded() }
                    }
                },
                onCancel: {
                    showPhotoPicker = false
                    restoreFocusIfNeeded()
                }
            )
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(
                contentTypes: [.item],
                onPick: { urls in
                    showFilePicker = false
                    Task {
                        await handleDocumentResults(urls)
                        await MainActor.run { restoreFocusIfNeeded() }
                    }
                },
                onCancel: {
                    showFilePicker = false
                    restoreFocusIfNeeded()
                }
            )
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toastManager.toast)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: channelToastManager.isVisible)
    }

    @ViewBuilder
    private var adminBackgroundOverlay: some View {
        if authManager.isAdmin && viewModel.activeChannel == .admin {
            LinearGradient(
                colors: [
                    ChatFlowTheme.adminAccent(colorScheme).opacity(colorScheme == .dark ? 0.3 : 0.18),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func messageList(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        MessageFlowCollectionView(
            viewModel: viewModel,
            topInset: topInset,
            bottomInset: bottomInset,
            isCompact: horizontalSizeClass == .compact,
            isKeyboardVisible: isInputFocused,
            onChannelSwipe: handleChannelSwipe
        )
    }

    /// Handle swipe gesture to switch between channels (admin only)
    private func handleChannelSwipe(_ newChannel: ChatChannelType) {
        guard authManager.isAdmin else { return }

        // Only switch if different channel
        guard newChannel != viewModel.activeChannel else { return }

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        // Switch channel and show toast
        viewModel.setActiveChannel(newChannel)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            channelToastManager.show(channel: newChannel)
        }
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
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            toastManager.show(error: .cameraUnavailable)
            restoreFocusIfNeeded()
            return
        }
        showCamera = true
    }

    private func handleCapturedImage(_ image: UIImage) async {
        guard let attachment = makeImageAttachment(from: image, suggestedFilename: "camera.jpg") else {
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
        var attachments: [PendingAttachment] = []
        for (index, image) in images.enumerated() {
            let filename = images.count > 1 ? "pasted-\(index + 1).png" : "pasted.png"
            if let attachment = makeImageAttachment(from: image, suggestedFilename: filename) {
                attachments.append(attachment)
            }
        }
        guard !attachments.isEmpty else {
            toastManager.show(error: .invalidData)
            return
        }
        insertAttachments(attachments)
    }

    private func handlePhotoResults(_ results: [PHPickerResult]) async {
        var attachments: [PendingAttachment] = []
        for result in results {
            if let attachment = await loadPhotoAttachment(from: result) {
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
        let mutable = NSMutableAttributedString(attributedString: viewModel.inputContent)
        let safeRange = clamp(selectionRange, length: mutable.length)
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
        viewModel.stageAttachments(attachments)
        viewModel.inputContent = mutable
        selectionRange = NSRange(location: insertionLocation, length: 0)
    }

    private func clamp(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let safeLocation = min(max(range.location, 0), length)
        let maxLength = max(0, min(range.length, length - safeLocation))
        return NSRange(location: safeLocation, length: maxLength)
    }

    private func loadPhotoAttachment(from result: PHPickerResult) async -> PendingAttachment? {
        let provider = result.itemProvider
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        do {
            let image = try await loadImage(from: provider)
            return makeImageAttachment(from: image, suggestedFilename: provider.suggestedName)
        } catch {
            return nil
        }
    }

    private func loadImage(from provider: NSItemProvider) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let image = object as? UIImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: AttachmentError.invalidData)
                }
            }
        }
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

    private func makeImageAttachment(from image: UIImage, suggestedFilename: String?) -> PendingAttachment? {
        guard let (data, mimeType) = encodeImage(image) else { return nil }
        return PendingAttachment(
            id: UUID(),
            data: data,
            thumbnail: makeThumbnail(from: image),
            mimeType: mimeType,
            filename: suggestedFilename
        )
    }

    private func encodeImage(_ image: UIImage) -> (Data, String)? {
        if let data = image.jpegData(compressionQuality: 0.85) {
            return (data, "image/jpeg")
        }
        if let data = image.pngData() {
            return (data, "image/png")
        }
        return nil
    }

    private func makeThumbnail(from image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 120
        let scale = min(maxDimension / max(image.size.width, image.size.height), 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
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
                .glassEffect(.regular, in: Capsule())
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

    /// Calculate concentric offset to align input bar with device corner radius.
    /// Returns ~16pt when keyboard hidden, 0pt when keyboard visible (handled by caller).
    private func calculateConcentricOffset(bottomInset: CGFloat) -> CGFloat {
        // Device corner radius: ~50pt for Face ID devices, 0pt for home button devices
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        let deviceCornerRadius: CGFloat = hasRoundedCorners ? 50 : 0

        let inputBarHeight: CGFloat = 48
        let elementSpacing: CGFloat = 8
        let concentricPadding = max(deviceCornerRadius - (inputBarHeight / 2), 8)

        let minSafeArea: CGFloat = 34
        let maxSafeArea: CGFloat = 100
        let maxOffset = max(minSafeArea - concentricPadding + elementSpacing, 0)
        let t = (bottomInset - minSafeArea) / (maxSafeArea - minSafeArea)
        let clampedT = max(0, min(1, t))
        return maxOffset * (1 - clampedT)
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
    func send(id: String, content: String, attachments: [WireAttachment], channelType: ChatChannelType) async throws {}
}

private struct AttachmentSourceSheet: View {
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(.secondary.opacity(0.4))
                .frame(width: 40, height: 4)
                .padding(.top, 12)

            Text("Add Attachment")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(ChatFlowTheme.warmBrown(colorScheme))

            VStack(spacing: 12) {
                AttachmentActionButton(
                    title: "Camera",
                    icon: "camera.fill",
                    action: onCamera
                )

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
            ChatFlowTheme.pageBackground(colorScheme)
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
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ChatFlowTheme.sage(colorScheme))
                    .frame(width: 28)

                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ChatFlowTheme.warmBrown(colorScheme))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ChatFlowTheme.warmBrown(colorScheme).opacity(0.4))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    return ChatView(
        auth: auth,
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device,
        uploadService: PreviewUploadService(),
        toastManager: ToastManager()
    )
    .environment(auth)
}

#Preview("With Messages") {
    let device = PreviewDevice()
    let auth = AuthManager()
    auth.storeCredentials(token: "preview-token", userId: "preview-user")
    auth.updateAdminStatus(true)
    return ChatView(
        auth: auth,
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device,
        uploadService: PreviewUploadService(),
        toastManager: ToastManager()
    )
    .environment(auth)
}
