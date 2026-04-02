import type { RefObject } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

export function RichMessageBody({
  content,
  contentRef,
  expanded = false
}: {
  content: string;
  contentRef?: RefObject<HTMLDivElement | null>;
  expanded?: boolean;
}) {
  return (
    <div
      ref={contentRef}
      className={expanded ? "message-markdown message-markdown--expanded" : "message-markdown"}
    >
      <ReactMarkdown
        components={{
          a(properties) {
            return <a {...properties} rel="noreferrer" target="_blank" />;
          }
        }}
        remarkPlugins={[remarkGfm]}
      >
        {content}
      </ReactMarkdown>
    </div>
  );
}

export function shouldOfferExpandedMessage(content: string) {
  return (
    content.length >= 280 ||
    content.includes("```") ||
    content.includes("|") ||
    content.includes("\n\n")
  );
}
