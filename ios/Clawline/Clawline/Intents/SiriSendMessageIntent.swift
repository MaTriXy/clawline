//
//  SiriSendMessageIntent.swift
//  Clawline
//
//  Created by Codex on 1/30/26.
//

import AppIntents
import Foundation
import OSLog

@available(iOS 17.0, *)
struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription("Send a message to Clawline by voice.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Bot")
    var botName: String?

    @Parameter(
        title: "Message",
        requestValueDialog: IntentDialog("What do you want to say?")
    )
    var message: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw SiriSendMessageIntentError.emptyMessage
        }

        let authSnapshot = await loadAuthSnapshot()
        guard let token = authSnapshot.token,
              let userId = authSnapshot.userId,
              ProviderBaseURLStore.baseURL != nil else {
            throw SiriSendMessageIntentError.notPaired
        }

        let resolvedBotName = SiriBotNameStore.resolveName(
            explicit: botName,
            stored: SiriBotNameStore.storedName
        )
        if let explicit = resolvedBotName.explicitOverride {
            SiriBotNameStore.storeName(explicit)
        }

        let sessionKey = authSnapshot.isAdmin
            ? SessionKey.dm
            : SessionKey.personal(userId: userId)
        let content = SiriBotNameStore.formatContent(
            message: trimmedMessage,
            botName: resolvedBotName.value
        )

        let device = DeviceIdentifier()
        let connector = URLSessionWebSocketConnector(
            connectTimeout: SiriSendTimeouts.connectSeconds,
            resourceTimeout: SiriSendTimeouts.resourceSeconds
        )
        let chatService = ProviderChatService(
            connector: connector,
            deviceId: device.deviceId,
            userIdProvider: { authSnapshot.userId }
        )

        defer { chatService.disconnect() }

        do {
            try await withTimeout(SiriSendTimeouts.connect) {
                try await chatService.connect(token: token, lastMessageId: nil)
            }

            let messageId = "c_\(UUID().uuidString)"
            let ackTask = Task {
                try await waitForAck(
                    messageId: messageId,
                    events: chatService.serviceEvents,
                    timeout: SiriSendTimeouts.ack
                )
            }
            defer { ackTask.cancel() }

            try await withTimeout(SiriSendTimeouts.send) {
                try await chatService.send(
                    id: messageId,
                    content: content,
                    attachments: [],
                    sessionKey: sessionKey
                )
            }

            try await ackTask.value
        } catch let error as SiriSendMessageIntentError {
            throw error
        } catch let error as ProviderChatService.Error {
            throw mapChatServiceError(error)
        } catch let error as URLError {
            logger.info("Siri send URLError: \(error.localizedDescription, privacy: .public)")
            throw SiriSendMessageIntentError.offline
        } catch {
            logger.info("Siri send failed: \(error.localizedDescription, privacy: .public)")
            throw SiriSendMessageIntentError.connectionTimeout
        }

        return .result(dialog: IntentDialog("Message sent."))
    }
}

@available(iOS 17.0, *)
struct ClawlineAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: SendMessageIntent(),
                phrases: [
                    "Tell Clawline to \(.message)",
                    "Send \(.message) to \(.botName)",
                    "Ask \(.botName) \(.message)"
                ],
                shortTitle: "Send Message",
                systemImageName: "bubble.left.and.bubble.right"
            )
        ]
    }
}

@available(iOS 17.0, *)
private enum SiriSendMessageIntentError: Error, LocalizedError {
    case notPaired
    case emptyMessage
    case connectionTimeout
    case authExpired
    case offline

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "Clawline isn’t paired yet. Open the app to pair."
        case .emptyMessage:
            return "What do you want to say?"
        case .connectionTimeout:
            return "Clawline didn’t respond in time. Try again."
        case .authExpired:
            return "Clawline needs you to sign in again. Open the app."
        case .offline:
            return "Clawline can’t reach the server right now. Try again soon."
        }
    }
}

