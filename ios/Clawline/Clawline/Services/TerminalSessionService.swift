//
//  TerminalSessionService.swift
//  Clawline
//
//  Created by Codex on 2/7/26.
//

import Foundation
import OSLog

@MainActor
final class TerminalSessionService {
    enum State: Equatable {
        case disconnected
        case connecting
        case ready
        case exited(code: Int?)
        case failed(String)
    }

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "TerminalSession")
    private let descriptor: TerminalSessionDescriptor
    private let auth: AuthManager
    private let deviceId: DeviceIdentifier

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private let outputContinuation: AsyncStream<Data>.Continuation
    let output: AsyncStream<Data>

    private let stateContinuation: AsyncStream<State>.Continuation
    let state: AsyncStream<State>

    convenience init(descriptor: TerminalSessionDescriptor) {
        self.init(descriptor: descriptor, auth: AuthManager(), deviceId: DeviceIdentifier())
    }

    init(descriptor: TerminalSessionDescriptor,
         auth: AuthManager,
         deviceId: DeviceIdentifier) {
        self.descriptor = descriptor
        self.auth = auth
        self.deviceId = deviceId

        var outCont: AsyncStream<Data>.Continuation!
        self.output = AsyncStream { cont in outCont = cont }
        self.outputContinuation = outCont

        var stCont: AsyncStream<State>.Continuation!
        self.state = AsyncStream { cont in stCont = cont }
        self.stateContinuation = stCont
    }

    deinit {}

    func connect(initialCols: Int, initialRows: Int, backfillLines: Int = 2000) {
        guard socket == nil else { return }
        stateContinuation.yield(.connecting)

        guard let url = makeTerminalWebSocketURL() else {
            stateContinuation.yield(.failed("Missing provider URL"))
            return
        }

        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }

        Task { [weak self] in
            await self?.sendAuth(initialCols: initialCols, initialRows: initialRows, backfillLines: backfillLines)
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        stateContinuation.yield(.disconnected)
    }

    func sendInput(_ data: Data) {
        guard let socket else { return }
        Task {
            do {
                try await socket.send(.data(data))
            } catch {
                logger.error("terminal_send_input_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        sendControl(["type": "terminal_resize", "cols": cols, "rows": rows])
    }

    func detach() {
        sendControl(["type": "terminal_detach"])
    }

    func close() {
        sendControl(["type": "terminal_close"])
    }

    private func sendControl(_ dict: [String: Any]) {
        guard let socket else { return }
        Task {
            do {
                let data = try JSONSerialization.data(withJSONObject: dict, options: [])
                let text = String(decoding: data, as: UTF8.self)
                try await socket.send(.string(text))
            } catch {
                logger.error("terminal_send_control_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeTerminalWebSocketURL() -> URL? {
        guard let base = ProviderBaseURLStore.baseURL else { return nil }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = components.scheme?.lowercased()
        components.scheme = (scheme == "https") ? "wss" : "ws"

        let path = descriptor.provider?.wsPath ?? "/ws/terminal"
        components.path = path.hasPrefix("/") ? path : ("/" + path)
        return components.url
    }

    private func sendAuth(initialCols: Int, initialRows: Int, backfillLines: Int) async {
        guard let socket else { return }
        guard let token = resolveAuthToken() else {
            stateContinuation.yield(.failed("Missing auth token"))
            disconnect()
            return
        }

        let authMode = resolveAuthMode()
        let payload: [String: Any] = [
            "type": "terminal_auth",
            "protocolVersion": 1,
            "authMode": authMode,
            "authToken": token,
            "deviceId": deviceId.deviceId,
            "terminalSessionId": descriptor.terminalSessionId,
            "backfillLines": backfillLines,
            "cols": initialCols,
            "rows": initialRows
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            let text = String(decoding: data, as: UTF8.self)
            try await socket.send(.string(text))
        } catch {
            stateContinuation.yield(.failed("Auth send failed"))
            disconnect()
        }
    }

    private func resolveAuthMode() -> String {
        if descriptor.auth?.terminalAccessToken != nil {
            return "terminal_access_token"
        }
        return "chat_token"
    }

    private func resolveAuthToken() -> String? {
        if let terminalToken = descriptor.auth?.terminalAccessToken, !terminalToken.isEmpty {
            return terminalToken
        }
        return auth.token
    }

    private func receiveLoop() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let data):
                    outputContinuation.yield(data)
                case .string(let text):
                    handleControl(text)
                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled { break }
                logger.error("terminal_receive_failed error=\(error.localizedDescription, privacy: .public)")
                stateContinuation.yield(.disconnected)
                break
            }
        }
    }

    private func handleControl(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }

        switch type {
        case "terminal_ready":
            stateContinuation.yield(.ready)
        case "terminal_exit":
            let code = obj["code"] as? Int
            stateContinuation.yield(.exited(code: code))
        case "terminal_error":
            let message = (obj["message"] as? String) ?? "Terminal error"
            stateContinuation.yield(.failed(message))
        case "terminal_closed":
            stateContinuation.yield(.disconnected)
        default:
            break
        }
    }

    private func pingLoop() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    socket.sendPing { error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                }
            } catch {
                if Task.isCancelled { break }
                logger.warning("terminal_ping_failed error=\(error.localizedDescription, privacy: .public)")
                stateContinuation.yield(.disconnected)
                disconnect()
                break
            }
        }
    }
}
