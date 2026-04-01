export type MessageRole = "user" | "assistant";

export interface DeviceInfoPayload {
  platform: string;
  model: string;
}

export interface PairRequestPayload {
  type: "pair_request";
  protocolVersion: 1;
  deviceId: string;
  claimedName: string;
  deviceInfo: DeviceInfoPayload;
}

export interface PairResultPayload {
  type: "pair_result";
  success: boolean;
  token?: string;
  userId?: string;
  reason?: string;
}

export interface AuthPayload {
  type: "auth";
  protocolVersion: 1;
  token: string;
  deviceId: string;
  lastMessageId?: string | null;
  replayCursorsBySessionKey?: Record<string, string>;
}

export interface AuthResultPayload {
  type: "auth_result";
  success: boolean;
  userId?: string;
  sessionId?: string;
  isAdmin?: boolean;
  replayCount?: number;
  replayTruncated?: boolean;
  historyReset?: boolean;
  sessionKeys?: string[];
  sessions?: SessionDescriptor[];
  reason?: string;
}

export interface SessionDescriptor {
  stream?: string;
  sessionKey: string;
}

export interface ClientMessagePayload {
  type: "message";
  id: string;
  content: string;
  attachments: unknown[];
  sessionKey?: string;
}

export interface ServerMessagePayload {
  type: "message";
  id: string;
  role: MessageRole;
  content: string;
  timestamp: number;
  streaming: boolean;
  deviceId?: string;
  sessionKey?: string;
  sender?: string;
  attachments: unknown[];
}

export interface AckPayload {
  type: "ack";
  id: string;
}

export interface ErrorPayload {
  type: "error";
  code: string;
  message?: string;
  messageId?: string;
}

export interface SessionInfoPayload {
  type: "session_info";
  userId?: string;
  isAdmin?: boolean;
  dmScope?: string;
  sessionKeys?: string[];
  sessions?: SessionDescriptor[];
}

export interface StreamSessionPayload {
  sessionKey: string;
  displayName: string;
  kind: string;
  orderIndex: number;
  isBuiltIn: boolean;
  createdAt: number;
  updatedAt: number;
  adopted?: boolean;
}

export interface StreamSnapshotPayload {
  type: "stream_snapshot";
  streams: StreamSessionPayload[];
}

export type PhaseOneServerPayload =
  | AckPayload
  | AuthResultPayload
  | ErrorPayload
  | ServerMessagePayload
  | SessionInfoPayload
  | StreamSnapshotPayload;

export function serializePairRequest(payload: PairRequestPayload) {
  return JSON.stringify(payload);
}

export function serializeAuthPayload(payload: AuthPayload) {
  return JSON.stringify(payload);
}

export function serializeClientMessage(payload: ClientMessagePayload) {
  return JSON.stringify(payload);
}

export function parsePairResultPayload(raw: string): PairResultPayload {
  const value = parseJsonRecord(raw);
  assertLiteral(value.type, "pair_result", "pair_result.type");
  assertBoolean(value.success, "pair_result.success");

  return {
    type: "pair_result",
    success: value.success,
    token: optionalString(value.token, "pair_result.token"),
    userId: optionalString(value.userId, "pair_result.userId"),
    reason: optionalString(value.reason, "pair_result.reason")
  };
}

export function parseAuthResultPayload(raw: string): AuthResultPayload {
  const value = parseJsonRecord(raw);
  assertLiteral(value.type, "auth_result", "auth_result.type");
  assertBoolean(value.success, "auth_result.success");

  return {
    type: "auth_result",
    success: value.success,
    userId: optionalString(value.userId, "auth_result.userId"),
    sessionId: optionalString(value.sessionId, "auth_result.sessionId"),
    isAdmin: optionalBoolean(value.isAdmin, "auth_result.isAdmin"),
    replayCount: optionalNumber(value.replayCount, "auth_result.replayCount"),
    replayTruncated: optionalBoolean(
      value.replayTruncated,
      "auth_result.replayTruncated"
    ),
    historyReset: optionalBoolean(value.historyReset, "auth_result.historyReset"),
    sessionKeys: optionalStringArray(value.sessionKeys, "auth_result.sessionKeys"),
    sessions: optionalSessionDescriptors(value.sessions, "auth_result.sessions"),
    reason: optionalString(value.reason, "auth_result.reason")
  };
}

export function parseServerPayload(raw: string): PhaseOneServerPayload {
  const value = parseJsonRecord(raw);
  const type = requiredString(value.type, "payload.type");

  switch (type) {
    case "message":
      return parseServerMessageFromRecord(value);
    case "ack":
      return parseAckFromRecord(value);
    case "stream_snapshot":
      return parseStreamSnapshotFromRecord(value);
    case "session_info":
      return parseSessionInfoFromRecord(value);
    case "auth_result":
      return parseAuthResultPayload(raw);
    case "error":
      return parseErrorFromRecord(value);
    default:
      throw new Error(`Unsupported server payload type: ${type}`);
  }
}

function parseAckFromRecord(value: JsonRecord): AckPayload {
  assertLiteral(value.type, "ack", "ack.type");
  return {
    type: "ack",
    id: requiredString(value.id, "ack.id")
  };
}

function parseErrorFromRecord(value: JsonRecord): ErrorPayload {
  assertLiteral(value.type, "error", "error.type");
  return {
    type: "error",
    code: requiredString(value.code, "error.code"),
    message: optionalString(value.message, "error.message"),
    messageId: optionalString(value.messageId, "error.messageId")
  };
}

