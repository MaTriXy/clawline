//
//  StreamSession.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import Foundation

struct StreamSession: Codable, Equatable, Identifiable {
    var id: String { sessionKey }
    let sessionKey: String
    var displayName: String
    let kind: String
    let orderIndex: Int
    let isBuiltIn: Bool
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionKey
        case displayName
        case kind
        case orderIndex
        case isBuiltIn
        case createdAt
        case updatedAt
    }

    init(sessionKey: String,
         displayName: String,
         kind: String,
         orderIndex: Int,
         isBuiltIn: Bool,
         createdAt: Date,
         updatedAt: Date) {
        self.sessionKey = sessionKey
        self.displayName = displayName
        self.kind = kind
        self.orderIndex = orderIndex
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(String.self, forKey: .kind)
        orderIndex = try container.decode(Int.self, forKey: .orderIndex)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        createdAt = try container.decodeUnixMillisDate(forKey: .createdAt)
        updatedAt = try container.decodeUnixMillisDate(forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(kind, forKey: .kind)
        try container.encode(orderIndex, forKey: .orderIndex)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encode(createdAt.timeIntervalSince1970 * 1000, forKey: .createdAt)
        try container.encode(updatedAt.timeIntervalSince1970 * 1000, forKey: .updatedAt)
    }
}

private extension KeyedDecodingContainer {
    func decodeUnixMillisDate(forKey key: Key) throws -> Date {
        if let milliseconds = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        if let intMilliseconds = try? decode(Int64.self, forKey: key) {
            return Date(timeIntervalSince1970: Double(intMilliseconds) / 1000)
        }
        throw DecodingError.typeMismatch(
            Date.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected unix epoch milliseconds."
            )
        )
    }
}
