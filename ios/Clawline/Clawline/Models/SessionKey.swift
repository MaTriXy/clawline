//
//  SessionKey.swift
//  Clawline
//
//  Created by Codex on 1/28/26.
//

import Foundation

enum SessionKey {
    static let dm = "agent:main:main"

    static func personal(userId: String) -> String {
        "agent:main:clawline:\(userId):main"
    }

    static func sessionKey(for channel: ChatChannelType, userId: String?) -> String? {
        switch channel {
        case .admin:
            return dm
        case .personal:
            guard let userId else { return nil }
            return personal(userId: userId)
        }
    }

    static func channelType(for sessionKey: String) -> ChatChannelType {
        sessionKey == dm ? .admin : .personal
    }
}
