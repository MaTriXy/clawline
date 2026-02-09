//
//  TerminalSessionDescriptor.swift
//  Clawline
//
//  Created by Codex on 2/7/26.
//

import Foundation

struct TerminalSessionDescriptor: Codable, Equatable {
    static let mimeType = "application/vnd.clawline.terminal-session+json"

    struct ProviderDescriptor: Codable, Equatable {
        let baseUrl: String?
        let wsPath: String?
    }

    struct Capabilities: Codable, Equatable {
        let interactive: Bool
        let supportsBinaryFrames: Bool
        let supportsResize: Bool
        let supportsDetach: Bool
    }

    struct Auth: Codable, Equatable {
        enum Mode: String, Codable, Equatable {
            case chatToken = "chat_token"
            case terminalAccessToken = "terminal_access_token"
        }

        let mode: Mode?
        let terminalAccessToken: String?
    }

    let version: Int
    let terminalSessionId: String
    let title: String?
    let provider: ProviderDescriptor?
    let capabilities: Capabilities?
    let auth: Auth?
    let expiresAtMs: Double?
}

