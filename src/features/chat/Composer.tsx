import { useEffect, useId, useRef, useState } from "react";
import { Paperclip, SendHorizontal } from "lucide-react";
import type { SessionProvisioningState } from "../streams/provisioning";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { generateUuidV4 } from "../../runtime/shared/uuid";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import {
  isUploadAuthFailure
} from "../../protocol/upload-api";
import { prepareOutboundAttachments } from "./outboundAttachments";

interface ComposerAttachmentDraft {
  file: File;
  id: string;
}

export function Composer({
  activeStreamDisplayName,
  provisioningState,
  sessionKey
}: {
  activeStreamDisplayName?: string;
  provisioningState: SessionProvisioningState;
  sessionKey?: string;
}) {
  const { state: authState, store: authStore } = useAuthSessionStore();
  const { store: chatStore } = useChatDomainStore();
  const { state: transportState, store: transportStore } = useTransportMachine();
  const [draft, setDraft] = useState("");
  const [isDragActive, setDragActive] = useState(false);
  const [isSubmitting, setSubmitting] = useState(false);
  const [stagedAttachments, setStagedAttachments] = useState<ComposerAttachmentDraft[]>([]);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const fileInputId = useId();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);

  const canSend =
    Boolean(sessionKey) &&
    transportState.phase === "live" &&
    provisioningState === "ready" &&
    !isSubmitting &&
    (draft.trim().length > 0 || stagedAttachments.length > 0);

  useEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea) {
      return;
    }

    textarea.style.height = "0px";
    const nextHeight = Math.min(Math.max(textarea.scrollHeight, 28), 140);
    textarea.style.height = `${nextHeight}px`;
  }, [draft]);

  async function submit() {
    if (!sessionKey || !authState.session) {
      return;
    }

    const content = draft.trim();
    if (content.length === 0 && stagedAttachments.length === 0) {
      return;
    }

    setSubmitting(true);
    setSubmitError(null);

    let preparedAttachments;
    try {
      preparedAttachments = await prepareOutboundAttachments({
        content,
        files: stagedAttachments.map((attachment) => attachment.file),
        serverUrl: authState.session.serverUrl,
        token: authState.session.token
      });
    } catch (error) {
      if (isUploadAuthFailure(error)) {
        setSubmitting(false);
        authStore.logout();
        return;
      }
      setSubmitError(
        error instanceof Error ? error.message : "Attachment upload failed."
      );
      setSubmitting(false);
      return;
    }

    const id = `c_${generateUuidV4()}`;
    const timestamp = Date.now();

    chatStore.enqueueOptimisticMessage({
      attachments: preparedAttachments.optimisticAttachments,
      content,
      deviceId: authState.session.deviceId,
      id,
      sessionKey,
      timestamp
    });

    setDraft("");
    setStagedAttachments([]);
    if (fileInputRef.current) {
      fileInputRef.current.value = "";
    }
    window.requestAnimationFrame(() => {
      textareaRef.current?.focus({ preventScroll: true });
    });

    try {
      await transportStore.sendMessage({
        attachments: preparedAttachments.wireAttachments,
        content,
        id,
        sessionKey
      });
    } catch {
      chatStore.markMessageFailed(id);
    } finally {
      setSubmitting(false);
    }
  }

  function appendFiles(files: readonly File[]) {
    if (files.length === 0) {
      return;
    }

    setSubmitError(null);
    setStagedAttachments((current) => [
      ...current,
      ...files.map((file) => ({
        file,
        id: generateUuidV4()
      }))
    ]);
  }

  function removeAttachment(attachmentId: string) {
    setStagedAttachments((current) =>
      current.filter((attachment) => attachment.id !== attachmentId)
    );
  }

  return (
    <section
      className={
        isDragActive ? "composer-shell composer-shell--drag-active" : "composer-shell"
      }
      data-testid="composer-shell"
      onDragEnter={(event) => {
        if (event.dataTransfer?.files.length) {
          event.preventDefault();
          setDragActive(true);
        }
      }}
      onDragLeave={(event) => {
        if (event.currentTarget === event.target) {
          setDragActive(false);
        }
      }}
      onDragOver={(event) => {
        if (event.dataTransfer?.files.length) {
          event.preventDefault();
        }
      }}
      onDrop={(event) => {
        event.preventDefault();
        setDragActive(false);
        appendFiles(Array.from(event.dataTransfer?.files ?? []));
      }}
      >
      <input
        aria-hidden="true"
        className="sr-only"
        id={fileInputId}
        multiple
        onChange={(event) => appendFiles(Array.from(event.target.files ?? []))}
        ref={fileInputRef}
        tabIndex={-1}
        type="file"
      />
      <label className="sr-only" htmlFor="composer-input">
        Message
      </label>
      {stagedAttachments.length > 0 ? (
        <div className="composer-attachments" data-testid="composer-attachments">
          {stagedAttachments.map((attachment) => (
            <div className="composer-attachment-chip" key={attachment.id}>
              <div className="composer-attachment-copy">
                <strong>{attachment.file.name || "attachment"}</strong>
                <span>{formatAttachmentSize(attachment.file.size)}</span>
              </div>
              <button
                className="button-secondary"
                onClick={() => removeAttachment(attachment.id)}
                type="button"
              >
                Remove
              </button>
            </div>
          ))}
        </div>
      ) : null}
      {submitError ? <p className="field-error">{submitError}</p> : null}
      <div className="composer-input-bar" data-testid="composer-input-bar">
        <button
          aria-label="Add attachment"
          className="composer-circle-button composer-circle-button--attach"
          disabled={!sessionKey || isSubmitting}
          onClick={() => fileInputRef.current?.click()}
          type="button"
        >
          <Paperclip aria-hidden="true" size={18} strokeWidth={2.1} />
        </button>
        <div className="composer-input-field">
          <textarea
            aria-keyshortcuts="Enter,Shift+Enter,Escape"
            enterKeyHint="send"
            id="composer-input"
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape") {
                event.preventDefault();
                event.currentTarget.blur();
                return;
              }

              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                void submit();
              }
            }}
            onPaste={(event) => {
              const files = Array.from(event.clipboardData?.files ?? []);
              if (files.length > 0) {
                event.preventDefault();
                appendFiles(files);
              }
            }}
            placeholder={
              sessionKey
                ? transportState.phase === "live" && provisioningState === "ready"
                  ? activeStreamDisplayName
                    ? `${activeStreamDisplayName} — ${sessionKey}`
                    : sessionKey
                  : provisioningState === "unavailable"
                    ? "This stream is unavailable for sending"
                    : provisioningState === "waiting"
                      ? "Waiting for provisioning"
                      : "Waiting for connection"
                : "Select a session"
            }
            ref={textareaRef}
            rows={1}
            value={draft}
          />
        </div>
        <button
          aria-label={isSubmitting ? "Uploading…" : "Send"}
          className="composer-circle-button composer-circle-button--send"
          disabled={!canSend}
          onClick={() => {
            void submit();
          }}
          type="button"
        >
          {isSubmitting ? (
            <span aria-hidden="true">…</span>
          ) : (
            <SendHorizontal aria-hidden="true" size={18} strokeWidth={2.1} />
          )}
        </button>
      </div>
    </section>
  );
}

function formatAttachmentSize(size: number) {
  if (size >= 1_000_000) {
    return `${(size / 1_000_000).toFixed(1)} MB`;
  }
  if (size >= 1_000) {
    return `${(size / 1_000).toFixed(1)} KB`;
  }
  return `${size} B`;
}
