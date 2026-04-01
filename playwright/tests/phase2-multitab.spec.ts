import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("second tab mirrors through one leader-owned socket", async ({ page }) => {
  const port = 18_801 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:flynn:main";
  let authCount = 0;
  let currentDeviceId = "DEVICE_TEST";

  const wss = new WebSocketServer({ port });

  wss.on("connection", (socket) => {
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as {
        type: string;
        id?: string;
        content?: string;
        deviceId?: string;
        sessionKey?: string;
      };

      if (payload.type === "pair_request") {
        currentDeviceId = payload.deviceId ?? currentDeviceId;
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
        currentDeviceId = payload.deviceId ?? currentDeviceId;
        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "user_flynn",
            sessionId: "sess_1",
            isAdmin: false,
            replayCount: 1,
            replayTruncated: false,
            historyReset: false,
            sessions: [{ stream: "main", sessionKey }]
          })
        );
        socket.send(
          JSON.stringify({
            type: "stream_snapshot",
            streams: [
              {
                sessionKey,
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: 1_764_133_200_000,
                updatedAt: 1_764_133_200_000
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_bootstrap",
            role: "assistant",
            content: "leader is live",
            timestamp: 1_764_133_200_200,
            streaming: false,
            sessionKey,
            attachments: []
          })
        );
        return;
      }

      if (payload.type === "message" && payload.id && payload.content) {
        socket.send(JSON.stringify({ type: "ack", id: payload.id }));
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_user_echo_shared",
            role: "user",
            content: payload.content,
            timestamp: 1_764_133_201_000,
            streaming: false,
            deviceId: currentDeviceId,
            sessionKey: payload.sessionKey,
            attachments: []
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_assistant_shared",
            role: "assistant",
            content: "mirrored across tabs",
            timestamp: 1_764_133_201_200,
            streaming: false,
            sessionKey: payload.sessionKey,
            attachments: []
          })
        );
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
      new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`)
    );
    await expect(page.getByText("leader is live")).toBeVisible();
    await expect.poll(() => authCount).toBe(1);

    await secondPage.goto(`/chat/${sessionKey}`);
    await expect(secondPage.getByText("leader is live")).toBeVisible();
    await expect.poll(() => authCount).toBe(1);
    await expect.poll(() => wss.clients.size).toBe(1);

    await secondPage.getByLabel("Message").fill("hello from tab two");
    await secondPage.getByRole("button", { name: "Send" }).click();

    await expect(page.getByText("mirrored across tabs")).toBeVisible();
    await expect(secondPage.getByText("mirrored across tabs")).toBeVisible();
    await expect.poll(() => authCount).toBe(1);
    await expect.poll(() => wss.clients.size).toBe(1);
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
