import Foundation

@MainActor
protocol TerminalSessionControlling: AnyObject {
    var output: AsyncStream<Data> { get }
    var state: AsyncStream<TerminalSessionService.State> { get }

    func connect(initialCols: Int, initialRows: Int, backfillLines: Int)
    func disconnect()
    func sendInput(_ data: Data)
    func resize(cols: Int, rows: Int)
}

extension TerminalSessionService: TerminalSessionControlling {}

@MainActor
final class TerminalSessionConnectionPool {
    struct AttachmentID: Hashable {
        fileprivate let rawValue = UUID()
    }

    private struct ConnectionKey: Hashable {
        let terminalSessionId: String
        let providerBaseURL: String?

        init(descriptor: TerminalSessionDescriptor) {
            self.terminalSessionId = descriptor.terminalSessionId
            self.providerBaseURL = descriptor.provider?.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private final class Consumer {
        weak var owner: AnyObject?
        let sequence: Int
        let onStateChange: (TerminalSessionService.State) -> Void
        let onOutput: (Data) -> Void

        init(owner: AnyObject,
             sequence: Int,
             onStateChange: @escaping (TerminalSessionService.State) -> Void,
             onOutput: @escaping (Data) -> Void) {
            self.owner = owner
            self.sequence = sequence
            self.onStateChange = onStateChange
            self.onOutput = onOutput
        }
    }

    private final class Entry {
        let descriptor: TerminalSessionDescriptor
        var service: (any TerminalSessionControlling)?
        var outputTask: Task<Void, Never>?
        var stateTask: Task<Void, Never>?
        var idleDisconnectTask: Task<Void, Never>?
        var consumers: [AttachmentID: Consumer] = [:]
        var nextConsumerSequence: Int = 0
        var activeConsumerID: AttachmentID?
        var currentState: TerminalSessionService.State?
        var currentSize: (cols: Int, rows: Int)?
        var requiresUserReconnect = false
        var outputBacklog: [Data] = []

        init(descriptor: TerminalSessionDescriptor) {
            self.descriptor = descriptor
        }
    }

    private let serviceFactory: (TerminalSessionDescriptor) -> any TerminalSessionControlling
    private let idleDisconnectDelay: Duration
    private var entries: [ConnectionKey: Entry] = [:]

    init(serviceFactory: @escaping (TerminalSessionDescriptor) -> any TerminalSessionControlling,
         idleDisconnectDelay: Duration = .seconds(30)) {
        self.serviceFactory = serviceFactory
        self.idleDisconnectDelay = idleDisconnectDelay
    }

    func attach(owner: AnyObject,
                descriptor: TerminalSessionDescriptor,
                initialCols: Int,
                initialRows: Int,
                onStateChange: @escaping (TerminalSessionService.State) -> Void,
                onOutput: @escaping (Data) -> Void) -> AttachmentID {
        let entry = entry(for: descriptor)
        cancelIdleDisconnect(for: entry)
        pruneConsumers(in: entry)

        entry.nextConsumerSequence &+= 1
        let attachmentID = AttachmentID()
        let consumer = Consumer(
            owner: owner,
            sequence: entry.nextConsumerSequence,
            onStateChange: onStateChange,
            onOutput: onOutput
        )
        entry.consumers[attachmentID] = consumer
        entry.activeConsumerID = attachmentID

        replayBufferedOutput(from: entry, to: consumer)
        if let currentState = entry.currentState {
            consumer.onStateChange(currentState)
        }

        if entry.currentSize == nil {
            entry.currentSize = (cols: initialCols, rows: initialRows)
        }

        if entry.service == nil, !entry.requiresUserReconnect {
            startServiceIfNeeded(for: entry, initialCols: initialCols, initialRows: initialRows)
        }

        return attachmentID
    }

    func detach(descriptor: TerminalSessionDescriptor, attachmentID: AttachmentID) {
        let key = ConnectionKey(descriptor: descriptor)
        guard let entry = entries[key] else { return }

        entry.consumers.removeValue(forKey: attachmentID)
        pruneConsumers(in: entry)

        if entry.activeConsumerID == attachmentID {
            entry.activeConsumerID = entry.consumers.max(by: { $0.value.sequence < $1.value.sequence })?.key
        }

        if entry.consumers.isEmpty {
            scheduleIdleDisconnect(forKey: key, entry: entry)
        }
    }

    func resize(descriptor: TerminalSessionDescriptor,
                attachmentID: AttachmentID,
                cols: Int,
                rows: Int) {
        let entry = entry(for: descriptor)
        entry.currentSize = (cols: cols, rows: rows)
        guard entry.activeConsumerID == attachmentID else { return }
        entry.service?.resize(cols: cols, rows: rows)
    }

    func sendInput(descriptor: TerminalSessionDescriptor,
                   attachmentID: AttachmentID,
                   data: Data) {
        let entry = entry(for: descriptor)
        guard entry.activeConsumerID == attachmentID else { return }
        entry.service?.sendInput(data)
    }

    func requestReconnect(descriptor: TerminalSessionDescriptor,
                          initialCols: Int,
                          initialRows: Int) {
        let entry = entry(for: descriptor)
        entry.currentSize = (cols: initialCols, rows: initialRows)
        entry.requiresUserReconnect = false
        cancelIdleDisconnect(for: entry)
        disposeService(for: entry, clearBacklog: true)
        startServiceIfNeeded(for: entry, initialCols: initialCols, initialRows: initialRows)
    }

    private func entry(for descriptor: TerminalSessionDescriptor) -> Entry {
        let key = ConnectionKey(descriptor: descriptor)
        if let existing = entries[key] {
            return existing
        }
        let entry = Entry(descriptor: descriptor)
        entries[key] = entry
        return entry
    }

    private func startServiceIfNeeded(for entry: Entry, initialCols: Int, initialRows: Int) {
        guard entry.service == nil else { return }
        let size = entry.currentSize ?? (cols: initialCols, rows: initialRows)
        entry.currentSize = size

        let service = serviceFactory(entry.descriptor)
        entry.service = service

        entry.outputTask = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            for await data in service.output {
                await MainActor.run {
                    guard entry.service != nil else { return }
                    entry.outputBacklog.append(data)
                    self.broadcastOutput(data, in: entry)
                }
            }
        }

        entry.stateTask = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            for await state in service.state {
                await MainActor.run {
                    guard entry.service != nil else { return }
                    entry.currentState = state
                    switch state {
                    case .connecting, .ready:
                        entry.requiresUserReconnect = false
                    case .disconnected, .exited, .failed:
                        entry.requiresUserReconnect = true
                    }
                    self.broadcastState(state, in: entry)
                }
            }
        }

