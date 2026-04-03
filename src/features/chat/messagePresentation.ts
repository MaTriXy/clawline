import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";

export type MessageSizeClass = "short" | "medium" | "long";

export interface MessagePresentation {
  isTruncated: boolean;
  isWide: boolean;
  sizeClass: MessageSizeClass;
}

export function getMessageSenderLabel(message: ChatMessageRecord) {
  return message.role === "user" ? "You" : message.sender ?? "Assistant";
}

export function getMessageSenderInitial(message: ChatMessageRecord) {
  const label = getMessageSenderLabel(message).trim();
  const initial = Array.from(label).find((character) => /\p{Letter}|\p{Number}/u.test(character));
  return (initial ?? "?").toUpperCase();
}

export function analyzeMessagePresentation(
  message: ChatMessageRecord,
  shouldOfferExpandedMessage: (content: string) => boolean
): MessagePresentation {
  const normalizedContent = message.content.trim();
  const wordCount = countWords(normalizedContent);
  const hasMarkdownTable = /\n\|(?:\s*:?-+:?\s*\|)+\s*(?:\n|$)/m.test(normalizedContent);
  const hasBlockContent =
    message.attachments.length > 0 ||
    hasMarkdownTable ||
    normalizedContent.includes("```") ||
    normalizedContent.includes("\n\n");
  const hasLinkPreviewCandidate = /https?:\/\/\S+|\[[^\]]+\]\((https?:\/\/[^)]+)\)/.test(
    normalizedContent
  );
  const sizeClass: MessageSizeClass = hasBlockContent
    ? "long"
    : wordCount <= 3
      ? "short"
      : wordCount <= 20
        ? "medium"
        : "long";

  return {
    isTruncated: shouldOfferExpandedMessage(message.content),
    isWide: message.attachments.length > 0 || hasMarkdownTable || hasLinkPreviewCandidate,
    sizeClass
  };
}

export function hasStreamingAssistantMessage(messages: ChatMessageRecord[]) {
  const lastAssistantMessage = [...messages].reverse().find((message) => message.role === "assistant");
  return lastAssistantMessage?.streaming === true;
}

function countWords(content: string) {
  return content
    .replace(/```[\s\S]*?```/g, " code ")
    .replace(/\[[^\]]+\]\((https?:\/\/[^)]+)\)/g, " link ")
    .replace(/[|*_`>#-]/g, " ")
    .split(/\s+/)
    .filter(Boolean).length;
}
