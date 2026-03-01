import SwiftUI
import WatchConnectivity

@main
struct Clawline_Watch_Watch_AppApp: App {
    @State private var credentialStore: WatchCredentialStore
    @State private var providerTransport: WatchProviderTransport
    @State private var voiceSession: WatchVoiceSession
    @State private var channelManager: WatchChannelManager

    private let wcSessionDelegate: WatchWCSessionDelegate?

    init() {
        let credentialStore = WatchCredentialStore()
        _credentialStore = State(initialValue: credentialStore)

        let transport = WatchProviderTransport(credentialStore: credentialStore)
        _providerTransport = State(initialValue: transport)

        let voiceSession = WatchVoiceSession(credentialStore: credentialStore)
        _voiceSession = State(initialValue: voiceSession)

        let channelManager = WatchChannelManager()
        _channelManager = State(initialValue: channelManager)

        voiceSession.onTranscriptReady = { transcript in
            let messageId = "c_\(UUID().uuidString)"
            let sessionKey = channelManager.engineSessionKey ?? channelManager.currentSessionKey

            Task {
                do {
                    try await transport.send(id: messageId, content: transcript, attachments: [], sessionKey: sessionKey)
                } catch {
                    await MainActor.run {
                        voiceSession.handleSendFailure(error: error)
                    }
                }
            }
        }

        if WCSession.isSupported() {
            let delegate = WatchWCSessionDelegate(credentialStore: credentialStore, transport: transport)
            self.wcSessionDelegate = delegate
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        } else {
            self.wcSessionDelegate = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            watchRootView
        }
    }

    @ViewBuilder
    private var watchRootView: some View {
        WatchMainView()
            .environment(credentialStore)
            .environment(providerTransport)
            .environment(voiceSession)
            .environment(channelManager)
    }
}
