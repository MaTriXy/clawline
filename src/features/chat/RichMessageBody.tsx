import type { RefObject } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

export function RichMessageBody({
  content,
  className,
  contentRef,
  expanded = false
}: {
  content: string;
  className?: string;
  contentRef?: RefObject<HTMLDivElement | null>;
  expanded?: boolean;
}) {
  const mergedClassName = [
    "message-markdown",
    expanded ? "message-markdown--expanded" : null,
    className
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <div
      ref={contentRef}
      className={mergedClassName}
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
  // Only truncate genuinely long messages — matches iOS tap-to-expand behavior
  return content.length >= 800;
}