        service.connect(initialCols: size.cols, initialRows: size.rows, backfillLines: 2000)
    }

    private func scheduleIdleDisconnect(forKey key: ConnectionKey, entry: Entry) {
        cancelIdleDisconnect(for: entry)
        entry.idleDisconnectTask = Task { [weak self, weak entry] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.idleDisconnectDelay)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            await MainActor.run {
                guard let entry else { return }
                guard entry.consumers.isEmpty else { return }
                entry.requiresUserReconnect = true
                entry.currentState = .disconnected
                self.disposeService(for: entry, clearBacklog: true)
            }
        }
    }

    private func cancelIdleDisconnect(for entry: Entry) {
        entry.idleDisconnectTask?.cancel()
        entry.idleDisconnectTask = nil
    }

    private func disposeService(for entry: Entry, clearBacklog: Bool = false) {
        entry.outputTask?.cancel()
        entry.outputTask = nil
        entry.stateTask?.cancel()
        entry.stateTask = nil
        let service = entry.service
        entry.service = nil
        if clearBacklog {
            entry.outputBacklog.removeAll(keepingCapacity: false)
        }
        service?.disconnect()
    }

    private func pruneConsumers(in entry: Entry) {
        let deadKeys = entry.consumers.compactMap { attachmentID, consumer in
            consumer.owner == nil ? attachmentID : nil
        }
        for key in deadKeys {
            entry.consumers.removeValue(forKey: key)
            if entry.activeConsumerID == key {
                entry.activeConsumerID = nil
            }
        }
    }

    private func replayBufferedOutput(from entry: Entry, to consumer: Consumer) {
        for chunk in entry.outputBacklog {
            consumer.onOutput(chunk)
        }
    }

    private func broadcastOutput(_ data: Data, in entry: Entry) {
        pruneConsumers(in: entry)
        for consumer in entry.consumers.values {
            consumer.onOutput(data)
        }
    }

    private func broadcastState(_ state: TerminalSessionService.State, in entry: Entry) {
        pruneConsumers(in: entry)
        for consumer in entry.consumers.values {
            consumer.onStateChange(state)
        }
    }
}
