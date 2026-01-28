//
//  ProviderChatService.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation
import OSLog

private final class AsyncStreamBroadcaster<Element> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let lock = NSLock()

    func stream(initial: Element? = nil) -> AsyncStream<Element> {
        AsyncStream { [weak self] continuation in
            let id = UUID()
            self?.lock.lock()
            self?.continuations[id] = continuation
            self?.lock.unlock()
            if let initial {
                continuation.yield(initial)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.remove(id)
                }
            }
        }
    }

    func send(_ value: Element) {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        current.forEach { $0.yield(value) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

final class ProviderChatService: ChatServicing {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ProviderChatService")
    private let messageLogger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
    enum Error: Swift.Error, LocalizedError {
        case missingBaseURL
        case notConnected
        case authFailed(String)
        case tokenRevoked(String)
        case sessionReplaced
        case invalidMessageId
        case serverError(code: String, message: String?)

        var errorDescription: String? {
            switch self {
            case .missingBaseURL:
                return "No provider configured. Pair with a provider first."
            case .notConnected:
                return "Could not send; not connected."
            case .authFailed(let reason):
                return "Authentication failed: \(reason)"
            case .tokenRevoked(let reason):
                return "Access revoked: \(reason)"
            case .sessionReplaced:
                return "Session replaced by another device."
            case .invalidMessageId:
                return "Client message IDs must start with c_."
            case .serverError(let code, let message):
                if let message, !message.isEmpty {
                    return message
                }
                return "Server error (\(code))."
            }
        }
    }

    private struct AuthPayload: Encodable {
        let type = "auth"
        let protocolVersion = 1
        let token: String
        let deviceId: String
        let lastMessageId: String?
    }

    private struct Envelope: Decodable {
        let type: String
    }

    private struct AuthResultPayload: Decodable {
        let type: String
        let success: Bool
        let userId: String?
        let isAdmin: Bool?
        let reason: String?
    }

    private struct AckPayload: Decodable {
        let type: String
        let id: String
    }

    private struct ErrorPayload: Decodable {
        let type: String
        let code: String
        let message: String?
        let messageId: String?
    }

    private struct UserInfoPayload: Decodable {
        let type: String
        let userId: String
        let isAdmin: Bool
    }

    private struct EventEnvelope: Decodable {
        let type: String
        let event: String
    }

    private struct ActivityEventPayload: Decodable {
        let type: String
        let event: String
        let payload: ActivityPayload

        struct ActivityPayload: Decodable {
            let isActive: Bool
            let sessionKey: String?
            let channelType: String?
        }
    }

    private struct PendingMessage {
        let payload: ClientMessagePayload
        var retryTask: Task<Void, Never>?
    }

    private let connector: any WebSocketConnecting
    private let deviceId: String
    private let baseURLProvider: () -> URL?
    private let userIdProvider: () -> String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let ackInterval: Duration = .seconds(5)

    private let messageBroadcaster = AsyncStreamBroadcaster<Message>()
    private let stateBroadcaster = AsyncStreamBroadcaster<ConnectionState>()
    private let serviceEventBroadcaster = AsyncStreamBroadcaster<ChatServiceEvent>()
    private var lastConnectionState: ConnectionState = .disconnected

    private var socket: (any WebSocketClient)?
    private var receiveTask: Task<Void, Never>?
    private var authContinuation: CheckedContinuation<Void, Swift.Error>?
    private var pendingMessages: [String: PendingMessage] = [:]
    private var shouldNotifyDisconnect = true
    private var pendingDisconnectReason: String?
    private var isConnecting = false

    init(connector: any WebSocketConnecting,
         deviceId: String,
         baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
         userIdProvider: @escaping () -> String? = { nil },
         encoder: JSONEncoder = JSONEncoder(),
         decoder: JSONDecoder = JSONDecoder()) {
        self.connector = connector
        self.deviceId = deviceId
        self.baseURLProvider = baseURLProvider
        self.userIdProvider = userIdProvider
        self.encoder = encoder
        self.decoder = decoder
    }

    var incomingMessages: AsyncStream<Message> { messageBroadcaster.stream() }
    var connectionState: AsyncStream<ConnectionState> { stateBroadcaster.stream(initial: lastConnectionState) }
    var serviceEvents: AsyncStream<ChatServiceEvent> { serviceEventBroadcaster.stream() }

    func connect(token: String, lastMessageId: String?) async throws {
        if isConnecting {
            logger.info("connect suppressed: already connecting")
            resolveAuthContinuation(with: .failure(Error.notConnected))
            return
        }
        isConnecting = true
        defer { isConnecting = false }

        guard let baseURL = baseURLProvider(),
              let wsURL = makeWebSocketURL(from: baseURL) else {
            throw Error.missingBaseURL
        }

        try await teardownConnection()
        shouldNotifyDisconnect = true
        pendingDisconnectReason = nil

        logger.info("connect start ws=\(wsURL.absoluteString, privacy: .public)")
        updateState(.connecting)
        let client = try await connector.connect(to: wsURL)
        socket = client
        startListening(on: client)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            authContinuation = continuation
            Task {
                do {
                    let authPayload = AuthPayload(
                        token: token,
                        deviceId: deviceId,
                        lastMessageId: lastMessageId
                    )
                    let data = try encoder.encode(authPayload)
                    guard let text = String(data: data, encoding: .utf8) else {
                        self.resolveAuthContinuation(with: .failure(Error.notConnected))
                        return
                    }
                    try await client.send(text: text)
                } catch {
                    self.resolveAuthContinuation(with: .failure(error))
                }
            }
        }
    }

    func disconnect() {
        logger.info("disconnect requested")
        performDisconnect(shouldNotify: false)
    }

    private func performDisconnect(shouldNotify: Bool, reason: String? = nil) {
        logger.info("performDisconnect notify=\(shouldNotify, privacy: .public) reason=\(reason ?? "nil", privacy: .public)")
        shouldNotifyDisconnect = shouldNotify
        pendingDisconnectReason = reason
        resolveAuthContinuation(with: .failure(Error.notConnected))
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close(with: .normalClosure)
        socket = nil
        if !pendingMessages.isEmpty {
            for (messageId, pending) in pendingMessages {
                pending.retryTask?.cancel()
                emitServiceEvent(.messageError(
                    messageId: messageId,
                    code: "connection_lost",
                    message: "Message not delivered - connection lost"
                ))
            }
        }
        pendingMessages.removeAll()
        logger.info("state -> disconnected (performDisconnect)")
        updateState(.disconnected)
    }

    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String) async throws {
        guard let socket else {
            throw Error.notConnected
        }
        guard id.hasPrefix("c_") else {
            throw Error.invalidMessageId
        }

        let payload = ClientMessagePayload(id: id, content: content, attachments: attachments, sessionKey: sessionKey)
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else { return }

        pendingMessages[id]?.retryTask?.cancel()
        let retryTask = scheduleRetry(for: payload)
        pendingMessages[id] = PendingMessage(payload: payload, retryTask: retryTask)

        try await socket.send(text: text)
    }

    // MARK: - Internal helpers

    private func makeWebSocketURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = (components.scheme == "https" ? "wss" : "ws")
        if components.path.isEmpty || components.path == "/" {
            components.path = "/ws"
        } else if !components.path.hasSuffix("/ws") {
            components.path.append("/ws")
        }
        return components.url
    }

    private func startListening(on client: any WebSocketClient) {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            var iterator = client.incomingTextMessages.makeAsyncIterator()
            while let text = await iterator.next() {
                handle(text: text)
            }
            handleSocketClose()
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            switch envelope.type {
            case "auth_result":
                handleAuthResult(data: data)
            case "message":
                handleMessage(data: data)
            case "ack":
                handleAck(data: data)
            case "error":
                handleServerError(data: data)
            case "user_info":
                handleUserInfo(data: data)
            case "event":
                handleEvent(data: data)
            default:
                logger.debug("Unknown message type: \(envelope.type, privacy: .public)")
                break
            }
        }
    }

    private func handleAuthResult(data: Data) {
        guard let result = try? decoder.decode(AuthResultPayload.self, from: data) else { return }
        if result.success {
            resolveAuthContinuation(with: .success(()))
            logger.info("state -> connected (auth success)")
            updateState(.connected)
            if let isAdmin = result.isAdmin {
                logger.info("Auth result received (userId: \(result.userId ?? "unknown", privacy: .public), isAdmin: \(isAdmin, privacy: .public))")
                let info = ChatUserInfo(userId: result.userId ?? "", isAdmin: isAdmin)
                emitServiceEvent(.userInfo(info))
            }
        } else {
            let reason = result.reason ?? "Unknown error"
            let error = Error.authFailed(reason)
            resolveAuthContinuation(with: .failure(error))
            logger.info("state -> failed (auth result) error=\(error.localizedDescription, privacy: .public)")
            updateState(.failed(error))
            performDisconnect(shouldNotify: false, reason: error.localizedDescription)
        }
    }

    private func handleMessage(data: Data) {
        guard let payload = try? decoder.decode(ServerMessagePayload.self, from: data) else { return }
        guard let sessionKey = resolveSessionKey(from: payload) else {
            logger.warning("Dropping message: missing sessionKey id=\(payload.id, privacy: .public)")
            return
        }
        let snippet = String(payload.content.prefix(80))
        messageLogger.info(
            "recv message id=\(payload.id, privacy: .public) sessionKey=\(sessionKey, privacy: .public) role=\(String(describing: payload.role), privacy: .public) streaming=\(payload.streaming, privacy: .public) deviceId=\(payload.deviceId ?? "nil", privacy: .public) snippet=\"\(snippet, privacy: .public)\""
        )
        let message = Message(payload: payload, sessionKey: sessionKey)
        messageBroadcaster.send(message)
    }

    private func handleAck(data: Data) {
        guard let payload = try? decoder.decode(AckPayload.self, from: data) else { return }
        if let pending = pendingMessages.removeValue(forKey: payload.id) {
            pending.retryTask?.cancel()
        }
    }

    private func handleServerError(data: Data) {
        guard let payload = try? decoder.decode(ErrorPayload.self, from: data) else { return }

        if let messageId = payload.messageId {
            if let pending = pendingMessages.removeValue(forKey: messageId) {
                pending.retryTask?.cancel()
            }
            emitServiceEvent(.messageError(messageId: messageId, code: payload.code, message: payload.message))
            return
        }

        let message = payload.message ?? payload.code
        switch payload.code {
        case "auth_failed":
            let error = Error.authFailed(message)
            resolveAuthContinuation(with: .failure(error))
            logger.info("state -> failed (server error auth_failed) error=\(error.localizedDescription, privacy: .public)")
            updateState(.failed(error))
            performDisconnect(shouldNotify: false, reason: error.localizedDescription)
        case "token_revoked":
            let error = Error.tokenRevoked(message)
            resolveAuthContinuation(with: .failure(error))
            logger.info("state -> failed (server error token_revoked) error=\(error.localizedDescription, privacy: .public)")
            updateState(.failed(error))
            performDisconnect(shouldNotify: false, reason: error.localizedDescription)
        case "session_replaced":
            let error = Error.sessionReplaced
            logger.info("state -> failed (server error session_replaced)")
            updateState(.failed(error))
            performDisconnect(shouldNotify: false, reason: error.localizedDescription)
        case "invalid_message", "payload_too_large", "invalid_channel":
            logger.info("message-level error without messageId code=\(payload.code, privacy: .public)")
            if !pendingMessages.isEmpty {
                for (messageId, pending) in pendingMessages {
                    pending.retryTask?.cancel()
                    emitServiceEvent(.messageError(
                        messageId: messageId,
                        code: payload.code,
                        message: payload.message
                    ))
                }
                pendingMessages.removeAll()
            } else {
                emitServiceEvent(.messageError(messageId: nil, code: payload.code, message: payload.message))
            }
        default:
            logger.info("state -> failed (server error) code=\(payload.code, privacy: .public)")
            updateState(.failed(Error.serverError(code: payload.code, message: payload.message)))
        }
    }

    private func handleUserInfo(data: Data) {
        guard let payload = try? decoder.decode(UserInfoPayload.self, from: data) else { return }
        let info = ChatUserInfo(userId: payload.userId, isAdmin: payload.isAdmin)
        emitServiceEvent(.userInfo(info))
    }

    private func handleEvent(data: Data) {
        guard let envelope = try? decoder.decode(EventEnvelope.self, from: data) else {
            logger.warning("Failed to decode event envelope")
            return
        }
        logger.info("Received event: \(envelope.event, privacy: .public)")

        switch envelope.event {
        case "activity":
            guard let payload = try? decoder.decode(ActivityEventPayload.self, from: data) else {
                logger.warning("Failed to decode activity event payload")
                return
            }
            // Map server channelType to iOS channel type
            // Server sends channelType: "admin" or "personal"
            let sessionKey = resolveSessionKey(from: payload.payload)
            logger.info("activity event isActive=\(payload.payload.isActive, privacy: .public) sessionKey=\(sessionKey ?? "nil", privacy: .public)")
            if let sessionKey {
                emitServiceEvent(.typingStateChanged(isTyping: payload.payload.isActive, sessionKey: sessionKey))
            }
        default:
            logger.debug("Unknown event type: \(envelope.event, privacy: .public)")
        }
    }

    private func resolveSessionKey(from payload: ServerMessagePayload) -> String? {
        if let sessionKey = payload.sessionKey {
            return sessionKey
        }
        guard let channelType = payload.channelType else { return nil }
        if let sessionKey = SessionKey.sessionKey(for: channelType, userId: userIdProvider()) {
            return sessionKey
        }
        logger.warning("Unable to derive sessionKey from channelType=\(channelType.rawValue, privacy: .public)")
        return nil
    }

    private func resolveSessionKey(from payload: ActivityEventPayload.ActivityPayload) -> String? {
        if let sessionKey = payload.sessionKey {
            return sessionKey
        }
        guard let raw = payload.channelType?.lowercased() else { return nil }
        let channelType: ChatChannelType
        switch raw {
        case "admin":
            channelType = .admin
        case "personal":
            channelType = .personal
        default:
            logger.warning("Unknown channelType: \(payload.channelType ?? "nil", privacy: .public)")
            return nil
        }
        if let sessionKey = SessionKey.sessionKey(for: channelType, userId: userIdProvider()) {
            return sessionKey
        }
        logger.warning("Unable to derive sessionKey from channelType=\(channelType.rawValue, privacy: .public)")
        return nil
    }

    private func updateState(_ state: ConnectionState) {
        lastConnectionState = state
        stateBroadcaster.send(state)
    }

    private func emitServiceEvent(_ event: ChatServiceEvent) {
        serviceEventBroadcaster.send(event)
    }

    private func handleSocketClose() {
        resolveAuthContinuation(with: .failure(Error.notConnected))

        // Notify the UI about each pending message that failed to send
        // This removes the optimistic placeholders so users know messages weren't delivered
        for (messageId, pending) in pendingMessages {
            pending.retryTask?.cancel()
            emitServiceEvent(.messageError(
                messageId: messageId,
                code: "connection_lost",
                message: "Message not delivered - connection lost"
            ))
        }
        pendingMessages.removeAll()

        logger.info("state -> disconnected (socket close) notify=\(self.shouldNotifyDisconnect, privacy: .public)")
        updateState(.disconnected)
        if shouldNotifyDisconnect {
            emitServiceEvent(.connectionInterrupted(reason: pendingDisconnectReason))
        }
        shouldNotifyDisconnect = true
        pendingDisconnectReason = nil
    }

    private func teardownConnection() async throws {
        performDisconnect(shouldNotify: false)
    }

    private func scheduleRetry(for payload: ClientMessagePayload) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(forDuration: ackInterval)
                guard let socket = self.socket else { return }
                guard self.pendingMessages[payload.id] != nil else { return }
                if let data = try? self.encoder.encode(payload),
                   let text = String(data: data, encoding: .utf8) {
                    try? await socket.send(text: text)
                }
            }
        }
    }

    private func resolveAuthContinuation(with result: Result<Void, Swift.Error>) {
        guard let continuation = authContinuation else { return }
        authContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
