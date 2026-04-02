import { fireEvent, render, screen, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MessageList } from "./MessageList";
import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";
import {
  AuthSessionStoreProvider,
  createAuthSessionStore
} from "../../runtime/auth/authSessionStore";

const RICH_MESSAGE: ChatMessageRecord = {
  id: "s_rich",
  role: "assistant",
  content: [
    "Intro paragraph.",
    "",
    "```ts",
    "console.log('hi');",
    "```",
    "",
    "After code.",
    "",
    "| Name | Value |",
    "| --- | --- |",
    "| alpha | beta |"
  ].join("\n"),
  timestamp: 1_764_201_200_000,
  streaming: false,
  sessionKey: "agent:main:clawline:flynn:main",
  attachments: [],
  delivery: "server",
  sender: "Assistant"
};

const ATTACHMENT_MESSAGE: ChatMessageRecord = {
  id: "s_attachments",
  role: "assistant",
  content: "Attachment surface",
  timestamp: 1_764_201_200_100,
  streaming: false,
  sessionKey: "agent:main:clawline:flynn:main",
  attachments: [
    {
      type: "image",
      mimeType: "image/png",
      data: "aW1hZ2U="
    },
    {
      type: "asset",
      assetId: "audio_1",
      metadata: {
        filename: "note.mp3",
        mimeType: "audio/mpeg"
      }
    },
    {
      type: "document",
      assetId: "video_1",
      metadata: {
        filename: "demo.mp4",
        mimeType: "video/mp4"
      }
    },
    {
      type: "document",
      assetId: "file_1",
      metadata: {
        filename: "report.pdf",
        mimeType: "application/pdf"
      }
    }
  ],
  delivery: "server",
  sender: "Assistant"
};

const LINK_MESSAGE: ChatMessageRecord = {
  id: "s_links",
  role: "assistant",
  content: [
    "Visit https://example.com/docs for docs.",
    "",
    "Here is a markdown link to [OpenAI](https://openai.com/research).",
    "",
    "```",
    "https://example.com/in-code",
    "```"
  ].join("\n"),
  timestamp: 1_764_201_200_200,
  streaming: false,
  sessionKey: "agent:main:clawline:flynn:main",
  attachments: [],
  delivery: "server",
  sender: "Assistant"
};

function makeMessage(index: number): ChatMessageRecord {
  return {
    id: `s_bulk_${index}`,
    role: index % 3 === 0 ? "user" : "assistant",
    content: `Message ${index} ${"detail ".repeat(24)}`,
    timestamp: 1_764_201_300_000 + index,
    streaming: false,
    sessionKey: "agent:main:clawline:flynn:main",
    attachments: [],
    delivery: "server",
    sender: index % 3 === 0 ? undefined : "Assistant"
  };
}

function renderMessageList(messages: ChatMessageRecord[]) {
  const authStore = createAuthSessionStore();
  authStore.storePairingSession({
    claimedName: "Desk Browser",
    deviceId: "browser-device-1",
    serverUrl: "ws://127.0.0.1:18800/ws",
    token: "jwt-token",
    userId: "user_1"
  });

  return render(
    <AuthSessionStoreProvider value={authStore}>
      <MessageList messages={messages} />
    </AuthSessionStoreProvider>
  );
}

function renderMessageListWithProps(input: {
  messages: ChatMessageRecord[];
  rememberedScrollState?: {
    offsetTop: number;
    stickToBottom: boolean;
  };
  sessionKey?: string;
  unreadAnchorMessageId?: string | null;
}) {
  const authStore = createAuthSessionStore();
  authStore.storePairingSession({
    claimedName: "Desk Browser",
    deviceId: "browser-device-1",
    serverUrl: "ws://127.0.0.1:18800/ws",
    token: "jwt-token",
    userId: "user_1"
  });

  return render(
    <AuthSessionStoreProvider value={authStore}>
      <MessageList
        messages={input.messages}
        rememberedScrollState={input.rememberedScrollState}
        sessionKey={input.sessionKey}
        unreadAnchorMessageId={input.unreadAnchorMessageId}
      />
    </AuthSessionStoreProvider>
  );
}

