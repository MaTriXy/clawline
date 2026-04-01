import { fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { MessageList } from "./MessageList";
import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";

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

describe("MessageList rich rendering", () => {
  it("renders markdown blocks in source order", () => {
    render(<MessageList messages={[RICH_MESSAGE]} />);

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
    render(<MessageList messages={[RICH_MESSAGE]} />);

    fireEvent.click(screen.getByRole("button", { name: "Expand" }));

    const dialog = screen.getByRole("dialog", { name: "Expanded message" });
    expect(within(dialog).getByText("Expanded view")).toBeInTheDocument();
    expect(within(dialog).getByText("console.log('hi');")).toBeInTheDocument();
    expect(within(dialog).getByRole("table")).toBeInTheDocument();

    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
    expect(screen.queryByRole("dialog", { name: "Expanded message" })).not.toBeInTheDocument();
  });
});
