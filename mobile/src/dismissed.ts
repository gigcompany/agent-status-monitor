import AsyncStorage from "@react-native-async-storage/async-storage";

/**
 * Finished tasks the user has cleared from the list. Mirrors the menu bar
 * app's StatusStore.dismissedIds: purely local UI state, never touches the
 * backend, so other viewers and machines are unaffected.
 */
const STORAGE_KEY = "agent-monitor.dismissed.v1";

export async function loadDismissed(): Promise<Set<string>> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    if (!raw) return new Set();
    return new Set(JSON.parse(raw) as string[]);
  } catch {
    return new Set();
  }
}

export async function saveDismissed(ids: Set<string>): Promise<void> {
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(Array.from(ids)));
}
