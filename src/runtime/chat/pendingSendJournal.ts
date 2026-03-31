import {
  clearPreference,
  loadPreference,
  savePreference
} from "../persistence/preferences";

const PENDING_SENDS_KEY = "pending-sends";

export interface PendingSendRecord {
  id: string;
  sessionKey: string;
  content: string;
  createdAt: number;
}

export function loadPendingSends() {
  return loadPreference<PendingSendRecord[]>(PENDING_SENDS_KEY, []);
}

export function savePendingSends(records: PendingSendRecord[]) {
  savePreference(PENDING_SENDS_KEY, records);
}

export function clearPendingSends() {
  clearPreference(PENDING_SENDS_KEY);
}
