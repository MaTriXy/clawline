import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

export function RichMessageBody({
  content,
  expanded = false
}: {
  content: string;
  expanded?: boolean;
}) {
  return (
    <div
      className={expanded ? "message-markdown message-markdown--expanded" : "message-markdown"}
    >
      <ReactMarkdown remarkPlugins={[remarkGfm]}>{content}</ReactMarkdown>
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
