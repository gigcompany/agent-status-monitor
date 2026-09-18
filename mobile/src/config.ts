import AsyncStorage from "@react-native-async-storage/async-storage";

/**
 * Same fields as ~/.agent-status/config.env on the desktop, just entered by
 * hand here since there is no shared filesystem to read it from. Only
 * Supabase is supported: `local` is a SQLite file on one Mac, unreachable
 * from a phone - a cloud backend is required for this app to work at all.
 */
export interface AppConfig {
  supabaseUrl: string;
  supabaseKey: string;
  supabaseTable: string;
  pollSeconds: number;
  lookbackHours: number;
}

export const DEFAULT_CONFIG: AppConfig = {
  supabaseUrl: "",
  supabaseKey: "",
  supabaseTable: "agent_tasks",
  pollSeconds: 5,
  lookbackHours: 12,
};

const STORAGE_KEY = "agent-monitor.config.v1";

export async function loadConfig(): Promise<AppConfig> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    if (!raw) return DEFAULT_CONFIG;
    const parsed = JSON.parse(raw);
    return { ...DEFAULT_CONFIG, ...parsed };
  } catch {
    // Corrupt or unreadable storage should not crash the app on launch.
    return DEFAULT_CONFIG;
  }
}

export async function saveConfig(config: AppConfig): Promise<void> {
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(config));
}

export function isConfigured(config: AppConfig): boolean {
  return config.supabaseUrl.trim().length > 0 && config.supabaseKey.trim().length > 0;
}
