//
//  WebSocketClient.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

struct WebSocketCloseInfo: Equatable {
    let code: Int?
    let reason: String?
}

protocol WebSocketClient: AnyObject {
    var incomingTextMessages: AsyncStream<String> { get }
    var lastCloseInfo: WebSocketCloseInfo? { get }

    func send(text: String) async throws
    func close(with code: URLSessionWebSocketTask.CloseCode?)
}

extension WebSocketClient {
    var lastCloseInfo: WebSocketCloseInfo? { nil }
}

protocol WebSocketConnecting {
    func connect(to url: URL) async throws -> WebSocketClient
}
