import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { ChatRoute } from "./ChatRoute";
import {
  AuthSessionStoreProvider,
  createAuthSessionStore
} from "../../runtime/auth/authSessionStore";
import {
  ChatDomainStoreProvider,
  createChatDomainStore
} from "../../runtime/chat/chatDomainStore";
import { createMemoryChatPersistence } from "../../runtime/persistence/indexedDbChatPersistence";
import {
  SettingsStoreProvider,
  createSettingsStore
} from "../../runtime/settings/settingsStore";
import {
  TransportMachineProvider,
  createTransportMachine
} from "../../runtime/transport/transportMachine";
import { FakeWebSocketFactory } from "../../test/support/fakeWebSocket";

function LocationProbe() {
  const location = useLocation();
  return <div data-testid="location">{location.pathname}</div>;
}

function renderChatRoute(initialPath: string) {
  const authStore = createAuthSessionStore();
  const chatStore = createChatDomainStore({
    persistence: createMemoryChatPersistence()
  });
  const settingsStore = createSettingsStore();
  const webSocketFactory = new FakeWebSocketFactory();

  authStore.storePairingSession({
    claimedName: "Desk Browser",
    deviceId: "browser-device-1",
    serverUrl: "ws://127.0.0.1:18800/ws",
    token: "jwt-token",
    userId: "user_1"
  });

  chatStore.applyStreamSnapshot([
    {
      sessionKey: "agent:main:clawline:user_1:main",
      displayName: "Personal",
      kind: "main",
      orderIndex: 0,
      isBuiltIn: true,
      createdAt: 10,
      updatedAt: 10,
      adopted: false
    },
    {
      sessionKey: "agent:main:clawline:user_1:side",
      displayName: "Side Thread",
      kind: "custom",
      orderIndex: 1,
      isBuiltIn: false,
      createdAt: 11,
      updatedAt: 11,
      adopted: false
    }
  ]);
  chatStore.applyIncomingMessage(
    {
      type: "message",
      id: "s_main",
      role: "assistant",
      content: "Main thread",
      timestamp: 10,
      streaming: false,
      sessionKey: "agent:main:clawline:user_1:main",
      attachments: []
    },
    "browser-device-1"
  );
  chatStore.applyIncomingMessage(
    {
      type: "message",
      id: "s_side",
      role: "assistant",
      content: "Side thread",
      timestamp: 11,
      streaming: false,
      sessionKey: "agent:main:clawline:user_1:side",
      attachments: []
    },
    "browser-device-1"
  );

  const transportMachine = createTransportMachine({
    authSessionStore: authStore,
    chatDomainStore: chatStore,
    webSocketFactory: webSocketFactory.create
  });
  webSocketFactory.sockets[0]?.emitOpen();
  webSocketFactory.sockets[0]?.emitMessage(
    JSON.stringify({ type: "auth_result", success: true })
  );

  return render(
    <SettingsStoreProvider value={settingsStore}>
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
          <TransportMachineProvider value={transportMachine}>
            <MemoryRouter initialEntries={[initialPath]}>
              <Routes>
                <Route
                  element={
                    <>
                      <ChatRoute />
                      <LocationProbe />
                    </>
                  }
                  path="/chat/:sessionKey?"
                />
              </Routes>
            </MemoryRouter>
          </TransportMachineProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    </SettingsStoreProvider>
  );
}

describe("ChatRoute", () => {
  it("uses the URL-selected session as the authoritative conversation", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:side");

    expect(screen.getByText("Side thread")).toBeInTheDocument();
    expect(screen.queryByText("Main thread")).not.toBeInTheDocument();
  });

  it("opens settings as an overlay without changing the route", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Settings" }));

    expect(screen.getByRole("heading", { name: "Appearance and diagnostics" })).toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
  });
});
