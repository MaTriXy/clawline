import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("messages use the wrapping flow layout without blank bubbles", async ({ page }) => {
  const port = 24_401 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:flynn:main";
  const server = createServer();
  const wss = new WebSocketServer({ server, path: "/ws" });
  let authRequestCount = 0;
  let socketCount = 0;

  wss.on("connection", (socket) => {
    socketCount += 1;
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "auth") {
        authRequestCount += 1;
        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "user_flynn",
            replayCount: 0,
            sessionKeys: [sessionKey]
          })
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "user_flynn",
            isAdmin: false,
            sessionKeys: [sessionKey]
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
                createdAt: 1_764_650_000_000,
                updatedAt: 1_764_650_000_000
              }
            ]
          })
        );

        for (const message of [
          {
            type: "message",
            id: "s_flow_1",
            role: "assistant",
            content: "Want tea?",
            timestamp: 1_764_650_000_010,
            streaming: false,
            sessionKey,
            attachments: []
          },
          {
            type: "message",
            id: "s_flow_2",
            role: "user",
            content: "Yes please!",
            timestamp: 1_764_650_000_020,
            streaming: false,
            sessionKey,
            attachments: []
          },
          {
            type: "message",
            id: "s_flow_3",
            role: "assistant",
            content: "Speaking of ceramics, I found this workshop!",
            timestamp: 1_764_650_000_030,
            streaming: false,
            sessionKey,
            attachments: []
          },
          {
            type: "message",
            id: "s_flow_4",
            role: "assistant",
            content:
              "This longer explanation should break onto its own row and keep a comfortable line length instead of trying to share space with the short reactions above it.",
            timestamp: 1_764_650_000_040,
            streaming: false,
            sessionKey,
            attachments: []
          }
        ]) {
          socket.send(JSON.stringify(message));
        }
      }
    });
  });

  await new Promise<void>((resolve) => {
    server.listen(port, "127.0.0.1", () => resolve());
  });
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(String(error)));

  try {
    await page.addInitScript((session) => {
      window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
      window.localStorage.setItem(
        "clawline-web:device-id",
        JSON.stringify(session.deviceId)
      );
    }, {
      claimedName: "Flynn Browser",
      deviceId: "phase5-flow-device",
      isAdmin: false,
      serverUrl: `ws://127.0.0.1:${port}/ws`,
      token: "jwt-phase5-flow-token",
      userId: "user_flynn"
    });
    await page.setViewportSize({ width: 820, height: 1180 });
    await page.goto(`/chat/${sessionKey}`);
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));
    await expect(page.getByTestId("message-s_flow_1")).toBeVisible();
    const debugState = {
      authRequestCount,
      bodyText: await page.locator("body").innerText(),
      messageCount: await page.locator('[data-testid^="message-s_flow_"]').count(),
      path: page.url(),
      rawHtml: await page
        .locator('[data-testid="message-list"]')
        .evaluate((element) => element.innerHTML)
        .catch(() => null),
      socketCount,
    };
    expect(debugState.messageCount, JSON.stringify(debugState)).toBe(4);
    expect(pageErrors, JSON.stringify(debugState)).toEqual([]);

    await expect(page.getByTestId("message-s_flow_1")).toContainText("Want tea?");
    await expect(page.getByTestId("message-s_flow_2")).toContainText("Yes please!");
    await expect(page.getByTestId("message-s_flow_3")).toContainText(
      "Speaking of ceramics, I found this workshop!"
    );
    await expect(page.getByTestId("message-s_flow_4")).toContainText(
      "This longer explanation should break onto its own row and keep a comfortable line length instead of trying to share space with the short reactions above it."
    );

    const positions = await page.evaluate(() => {
      function metrics(id: string) {
        const bubble = document.querySelector<HTMLElement>(`[data-testid="message-${id}"]`);
        if (!bubble) {
          return null;
        }
        const rect = bubble.getBoundingClientRect();
        return {
          height: rect.height,
          left: rect.left,
          top: rect.top,
          width: rect.width
        };
      }

      return {
        first: metrics("s_flow_1"),
        second: metrics("s_flow_2"),
        third: metrics("s_flow_3"),
        fourth: metrics("s_flow_4")
      };
    });

    expect(positions.first).not.toBeNull();
    expect(positions.second).not.toBeNull();
    expect(positions.third).not.toBeNull();
    expect(positions.fourth).not.toBeNull();
    expect(Math.abs(positions.first!.top - positions.second!.top)).toBeLessThanOrEqual(4);
    expect(positions.second!.left).toBeGreaterThan(positions.first!.left + 40);
    expect(positions.third!.top).toBeGreaterThan(positions.first!.top + positions.first!.height);
    expect(positions.third!.width).toBeGreaterThanOrEqual(200);
    expect(positions.third!.width).toBeLessThan(460);
    expect(positions.fourth!.top).toBeGreaterThan(positions.third!.top + positions.third!.height);
    for (const appearance of ["dark", "light"] as const) {
      await applyAppearance(page, appearance);
      await expect(page.getByTestId("message-list")).toHaveScreenshot(
        `phase5-flow-layout-${appearance}.png`,
        {
          animations: "disabled",
          caret: "hide",
          maxDiffPixelRatio: 0.02
        }
      );
    }
  } finally {
    try {
      await page.goto("about:blank");
    } catch {
      // Ignore teardown navigation errors if the test already closed the page.
    }
    for (const client of wss.clients) {
      client.terminate();
    }
    await new Promise<void>((resolve, reject) => {
      wss.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        server.close((serverError) => {
          if (serverError) {
            reject(serverError);
            return;
          }
          resolve();
        });
      });
    });
  }
});

async function applyAppearance(
  page: import("@playwright/test").Page,
  appearance: "dark" | "light"
) {
  await page.evaluate((mode) => {
    window.localStorage.setItem(
      "clawline-web:settings",
      JSON.stringify({
        appearance: mode,
        diagnostics: false,
        fontScale: "default"
      })
    );
    document.documentElement.dataset.appearance = mode;
  }, appearance);
  await page.reload();
}

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
