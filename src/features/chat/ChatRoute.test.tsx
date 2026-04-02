import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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

const TEST_STREAMS = [
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
    sessionKey: "agent:main:main",
    displayName: "Global DM",
    kind: "global_dm",
    orderIndex: 1,
    isBuiltIn: true,
    createdAt: 10,
    updatedAt: 10,
    adopted: true
  },
  {
    sessionKey: "agent:main:clawline:user_1:side",
    displayName: "Side Thread",
    kind: "custom",
    orderIndex: 2,
    isBuiltIn: false,
    createdAt: 11,
    updatedAt: 11,
    adopted: false
  }
] as const;

function LocationProbe() {
  const location = useLocation();
  return <div data-testid="location">{location.pathname}</div>;
}

function renderChatRoute(
  initialPath: string,
  {
    sessionKeys = ["agent:main:clawline:user_1:main", "agent:main:main"]
  }: {
    sessionKeys?: string[];
  } = {}
) {
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

  chatStore.applyStreamSnapshot(TEST_STREAMS.map((stream) => ({ ...stream })));
  chatStore.applySessionInfo({
    type: "session_info",
    sessionKeys
  });
  chatStore.applyIncomingMessage(
    {
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_main",
        role: "assistant",
        content: "Main thread",
        timestamp: 10,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    },
  );
  chatStore.applyIncomingMessage(
    {
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side",
        role: "assistant",
        content: "Side thread",
        timestamp: 11,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    },
  );

  const transportMachine = createTransportMachine({
    authSessionStore: authStore,
    chatDomainStore: chatStore,
    webSocketFactory: webSocketFactory.create
  });
  webSocketFactory.sockets[0]?.emitOpen();
  webSocketFactory.sockets[0]?.emitMessage(
    JSON.stringify({
      type: "auth_result",
      success: true,
      sessionKeys
    })
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
  beforeEach(() => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = input instanceof URL ? input : new URL(String(input));

        if (url.pathname === "/api/streams") {
          return new Response(JSON.stringify({ streams: TEST_STREAMS }), {
            headers: { "Content-Type": "application/json" },
            status: 200
          });
        }

        if (url.pathname === "/api/trackable-sessions") {
          return new Response(JSON.stringify({ sessions: [] }), {
            headers: { "Content-Type": "application/json" },
            status: 200
          });
        }

        return new Response(JSON.stringify({ error: { code: "unexpected_path" } }), {
          headers: { "Content-Type": "application/json" },
          status: 404
        });
      })
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("keeps the URL-selected session active when provider inventory still exposes it", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:side", {
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });

    expect(screen.getByText("Side thread")).toBeInTheDocument();
    expect(screen.queryByText("Main thread")).not.toBeInTheDocument();
  });

  it("reconciles a boot-selected stream back to provider-visible inventory when it is no longer available", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:side");

    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
    expect(screen.getByText("Main thread")).toBeInTheDocument();
    expect(screen.queryByText("Side thread")).not.toBeInTheDocument();
  });

  it("opens settings as an overlay without changing the route", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Settings" }));

    expect(screen.getByRole("heading", { name: "Appearance and diagnostics" })).toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
  });

  it("opens session selection as an overlay without changing the route", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Open sessions" }));

    expect(screen.getByRole("heading", { name: "Sessions" })).toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
  });

  it("opens stream management from the session sheet without changing the route", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Open sessions" }));
    fireEvent.click(screen.getByRole("button", { name: "Manage" }));

    expect(screen.getByRole("heading", { name: "Manage sessions" })).toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
  });

  it("disables untrack for built-in adopted sessions", async () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Open sessions" }));
    fireEvent.click(screen.getByRole("button", { name: "Manage" }));

    const streamManager = await screen.findByLabelText("Manage streams");
    const globalCard = within(streamManager)
      .getByText("agent:main:main")
      .closest(".stream-manager-card");
    expect(globalCard).not.toBeNull();
    expect(
      within(globalCard as HTMLElement).queryByRole("button", { name: "Untrack" })
    ).toBeNull();
    expect(
      within(globalCard as HTMLElement).getByRole("button", { name: "Delete" })
    ).toBeDisabled();
  });

  it("clears unread state when the URL-selected session becomes active", async () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:side", {
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });

    expect(screen.getByText("Side thread")).toBeInTheDocument();

    await waitFor(() => {
      expect(screen.queryByLabelText("1 unread messages")).not.toBeInTheDocument();
    });
  });

  it("shows unavailable provisioning state when the user explicitly switches to a non-provisioned session", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Open sessions" }));
    fireEvent.click(screen.getByRole("button", { name: /Side Thread/i }));

    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:side"
    );
    expect(
      screen.getByText("This session is unavailable for sending. Switch streams and try again.")
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
  });
});
