//
//  SessionKey.swift
//  Clawline
//
//  Created by Codex on 1/28/26.
//

import Foundation

enum SessionKey {
    static let adminFallback = "agent:main:main"

    static func channelType(for sessionKey: String) -> ChatChannelType {
        sessionKey == adminFallback ? .admin : .personal
    }
}
