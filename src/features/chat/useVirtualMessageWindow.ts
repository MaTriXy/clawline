import { useEffect, useMemo, useRef, useState, type RefObject } from "react";
import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";

const BOTTOM_THRESHOLD_PX = 32;
const DEFAULT_MESSAGE_HEIGHT = 320;
const DEFAULT_VIEWPORT_HEIGHT = 720;
const MESSAGE_GAP_REM = 0.9;
const OVERSCAN_PX = 1_000;

export interface VirtualMessageWindow {
  containerRef: RefObject<HTMLElement | null>;
  isAtBottom: boolean;
  handleScroll: () => void;
  registerMessageHeight: (messageId: string, height: number) => void;
  renderedMessages: Array<{
    message: ChatMessageRecord;
    offsetTop: number;
  }>;
  scrollTop: number;
  scrollToBottom: () => void;
  scrollToMessage: (messageId: string, alignment?: "center" | "start") => boolean;
  scrollToOffset: (offsetTop: number) => void;
  totalHeight: number;
}

export function useVirtualMessageWindow(messages: ChatMessageRecord[]): VirtualMessageWindow {
  const containerRef = useRef<HTMLElement | null>(null);
  const shouldStickToBottomRef = useRef(false);
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportHeight, setViewportHeight] = useState(DEFAULT_VIEWPORT_HEIGHT);
  const [gapPx, setGapPx] = useState(14);
  const [measuredHeights, setMeasuredHeights] = useState<Record<string, number>>({});

  useEffect(() => {
    const container = containerRef.current;
    if (!container) {
      return;
    }
    const target = container;

    function syncContainerMetrics(target: HTMLElement) {
      setViewportHeight(target.clientHeight || DEFAULT_VIEWPORT_HEIGHT);
      const fontSize = Number.parseFloat(window.getComputedStyle(target).fontSize);
      setGapPx(Number.isFinite(fontSize) ? fontSize * MESSAGE_GAP_REM : 14);
    }

    syncContainerMetrics(target);

    const resizeObserver =
      typeof window.ResizeObserver === "function"
        ? new window.ResizeObserver(() => {
            syncContainerMetrics(target);
          })
        : null;

    resizeObserver?.observe(target);
    function handleWindowResize() {
      syncContainerMetrics(target);
    }

    window.addEventListener("resize", handleWindowResize);

    return () => {
      resizeObserver?.disconnect();
      window.removeEventListener("resize", handleWindowResize);
    };
  }, []);

  const layout = useMemo(
    () => buildVirtualLayout(messages, measuredHeights, scrollTop, viewportHeight, gapPx),
    [gapPx, measuredHeights, messages, scrollTop, viewportHeight]
  );

  function handleScroll() {
    if (!containerRef.current) {
      return;
    }

    const nextScrollTop = containerRef.current.scrollTop;
    const maxScrollTop = Math.max(
      0,
      containerRef.current.scrollHeight - containerRef.current.clientHeight
    );
    shouldStickToBottomRef.current = maxScrollTop - nextScrollTop <= BOTTOM_THRESHOLD_PX;
    setScrollTop(nextScrollTop);
  }

  useEffect(() => {
    const container = containerRef.current;
    if (!container || !shouldStickToBottomRef.current) {
      return;
    }

    container.scrollTop = container.scrollHeight;
    setScrollTop(container.scrollTop);
  }, [layout.totalHeight]);

  return {
    containerRef,
    handleScroll,
    isAtBottom:
      Math.max(0, layout.totalHeight - viewportHeight - scrollTop) <= BOTTOM_THRESHOLD_PX,
    registerMessageHeight(messageId, height) {
      if (height <= 0) {
        return;
      }

      setMeasuredHeights((current) =>
        current[messageId] === height
          ? current
          : {
              ...current,
              [messageId]: height
            }
      );
    },
    renderedMessages: layout.renderedMessages,
    scrollTop,
    scrollToBottom() {
      const container = containerRef.current;
      if (!container) {
        return;
      }

      shouldStickToBottomRef.current = true;
      container.scrollTop = container.scrollHeight;
      setScrollTop(container.scrollTop);
    },
    scrollToMessage(messageId, alignment = "start") {
      const container = containerRef.current;
      const messageLayout = layout.messageLayouts.find(
        (entry) => entry.message.id === messageId
      );

      if (!container || !messageLayout) {
        return false;
      }

      const nextOffset =
        alignment === "center"
          ? Math.max(
              0,
              messageLayout.offsetTop - (container.clientHeight - messageLayout.height) / 2
            )
          : messageLayout.offsetTop;

      shouldStickToBottomRef.current = false;
      container.scrollTop = nextOffset;
      setScrollTop(container.scrollTop);
      return true;
    },
    scrollToOffset(offsetTop) {
      const container = containerRef.current;
      if (!container) {
        return;
      }

      shouldStickToBottomRef.current = false;
      container.scrollTop = Math.max(0, offsetTop);
      setScrollTop(container.scrollTop);
    },
    totalHeight: layout.totalHeight
  };
}

function buildVirtualLayout(
  messages: ChatMessageRecord[],
  measuredHeights: Record<string, number>,
  scrollTop: number,
  viewportHeight: number,
  gapPx: number
) {
  let offsetTop = 0;
  const messageLayouts = messages.map((message, index) => {
    const height = measuredHeights[message.id] ?? DEFAULT_MESSAGE_HEIGHT;
    const layout = {
      height,
      message,
      offsetTop
    };
    offsetTop += height + (index < messages.length - 1 ? gapPx : 0);
    return layout;
  });

  const clampedScrollTop = Math.min(scrollTop, Math.max(0, offsetTop - viewportHeight));
  const visibleTop = Math.max(0, clampedScrollTop - OVERSCAN_PX);
  const visibleBottom = clampedScrollTop + viewportHeight + OVERSCAN_PX;
  const renderedMessages: Array<{
    message: ChatMessageRecord;
    offsetTop: number;
  }> = [];

  for (const layout of messageLayouts) {
    const messageBottom = layout.offsetTop + layout.height;

    if (messageBottom >= visibleTop && layout.offsetTop <= visibleBottom) {
      renderedMessages.push({
        message: layout.message,
        offsetTop: layout.offsetTop
      });
    }
  }

  return {
    messageLayouts,
    renderedMessages,
    totalHeight: offsetTop
  };
}
