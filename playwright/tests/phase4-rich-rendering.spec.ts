import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("markdown messages render rich blocks and expand into an overlay", async ({ page }) => {
  const port = 21_901 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:flynn:main";
  const richContent = [
    "Intro paragraph.",
    "",
    "```ts",
    "console.log('phase4');",
    "```",
    "",
    "| Name | Value |",
    "| --- | --- |",
    "| alpha | beta |"
  ].join("\n");

  const server = createServer();
  const wss = new WebSocketServer({ server, path: "/ws" });

  wss.on("connection", (socket) => {
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "pair_request") {
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-phase4-token",
            userId: "user_flynn"
          })
        );
        return;
      }

      if (payload.type === "auth") {
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
            isAdmin: true,
            sessionKeys: [sessionKey]
          })
        );
        socket.send(
          JSON.stringify({
            type: "stream_snapshot",
            streams: [
              {
                sessionKey,
                displayName: "Personal",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: 1_764_201_200_000,
                updatedAt: 1_764_201_200_000,
                adopted: false
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_rich_1",
            role: "assistant",
            content: richContent,
            timestamp: 1_764_201_200_100,
            streaming: false,
            sessionKey,
            attachments: []
          })
        );
      }
    });
  });

  await new Promise<void>((resolve) => {
    server.listen(port, "127.0.0.1", () => resolve());
  });

  try {
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Flynn Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));
    await expect(page.locator(".message-markdown pre")).toContainText("console.log('phase4');");
    await expect(page.locator(".message-markdown table")).toContainText("alpha");
    await expect(page.locator('[data-testid="message-s_rich_1"] .message-markdown')).toHaveScreenshot(
      "phase4-rich-rendering-message.png",
      {
        animations: "disabled",
        caret: "hide"
      }
    );

    await page.getByRole("button", { name: "Expand" }).click();
    const dialog = page.getByRole("dialog", { name: "Expanded message" });
    await expect(dialog).toContainText("Expanded view");
    await expect(dialog.locator("pre")).toContainText("console.log('phase4');");
    await expect(dialog.locator("table")).toContainText("beta");
    await expect(dialog).toHaveScreenshot("phase4-rich-rendering-overlay.png", {
      animations: "disabled",
      caret: "hide"
    });
    await dialog.getByRole("button", { name: "Close" }).click();
    await expect(dialog).toHaveCount(0);
  } finally {
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

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
