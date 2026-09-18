import AsyncStorage from "@react-native-async-storage/async-storage";

/**
 * Tasks the user has cleared from the list, and the `updatedAt` each one had
 * at the moment they cleared it. Mirrors the menu bar app's
 * StatusStore.dismissedAt: purely local UI state, never touches the backend,
 * so other viewers and machines are unaffected.
 *
 * Recording the timestamp rather than a flat id set is what makes clearing
 * safe for live (waiting/working) tasks specifically: unlike done/failed,
 * those can receive a genuinely new update after being cleared (a retried
 * turn, a new question), and that should reappear rather than stay silenced
 * forever.
 */
const STORAGE_KEY = "agent-monitor.dismissed.v2";

export type DismissedMap = Record<string, string>; // task id -> updatedAt ISO string

export async function loadDismissed(): Promise<DismissedMap> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    return JSON.parse(raw) as DismissedMap;
  } catch {
    return {};
  }
}

export async function saveDismissed(map: DismissedMap): Promise<void> {
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(map));
}
