import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("two tabs keep independent sockets, routing, and unread state", async ({
  page
}) => {
  const port = 18_801 + Math.floor(Math.random() * 1_000);
  const mainSessionKey = "agent:main:clawline:flynn:main";
  const sideSessionKey = "agent:main:clawline:flynn:side";
  let authCount = 0;
  let outboundMessageCount = 0;
  let serverMessageCounter = 0;

  const sockets = new Set<import("ws").WebSocket>();
  const wss = new WebSocketServer({ port });

  function broadcast(payload: unknown) {
    const encoded = JSON.stringify(payload);
    for (const client of sockets) {
      client.send(encoded);
    }
  }

  wss.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));

    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as {
        type: string;
        id?: string;
        content?: string;
        deviceId?: string;
        sessionKey?: string;
      };

      if (payload.type === "pair_request") {
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-test-token",
            userId: "user_flynn"
          })
        );
        return;
      }

      if (payload.type === "auth") {
        authCount += 1;
        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "user_flynn",
            sessionId: `sess_${authCount}`,
            isAdmin: false,
            replayCount: 1,
            replayTruncated: false,
            historyReset: false,
            sessions: [
              { stream: "main", sessionKey: mainSessionKey },
              { stream: "side", sessionKey: sideSessionKey }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "user_flynn",
            isAdmin: false,
            sessionKeys: [mainSessionKey, sideSessionKey]
          })
        );
        socket.send(
          JSON.stringify({
            type: "stream_snapshot",
            streams: [
              {
                sessionKey: mainSessionKey,
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: 1_764_133_200_000,
                updatedAt: 1_764_133_200_000
              },
              {
                sessionKey: sideSessionKey,
                displayName: "Side thread",
                kind: "session",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: 1_764_133_200_100,
                updatedAt: 1_764_133_200_100
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: `s_bootstrap_${authCount}`,
            role: "assistant",
            content: "bootstrap ready",
            timestamp: 1_764_133_200_200 + authCount,
            streaming: false,
            sessionKey: mainSessionKey,
            attachments: []
          })
        );
        return;
      }

      if (payload.type === "message" && payload.id && payload.content) {
        outboundMessageCount += 1;
        serverMessageCounter += 1;

        socket.send(JSON.stringify({ type: "ack", id: payload.id }));
        broadcast({
          type: "message",
          id: `s_user_echo_${serverMessageCounter}`,
          role: "user",
          content: payload.content,
          timestamp: 1_764_133_201_000 + serverMessageCounter,
          streaming: false,
          deviceId: payload.deviceId,
          sessionKey: payload.sessionKey,
          attachments: []
        });
        broadcast({
          type: "message",
          id: `s_assistant_${serverMessageCounter}`,
          role: "assistant",
          content: `ack ${serverMessageCounter}`,
          timestamp: 1_764_133_201_200 + serverMessageCounter,
          streaming: false,
          sessionKey: payload.sessionKey,
          attachments: []
        });
      }
    });
  });

  const secondPage = await page.context().newPage();

  try {
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Flynn Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();

    await expect(page).toHaveURL(
      new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`)
    );
    await expect(page.getByText("bootstrap ready").first()).toBeVisible();

    await secondPage.goto(`/chat/${mainSessionKey}`);
    await expect(secondPage.getByText("bootstrap ready").first()).toBeVisible();
    await expect.poll(() => authCount).toBe(2);
    await expect.poll(() => sockets.size).toBe(2);

    await secondPage.getByRole("button", { name: /Side thread/ }).click();
    await expect(secondPage).toHaveURL(
      new RegExp(`/chat/${escapeForRegExp(sideSessionKey)}$`)
    );
    await expect(page).toHaveURL(
      new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`)
    );

    broadcast({
      type: "message",
      id: "s_side_assistant_1",
      role: "assistant",
      content: "Side channel ping",
      timestamp: 1_764_133_202_000,
      streaming: false,
      sessionKey: sideSessionKey,
      attachments: []
    });

    await expect(secondPage.getByText("Side channel ping")).toBeVisible();
    await expect(
      page.getByLabel("1 unread messages").locator("..")
    ).toContainText("1");

    await page.getByRole("textbox", { name: "Message" }).fill("hello from tab one");
    await page.getByRole("button", { name: "Send" }).click();
    await secondPage
      .getByRole("textbox", { name: "Message" })
      .fill("hello from tab two");
    await secondPage.getByRole("button", { name: "Send" }).click();

    await expect.poll(() => outboundMessageCount).toBe(2);
    await expect.poll(() => sockets.size).toBe(2);
    await expect(page.getByText("ack 1")).toBeVisible();
    await expect(secondPage.getByText("ack 2")).toBeVisible();
    await expect(page.getByText("Sending...")).toHaveCount(0);
    await expect(secondPage.getByText("Sending...")).toHaveCount(0);
  } finally {
    await secondPage.close();
    for (const client of wss.clients) {
      client.terminate();
    }
    await new Promise<void>((resolve, reject) => {
      wss.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  }
});

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
