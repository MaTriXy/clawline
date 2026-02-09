//
//  RootView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI

struct RootView: View {
    let uploadService: any UploadServicing
    @State private var toastManager = ToastManager()
    @State private var chatViewModel: ChatViewModel?
    @Environment(AuthManager.self) private var auth
    @Environment(\.connectionService) private var connection
    @Environment(\.deviceIdentifier) private var device
    @Environment(\.chatService) private var chatService
    @Environment(\.settingsManager) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("provider.baseURL") private var providerBaseURLString: String = ""

    private var isProviderConfigured: Bool {
        let trimmed = providerBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return URL(string: trimmed) != nil
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.1, green: 0.12, blue: 0.15)  // Slate
            : Color(uiColor: .systemGray6)              // Light gray
    }

    var body: some View {
        Group {
            // If the provider base URL is missing (fresh install / wiped defaults), route to
            // onboarding so the user can recover without having to send a message.
            if !auth.isAuthenticated || !isProviderConfigured {
                PairingView(auth: auth, connection: connection, device: device)
            } else if let chatViewModel {
                ChatView(viewModel: chatViewModel, toastManager: toastManager)
            } else {
                ProgressView()
                    .task { ensureChatViewModel() }
            }
        }
        .modifier(KeyboardSafeAreaMode(isActive: auth.isAuthenticated && isProviderConfigured))
#if os(visionOS)
        .preferredColorScheme(settings.preferredColorScheme)
#endif
        .task(id: "\(auth.isAuthenticated)-\(providerBaseURLString)") {
            if auth.isAuthenticated && isProviderConfigured {
                ensureChatViewModel()
            } else {
                chatViewModel = nil
            }
        }
        .environment(\.uploadService, uploadService)
        .background {
#if os(visionOS)
            Color.clear
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
#else
            backgroundColor
                .backgroundEffect(settings.effectConfig)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
#endif
        }
        .animation(.easeInOut(duration: 0.3), value: auth.isAuthenticated)
    }

    @MainActor
    private func ensureChatViewModel() {
        guard chatViewModel == nil else { return }
        guard isProviderConfigured else { return }
        chatViewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: settings,
            device: device,
            uploadService: uploadService,
            toastManager: toastManager
        )
    }
}

private struct KeyboardSafeAreaMode: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.ignoresSafeArea(.keyboard)
        } else {
            content
        }
    }
}

// MARK: - Previews

#Preview("Unauthenticated") {
    RootView(uploadService: PreviewUploadService())
        .environment(AuthManager())
        .environment(\.connectionService, StubConnectionService())
        .environment(\.deviceIdentifier, DeviceIdentifier())
        .environment(\.chatService, StubChatService())
}

#Preview("Authenticated") {
    let auth = AuthManager()
    auth.storeCredentials(token: "preview-token", userId: "preview-user")
    return RootView(uploadService: PreviewUploadService())
        .environment(auth)
        .environment(\.connectionService, StubConnectionService())
        .environment(\.deviceIdentifier, DeviceIdentifier())
        .environment(\.chatService, StubChatService())
}

private struct PreviewUploadService: UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String { "preview-asset" }
    func download(assetId: String) async throws -> Data { Data() }
}
