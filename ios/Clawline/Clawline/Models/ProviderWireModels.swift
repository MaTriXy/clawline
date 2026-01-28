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
    let content: String
    let timestamp: Date
    let streaming: Bool
    let deviceId: String?
    let sessionKey: String?
    let attachments: [Attachment]
    let channelType: ChatChannelType?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case role
        case content
        case timestamp
        case streaming
        case deviceId
        case sessionKey
        case attachments
        case channelType
    }

    init(type: String = "message",
         id: String,
         role: Message.Role,
         content: String,
         timestamp: Date,
         streaming: Bool,
         deviceId: String?,
         sessionKey: String?,
         attachments: [Attachment],
         channelType: ChatChannelType? = nil) {
        self.type = type
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.streaming = streaming
        self.deviceId = deviceId
        self.sessionKey = sessionKey
        self.attachments = attachments
        self.channelType = channelType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(Message.Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        let milliseconds = try container.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
        streaming = try container.decode(Bool.self, forKey: .streaming)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        channelType = try container.decodeIfPresent(ChatChannelType.self, forKey: .channelType)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp.timeIntervalSince1970 * 1000, forKey: .timestamp)
        try container.encode(streaming, forKey: .streaming)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encodeIfPresent(sessionKey, forKey: .sessionKey)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(channelType, forKey: .channelType)
    }
}

struct ClientMessagePayload: Codable, Equatable {
    let type: String
    let id: String
    let content: String
    let attachments: [WireAttachment]
    let sessionKey: String
    let channelType: ChatChannelType?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case content
        case attachments
        case sessionKey
        case channelType
    }

    init(id: String, content: String, attachments: [WireAttachment], sessionKey: String, channelType: ChatChannelType? = nil, type: String = "message") {
        self.type = type
        self.id = id
        self.content = content
        self.attachments = attachments
        self.sessionKey = sessionKey
        self.channelType = channelType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "message"
        self.id = try container.decode(String.self, forKey: .id)
        self.content = try container.decode(String.self, forKey: .content)
        self.attachments = try container.decodeIfPresent([WireAttachment].self, forKey: .attachments) ?? []
        self.sessionKey = try container.decode(String.self, forKey: .sessionKey)
        self.channelType = try container.decodeIfPresent(ChatChannelType.self, forKey: .channelType)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(channelType, forKey: .channelType)
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
            channelType: SessionKey.channelType(for: sessionKey)
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
        return ClientMessagePayload(id: id, content: content, attachments: wireAttachments, sessionKey: sessionKey)
    }
}
