import React, { useEffect, useState } from "react";
import { ActivityIndicator, useColorScheme, View } from "react-native";
import { PaperProvider } from "react-native-paper";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { StatusBar } from "expo-status-bar";

import { AppConfig, isConfigured, loadConfig, saveConfig } from "./src/config";
import { useAppTheme } from "./src/theme";
import HomeScreen from "./src/screens/HomeScreen";
import SettingsScreen from "./src/screens/SettingsScreen";

type Screen = "home" | "settings";

export default function App() {
  const theme = useAppTheme();
  const colorScheme = useColorScheme();
  const [config, setConfig] = useState<AppConfig | null>(null);
  const [screen, setScreen] = useState<Screen>("home");

  useEffect(() => {
    loadConfig().then((loaded) => {
      setConfig(loaded);
      // First launch with nothing saved yet - go straight to setup instead
      // of showing an empty board with no explanation.
      if (!isConfigured(loaded)) setScreen("settings");
    });
  }, []);

  async function handleSave(next: AppConfig) {
    await saveConfig(next);
    setConfig(next);
  }

  if (!config) {
    return (
      <PaperProvider theme={theme}>
        <View style={{ flex: 1, alignItems: "center", justifyContent: "center" }}>
          <ActivityIndicator />
        </View>
      </PaperProvider>
    );
  }

  return (
    <SafeAreaProvider>
      <PaperProvider theme={theme}>
        <StatusBar style={colorScheme === "dark" ? "light" : "dark"} />
        {screen === "settings" ? (
          <SettingsScreen config={config} onSave={handleSave} onDone={() => setScreen("home")} />
        ) : (
          <HomeScreen config={config} onOpenSettings={() => setScreen("settings")} />
        )}
      </PaperProvider>
    </SafeAreaProvider>
  );
}
