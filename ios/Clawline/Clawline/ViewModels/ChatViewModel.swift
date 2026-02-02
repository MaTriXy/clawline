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
    private var didRestoreActiveChannel = false

    /// Returns messages for a specific channel (used by paged channel views)
    func messages(for channel: ChatChannelType) -> [Message] {
        guard let sessionKey = sessionKey(for: channel) else { return [] }
        return sessionMessages[sessionKey] ?? []
    }
    func sessionKey(for channel: ChatChannelType) -> String? {
        if channel == .admin, auth.isAdmin == false {
            return nil
        }
        let key = SessionKey.sessionKey(for: channel, userId: auth.currentUserId)
        if key == nil {
            self.logger.warning("Missing session key for channel=\(channel.rawValue, privacy: .public) userId=\(self.auth.currentUserId ?? "nil", privacy: .public)")
        }
        return key
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
    private(set) var typingSessionKey: String?
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var connectionAlert: ConnectionAlertSeverity? {
        didSet {
            logger.info("[trace] connectionAlert changed to \(String(describing: self.connectionAlert)) canSend=\(self.canSend)")
        }
    }
    private(set) var inputResetToken: Int = 0
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
    private var sessionMessages: [String: [Message]] = [:]
    private var lastServerMessageIdBySession: [String: String] = [:]
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
    private var downloadedAssetData: [String: Data] = [:]
    private let channelDefaults = UserDefaults.standard
    private var persistDebounceTasks: [String: Task<Void, Never>] = [:]
    private var pendingPersistPayloads: [String: [Message]] = [:]
    private let messageCacheLimit = 500
    private var restoredSessionKeys: Set<String> = []

    private struct PendingLocalMessage: Equatable {
        let id: String
        let sessionKey: String
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
            restoreLastServerMessageIdIfNeeded()
            restoreActiveChannelIfNeeded()
            if let sessionKey = sessionKey(for: activeChannel) {
                restoreLastServerMessageIdIfNeeded(for: sessionKey)
                restoreCachedMessagesIfNeeded(for: sessionKey)
            }
            if let personalKey = SessionKey.sessionKey(for: .personal, userId: auth.currentUserId) {
                restoreLastServerMessageIdIfNeeded(for: personalKey)
                restoreCachedMessagesIfNeeded(for: personalKey)
            }
            if auth.isAdmin {
                restoreLastServerMessageIdIfNeeded(for: SessionKey.dm)
                restoreCachedMessagesIfNeeded(for: SessionKey.dm)
            }
            switch connectionState {
            case .connected, .connecting, .reconnecting:
                break
            default:
                scheduleReconnect(immediate: true, reason: .authStateChange)
            }
        } else {
            didRestoreActiveChannel = false
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
        if let sessionKey = sessionKey(for: channel) {
            restoreLastServerMessageIdIfNeeded(for: sessionKey)
            restoreCachedMessagesIfNeeded(for: sessionKey)
            ensureSessionStorage(for: sessionKey)
            messages = sessionMessages[sessionKey] ?? []
            lastServerMessageId = lastServerMessageIdBySession[sessionKey]
        } else {
            messages = []
        }
        persistActiveChannel(channel)
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
        guard let sessionKey = sessionKey(for: channel) else {
            toastManager.show("Missing session key. Please reconnect.")
            isSending = false
            return
        }
        let placeholder = Message(
            id: clientId,
            role: .user,
            content: text,
            timestamp: Date(),
            streaming: false,
            attachments: makeDisplayAttachments(from: pendingAttachments),
            deviceId: deviceId,
            sessionKey: sessionKey,
            channelType: channel
        )
        appendMessage(placeholder)
        pendingLocalMessages.append(PendingLocalMessage(id: clientId, sessionKey: sessionKey))

        error = nil

        sendTask = Task { [weak self] in
            await self?.performSend(
                clientId: clientId,
                content: text,
                pendingAttachments: pendingAttachments,
                sessionKey: sessionKey
            )
        }
    }

    func retryMessage(messageId: String) {
        guard !isSending else { return }
        guard let (message, sessionKey, index) = findMessage(id: messageId) else { return }

        let clientId = "c_\(UUID().uuidString)"
        let retryMessage = Message(
            id: clientId,
            role: message.role,
            content: message.content,
            timestamp: Date(),
            streaming: false,
            attachments: message.attachments,
            deviceId: deviceId,
            sessionKey: sessionKey,
            channelType: message.channelType
        )

        var messageList = sessionMessages[sessionKey] ?? []
        messageList[index] = retryMessage
        setMessages(messageList, for: sessionKey)

        pendingLocalMessages.removeAll { $0.id == messageId }
        pendingLocalMessages.append(PendingLocalMessage(id: clientId, sessionKey: sessionKey))
        messageFailures.removeValue(forKey: messageId)

        isSending = true
        activeClientMessageId = clientId

        sendTask = Task { [weak self] in
            await self?.performRetrySend(
                clientId: clientId,
                content: retryMessage.content,
                attachments: retryMessage.attachments,
                sessionKey: sessionKey
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
        var sessionKeysToClear = Set(lastServerMessageIdBySession.keys)
        sessionKeysToClear.formUnion(sessionMessages.keys)
        if let userId = auth.currentUserId, !userId.isEmpty {
            sessionKeysToClear.insert(SessionKey.personal(userId: userId))
        }
        sessionKeysToClear.insert(SessionKey.dm)
        for key in sessionKeysToClear {
            persistLastServerMessageId(nil, for: key)
        }
        lastServerMessageId = nil
        lastServerMessageIdBySession.removeAll()
        auth.clearCredentials()
        clearConnectionAlert()
        messageFailures.removeAll()
        error = nil
        clearInput()
        sessionMessages = [:]
        messages = []
        activeChannel = .personal
        pendingLocalMessages.removeAll()
        isAssistantTyping = false
        typingSessionKey = nil
        shouldMorphTypingIndicator = false
        connectionStableTask?.cancel()
        connectionStableTask = nil
        restoredSessionKeys.removeAll()
        clearMessageCache()
    }

    func clearError() {
        error = nil
    }

    private func handleIncoming(_ message: Message) {
        let snippet = String(message.content.prefix(80))
        logger.info(
            "incoming id=\(message.id, privacy: .public) sessionKey=\(message.sessionKey, privacy: .public) channel=\(message.channelType.rawValue, privacy: .public) role=\(String(describing: message.role), privacy: .public) streaming=\(message.streaming, privacy: .public) deviceId=\(message.deviceId ?? "nil", privacy: .public) snippet=\"\(snippet, privacy: .public)\""
        )

        var resolvedMessage = message
        if message.role == .assistant,
           message.attachments.isEmpty,
           isNoReplyContent(message.content) {
            resolvedMessage = Message(
                id: message.id,
                role: message.role,
                content: "👀",
                timestamp: message.timestamp,
                streaming: false,
                attachments: [],
                deviceId: message.deviceId,
                sessionKey: message.sessionKey,
                channelType: message.channelType
            )
        }

        // Check if this is an assistant message arriving while typing indicator is visible.
        // If so, the UI should morph the typing indicator into this message instead of inserting new.
        if message.role == .assistant,
           isAssistantTyping,
           let typingSessionKey,
           typingSessionKey == message.sessionKey {
            shouldMorphTypingIndicator = true
            isAssistantTyping = false
            self.typingSessionKey = nil
        } else {
            shouldMorphTypingIndicator = false
        }

        if replacePendingMessageIfNeeded(with: resolvedMessage) {
            logger.info("incoming replacePending id=\(resolvedMessage.id, privacy: .public)")
            updateLastServerMessageIdIfNeeded(with: resolvedMessage)
            resolveAssetAttachmentsIfNeeded(for: resolvedMessage)
            return
        }

        ensureSessionStorage(for: resolvedMessage.sessionKey)
        var messageList = sessionMessages[resolvedMessage.sessionKey] ?? []
        if let existingIndex = messageList.firstIndex(where: { $0.id == resolvedMessage.id }) {
            logger.info("incoming duplicate id=\(resolvedMessage.id, privacy: .public) index=\(existingIndex, privacy: .public) sessionKey=\(resolvedMessage.sessionKey, privacy: .public)")
            messageList[existingIndex] = resolvedMessage
        } else {
            messageList.append(resolvedMessage)
        }
        setMessages(messageList, for: resolvedMessage.sessionKey)

        updateLastServerMessageIdIfNeeded(with: resolvedMessage)
        resolveAssetAttachmentsIfNeeded(for: resolvedMessage)
    }

    private func resolveAssetAttachmentsIfNeeded(for message: Message) {
        let needsDownload = message.attachments.contains { attachment in
            guard attachment.data == nil else { return false }
            guard let assetId = attachment.assetId else { return false }
            if downloadedAssetData[assetId] != nil { return true }
            if attachment.type == .image { return true }
            if attachment.type == .asset { return true }
            return attachment.mimeType?.lowercased().hasPrefix("image/") == true
        }
        guard needsDownload else { return }

        Task { [weak self] in
            guard let self else { return }
            var updatedAttachments = message.attachments
            var didUpdate = false

            for (index, attachment) in updatedAttachments.enumerated() {
                guard attachment.data == nil else { continue }
                guard let assetId = attachment.assetId else { continue }
                if let cached = downloadedAssetData[assetId] {
                    logger.info("attachment cache hit id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public) bytes=\(cached.count, privacy: .public)")
                    updatedAttachments[index] = Attachment(
                        id: attachment.id,
                        type: attachment.type,
                        mimeType: attachment.mimeType,
                        data: cached,
                        assetId: attachment.assetId,
                        filename: attachment.filename,
                        size: attachment.size ?? cached.count
                    )
                    didUpdate = true
                    continue
                }

                do {
                    logger.info("attachment download start id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public)")
                    let data = try await uploadService.download(assetId: assetId)
                    guard !data.isEmpty else { continue }
                    // Only attach data if it decodes as an image to avoid corrupt assets.
                    guard UIImage(data: data) != nil else {
                        logger.error("attachment download non-image id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public) bytes=\(data.count, privacy: .public)")
                        continue
                    }
                    downloadedAssetData[assetId] = data
                    logger.info("attachment download ok id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public) bytes=\(data.count, privacy: .public)")
                    updatedAttachments[index] = Attachment(
                        id: attachment.id,
                        type: attachment.type,
                        mimeType: attachment.mimeType,
                        data: data,
                        assetId: attachment.assetId,
                        filename: attachment.filename,
                        size: attachment.size ?? data.count
                    )
                    didUpdate = true
                } catch {
                    logger.error("attachment download failed id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }

            guard didUpdate else { return }
            let updatedMessage = Message(
                id: message.id,
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                streaming: message.streaming,
                attachments: updatedAttachments,
                deviceId: message.deviceId,
                sessionKey: message.sessionKey,
                channelType: message.channelType
            )

            await MainActor.run {
                self.ensureSessionStorage(for: updatedMessage.sessionKey)
                var messageList = self.sessionMessages[updatedMessage.sessionKey] ?? []
                if let existingIndex = messageList.firstIndex(where: { $0.id == updatedMessage.id }) {
                    messageList[existingIndex] = updatedMessage
                } else {
                    messageList.append(updatedMessage)
                }
                self.setMessages(messageList, for: updatedMessage.sessionKey)
            }
        }
    }

    private func replacePendingMessageIfNeeded(with message: Message) -> Bool {
        guard message.role == .user,
              message.deviceId == deviceId else {
            return false
        }

        guard let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.sessionKey == message.sessionKey }) else {
            return false
        }

        let pending = pendingLocalMessages.remove(at: pendingIndex)
        ensureSessionStorage(for: pending.sessionKey)
        var messageList = sessionMessages[pending.sessionKey] ?? []
        guard let placeholderIndex = messageList.firstIndex(where: { $0.id == pending.id }) else {
            return false
        }

        messageList[placeholderIndex] = message
        setMessages(messageList, for: pending.sessionKey)
        if activeClientMessageId == pending.id {
            activeClientMessageId = nil
        }
        messageFailures.removeValue(forKey: pending.id)
        return true
    }

    private func appendMessage(_ message: Message) {
        ensureSessionStorage(for: message.sessionKey)
        var messageList = sessionMessages[message.sessionKey] ?? []
        messageList.append(message)
        setMessages(messageList, for: message.sessionKey)
    }

    private func setMessages(_ newMessages: [Message], for sessionKey: String) {
        sessionMessages[sessionKey] = newMessages
        persistMessages(newMessages, for: sessionKey)
        if sessionKey == self.sessionKey(for: activeChannel) {
            messages = newMessages
            let total = newMessages.count
            let uniqueCount = Set(newMessages.map(\.id)).count
            if uniqueCount != total {
                logger.info("message list duplicate ids detected sessionKey=\(sessionKey, privacy: .public) total=\(total, privacy: .public) unique=\(uniqueCount, privacy: .public)")
            }
        }
    }

    private func ensureSessionStorage(for sessionKey: String) {
        if sessionMessages[sessionKey] == nil {
            sessionMessages[sessionKey] = []
        }
    }

    private func updateLastServerMessageIdIfNeeded(with message: Message) {
        guard message.id.hasPrefix("s_") else { return }
        lastServerMessageIdBySession[message.sessionKey] = message.id
        if message.sessionKey == sessionKey(for: activeChannel) {
            lastServerMessageId = message.id
        }
        persistLastServerMessageId(message.id, for: message.sessionKey)
    }


    private func removePlaceholder(withId id: String) {
        let keys = Array(sessionMessages.keys)
        for key in keys {
            var list = sessionMessages[key] ?? []
            if let index = list.firstIndex(where: { $0.id == id }) {
                list.remove(at: index)
                setMessages(list, for: key)
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
            isAssistantTyping = false
            typingSessionKey = nil
        case .disconnected:
            connectionStableTask?.cancel()
            connectionStableTask = nil
            beginConnectionAlert(message: "Not connected to provider.")
            scheduleReconnect(reason: .connectionStateDisconnected)
            isAssistantTyping = false
            typingSessionKey = nil
        case .failed(let err):
            connectionStableTask?.cancel()
            connectionStableTask = nil
            handleConnectionFailure(err)
            scheduleReconnect(reason: .connectionStateFailed)
            isAssistantTyping = false
            typingSessionKey = nil
        case .connecting, .reconnecting:
            beginConnectionAlert(message: "Reconnecting…", shouldAnnounce: false)
            isAssistantTyping = false
            typingSessionKey = nil
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
                    self.reconnectBackoff = min(self.reconnectBackoff * 2, .seconds(10))
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
                              sessionKey: String) async {
        defer { sendTask = nil }
        do {
            let wireAttachments = try await buildWireAttachments(from: pendingAttachments, content: content)
            try Task.checkCancellation()
            try await chatService.send(
                id: clientId,
                content: content,
                attachments: wireAttachments,
                sessionKey: sessionKey
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

    private func performRetrySend(clientId: String,
                                  content: String,
                                  attachments: [Attachment],
                                  sessionKey: String) async {
        defer { sendTask = nil }
        do {
            let wireAttachments = try await buildWireAttachments(from: attachments, content: content)
            try Task.checkCancellation()
            try await chatService.send(
                id: clientId,
                content: content,
                attachments: wireAttachments,
                sessionKey: sessionKey
            )
            await MainActor.run {
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
                logger.info("attachment inline id=\(attachment.id.uuidString, privacy: .public) bytes=\(attachment.size, privacy: .public)")
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
            logger.info("attachment uploaded id=\(attachment.id.uuidString, privacy: .public) assetId=\(assetId, privacy: .public) bytes=\(attachment.size, privacy: .public)")
            results.append(.asset(assetId: assetId))
        }
        return results
    }

    private func buildWireAttachments(from attachments: [Attachment],
                                      content: String) async throws -> [WireAttachment] {
        var results: [WireAttachment] = []
        let contentBytes = content.lengthOfBytes(using: .utf8)
        if contentBytes > PendingAttachment.totalPayloadByteLimit {
            throw AttachmentError.payloadTooLarge
        }

        var inlineBytes = 0
        for attachment in attachments {
            try Task.checkCancellation()

            if let assetId = attachment.assetId {
                results.append(.asset(assetId: assetId))
                continue
            }

            guard let data = attachment.data else {
                throw AttachmentError.invalidData
            }
            let mimeType = attachment.mimeType ?? "application/octet-stream"
            let canInline = PendingAttachment.inlineMimeTypes.contains(mimeType.lowercased())
                && data.count <= PendingAttachment.inlineByteLimit
                && inlineBytes + data.count <= PendingAttachment.inlineTotalByteLimit
                && contentBytes + inlineBytes + data.count <= PendingAttachment.totalPayloadByteLimit

            if canInline {
                results.append(.image(mimeType: mimeType, data: data))
                inlineBytes += data.count
                continue
            }

            if data.count > PendingAttachment.maxUploadByteLimit {
                throw AttachmentError.uploadTooLarge
            }

            let assetId = try await uploadService.upload(
                data: data,
                mimeType: mimeType,
                filename: nil
            )
            results.append(.asset(assetId: assetId))
        }

        return results
    }

    private func findMessage(id: String) -> (message: Message, sessionKey: String, index: Int)? {
        for (sessionKey, list) in sessionMessages {
            if let index = list.firstIndex(where: { $0.id == id }) {
                return (list[index], sessionKey, index)
            }
        }
        return nil
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
                assetId: nil,
                filename: pending.filename,
                size: pending.data.count
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
        inputResetToken &+= 1
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
            if isNoReply(code: code, message: message) {
                handleNoReplyAck(messageId: messageId)
                return
            }
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
        case .messageAcked:
            break
        case .connectionInterrupted(let reason):
            beginConnectionAlert(message: reason ?? "Connection interrupted.")
        case .userInfo(let info):
            let wasAdmin = auth.isAdmin
            auth.updateAdminStatus(info.isAdmin)
            if info.isAdmin {
                restoreCachedMessagesIfNeeded(for: SessionKey.dm)
                ensureSessionStorage(for: SessionKey.dm)
                if !wasAdmin {
                    toastManager.show("DM channel unlocked")
                }
                if activeChannel != .admin, persistedChannel() == .admin {
                    setActiveChannel(.admin)
                }
            } else if wasAdmin {
                toastManager.show("DM access revoked")
                if activeChannel == .admin {
                    setActiveChannel(.personal)
                }
            }
        case .typingStateChanged(let isTyping, let sessionKey):
            logger.info("typingStateChanged isTyping=\(isTyping, privacy: .public) sessionKey=\(sessionKey, privacy: .public) activeChannel=\(self.activeChannel.rawValue, privacy: .public)")
            // Track which session has the typing indicator
            // (used by paged TabView to show indicator only on the correct page)
            if isTyping {
                self.isAssistantTyping = true
                self.typingSessionKey = sessionKey
            } else if self.typingSessionKey == sessionKey {
                // Only clear if the stop event is for the same session we're tracking
                self.isAssistantTyping = false
                self.typingSessionKey = nil
            }
        }
    }

    private func channelDefaultsKey() -> String {
        if let userId = auth.currentUserId, !userId.isEmpty {
            return "clawline.lastChannel.\(userId)"
        }
        return "clawline.lastChannel"
    }

    private func lastServerMessageDefaultsKey(for sessionKey: String) -> String {
        var components = ["clawline.lastServerMessageId"]
        if let userId = auth.currentUserId, !userId.isEmpty {
            components.append(userId)
        }
        components.append(deviceId)
        components.append(sessionKey)
        return components.joined(separator: ".")
    }

    private func persistLastServerMessageId(_ value: String?, for sessionKey: String) {
        let key = lastServerMessageDefaultsKey(for: sessionKey)
        if let value, !value.isEmpty {
            channelDefaults.set(value, forKey: key)
        } else {
            channelDefaults.removeObject(forKey: key)
        }
    }

    private func restoreLastServerMessageIdIfNeeded() {
        guard lastServerMessageId == nil else { return }
        guard let sessionKey = sessionKey(for: activeChannel) else { return }
        restoreLastServerMessageIdIfNeeded(for: sessionKey)
        lastServerMessageId = lastServerMessageIdBySession[sessionKey]
    }

    private func restoreLastServerMessageIdIfNeeded(for sessionKey: String) {
        guard lastServerMessageIdBySession[sessionKey] == nil else { return }
        if let stored = channelDefaults.string(forKey: lastServerMessageDefaultsKey(for: sessionKey)) {
            lastServerMessageIdBySession[sessionKey] = stored
        }
    }

    private func messageCacheDirectoryURL() -> URL? {
        let fileManager = FileManager.default
        guard let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directoryURL = baseURL
            .appendingPathComponent("Clawline", isDirectory: true)
            .appendingPathComponent("MessageCache", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            logger.error("message cache create dir failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        return directoryURL
    }

    private func messageCacheURL(for sessionKey: String) -> URL? {
        guard let directoryURL = messageCacheDirectoryURL() else { return nil }
        let filename = safeFilename(for: sessionKey)
        return directoryURL.appendingPathComponent("\(filename).json")
    }

    private func safeFilename(for sessionKey: String) -> String {
        let sanitized = sessionKey
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return sanitized.isEmpty ? "session" : sanitized
    }

    private func restoreCachedMessagesIfNeeded(for sessionKey: String) {
        guard restoredSessionKeys.contains(sessionKey) == false else { return }
        restoredSessionKeys.insert(sessionKey)
        guard let url = messageCacheURL(for: sessionKey) else { return }
        Task.detached { [weak self, sessionKey, url] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: url) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let decoded = try decoder.decode([Message].self, from: data)
                let filtered = decoded.filter { $0.sessionKey == sessionKey }
                guard !filtered.isEmpty else {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if self.sessionKey(for: self.activeChannel) == sessionKey {
                            self.lastServerMessageId = nil
                        }
                        self.lastServerMessageIdBySession.removeValue(forKey: sessionKey)
                        self.persistLastServerMessageId(nil, for: sessionKey)
                    }
                    return
                }
                await MainActor.run { [weak self, filtered] in
                    guard let self else { return }
                    self.setMessages(filtered, for: sessionKey)
                    if let candidate = self.lastServerMessageId(from: filtered) {
                        self.lastServerMessageIdBySession[sessionKey] = candidate
                        if self.sessionKey(for: self.activeChannel) == sessionKey {
                            self.lastServerMessageId = candidate
                        }
                        self.persistLastServerMessageId(candidate, for: sessionKey)
                    }
                    self.logger.info("message cache restored sessionKey=\(sessionKey, privacy: .public) count=\(filtered.count, privacy: .public)")
                }
            } catch {
                let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
                logger.error("message cache decode failed sessionKey=\(sessionKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persistMessages(_ messages: [Message], for sessionKey: String) {
        guard let url = messageCacheURL(for: sessionKey) else { return }
        let payload = trimMessagesForCache(messages)
        pendingPersistPayloads[sessionKey] = payload
        persistDebounceTasks[sessionKey]?.cancel()
        persistDebounceTasks[sessionKey] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard let pendingPayload = self.pendingPersistPayloads[sessionKey] else { return }
            self.pendingPersistPayloads[sessionKey] = nil
            Task.detached { [pendingPayload, url, sessionKey] in
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                do {
                    let data = try encoder.encode(pendingPayload)
                    try data.write(to: url, options: [.atomic])
                } catch {
                    let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
                    logger.error("message cache write failed sessionKey=\(sessionKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func trimMessagesForCache(_ messages: [Message]) -> [Message] {
        guard messages.count > messageCacheLimit else { return messages }
        return Array(messages.suffix(messageCacheLimit))
    }

    private func lastServerMessageId(from messages: [Message]) -> String? {
        for message in messages.reversed() where message.id.hasPrefix("s_") {
            return message.id
        }
        return nil
    }

    private func clearMessageCache() {
        let fileManager = FileManager.default
        guard let directoryURL = messageCacheDirectoryURL() else { return }
        guard let contents = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        for fileURL in contents {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func persistActiveChannel(_ channel: ChatChannelType) {
        channelDefaults.set(channel.rawValue, forKey: channelDefaultsKey())
    }

    private func persistedChannel() -> ChatChannelType? {
        guard let raw = channelDefaults.string(forKey: channelDefaultsKey()) else { return nil }
        return ChatChannelType(rawValue: raw)
    }

    private func restoreActiveChannelIfNeeded() {
        guard !didRestoreActiveChannel else { return }
        didRestoreActiveChannel = true
        guard let stored = persistedChannel() else { return }
        if stored == .admin, auth.isAdmin == false {
            return
        }
        setActiveChannel(stored)
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
        case "session_locked":
            return "Session is locked. Message not delivered."
        case "connection_lost":
            return "Message not delivered — connection lost."
        case "invalid_channel":
            return "Cannot send to this channel."
        default:
            return "Message failed (\(code))."
        }
    }

    private func isNoReply(code: String, message: String?) -> Bool {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedCode == "no_reply" || normalizedCode == "no-reply" || normalizedCode.hasPrefix("no_reply") {
            return true
        }
        let trimmedMessage = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMessage.uppercased() == "NO_REPLY" {
            return true
        }
        let lowered = trimmedMessage.lowercased()
        if lowered.contains("no_reply") || lowered.contains("no reply") {
            return true
        }
        if lowered.contains("unable to deliver reply") {
            return true
        }
        return false
    }

    private func isNoReplyContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.uppercased() == "NO_REPLY"
    }

    private func handleNoReplyAck(messageId: String?) {
        var resolvedSessionKey: String?
        if let messageId,
           let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == messageId }) {
            resolvedSessionKey = pendingLocalMessages[pendingIndex].sessionKey
            pendingLocalMessages.remove(at: pendingIndex)
        }
        if let messageId, activeClientMessageId == messageId {
            activeClientMessageId = nil
        }
        isSending = false

        guard let sessionKey = resolvedSessionKey ?? sessionKey(for: activeChannel) else { return }
        let ack = Message(
            id: "s_no_reply_\(UUID().uuidString)",
            role: .assistant,
            content: "👀",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: sessionKey,
            channelType: SessionKey.channelType(for: sessionKey)
        )
        appendMessage(ack)
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
            hasher.combine(attachment.data?.count ?? 0)
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
        let activeKey = sessionKey(for: activeChannel)
        let cursor = activeKey.flatMap { lastServerMessageIdBySession[$0] } ?? lastServerMessageId
        return (auth.token, cursor)
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
