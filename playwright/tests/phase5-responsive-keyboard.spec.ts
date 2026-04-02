import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test.describe("Phase 5 responsive and keyboard flow", () => {
  test("chat shell stays usable on iPad and mobile breakpoints", async ({ page }) => {
    const { close, port } = await startPhase5Server();

    try {
      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      for (const viewport of [
        { height: 1180, width: 820 },
        { height: 844, width: 390 }
      ]) {
        await page.setViewportSize(viewport);
        await page.goto(`/chat/${MAIN_SESSION_KEY}`);
        await expect(page.locator(".status-pill", { hasText: "Connected" })).toBeVisible();

        const railBox = await page.getByTestId("stream-rail").boundingBox();
        const panelBox = await page.getByTestId("chat-panel").boundingBox();
        expect(railBox).not.toBeNull();
        expect(panelBox).not.toBeNull();
        expect(railBox!.y).toBeLessThan(panelBox!.y);
        expect(Math.abs(railBox!.x - panelBox!.x)).toBeLessThanOrEqual(2);
        expect(Math.abs(railBox!.width - panelBox!.width)).toBeLessThanOrEqual(2);

        expect(
          await page.getByTestId("stream-rail-list").evaluate((element) => {
            const styles = window.getComputedStyle(element);
            return {
              gridAutoFlow: styles.gridAutoFlow,
              overflowX: styles.overflowX
            };
          })
        ).toEqual({
          gridAutoFlow: "column",
          overflowX: "auto"
        });

        if (viewport.width <= 390) {
          expect(
            await page.locator(".chat-header-actions").evaluate((element) => {
              return window.getComputedStyle(element).flexWrap;
            })
          ).toBe("wrap");
          expect(
            await page.locator(".composer-footer").evaluate((element) => {
              return window.getComputedStyle(element).flexWrap;
            })
          ).toBe("wrap");
        }
      }
    } finally {
      await close();
    }
  });

  test("composer supports keyboard send, newline, and dismiss flow", async ({ page }) => {
    const { close, port, receivedClientMessages } = await startPhase5Server();

    try {
      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      await page.setViewportSize({ height: 1180, width: 820 });
      await page.goto(`/chat/${MAIN_SESSION_KEY}`);
      await expect(page.locator(".status-pill", { hasText: "Connected" })).toBeVisible();

      await focusComposerWithKeyboard(page);

      await page.keyboard.type("Line one");
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.type("Line two");
      await expect(page.getByLabel("Message")).toHaveValue("Line one\nLine two");

      await page.keyboard.press("Enter");

      await expect
        .poll(() => receivedClientMessages.at(-1)?.content ?? null)
        .toBe("Line one\nLine two");
      await expect(page.getByText("Line one")).toBeVisible();
      await expect(page.getByText("Line two")).toBeVisible();
      await expect(page.getByLabel("Message")).toHaveValue("");
      await expect(page.getByLabel("Message")).toBeFocused();

      await page.keyboard.type("Draft to dismiss");
      await page.keyboard.press("Escape");
      await expect(page.getByLabel("Message")).not.toBeFocused();
    } finally {
      await close();
    }
  });
});

const MAIN_SESSION_KEY = "agent:main:clawline:flynn:main";
const SIDE_SESSION_KEY = "agent:main:clawline:flynn:side";

async function startPhase5Server() {
  const port = 24_501 + Math.floor(Math.random() * 1_000);
  const server = createServer();
  const wss = new WebSocketServer({ server, path: "/ws" });
  const sockets = new Set<import("ws").WebSocket>();
  const receivedClientMessages: Array<{ content: string; id: string; sessionKey?: string }> = [];

  wss.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "auth") {
        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "user_flynn",
            replayCount: 2,
            sessionKeys: [MAIN_SESSION_KEY, SIDE_SESSION_KEY]
          })
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "user_flynn",
            isAdmin: false,
            sessionKeys: [MAIN_SESSION_KEY, SIDE_SESSION_KEY]
          })
        );
        socket.send(
          JSON.stringify({
            type: "stream_snapshot",
            streams: [
              {
                sessionKey: MAIN_SESSION_KEY,
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: 1_764_400_000_000,
                updatedAt: 1_764_400_000_000,
                adopted: false
              },
              {
                sessionKey: SIDE_SESSION_KEY,
                displayName: "Side",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: 1_764_400_000_100,
                updatedAt: 1_764_400_000_100,
                adopted: false
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_phase5_1",
            role: "assistant",
            content: "Keyboard flow check",
            timestamp: 1_764_400_000_200,
            streaming: false,
            sessionKey: MAIN_SESSION_KEY,
            attachments: []
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_phase5_2",
            role: "assistant",
            content: "Responsive shell check",
            timestamp: 1_764_400_000_300,
            streaming: false,
            sessionKey: SIDE_SESSION_KEY,
            attachments: []
          })
        );
        return;
      }

      if (payload.type === "message") {
        receivedClientMessages.push(payload as { content: string; id: string; sessionKey?: string });
        socket.send(JSON.stringify({ type: "ack", id: payload.id }));
        socket.send(
          JSON.stringify({
            type: "message",
            id: `server_${payload.id}`,
            role: "user",
            content: (payload as { content: string }).content,
            timestamp: Date.now(),
            streaming: false,
            deviceId: "browser-device-1",
            sessionKey: (payload as { sessionKey?: string }).sessionKey ?? MAIN_SESSION_KEY,
            attachments: []
          })
        );
      }
    });
  });

  await new Promise<void>((resolve) => {
    server.listen(port, "127.0.0.1", () => resolve());
  });

  return {
    close: async () => {
      await Promise.resolve();
      await Promise.all(
        Array.from(sockets, (socket) => {
          socket.terminate();
          return Promise.resolve();
        })
      );
      server.closeAllConnections?.();
      await new Promise<void>((resolve, reject) => {
        wss.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          server.close((closeError) => {
            if (closeError) {
              reject(closeError);
              return;
            }
            resolve();
          });
        });
      });
    },
    port,
    receivedClientMessages
  };
}

function makeSession(port: number) {
  return {
    claimedName: "Flynn Browser",
    deviceId: "browser-device-1",
    isAdmin: false,
    serverUrl: `ws://127.0.0.1:${port}/ws`,
    token: "jwt-phase5-token",
    userId: "user_flynn"
  };
}

async function focusComposerWithKeyboard(page: import("@playwright/test").Page) {
  for (let attempt = 0; attempt < 16; attempt += 1) {
    await page.keyboard.press("Tab");
    const activeId = await page.evaluate(() => {
      return (document.activeElement as HTMLElement | null)?.id ?? null;
    });
    if (activeId === "composer-input") {
      return;
    }
  }

  throw new Error("Failed to focus composer input with keyboard navigation");
}
