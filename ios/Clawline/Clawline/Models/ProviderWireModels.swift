//
//  ProviderWireModels.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

struct ServerMessagePayload: Codable, Equatable {
    let type: String
    let id: String
    let role: Message.Role
    let sender: String?
    let content: String
    let timestamp: Date
    let streaming: Bool
    let deviceId: String?
    let sessionKey: String?
    let attachments: [Attachment]

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case role
        case sender
        case content
        case timestamp
        case streaming
        case deviceId
        case sessionKey
        case attachments
    }

    init(type: String = "message",
         id: String,
         role: Message.Role,
         content: String,
         timestamp: Date,
         streaming: Bool,
         deviceId: String?,
         sessionKey: String?,
         attachments: [Attachment]) {
        self.type = type
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.streaming = streaming
        self.deviceId = deviceId
        self.sessionKey = sessionKey
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        sender = try container.decodeIfPresent(String.self, forKey: .sender)
        if let decodedRole = try container.decodeIfPresent(Message.Role.self, forKey: .role) {
            role = decodedRole
        } else if let sender {
            role = sender.lowercased() == Message.Role.assistant.rawValue ? .assistant : .user
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.role,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing role/sender")
            )
        }
        content = try container.decode(String.self, forKey: .content)
        let milliseconds = try container.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
        streaming = try container.decode(Bool.self, forKey: .streaming)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(sender, forKey: .sender)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp.timeIntervalSince1970 * 1000, forKey: .timestamp)
        try container.encode(streaming, forKey: .streaming)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encodeIfPresent(sessionKey, forKey: .sessionKey)
        try container.encode(attachments, forKey: .attachments)
    }
}

struct ClientMessagePayload: Codable, Equatable {
    let type: String
    let id: String
    let content: String
    let attachments: [WireAttachment]
    let sessionKey: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case content
        case attachments
        case sessionKey
    }

    init(id: String, content: String, attachments: [WireAttachment], sessionKey: String?, type: String = "message") {
        self.type = type
        self.id = id
        self.content = content
        self.attachments = attachments
        self.sessionKey = sessionKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "message"
        self.id = try container.decode(String.self, forKey: .id)
        self.content = try container.decode(String.self, forKey: .content)
        self.attachments = try container.decodeIfPresent([WireAttachment].self, forKey: .attachments) ?? []
        self.sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(sessionKey, forKey: .sessionKey)
    }
}

extension Message {
    init(payload: ServerMessagePayload, sessionKey: String) {
        self.init(
            id: payload.id,
            role: payload.role,
            content: payload.content,
            timestamp: payload.timestamp,
            streaming: payload.streaming,
            attachments: payload.attachments,
            deviceId: payload.deviceId,
            sessionKey: sessionKey,
            sender: payload.sender
        )
    }

    func toClientPayload() -> ClientMessagePayload {
        let wireAttachments: [WireAttachment] = attachments.compactMap { attachment in
            if let assetId = attachment.assetId {
                return .asset(assetId: assetId)
            }
            if let data = attachment.data, let mimeType = attachment.mimeType {
                return .image(mimeType: mimeType, data: data)
            }
            return nil
        }
        return ClientMessagePayload(
            id: id,
            content: content,
            attachments: wireAttachments,
            sessionKey: sessionKey
        )
    }
}
