import { openDB } from "idb";
import type { ChatDomainSnapshot } from "../chat/chatDomainStore";

const DATABASE_NAME = "clawline-web";
const DATABASE_VERSION = 1;
const SNAPSHOT_KEY = "phase1-snapshot";

export interface ChatPersistence {
  load(): Promise<ChatDomainSnapshot | null>;
  save(snapshot: ChatDomainSnapshot): Promise<void>;
  clear(): Promise<void>;
}

export function createMemoryChatPersistence(
  initialSnapshot: ChatDomainSnapshot | null = null
): ChatPersistence {
  let snapshot = initialSnapshot;

  return {
    async load() {
      return snapshot;
    },
    async save(nextSnapshot) {
      snapshot = nextSnapshot;
    },
    async clear() {
      snapshot = null;
    }
  };
}

export function createIndexedDbChatPersistence(): ChatPersistence {
  return {
    async load() {
      const database = await openDatabase();
      return (await database.get("chatSnapshots", SNAPSHOT_KEY)) ?? null;
    },
    async save(snapshot) {
      const database = await openDatabase();
      await database.put("chatSnapshots", snapshot, SNAPSHOT_KEY);
    },
    async clear() {
      const database = await openDatabase();
      await database.delete("chatSnapshots", SNAPSHOT_KEY);
    }
  };
}

async function openDatabase() {
  return openDB(DATABASE_NAME, DATABASE_VERSION, {
    upgrade(database) {
      if (!database.objectStoreNames.contains("chatSnapshots")) {
        database.createObjectStore("chatSnapshots");
      }
    }
  });
}