function parseSessionInfoFromRecord(value: JsonRecord): SessionInfoPayload {
  assertLiteral(value.type, "session_info", "session_info.type");
  return {
    type: "session_info",
    userId: optionalString(value.userId, "session_info.userId"),
    isAdmin: optionalBoolean(value.isAdmin, "session_info.isAdmin"),
    dmScope: optionalString(value.dmScope, "session_info.dmScope"),
    sessionKeys: optionalStringArray(value.sessionKeys, "session_info.sessionKeys"),
    sessions: optionalSessionDescriptors(value.sessions, "session_info.sessions")
  };
}

function parseStreamSnapshotFromRecord(value: JsonRecord): StreamSnapshotPayload {
  assertLiteral(value.type, "stream_snapshot", "stream_snapshot.type");
  return {
    type: "stream_snapshot",
    streams: requiredArray(value.streams, "stream_snapshot.streams").map(
      (stream, index) => parseStreamSession(stream, `stream_snapshot.streams[${index}]`)
    )
  };
}

function parseServerMessageFromRecord(value: JsonRecord): ServerMessagePayload {
  assertLiteral(value.type, "message", "message.type");

  const role = requiredString(value.role, "message.role");
  if (role !== "user" && role !== "assistant") {
    throw new Error(`Invalid message.role: ${role}`);
  }

  return {
    type: "message",
    id: requiredString(value.id, "message.id"),
    role,
    content: requiredStringAllowEmpty(value.content, "message.content"),
    timestamp: requiredNumber(value.timestamp, "message.timestamp"),
    streaming: requiredBoolean(value.streaming, "message.streaming"),
    deviceId: optionalString(value.deviceId, "message.deviceId"),
    sessionKey: optionalString(value.sessionKey, "message.sessionKey"),
    sender: optionalString(value.sender, "message.sender"),
    attachments: optionalArray(value.attachments, "message.attachments") ?? []
  };
}

function optionalSessionDescriptors(
  value: unknown,
  field: string
): SessionDescriptor[] | undefined {
  if (value == null) {
    return undefined;
  }

  return requiredArray(value, field).map((entry, index) => {
    const record = asRecord(entry, `${field}[${index}]`);
    return {
      stream: optionalString(record.stream, `${field}[${index}].stream`),
      sessionKey: requiredString(record.sessionKey, `${field}[${index}].sessionKey`)
    };
  });
}

function parseStreamSession(value: unknown, field: string): StreamSessionPayload {
  const record = asRecord(value, field);
  return {
    sessionKey: requiredString(record.sessionKey, `${field}.sessionKey`),
    displayName: requiredString(record.displayName, `${field}.displayName`),
    kind: requiredString(record.kind, `${field}.kind`),
    orderIndex: requiredNumber(record.orderIndex, `${field}.orderIndex`),
    isBuiltIn: requiredBoolean(record.isBuiltIn, `${field}.isBuiltIn`),
    createdAt: requiredNumber(record.createdAt, `${field}.createdAt`),
    updatedAt: requiredNumber(record.updatedAt, `${field}.updatedAt`),
    adopted: optionalBoolean(record.adopted, `${field}.adopted`)
  };
}

type JsonRecord = Record<string, unknown>;

function parseJsonRecord(raw: string): JsonRecord {
  const parsed = JSON.parse(raw) as unknown;
  return asRecord(parsed, "payload");
}

function asRecord(value: unknown, field: string): JsonRecord {
  if (typeof value !== "object" || value == null || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as JsonRecord;
}

function assertLiteral(
  value: unknown,
  expected: string,
  field: string
): asserts value is string {
  if (value !== expected) {
    throw new Error(`${field} must be ${expected}`);
  }
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${field} must be a non-empty string`);
  }
  return value;
}

function optionalString(value: unknown, field: string): string | undefined {
  if (value == null) {
    return undefined;
  }
  if (typeof value !== "string") {
    throw new Error(`${field} must be a string`);
  }
  return value;
}

function requiredStringAllowEmpty(value: unknown, field: string): string {
  if (typeof value !== "string") {
    throw new Error(`${field} must be a string`);
  }
  return value;
}

function optionalStringArray(value: unknown, field: string): string[] | undefined {
  if (value == null) {
    return undefined;
  }
  return requiredArray(value, field).map((entry, index) =>
    requiredString(entry, `${field}[${index}]`)
  );
}

function requiredNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || Number.isNaN(value)) {
    throw new Error(`${field} must be a number`);
  }
  return value;
}

function optionalNumber(value: unknown, field: string): number | undefined {
  if (value == null) {
    return undefined;
  }
  return requiredNumber(value, field);
}

function requiredBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw new Error(`${field} must be a boolean`);
  }
  return value;
}

function optionalBoolean(value: unknown, field: string): boolean | undefined {
  if (value == null) {
    return undefined;
  }
  if (typeof value !== "boolean") {
    throw new Error(`${field} must be a boolean`);
  }
  return value;
}

function assertBoolean(value: unknown, field: string): asserts value is boolean {
  if (typeof value !== "boolean") {
    throw new Error(`${field} must be a boolean`);
  }
}

function requiredArray(value: unknown, field: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`${field} must be an array`);
  }
  return value;
}

function optionalArray(value: unknown, field: string): unknown[] | undefined {
  if (value == null) {
    return undefined;
  }
  return requiredArray(value, field);
}
