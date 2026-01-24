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
    private(set) var messages: [Message] = []
    private(set) var activeChannel: ChatChannelType = .personal

    /// Returns messages for a specific channel (used by paged channel views)
    func messages(for channel: ChatChannelType) -> [Message] {
        channelMessages[channel] ?? []
    }
    private(set) var lastServerMessageId: String?
    var inputContent: NSAttributedString = NSAttributedString() {
        didSet { pruneAttachmentData() }
    }
    var attachmentData: [UUID: PendingAttachment] = [:]
    private(set) var isSending: Bool = false
    private(set) var isAssistantTyping: Bool = false
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var connectionAlert: ConnectionAlertSeverity?
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
    private var lastForegroundReconnectTrigger: Date?
    private let foregroundReconnectDebounceInterval: TimeInterval = 5
    private var activeClientMessageId: String?
    private let connectionAlertGracePeriod: Duration
    private var connectionAlertTask: Task<Void, Never>?
    private var pendingConnectionErrorMessage: String?
    private var messageFailures: [String: MessageFailure] = [:]
    private var presentationCache: [PresentationCacheKey: PresentationCacheEntry] = [:]
    private var tableParseStates: [String: StreamingTableParseState] = [:]

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
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    func onAppear() async {
        guard observationTask == nil, auth.token != nil else { return }

        startObserving()
        scheduleReconnect(immediate: true)
    }

    func onDisappear() {
        observationTask?.cancel()
        observationTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelSend()
        chatService.disconnect()
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
            scheduleReconnect(immediate: false)
        }
    }

    private func startObserving() {
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
        clearInput()

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
        switch state {
        case .connected:
            reconnectBackoff = .seconds(1)
            reconnectTask?.cancel()
            reconnectTask = nil
            clearConnectionAlert()
            error = nil
            lastForegroundReconnectTrigger = nil
        case .disconnected:
            beginConnectionAlert(message: "Not connected to provider.")
            scheduleReconnect()
        case .failed(let err):
            handleConnectionFailure(err)
            scheduleReconnect()
        case .connecting, .reconnecting:
            beginConnectionAlert(message: "Reconnecting…", shouldAnnounce: false)
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard reconnectTask == nil, auth.token != nil else { return }

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let jitter = Duration.milliseconds(Int.random(in: 0...1000))
            let delay = immediate ? Duration.zero : reconnectBackoff + jitter
            if delay > .zero {
                try? await Task.sleep(forDuration: delay)
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
                    self.scheduleReconnect()
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
            let wireAttachments = try await buildWireAttachments(from: pendingAttachments)
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

    private func buildWireAttachments(from attachments: [PendingAttachment]) async throws -> [WireAttachment] {
        var results: [WireAttachment] = []
        for attachment in attachments {
            try Task.checkCancellation()
            if attachment.requiresUpload {
                let assetId = try await uploadService.upload(
                    data: attachment.data,
                    mimeType: attachment.mimeType,
                    filename: attachment.filename
                )
                results.append(.asset(assetId: assetId))
            } else {
                results.append(.image(mimeType: attachment.mimeType, data: attachment.data))
            }
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
            messageFailures[messageId] = MessageFailure(code: code, message: message)
            if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == messageId }) {
                pendingLocalMessages.remove(at: pendingIndex)
            }
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
        case .typingStateChanged(let isTyping):
            logger.info("typingStateChanged isTyping=\(isTyping, privacy: .public) (was \(self.isAssistantTyping, privacy: .public))")
            isAssistantTyping = isTyping
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
            return "Slow down a bit; you’re being rate limited."
        case "upload_failed_retryable":
            return "Upload failed; try again."
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
