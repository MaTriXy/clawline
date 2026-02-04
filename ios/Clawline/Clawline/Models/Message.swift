//
//  Message.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

enum ChatStream: String, Codable, CaseIterable, Equatable {
    case personal
    case admin

    var displayName: String {
        switch self {
        case .personal:
            return "Personal"
        case .admin:
            return "DM"
        }
    }
}

struct ChatUserInfo: Equatable {
    let userId: String
    let isAdmin: Bool
}

struct Message: Identifiable, Equatable, Codable {
    let id: String
    let role: Role
    let content: String
    let timestamp: Date
    var streaming: Bool
    let attachments: [Attachment]
    let deviceId: String?
    let sessionKey: String
    let sender: String? = nil

    init(id: String,
         role: Role,
         content: String,
         timestamp: Date,
         streaming: Bool,
         attachments: [Attachment],
         deviceId: String?,
         sessionKey: String,
         sender: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.streaming = streaming
        self.attachments = attachments
        self.deviceId = deviceId
        self.sessionKey = sessionKey
        self.sender = sender
    }

    var stream: ChatStream {
        SessionKey.stream(for: sessionKey)
    }

    var displayName: String {
        switch role {
        case .user:
            return "You"
        case .assistant:
            if let sender, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return sender
            }
            return "Assistant"
        }
    }

    enum Role: String, Codable {
        case user
        case assistant
    }
}
