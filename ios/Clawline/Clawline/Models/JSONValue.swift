//
//  JSONValue.swift
//  Clawline
//
//  Created by Codex on 2/9/26.
//

import Foundation

enum JSONValue: Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    static func from(any value: Any, depthLimit: Int = 32) -> JSONValue? {
        guard depthLimit > 0 else { return nil }

        switch value {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as Float:
            return .number(Double(value))
        case let value as String:
            return .string(value)
        case let value as [Any]:
            var items: [JSONValue] = []
            items.reserveCapacity(value.count)
            for item in value {
                guard let decoded = from(any: item, depthLimit: depthLimit - 1) else { return nil }
                items.append(decoded)
            }
            return .array(items)
        case let value as [String: Any]:
            var obj: [String: JSONValue] = [:]
            obj.reserveCapacity(value.count)
            for (k, v) in value {
                guard k.count <= 256 else { return nil }
                guard let decoded = from(any: v, depthLimit: depthLimit - 1) else { return nil }
                obj[k] = decoded
            }
            return .object(obj)
        default:
            return nil
        }
    }
}

