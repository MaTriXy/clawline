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

      for (const appearance of ["dark", "light"] as const) {
        await page.setViewportSize({ height: 1180, width: 820 });
        await page.goto(`/chat/${MAIN_SESSION_KEY}`);
        await applyAppearance(page, appearance);
        await expect(page.getByRole("button", { name: "Manage streams" })).toBeVisible();
        const dots = page.getByRole("button", { name: "Manage streams" });
        await expect(page.getByTestId("composer-input-bar")).toBeVisible();

        await expect(page.getByTestId("chat-layout")).toHaveScreenshot(
          `phase5-chat-shell-${appearance}.png`,
          { animations: "disabled" }
        );

        await dots.click();
        const popover = page.getByTestId("session-popover");
        await expect(popover).toBeVisible();
        const popoverBox = await popover.boundingBox();
        expect(popoverBox).not.toBeNull();
        expect(popoverBox!.width).toBeLessThan(820 * 0.52);
        await expect(popover).toHaveScreenshot(`phase5-session-popover-${appearance}.png`, {
          animations: "disabled"
        });
        await page.mouse.click(12, 12);
        await expect(popover).toHaveCount(0);

        if (appearance === "dark") {
          await swipeChatPanel(page, { endX: 120, startX: 300, y: 360 });
          await expect(page.getByText("Responsive shell check")).toBeVisible();
          await expect(page).toHaveURL(new RegExp(`${SIDE_SESSION_KEY.replaceAll(":", "\\:")}$`));

          await swipeChatPanel(page, { endX: 300, startX: 120, y: 360 });
          await expect(page.getByText("Keyboard flow check")).toBeVisible();
          await expect(page).toHaveURL(new RegExp(`${MAIN_SESSION_KEY.replaceAll(":", "\\:")}$`));
        }
      }

      for (const viewport of [{ height: 1180, width: 820 }, { height: 844, width: 390 }]) {
        await page.setViewportSize(viewport);
        await page.goto(`/chat/${MAIN_SESSION_KEY}`);
        await expect(page.getByRole("button", { name: "Manage streams" })).toBeVisible();
        expect(await page.getByTestId("session-popover").count()).toBe(0);

        const dots = page.getByRole("button", { name: "Manage streams" });
        await expect(page.getByTestId("composer-input-bar")).toBeVisible();

        await dots.click();
        const popover = page.getByTestId("session-popover");
        await expect(popover).toBeVisible();
        const popoverBox = await popover.boundingBox();
        expect(popoverBox).not.toBeNull();

        if (viewport.width > 500) {
          expect(popoverBox!.width).toBeLessThan(viewport.width * 0.52);
        } else {
          expect(popoverBox!.width).toBeGreaterThan(viewport.width * 0.78);
        }

        await expect(page.getByTestId("session-popover-list")).toBeVisible();
        await page.mouse.click(12, 12);
        await expect(popover).toHaveCount(0);

        if (viewport.width <= 390) {
          expect(
            await page.locator(".chat-floating-stack").evaluate((element) => {
              return window.getComputedStyle(element).justifyItems;
            })
          ).toBe("center");
          expect(
            await page.locator(".composer-input-bar").evaluate((element) => {
              return window.getComputedStyle(element).display;
            })
          ).toBe("grid");
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
      await expect(page.getByRole("button", { name: "Manage streams" })).toBeVisible();

      const focusOrder = await captureFocusOrder(page, 3);
      expect(focusOrder).toEqual([
        "Manage streams",
        "Add attachment",
        "Message"
      ]);

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

  test("sending with a mobile keyboard inset keeps the newest bubbles above the keyboard", async ({ page }) => {
    const { close, receivedClientMessages, port } = await startPhase5Server();

    try {
      await page.addInitScript(() => {
        const listeners = new Map<string, Set<EventListener>>();
        let height = window.innerHeight;
        let offsetTop = 0;

        const visualViewport = {
          get width() {
            return window.innerWidth;
          },
          get height() {
            return height;
          },
          get offsetTop() {
            return offsetTop;
          },
          addEventListener(type: string, listener: EventListener) {
            const bucket = listeners.get(type) ?? new Set<EventListener>();
            bucket.add(listener);
            listeners.set(type, bucket);
          },
          removeEventListener(type: string, listener: EventListener) {
            listeners.get(type)?.delete(listener);
          }
        };

        const dispatch = (type: string) => {
          const event = new Event(type);
          for (const listener of listeners.get(type) ?? []) {
            listener.call(visualViewport, event);
          }
        };

        Object.defineProperty(window, "visualViewport", {
          configurable: true,
          get() {
            return visualViewport;
          }
        });

        Object.assign(window, {
          __setVisualViewportInsetForTest(nextInset: number) {
            height = Math.max(0, window.innerHeight - nextInset);
            offsetTop = 0;
            dispatch("resize");
            dispatch("scroll");
          }
        });
      });

      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      await page.setViewportSize({ height: 844, width: 390 });
      await page.goto(`/chat/${MAIN_SESSION_KEY}`);
      const composer = page.getByLabel("Message");
      await composer.click();
      await setVisualViewportInset(page, 280);

      await expect
        .poll(() => readKeyboardInset(page))
        .toBe("280px");

      await composer.fill("Latest bubble stays visible");
      await page.keyboard.press("Enter");

      await expect
        .poll(() => receivedClientMessages.at(-1)?.content ?? null)
        .toBe("Latest bubble stays visible");

      await setVisualViewportInset(page, 0);
      await setVisualViewportInset(page, 280);

      await expect(composer).toBeFocused();
      await expect(composer).toHaveValue("");
      await expect
        .poll(() => readKeyboardInset(page))
        .toBe("280px");
      await expect(page.getByText("Latest bubble stays visible")).toBeVisible();

      await expect
        .poll(async () => {
          const messageBox = await page.locator(".message-bubble--user").last().boundingBox();
          const composerBox = await page.getByTestId("composer-input-bar").boundingBox();

          if (!messageBox || !composerBox) {
            return null;
          }

          return Math.round(composerBox.y - (messageBox.y + messageBox.height));
        })
        .toBeGreaterThanOrEqual(8);
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

async function applyAppearance(
  page: import("@playwright/test").Page,
  appearance: "dark" | "light"
) {
  await page.waitForLoadState("domcontentloaded");
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

async function swipeChatPanel(
  page: import("@playwright/test").Page,
  input: { endX: number; startX: number; y: number }
) {
  await page.getByTestId("chat-panel").evaluate((element, gesture) => {
    const start = new Event("touchstart", { bubbles: true, cancelable: true });
    Object.defineProperty(start, "touches", {
      value: [{ clientX: gesture.startX, clientY: gesture.y }]
    });
    Object.defineProperty(start, "changedTouches", {
      value: [{ clientX: gesture.startX, clientY: gesture.y }]
    });
    element.dispatchEvent(start);

    const end = new Event("touchend", { bubbles: true, cancelable: true });
    Object.defineProperty(end, "touches", { value: [] });
    Object.defineProperty(end, "changedTouches", {
      value: [{ clientX: gesture.endX, clientY: gesture.y }]
    });
    element.dispatchEvent(end);
  }, input);
}

async function readKeyboardInset(page: import("@playwright/test").Page) {
  return page.getByTestId("chat-layout").evaluate((element) => {
    return window.getComputedStyle(element).getPropertyValue("--chat-keyboard-inset").trim();
  });
}

async function setVisualViewportInset(
  page: import("@playwright/test").Page,
  inset: number
) {
  await page.evaluate((nextInset) => {
    (
      window as typeof window & {
        __setVisualViewportInsetForTest?: (value: number) => void;
      }
    ).__setVisualViewportInsetForTest?.(nextInset);
  }, inset);
}

async function captureFocusOrder(
  page: import("@playwright/test").Page,
  steps: number
) {
  const labels: string[] = [];

  for (let index = 0; index < steps; index += 1) {
    await page.keyboard.press("Tab");
    labels.push(
      await page.evaluate(() => {
        const element = document.activeElement as HTMLElement | null;
        if (!element) {
          return "<none>";
        }

        if (element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement) {
          return element.labels?.[0]?.textContent?.trim() ?? element.id ?? element.tagName;
        }

        return (
          element.getAttribute("aria-label") ??
          element.getAttribute("aria-labelledby") ??
          element.textContent?.replace(/\s+/g, " ").trim() ??
          element.tagName
        );
      })
    );
  }

  return labels.map((label) => label.replace(/(?<=\w)(ready)(?=\w)/g, " ready "));
}
