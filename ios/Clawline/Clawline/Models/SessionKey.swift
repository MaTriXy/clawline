//
//  SessionKey.swift
//  Clawline
//
//  Created by Codex on 1/28/26.
//

import Foundation

enum SessionKey {
    static let admin = "agent:main:main"

    static func stream(for sessionKey: String) -> ChatStream {
        sessionKey == admin ? .admin : .personal
    }
}
