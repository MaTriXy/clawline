//
//  SessionKey.swift
//  Clawline
//
//  Created by Codex on 1/28/26.
//

import Foundation

enum SessionKey {
    static let admin = "agent:main:main"
    static let clawlineDMPrefix = "agent:main:clawline:"

    /// Clawline Main session key. This is the only session key the client is allowed to
    /// construct directly; it is channel-scoped and stable across dmScope modes.
    ///
    /// Ref: `/Users/mike/shared-workspace/clawline/specs/chat-information-architecture.md`
    static func clawlineMain(userId: String) -> String {
        "agent:main:clawline:\(userId):main"
    }

    /// Terminal bubbles MVP policy: DM-only session keys.
    static func isClawlinePersonalDM(_ sessionKey: String) -> Bool {
        sessionKey.hasPrefix(clawlineDMPrefix)
    }

    static func stream(for sessionKey: String) -> ChatStream {
        SessionRegistry.shared.stream(for: sessionKey)
    }
}
