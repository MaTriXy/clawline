//
//  TerminalSessionDescriptor.swift
//  Clawline
//
//  Created by Codex on 2/7/26.
//

import Foundation

struct TerminalSessionDescriptor: Codable, Equatable {
    static let mimeType = "application/vnd.clawline.terminal-session+json"

    private enum CodingKeys: String, CodingKey {
        case version
        case terminalSessionId
        case title
        case name
        case provider
        case capabilities
        case auth
        case expiresAtMs
    }

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

    init(
        version: Int = 1,
        terminalSessionId: String,
        title: String?,
        provider: ProviderDescriptor?,
        capabilities: Capabilities?,
        auth: Auth?,
        expiresAtMs: Double?
    ) {
        self.version = version
        self.terminalSessionId = terminalSessionId
        self.title = title
        self.provider = provider
        self.capabilities = capabilities
        self.auth = auth
        self.expiresAtMs = expiresAtMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Backward/forward compatibility:
        // - Older descriptors may omit version.
        // - Some producers use "name" instead of "title".
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        terminalSessionId = try container.decode(String.self, forKey: .terminalSessionId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)

        provider = try container.decodeIfPresent(ProviderDescriptor.self, forKey: .provider)
        capabilities = try container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
        auth = try container.decodeIfPresent(Auth.self, forKey: .auth)
        expiresAtMs = try container.decodeIfPresent(Double.self, forKey: .expiresAtMs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(terminalSessionId, forKey: .terminalSessionId)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(auth, forKey: .auth)
        try container.encodeIfPresent(expiresAtMs, forKey: .expiresAtMs)
    }
}
