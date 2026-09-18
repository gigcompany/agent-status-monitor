import { useColorScheme } from "react-native";
import { MD3DarkTheme, MD3LightTheme, MD3Theme } from "react-native-paper";
import { useMaterial3Theme } from "@pchmn/expo-material3-theme";

/**
 * Real Material You: on Android 12+ this reads the device's wallpaper-derived
 * system palette; everywhere else it falls back to a fixed seed color, which
 * still gives correct MD3 light/dark schemes, just not a per-device one.
 */
export function useAppTheme(): MD3Theme {
  const colorScheme = useColorScheme();
  const { theme } = useMaterial3Theme();

  const scheme = colorScheme === "dark" ? theme.dark : theme.light;
  const base = colorScheme === "dark" ? MD3DarkTheme : MD3LightTheme;

  return {
    ...base,
    colors: { ...base.colors, ...scheme },
  };
}
