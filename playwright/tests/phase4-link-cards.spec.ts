import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("message links render as lightweight cards without turning code-block URLs into previews", async ({
  page
}) => {
  const port = 21_941 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:flynn:main";
  const linkContent = [
    "Visit https://example.com/docs for docs.",
    "",
    "Here is a markdown link to [OpenAI](https://openai.com/research).",
    "",
    "```",
    "https://example.com/in-code",
    "```"
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
            token: "jwt-phase4-link-token",
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
                createdAt: 1_764_202_900_000,
                updatedAt: 1_764_202_900_000,
                adopted: false
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_links_1",
            role: "assistant",
            content: linkContent,
            timestamp: 1_764_202_900_100,
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
    await page.setViewportSize({ width: 820, height: 1180 });
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Flynn Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));

    for (const appearance of ["dark", "light"] as const) {
      await applyAppearance(page, appearance);

      await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));

      const docsCard = page.locator('.message-link-card[href="https://example.com/docs"]');
      await expect(docsCard).toBeVisible();
      await expect(docsCard).toHaveAttribute("href", "https://example.com/docs");

      const openAiCard = page.locator('.message-link-card[href="https://openai.com/research"]');
      await expect(openAiCard).toBeVisible();
      await expect(openAiCard).toHaveAttribute("href", "https://openai.com/research");
      await expect(page.getByTestId("message-s_links_1")).toHaveScreenshot(
        `phase4-link-cards-surface-${appearance}.png`,
        {
          animations: "disabled",
          caret: "hide",
          maxDiffPixelRatio: 0.02
        }
      );

      await expect(page.getByText("https://example.com/in-code")).toBeVisible();
      await expect(page.locator('.message-link-card[href*="in-code"]')).toHaveCount(0);
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
    server.closeAllConnections?.();
    await new Promise<void>((resolve, reject) => {
      wss.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
    await new Promise<void>((resolve, reject) => {
      server.close((serverError) => {
        if (serverError) {
          reject(serverError);
          return;
        }
        resolve();
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
