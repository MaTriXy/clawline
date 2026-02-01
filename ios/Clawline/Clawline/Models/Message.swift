//
//  Message.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

enum ChatChannelType: String, Codable, CaseIterable, Equatable {
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
    let channelType: ChatChannelType

    enum Role: String, Codable {
        case user
        case assistant
    }
}