const originalCreateObjectUrl = URL.createObjectURL;
const originalRevokeObjectUrl = URL.revokeObjectURL;

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof URL ? input : new URL(String(input));
      if (url.pathname.endsWith("/audio_1")) {
        return new Response(new Blob(["audio"], { type: "audio/mpeg" }), { status: 200 });
      }
      if (url.pathname.endsWith("/video_1")) {
        return new Response(new Blob(["video"], { type: "video/mp4" }), { status: 200 });
      }
      if (url.pathname.endsWith("/file_1")) {
        return new Response(new Blob(["file"], { type: "application/pdf" }), { status: 200 });
      }
      return new Response(null, { status: 404 });
    })
  );

  Object.defineProperty(URL, "createObjectURL", {
    configurable: true,
    value: vi.fn((value: Blob) => `blob:${value.type || "application/octet-stream"}`)
  });
  Object.defineProperty(URL, "revokeObjectURL", {
    configurable: true,
    value: vi.fn()
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  Object.defineProperty(URL, "createObjectURL", {
    configurable: true,
    value: originalCreateObjectUrl
  });
  Object.defineProperty(URL, "revokeObjectURL", {
    configurable: true,
    value: originalRevokeObjectUrl
  });
});

describe("MessageList rich rendering", () => {
  it("renders sender avatar waypoints with paired initials and alignment", () => {
    renderMessageList([
      RICH_MESSAGE,
      {
        id: "s_user",
        role: "user",
        content: "On it.",
        timestamp: 1_764_201_200_050,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server"
      }
    ]);

    const assistantAvatar = screen.getByTestId("message-avatar-s_rich");
    const assistantBubble = screen.getByTestId("message-s_rich");
    expect(assistantAvatar).toHaveTextContent("A");
    expect(assistantBubble.parentElement?.firstElementChild).toBe(assistantAvatar);

    const userAvatar = screen.getByTestId("message-avatar-s_user");
    const userBubble = screen.getByTestId("message-s_user");
    expect(userAvatar).toHaveTextContent("Y");
    expect(userBubble.parentElement?.lastElementChild).toBe(userAvatar);
  });

  it("renders markdown blocks in source order", () => {
    renderMessageList([RICH_MESSAGE]);

    const bubble = screen.getByTestId("message-s_rich");
    const markdown = bubble.querySelector(".message-markdown");
    expect(markdown).not.toBeNull();

    const children = Array.from(markdown?.children ?? []).map((child) => child.tagName);
    expect(children).toEqual(["P", "PRE", "P", "TABLE"]);
    expect(within(bubble).getByText("Intro paragraph.")).toBeInTheDocument();
    expect(within(bubble).getByText("console.log('hi');")).toBeInTheDocument();
    expect(within(bubble).getByText("After code.")).toBeInTheDocument();
    expect(within(bubble).getByRole("table")).toBeInTheDocument();
  });

  it("opens detailed messages in an expanded overlay", () => {
    renderMessageList([RICH_MESSAGE]);

    fireEvent.click(screen.getByRole("button", { name: "Expand" }));

    const dialog = screen.getByRole("dialog", { name: "Expanded message" });
    expect(within(dialog).getByText("Expanded view")).toBeInTheDocument();
    expect(within(dialog).getByText("console.log('hi');")).toBeInTheDocument();
    expect(within(dialog).getByRole("table")).toBeInTheDocument();

    fireEvent.click(within(dialog).getByRole("button", { name: "Close expanded message" }));
    expect(screen.queryByRole("dialog", { name: "Expanded message" })).not.toBeInTheDocument();
  });

  it("renders image, audio, video, and file attachments", async () => {
    renderMessageList([ATTACHMENT_MESSAGE]);

    expect(await screen.findByAltText("attachment")).toBeInTheDocument();
    expect(await screen.findByLabelText("note.mp3")).toBeInTheDocument();
    expect(await screen.findByLabelText("demo.mp4")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Download report.pdf" })).toBeInTheDocument();
  });

  it("renders link cards for visible message links but not code-block URLs", async () => {
    renderMessageList([LINK_MESSAGE]);

    const cards = await screen.findByText("EXAMPLE.COM");
    const cardSurface = cards.closest(".message-link-cards");
    expect(cardSurface).not.toBeNull();

    const linkCards = Array.from(
      (cardSurface as HTMLElement).querySelectorAll<HTMLAnchorElement>(".message-link-card")
    );
    expect(linkCards.map((card) => card.href)).toEqual([
      "https://example.com/docs",
      "https://openai.com/research"
    ]);
    expect(linkCards.some((card) => card.href.includes("in-code"))).toBe(false);
  });

  it("virtualizes large transcripts while keeping deep messages reachable", async () => {
    renderMessageList(Array.from({ length: 240 }, (_, index) => makeMessage(index + 1)));

    const list = screen.getByTestId("message-list");
    const initialRows = list.querySelectorAll<HTMLElement>('[data-testid^="message-s_bulk_"]');
    expect(initialRows.length).toBeGreaterThan(0);
    expect(initialRows.length).toBeLessThan(30);
    expect(screen.queryByTestId("message-s_bulk_240")).not.toBeInTheDocument();

    fireEvent.scroll(list, { target: { scrollTop: 100_000 } });

    expect(await screen.findByTestId("message-s_bulk_240")).toBeInTheDocument();
    expect(screen.queryByTestId("message-s_bulk_1")).not.toBeInTheDocument();
  });

  it("restores persisted scroll position for the selected session", async () => {
    renderMessageListWithProps({
      messages: Array.from({ length: 240 }, (_, index) => makeMessage(index + 1)),
      rememberedScrollState: {
        offsetTop: 100_000,
        stickToBottom: false
      },
      sessionKey: "agent:main:clawline:flynn:main"
    });

    expect(await screen.findByTestId("message-s_bulk_240")).toBeInTheDocument();
    expect(screen.queryByTestId("message-s_bulk_1")).not.toBeInTheDocument();
  });

  it("anchors to the first unread message before unread clears", async () => {
    renderMessageListWithProps({
      messages: Array.from({ length: 240 }, (_, index) => makeMessage(index + 1)),
      sessionKey: "agent:main:clawline:flynn:main",
      unreadAnchorMessageId: "s_bulk_200"
    });

    expect(await screen.findByTestId("message-s_bulk_200")).toBeInTheDocument();
    expect(screen.queryByTestId("message-s_bulk_1")).not.toBeInTheDocument();
  });

  it("anchors when unread state arrives after initial session restoration", async () => {
    const authStore = createAuthSessionStore();
    authStore.storePairingSession({
      claimedName: "Desk Browser",
      deviceId: "browser-device-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token",
      userId: "user_1"
    });
    const onUnreadAnchorConsumed = vi.fn();
    const messages = Array.from({ length: 240 }, (_, index) => makeMessage(index + 1));

    const view = render(
      <AuthSessionStoreProvider value={authStore}>
        <MessageList
          messages={messages}
          onUnreadAnchorConsumed={onUnreadAnchorConsumed}
          sessionKey="agent:main:clawline:flynn:main"
          unreadAnchorMessageId={null}
        />
      </AuthSessionStoreProvider>
    );

    view.rerender(
      <AuthSessionStoreProvider value={authStore}>
        <MessageList
          messages={messages}
          onUnreadAnchorConsumed={onUnreadAnchorConsumed}
          sessionKey="agent:main:clawline:flynn:main"
          unreadAnchorMessageId="s_bulk_200"
        />
      </AuthSessionStoreProvider>
    );

    expect(await screen.findByTestId("message-s_bulk_200")).toBeInTheDocument();
    expect(onUnreadAnchorConsumed).toHaveBeenCalledWith("s_bulk_200");
  });

  it("shows a jump-to-latest affordance when scrolled away from bottom", async () => {
    renderMessageListWithProps({
      messages: Array.from({ length: 240 }, (_, index) => makeMessage(index + 1)),
      sessionKey: "agent:main:clawline:flynn:main"
    });

    const list = screen.getByTestId("message-list");
    fireEvent.scroll(list, { target: { scrollTop: 20_000 } });

    expect(await screen.findByTestId("scroll-to-bottom-button")).toBeInTheDocument();
  });
});
