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
        // Required pattern:
        // `agent:main:clawline:<userId>:main`
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        guard parts[0] == "agent", parts[1] == "main", parts[2] == "clawline" else { return false }
        guard !parts[3].isEmpty else { return false }
        guard parts[4] == "main" else { return false }
        return true
    }

    static func stream(for sessionKey: String) -> ChatStream {
        SessionRegistry.shared.stream(for: sessionKey)
    }
}
