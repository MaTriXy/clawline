//
//  ChatViewModel.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import Observation
import OSLog
import UIKit

enum ConnectionAlertSeverity: Equatable {
    case caution
    case critical
}

protocol ChatViewModelHosting: AnyObject {
    func handleSceneDidBecomeActive()
}

@Observable
@MainActor
final class ChatViewModel: ChatViewModelHosting {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
    private let instanceId = UUID().uuidString
    private(set) var messages: [Message] = []
    private(set) var activeChannel: ChatChannelType = .personal

    /// Returns messages for a specific channel (used by paged channel views)
    func messages(for channel: ChatChannelType) -> [Message] {
        channelMessages[channel] ?? []
    }
    private(set) var lastServerMessageId: String?
    var inputContent: NSAttributedString = NSAttributedString() {
        didSet {
            pruneAttachmentData()
            logger.info("[trace] inputContent len=\(self.inputContent.length) empty=\(self.inputContent.isEffectivelyEmpty) canSend=\(self.canSend) alert=\(String(describing: self.connectionAlert))")
        }
    }
    var attachmentData: [UUID: PendingAttachment] = [:]
    private(set) var isSending: Bool = false
    private(set) var isAssistantTyping: Bool = false
    private(set) var typingChannel: ChatChannelType?
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var connectionAlert: ConnectionAlertSeverity? {
        didSet {
            logger.info("[trace] connectionAlert changed to \(String(describing: self.connectionAlert)) canSend=\(self.canSend)")
        }
    }
    private(set) var error: String?
    private(set) var sendTask: Task<Void, Never>?
    /// Tracks if typing indicator was visible when a message arrives (for morph transition).
    private(set) var shouldMorphTypingIndicator: Bool = false

    var canSend: Bool {
        connectionAlert == nil && !inputContent.isEffectivelyEmpty
    }

    let toastManager: ToastManager

    private let auth: any AuthManaging
    private let chatService: any ChatServicing
    private let uploadService: any UploadServicing
    private let settings: SettingsManager
    private let deviceId: String
    private var observationTask: Task<Void, Never>?
    private var channelMessages: [ChatChannelType: [Message]] = [.personal: []]
    private var pendingLocalMessages: [PendingLocalMessage] = []
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBackoff: Duration = .seconds(1)
    private var lastReconnectAttemptAt: Date?
    private let minimumReconnectInterval: TimeInterval = 1.0
    private var lastReconnectRequestAt: Date?
    private var lastForegroundReconnectTrigger: Date?
    private let foregroundReconnectDebounceInterval: TimeInterval = 5
    private var connectionStableTask: Task<Void, Never>?
    private let stableConnectionInterval: Duration = .seconds(5)
    private var activeClientMessageId: String?
    private let connectionAlertGracePeriod: Duration
    private var connectionAlertTask: Task<Void, Never>?
    private var pendingConnectionErrorMessage: String?
    private var messageFailures: [String: MessageFailure] = [:]
    private var presentationCache: [PresentationCacheKey: PresentationCacheEntry] = [:]
    private var tableParseStates: [String: StreamingTableParseState] = [:]
    private var uploadedAssetIds: [UUID: String] = [:]

    private struct PendingLocalMessage: Equatable {
        let id: String
        let channel: ChatChannelType
    }

