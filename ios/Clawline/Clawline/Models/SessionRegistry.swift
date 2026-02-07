//
//  SessionRegistry.swift
//  Clawline
//
//  Tracks the server-provisioned session keys and maps them to local UI streams.
//  Session keys are opaque; we do not parse them (Clawline invariants N3/N7).
//

import Foundation

final class SessionRegistry {
    static let shared = SessionRegistry()

    private let lock = NSLock()
    private var personalSessionKey: String?
    private var adminSessionKey: String?

    private init() {}

    func update(personal: String?, admin: String?) {
        lock.lock()
        personalSessionKey = personal
        adminSessionKey = admin
        lock.unlock()
    }

    func stream(for sessionKey: String) -> ChatStream {
        lock.lock()
        let adminKey = adminSessionKey
        lock.unlock()
        if let adminKey, sessionKey == adminKey {
            return .admin
        }
        return .personal
    }
}

