//
//  SessionStatus.swift
//  Clawline
//
//  Created by Codex on 4/29/26.
//

import Foundation

struct SessionStatus: Decodable, Equatable {
    let sessionKey: String
    let display: Display
    let run: Run
    let context: Context?
    let approval: Approval?
    let capabilities: Capabilities

    struct Display: Decodable, Equatable {
        let model: String?
        let fallbackModels: [String]?
        let provider: String?
        let harness: String?
        let reasoningLevel: String?
        let thinkingLevel: String?
        let fastMode: Bool?
        let mode: String?
        let verbosity: String?
    }

    struct Run: Decodable, Equatable {
        enum State: String, Decodable {
            case idle
            case queued
            case running
            case unknown

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let raw = try container.decode(String.self)
                self = State(rawValue: raw) ?? .unknown
            }
        }

        let state: State
        let runId: String?
        let messageId: String?
        let startedAt: TimeInterval?
        let queueDepth: Int?
    }

    struct Context: Decodable, Equatable {
        let available: Bool?
        let compaction: JSONValue?
    }

    struct Approval: Decodable, Equatable {
        let state: String?
    }

    struct Capabilities: Decodable, Equatable {
        let cancelCurrentRun: Capability?
        let setModel: Capability?
        let setReasoning: Capability?
        let setMode: Capability?
        let setVerbosity: Capability?
        let canCancelCurrentRun: Bool?
        let canChangeModel: Bool?
        let canChangeReasoning: Bool?
        let canChangeFastMode: Bool?
        let canChangeVerbosity: Bool?
        let readOnlyStatus: Bool?
    }

    struct Capability: Decodable, Equatable {
        let supported: Bool
        let reason: String?
    }
}

struct SessionControlResponse: Decodable, Equatable {
    let ok: Bool
    let sessionKey: String
    let action: String
    let code: String?
    let message: String?
    let status: SessionStatus?
    let capabilities: SessionStatus.Capabilities?
}