    init(auth: any AuthManaging,
         chatService: any ChatServicing,
         settings: SettingsManager,
         device: any DeviceIdentifying,
         uploadService: any UploadServicing,
         toastManager: ToastManager,
         connectionAlertGracePeriod: Duration = .seconds(2)) {
        logger.info("ChatViewModel init id=\(self.instanceId, privacy: .public)")
        self.auth = auth
        self.chatService = chatService
        self.settings = settings
        self.deviceId = device.deviceId
        self.uploadService = uploadService
        self.toastManager = toastManager
        self.connectionAlertGracePeriod = connectionAlertGracePeriod
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarningNotification),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAuthStateChangeNotification),
            name: Notification.Name("AuthStateDidChange"),
            object: nil
        )
        handleAuthStateChange()
    }

    deinit {
        logger.info("ChatViewModel deinit id=\(self.instanceId, privacy: .public)")
        NotificationCenter.default.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: Notification.Name("AuthStateDidChange"), object: nil)
    }

    func onAppear() async {
        guard observationTask == nil, auth.token != nil else { return }

        logger.info("ChatViewModel onAppear id=\(self.instanceId, privacy: .public)")
        startObserving()
        scheduleReconnect(immediate: true, reason: .onAppear)
    }

    func onDisappear() {
        logger.info("ChatViewModel onDisappear id=\(self.instanceId, privacy: .public)")
        observationTask?.cancel()
        observationTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionStableTask?.cancel()
        connectionStableTask = nil
        cancelSend()
        chatService.disconnect()
    }

    @objc private func handleAuthStateChangeNotification() {
        handleAuthStateChange()
    }

    private func handleAuthStateChange() {
        if auth.token != nil {
            if observationTask == nil {
                startObserving()
            }
            switch connectionState {
            case .connected, .connecting, .reconnecting:
                break
            default:
                scheduleReconnect(immediate: true, reason: .authStateChange)
            }
        } else {
            observationTask?.cancel()
            observationTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            connectionStableTask?.cancel()
            connectionStableTask = nil
            chatService.disconnect()
        }
    }

    func setActiveChannel(_ channel: ChatChannelType) {
        if channel == .admin, auth.isAdmin == false {
            return
        }
        guard activeChannel != channel else { return }
        activeChannel = channel
        ensureChannelStorage(for: channel)
        messages = channelMessages[channel] ?? []
    }

    func handleSceneDidBecomeActive() {
        guard auth.token != nil else { return }
        logger.info("ChatViewModel sceneDidBecomeActive id=\(self.instanceId, privacy: .public) state=\(String(describing: self.connectionState), privacy: .public)")
        switch connectionState {
        case .connected, .connecting, .reconnecting:
            break
        default:
            guard reconnectTask == nil else { return }
            let now = Date()
            if let last = lastForegroundReconnectTrigger,
               now.timeIntervalSince(last) < foregroundReconnectDebounceInterval {
                return
            }
            lastForegroundReconnectTrigger = now
            scheduleReconnect(immediate: false, reason: .sceneDidBecomeActive)
        }
    }

    private func startObserving() {
        logger.info("ChatViewModel startObserving id=\(self.instanceId, privacy: .public)")
        observationTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await self?.observeMessages()
                }

                group.addTask { [weak self] in
                    await self?.observeConnectionState()
                }

                group.addTask { [weak self] in
                    await self?.observeServiceEvents()
                }
            }
        }
    }

    @MainActor
    private func observeMessages() async {
        for await message in chatService.incomingMessages {
            handleIncoming(message)
        }
    }

    @MainActor
    private func observeConnectionState() async {
        for await state in chatService.connectionState {
            logger.info("ChatViewModel stateStream id=\(self.instanceId, privacy: .public) state=\(String(describing: state), privacy: .public)")
            connectionState = state
            handleConnectionState(state)
        }
    }

    @MainActor
    private func observeServiceEvents() async {
        for await event in chatService.serviceEvents {
            handle(serviceEvent: event)
        }
    }

    func send() {
        guard !isSending else { return }
        isSending = true  // Set immediately to prevent double-tap race condition

        pruneAttachmentData()
        let (text, pendingIds) = inputContent.contentForSending()
        let pendingAttachments = pendingIds.compactMap { attachmentData[$0] }

        guard !text.isEmpty || !pendingAttachments.isEmpty else {
            isSending = false
            return
        }

        if pendingAttachments.isEmpty && handleSlashCommand(text) {
            isSending = false
            return
        }

        let clientId = "c_\(UUID().uuidString)"
        activeClientMessageId = clientId

        let channel = activeChannel
        let placeholder = Message(
            id: clientId,
            role: .user,
            content: text,
            timestamp: Date(),
            streaming: false,
            attachments: makeDisplayAttachments(from: pendingAttachments),
            deviceId: deviceId,
            channelType: channel
        )
        appendMessage(placeholder)
        pendingLocalMessages.append(PendingLocalMessage(id: clientId, channel: channel))

        error = nil

        sendTask = Task { [weak self] in
            await self?.performSend(
                clientId: clientId,
                content: text,
                pendingAttachments: pendingAttachments,
                channelType: channel
            )
        }
    }

    func cancelSend() {
        guard isSending else { return }
        sendTask?.cancel()
        sendTask = nil
        if let activeClientMessageId {
            removePlaceholder(withId: activeClientMessageId)
        }
        activeClientMessageId = nil
        isSending = false
    }

    func stageAttachments(_ attachments: [PendingAttachment]) {
        attachments.forEach { attachmentData[$0.id] = $0 }
    }

    func logout() {
        cancelSend()
        observationTask?.cancel()
        observationTask = nil
        chatService.disconnect()
        auth.clearCredentials()
        clearConnectionAlert()
        messageFailures.removeAll()
        error = nil
        clearInput()
        channelMessages = [.personal: []]
        messages = []
        activeChannel = .personal
        pendingLocalMessages.removeAll()
        connectionStableTask?.cancel()
        connectionStableTask = nil
    }

    func clearError() {
        error = nil
    }

    private func handleIncoming(_ message: Message) {
        let snippet = String(message.content.prefix(80))
        logger.info(
            "incoming id=\(message.id, privacy: .public) channel=\(message.channelType.rawValue, privacy: .public) role=\(String(describing: message.role), privacy: .public) streaming=\(message.streaming, privacy: .public) deviceId=\(message.deviceId ?? "nil", privacy: .public) snippet=\"\(snippet, privacy: .public)\""
        )

        // Check if this is an assistant message arriving while typing indicator is visible.
        // If so, the UI should morph the typing indicator into this message instead of inserting new.
        if message.role == .assistant && isAssistantTyping {
            shouldMorphTypingIndicator = true
            isAssistantTyping = false
        } else {
            shouldMorphTypingIndicator = false
        }

        if replacePendingMessageIfNeeded(with: message) {
            logger.info("incoming replacePending id=\(message.id, privacy: .public)")
            updateLastServerMessageIdIfNeeded(with: message)
            return
        }

        ensureChannelStorage(for: message.channelType)
        var channelList = channelMessages[message.channelType] ?? []
        if let existingIndex = channelList.firstIndex(where: { $0.id == message.id }) {
            logger.info("incoming duplicate id=\(message.id, privacy: .public) index=\(existingIndex, privacy: .public) channel=\(message.channelType.rawValue, privacy: .public)")
            channelList[existingIndex] = message
        } else {
            channelList.append(message)
        }
        setMessages(channelList, for: message.channelType)

        updateLastServerMessageIdIfNeeded(with: message)
    }

    private func replacePendingMessageIfNeeded(with message: Message) -> Bool {
        guard message.role == .user,
              message.deviceId == deviceId else {
            return false
        }

        guard let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.channel == message.channelType }) else {
            return false
        }

        let pending = pendingLocalMessages.remove(at: pendingIndex)
        ensureChannelStorage(for: pending.channel)
        var channelList = channelMessages[pending.channel] ?? []
        guard let placeholderIndex = channelList.firstIndex(where: { $0.id == pending.id }) else {
            return false
        }

        channelList[placeholderIndex] = message
        setMessages(channelList, for: pending.channel)
        if activeClientMessageId == pending.id {
            activeClientMessageId = nil
        }
        return true
    }

    private func appendMessage(_ message: Message) {
        ensureChannelStorage(for: message.channelType)
        var channelList = channelMessages[message.channelType] ?? []
        channelList.append(message)
        setMessages(channelList, for: message.channelType)
    }

    private func setMessages(_ newMessages: [Message], for channel: ChatChannelType) {
        channelMessages[channel] = newMessages
        if channel == activeChannel {
            messages = newMessages
            let total = newMessages.count
            let uniqueCount = Set(newMessages.map(\.id)).count
            if uniqueCount != total {
                logger.info("message list duplicate ids detected channel=\(channel.rawValue, privacy: .public) total=\(total, privacy: .public) unique=\(uniqueCount, privacy: .public)")
            }
        }
    }

    private func ensureChannelStorage(for channel: ChatChannelType) {
        if channelMessages[channel] == nil {
            channelMessages[channel] = []
        }
    }

    private func updateLastServerMessageIdIfNeeded(with message: Message) {
        guard message.id.hasPrefix("s_") else { return }
        lastServerMessageId = message.id
    }


    private func removePlaceholder(withId id: String) {
        let channels = Array(channelMessages.keys)
        for channel in channels {
            var list = channelMessages[channel] ?? []
            if let index = list.firstIndex(where: { $0.id == id }) {
                list.remove(at: index)
                setMessages(list, for: channel)
                break
            }
        }
        if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == id }) {
            pendingLocalMessages.remove(at: pendingIndex)
        }
        messageFailures.removeValue(forKey: id)
    }

    private func handleConnectionState(_ state: ConnectionState) {
        logger.info("ChatViewModel handleConnectionState id=\(self.instanceId, privacy: .public) state=\(String(describing: state), privacy: .public)")
        switch state {
        case .connected:
            connectionStableTask?.cancel()
            connectionStableTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(forDuration: self.stableConnectionInterval)
                await MainActor.run {
                    if self.connectionState == .connected {
                        self.reconnectBackoff = .seconds(1)
                    }
                }
            }
            reconnectTask?.cancel()
            reconnectTask = nil
            clearConnectionAlert()
            error = nil
            lastForegroundReconnectTrigger = nil
        case .disconnected:
            connectionStableTask?.cancel()
            connectionStableTask = nil
            beginConnectionAlert(message: "Not connected to provider.")
            scheduleReconnect(reason: .connectionStateDisconnected)
        case .failed(let err):
            connectionStableTask?.cancel()
            connectionStableTask = nil
            handleConnectionFailure(err)
            scheduleReconnect(reason: .connectionStateFailed)
        case .connecting, .reconnecting:
            beginConnectionAlert(message: "Reconnecting…", shouldAnnounce: false)
        }
    }

    private enum ReconnectTrigger: String {
        case onAppear
        case sceneDidBecomeActive
        case connectionStateDisconnected
        case connectionStateFailed
        case authStateChange
    }

    private func scheduleReconnect(immediate: Bool = false, reason: ReconnectTrigger = .connectionStateFailed) {
        let now = Date()
        if let lastRequest = lastReconnectRequestAt {
            let elapsed = now.timeIntervalSince(lastRequest)
            if elapsed < minimumReconnectInterval {
                logger.info("reconnect debounced reason=\(reason.rawValue, privacy: .public) elapsed=\(elapsed, privacy: .public)")
                return
            }
        }
        lastReconnectRequestAt = now
        guard reconnectTask == nil, auth.token != nil else {
            logger.info("reconnect suppressed reason=\(reason.rawValue, privacy: .public) reconnectTask=\(self.reconnectTask != nil, privacy: .public) hasToken=\(self.auth.token != nil, privacy: .public)")
            return
        }

        logger.info("reconnect scheduled id=\(self.instanceId, privacy: .public) reason=\(reason.rawValue, privacy: .public) immediate=\(immediate, privacy: .public) backoff=\(String(describing: self.reconnectBackoff), privacy: .public) state=\(String(describing: self.connectionState), privacy: .public)")

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let jitter = Duration.milliseconds(Int.random(in: 0...1000))
            var delay = immediate ? Duration.zero : reconnectBackoff + jitter
            if let lastAttempt = self.lastReconnectAttemptAt {
                let elapsed = Date().timeIntervalSince(lastAttempt)
                let minDelay = max(0, self.minimumReconnectInterval - elapsed)
                delay = max(delay, .seconds(minDelay))
            }
            if delay > .zero {
                try? await Task.sleep(forDuration: delay)
            }
            await MainActor.run {
                self.lastReconnectAttemptAt = Date()
            }
            let snapshot = await MainActor.run { self.connectionSnapshot() }
            guard let token = snapshot.token else { return }
            await MainActor.run {
                self.auth.refreshAdminStatusFromToken()
            }

            do {
                try await self.chatService.connect(token: token, lastMessageId: snapshot.lastMessageId)
                await MainActor.run {
                    self.reconnectBackoff = .seconds(1)
                    self.reconnectTask = nil
                    self.error = nil
                }
            } catch {
                await MainActor.run {
                    if let providerError = error as? ProviderChatService.Error {
                        switch providerError {
                        case .authFailed:
                            self.enterCriticalConnectionAlert(message: providerError.errorDescription ?? "Authentication failed.")
                            self.reconnectTask = nil
                            self.logout()
                            return
                        case .missingBaseURL:
                            self.enterCriticalConnectionAlert(message: providerError.errorDescription ?? "No provider configured.")
                        default:
                            self.beginConnectionAlert(message: providerError.errorDescription ?? "Connection interrupted.")
                        }
                    } else {
                        self.beginConnectionAlert(message: "Failed to connect: \(error.localizedDescription)")
                    }
                    self.reconnectBackoff = min(self.reconnectBackoff * 2, .seconds(30))
                    self.reconnectTask = nil
                    self.scheduleReconnect(reason: .connectionStateFailed)
                }
            }
        }
    }

    private func handleConnectionFailure(_ error: Swift.Error) {
        if shouldDebounceConnectionError(error) {
            beginConnectionAlert(message: error.localizedDescription)
        } else {
            enterCriticalConnectionAlert(message: error.localizedDescription)
        }
    }

    private func shouldDebounceConnectionError(_ error: Swift.Error) -> Bool {
        guard let providerError = error as? ProviderChatService.Error else {
            return true
        }
        switch providerError {
        case .authFailed, .missingBaseURL:
            return false
        default:
            return true
        }
    }

    private func beginConnectionAlert(message: String, shouldAnnounce: Bool = true) {
        let resolvedMessage = message.isEmpty ? "Connection interrupted." : message
        pendingConnectionErrorMessage = resolvedMessage
        if connectionAlert != .critical {
            connectionAlert = .caution
            error = nil
        }
        if shouldAnnounce {
            toastManager.show(resolvedMessage)
        }
        connectionAlertTask?.cancel()
        connectionAlertTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(forDuration: self.connectionAlertGracePeriod)
            await MainActor.run {
                guard self.connectionAlert == .caution else { return }
                self.connectionAlert = .critical
                self.error = self.pendingConnectionErrorMessage
                self.toastManager.show(self.pendingConnectionErrorMessage ?? resolvedMessage)
            }
        }
    }

    private func enterCriticalConnectionAlert(message: String) {
        let resolvedMessage = message.isEmpty ? "Connection interrupted." : message
        connectionAlertTask?.cancel()
        connectionAlertTask = nil
        pendingConnectionErrorMessage = resolvedMessage
        connectionAlert = .critical
        error = resolvedMessage
        toastManager.show(resolvedMessage)
    }

    private func clearConnectionAlert() {
        connectionAlertTask?.cancel()
        connectionAlertTask = nil
        pendingConnectionErrorMessage = nil
        connectionAlert = nil
    }

    private func performSend(clientId: String,
                              content: String,
                              pendingAttachments: [PendingAttachment],
                              channelType: ChatChannelType) async {
        defer { sendTask = nil }
        do {
            let wireAttachments = try await buildWireAttachments(from: pendingAttachments, content: content)
            try Task.checkCancellation()
            try await chatService.send(
                id: clientId,
                content: content,
                attachments: wireAttachments,
                channelType: channelType
            )
            await MainActor.run {
                clearInput()
                isSending = false
                activeClientMessageId = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                removePlaceholder(withId: clientId)
                isSending = false
                activeClientMessageId = nil
            }
        } catch let attachmentError as AttachmentError {
            await MainActor.run {
                toastManager.show(error: attachmentError)
                removePlaceholder(withId: clientId)
                isSending = false
                activeClientMessageId = nil
            }
        } catch {
            await MainActor.run {
                toastManager.show(error.localizedDescription)
                removePlaceholder(withId: clientId)
                isSending = false
                activeClientMessageId = nil
            }
        }
    }

    private func buildWireAttachments(from attachments: [PendingAttachment],
                                      content: String) async throws -> [WireAttachment] {
        var results: [WireAttachment] = []
        let contentBytes = content.lengthOfBytes(using: .utf8)
        if contentBytes > PendingAttachment.totalPayloadByteLimit {
            throw AttachmentError.payloadTooLarge
        }

        var inlineBytes = 0
        for attachment in attachments {
            try Task.checkCancellation()
            let canInline = attachment.isInlineCapableImage
                && attachment.size <= PendingAttachment.inlineByteLimit
                && inlineBytes + attachment.size <= PendingAttachment.inlineTotalByteLimit
                && contentBytes + inlineBytes + attachment.size <= PendingAttachment.totalPayloadByteLimit

            if canInline {
                results.append(.image(mimeType: attachment.mimeType, data: attachment.data))
                inlineBytes += attachment.size
                continue
            }

            if attachment.size > PendingAttachment.maxUploadByteLimit {
                throw AttachmentError.uploadTooLarge
            }

            if let cachedAssetId = uploadedAssetIds[attachment.id] {
                results.append(.asset(assetId: cachedAssetId))
                continue
            }

            let assetId = try await uploadService.upload(
                data: attachment.data,
                mimeType: attachment.mimeType,
                filename: attachment.filename
            )
            uploadedAssetIds[attachment.id] = assetId
            results.append(.asset(assetId: assetId))
        }
        return results
    }

    private func makeDisplayAttachments(from pendingAttachments: [PendingAttachment]) -> [Attachment] {
        pendingAttachments.map { pending in
            let type: AttachmentType
            if pending.mimeType.lowercased().hasPrefix("image/") {
                type = .image
            } else {
                type = .document
            }
            return Attachment(
                id: pending.id.uuidString,
                type: type,
                mimeType: pending.mimeType,
                data: type == .image ? pending.data : nil,
                assetId: nil
            )
        }
    }

    private func pruneAttachmentData() {
        let referencedIds = Set(inputContent.pendingAttachmentIds())
        let orphanedKeys = attachmentData.keys.filter { !referencedIds.contains($0) }
        orphanedKeys.forEach { attachmentData.removeValue(forKey: $0) }
        orphanedKeys.forEach { uploadedAssetIds.removeValue(forKey: $0) }
    }

    private func handleMemoryWarning() {
        presentationCache.removeAll()
        tableParseStates.removeAll()
    }

    @MainActor
    @objc
    private func handleMemoryWarningNotification() {
        handleMemoryWarning()
    }

    private func clearInput() {
        inputContent = NSAttributedString(string: "")
        attachmentData.removeAll()
        uploadedAssetIds.removeAll()
    }


    func presentation(for message: Message, metrics: ChatFlowTheme.Metrics) -> MessagePresentation {
        let key = PresentationCacheKey(messageID: message.id, isCompact: metrics.isCompact)
        let fingerprint = presentationFingerprint(for: message)
        if let cached = presentationCache[key], cached.fingerprint == fingerprint {
            return cached.presentation
        }

        var state = tableParseStates[message.id] ?? StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &state
        )
        var resolvedPresentation = presentation

        if !message.streaming, state.isDirty {
            var canonicalState = StreamingTableParseState()
            resolvedPresentation = MessagePresentationBuilder.build(
                from: message,
                metrics: metrics,
                streamingState: &canonicalState
            )
        }

        if message.streaming {
            tableParseStates[message.id] = state
        } else {
            tableParseStates[message.id] = nil
        }

        presentationCache[key] = PresentationCacheEntry(
            fingerprint: fingerprint,
            presentation: resolvedPresentation
        )
        trimPresentationCache()
        trimStreamingStates()
        return resolvedPresentation
    }

    func failureMessage(for messageId: String) -> String? {
        guard let failure = messageFailures[messageId] else { return nil }
        return userFacingMessage(for: failure.code, fallback: failure.message)
    }

    private func handle(serviceEvent: ChatServiceEvent) {
        switch serviceEvent {
        case .messageError(let messageId, let code, let message):
            let resolved = userFacingMessage(for: code, fallback: message)
            toastManager.show(resolved)
            guard let messageId else { return }
            // Remove the optimistic placeholder from the UI so user knows message wasn't sent
            removePlaceholder(withId: messageId)
            if activeClientMessageId == messageId {
                activeClientMessageId = nil
            }
            isSending = false
        case .connectionInterrupted(let reason):
            beginConnectionAlert(message: reason ?? "Connection interrupted.")
        case .userInfo(let info):
            let wasAdmin = auth.isAdmin
            auth.updateAdminStatus(info.isAdmin)
            if info.isAdmin {
                ensureChannelStorage(for: .admin)
                if !wasAdmin {
                    toastManager.show("DM channel unlocked")
                }
            } else if wasAdmin {
                toastManager.show("DM access revoked")
                if activeChannel == .admin {
                    setActiveChannel(.personal)
                }
            }
        case .typingStateChanged(let isTyping, let channel):
            logger.info("typingStateChanged isTyping=\(isTyping, privacy: .public) channel=\(channel.rawValue, privacy: .public) activeChannel=\(self.activeChannel.rawValue, privacy: .public)")
            // Track which channel has the typing indicator
            // (used by paged TabView to show indicator only on the correct page)
            if isTyping {
                self.isAssistantTyping = true
                self.typingChannel = channel
            } else if self.typingChannel == channel {
                // Only clear if the stop event is for the same channel we're tracking
                self.isAssistantTyping = false
                self.typingChannel = nil
            }
        }
    }

    private func userFacingMessage(for code: String, fallback: String?) -> String {
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        switch code {
        case "invalid_message":
            return "Provider rejected that message."
        case "payload_too_large":
            return "That message is too large to send."
        case "asset_not_found":
            return "Attachment could not be found on the provider."
        case "rate_limited":
            return "Slow down a bit; you're being rate limited."
        case "upload_failed_retryable":
            return "Upload failed; try again."
        case "queue_failed", "queue_full":
            return "Message couldn't be queued. Try again."
        case "connection_lost":
            return "Message not delivered — connection lost."
        case "invalid_channel":
            return "Cannot send to this channel."
        default:
            return "Message failed (\(code))."
        }
    }

    private func trimPresentationCache() {
        let activeIds = Set(messages.map(\.id))
        guard !activeIds.isEmpty else { return }
        presentationCache = presentationCache.filter { activeIds.contains($0.key.messageID) }
    }

    private func trimStreamingStates(maxEntries: Int = 120) {
        let activeIds = Set(messages.prefix(100).map(\.id))
        tableParseStates = tableParseStates.filter { activeIds.contains($0.key) }
        guard tableParseStates.count > maxEntries else { return }
        let overflow = tableParseStates.count - maxEntries
        for key in tableParseStates.keys.prefix(overflow) {
            tableParseStates.removeValue(forKey: key)
        }
    }

    private struct MessageFailure: Equatable {
        let code: String
        let message: String?
    }

    private struct PresentationCacheKey: Hashable {
        let messageID: String
        let isCompact: Bool
    }

    private struct PresentationCacheEntry {
        let fingerprint: Int
        let presentation: MessagePresentation
    }

    private func presentationFingerprint(for message: Message) -> Int {
        var hasher = Hasher()
        hasher.combine(message.id)
        hasher.combine(message.content)
        hasher.combine(message.streaming)
        hasher.combine(message.attachments.count)
        for attachment in message.attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.mimeType ?? "")
            hasher.combine(attachment.assetId ?? "")
            hasher.combine(attachment.type.rawValue)
        }
        return hasher.finalize()
    }

    private func handleSlashCommand(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        switch lowercased {
        case "/logout":
            clearInput()
            logout()
            return true
        case "/settings":
            clearInput()
            settings.toggleSettings()
            return true
        default:
            return false
        }
    }

    @MainActor
    private func connectionSnapshot() -> (token: String?, lastMessageId: String?) {
        (auth.token, lastServerMessageId)
    }

#if DEBUG
    func debugConnectionSnapshot() -> (token: String?, lastMessageId: String?) {
        connectionSnapshot()
    }

    func debugConnectionAlert() -> ConnectionAlertSeverity? {
        connectionAlert
    }

    func debugPresentationCacheSize() -> Int {
        presentationCache.count
    }

    func debugTableParseStateSize() -> Int {
        tableParseStates.count
    }
#endif
}
