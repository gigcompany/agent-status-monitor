import React, { useState } from "react";
import { ScrollView, StyleSheet, View } from "react-native";
import { Appbar, Button, HelperText, Text, TextInput, useTheme } from "react-native-paper";
import { AppConfig } from "../config";
import { fetchTasks } from "../api";

interface Props {
  config: AppConfig;
  onSave: (config: AppConfig) => Promise<void>;
  onDone: () => void;
}

export default function SettingsScreen({ config, onSave, onDone }: Props) {
  const theme = useTheme();
  const [draft, setDraft] = useState<AppConfig>(config);
  const [saving, setSaving] = useState(false);
  const [checkResult, setCheckResult] = useState<{ ok: boolean; message: string } | null>(null);

  const update = <K extends keyof AppConfig>(key: K, value: AppConfig[K]) =>
    setDraft((prev) => ({ ...prev, [key]: value }));

  async function handleTest() {
    setCheckResult(null);
    try {
      const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
      await fetchTasks(draft, since);
      setCheckResult({ ok: true, message: "Connected - the board is reachable." });
    } catch (error) {
      setCheckResult({
        ok: false,
        message: error instanceof Error ? error.message : "Connection failed",
      });
    }
  }

  async function handleSave() {
    setSaving(true);
    try {
      await onSave(draft);
      onDone();
    } finally {
      setSaving(false);
    }
  }

  return (
    <View style={{ flex: 1, backgroundColor: theme.colors.background }}>
      <Appbar.Header>
        <Appbar.BackAction onPress={onDone} />
        <Appbar.Content title="Settings" />
      </Appbar.Header>

      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        <Text variant="labelLarge" style={styles.sectionLabel}>
          Supabase
        </Text>
        <Text variant="bodySmall" style={styles.helper}>
          Same project the menu bar app uses. Find these under Project
          Settings → API. Use the anon key, never the service_role key.
        </Text>

        <TextInput
          label="Project URL"
          placeholder="https://xxxxxxxx.supabase.co"
          value={draft.supabaseUrl}
          onChangeText={(v) => update("supabaseUrl", v)}
          autoCapitalize="none"
          autoCorrect={false}
          keyboardType="url"
          mode="outlined"
          style={styles.field}
        />
        <TextInput
          label="anon key"
          value={draft.supabaseKey}
          onChangeText={(v) => update("supabaseKey", v)}
          autoCapitalize="none"
          autoCorrect={false}
          secureTextEntry
          mode="outlined"
          style={styles.field}
        />
        <TextInput
          label="Table"
          value={draft.supabaseTable}
          onChangeText={(v) => update("supabaseTable", v)}
          autoCapitalize="none"
          autoCorrect={false}
          mode="outlined"
          style={styles.field}
        />

        <Text variant="labelLarge" style={styles.sectionLabel}>
          Display
        </Text>
        <TextInput
          label="Refresh every (seconds)"
          value={String(draft.pollSeconds)}
          onChangeText={(v) => update("pollSeconds", Math.max(2, parseInt(v, 10) || 5))}
          keyboardType="number-pad"
          mode="outlined"
          style={styles.field}
        />
        <TextInput
          label="Show activity from last (hours)"
          value={String(draft.lookbackHours)}
          onChangeText={(v) => update("lookbackHours", Math.max(1, parseInt(v, 10) || 12))}
          keyboardType="number-pad"
          mode="outlined"
          style={styles.field}
        />

        <Button
          mode="outlined"
          onPress={handleTest}
          disabled={!draft.supabaseUrl || !draft.supabaseKey}
          style={styles.field}
        >
          Test connection
        </Button>
        {checkResult && (
          <HelperText type={checkResult.ok ? "info" : "error"} visible>
            {checkResult.message}
          </HelperText>
        )}

        <Button
          mode="contained"
          onPress={handleSave}
          loading={saving}
          disabled={!draft.supabaseUrl || !draft.supabaseKey}
          style={styles.saveButton}
        >
          Save
        </Button>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, paddingBottom: 40 },
  sectionLabel: { marginTop: 12, marginBottom: 4 },
  helper: { marginBottom: 12, opacity: 0.7 },
  field: { marginBottom: 12 },
  saveButton: { marginTop: 12 },
});