@available(iOS 17.0, *)
private struct SiriAuthSnapshot {
    let token: String?
    let userId: String?
    let isAdmin: Bool
}

@available(iOS 17.0, *)
@MainActor
private func loadAuthSnapshot() -> SiriAuthSnapshot {
    let authManager = AuthManager()
    return SiriAuthSnapshot(
        token: authManager.token,
        userId: authManager.currentUserId,
        isAdmin: authManager.isAdmin
    )
}

@available(iOS 17.0, *)
private enum SiriBotNameStore {
    private static let key = "siri.botName"
    private static let defaultName = "CLU"

    static var storedName: String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func storeName(_ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    struct ResolvedName {
        let value: String
        let explicitOverride: String?
    }

    static func resolveName(explicit: String?, stored: String?) -> ResolvedName {
        let trimmedExplicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStored = stored?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedExplicit, !trimmedExplicit.isEmpty {
            return ResolvedName(value: trimmedExplicit, explicitOverride: trimmedExplicit)
        }
        if let trimmedStored, !trimmedStored.isEmpty {
            return ResolvedName(value: trimmedStored, explicitOverride: nil)
        }
        return ResolvedName(value: defaultName, explicitOverride: nil)
    }

    static func formatContent(message: String, botName: String) -> String {
        if botName.caseInsensitiveCompare(defaultName) == .orderedSame {
            return message
        }
        return "@\(botName) \(message)"
    }
}

@available(iOS 17.0, *)
private enum SiriSendTimeouts {
    static let connect = Duration.seconds(6)
    static let send = Duration.seconds(3)
    static let ack = Duration.seconds(3)
    static let connectSeconds: TimeInterval = 6
    static let resourceSeconds: TimeInterval = 12
}

@available(iOS 17.0, *)
private func withTimeout<T>(_ timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(forDuration: timeout)
            throw SiriSendMessageIntentError.connectionTimeout
        }
        guard let value = try await group.next() else {
            throw SiriSendMessageIntentError.connectionTimeout
        }
        group.cancelAll()
        return value
    }
}

@available(iOS 17.0, *)
private func waitForAck(
    messageId: String,
    events: AsyncStream<ChatServiceEvent>,
    timeout: Duration
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            var iterator = events.makeAsyncIterator()
            while let event = await iterator.next() {
                switch event {
                case .messageAcked(let ackId) where ackId == messageId:
                    return
                case .messageError(let errorMessageId, let code, let message)
                        where errorMessageId == messageId:
                    throw mapMessageError(code: code, message: message)
                case .connectionInterrupted:
                    throw SiriSendMessageIntentError.offline
                default:
                    continue
                }
            }
            throw SiriSendMessageIntentError.connectionTimeout
        }
        group.addTask {
            try await Task.sleep(forDuration: timeout)
            throw SiriSendMessageIntentError.connectionTimeout
        }
        guard let _ = try await group.next() else {
            throw SiriSendMessageIntentError.connectionTimeout
        }
        group.cancelAll()
    }
}

@available(iOS 17.0, *)
private func mapChatServiceError(_ error: ProviderChatService.Error) -> SiriSendMessageIntentError {
    switch error {
    case .missingBaseURL:
        return .notPaired
    case .authFailed, .tokenRevoked:
        return .authExpired
    case .authTimeout:
        return .connectionTimeout
    case .notConnected, .sessionReplaced, .invalidMessageId, .serverError:
        return .connectionTimeout
    }
}

@available(iOS 17.0, *)
private func mapMessageError(code: String, message: String?) -> SiriSendMessageIntentError {
    switch code {
    case "auth_failed", "token_revoked":
        return .authExpired
    case "connection_lost":
        return .offline
    default:
        if let message, message.lowercased().contains("offline") {
            return .offline
        }
        return .connectionTimeout
    }
}

@available(iOS 17.0, *)
private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "SiriSendMessageIntent")
