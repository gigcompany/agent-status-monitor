import React, { useCallback, useEffect, useRef, useState } from "react";
import { RefreshControl, SectionList, StyleSheet, View } from "react-native";
import {
  ActivityIndicator,
  Appbar,
  Badge,
  Icon,
  Snackbar,
  Text,
  useTheme,
} from "react-native-paper";
import { AppConfig, isConfigured } from "../config";
import { fetchTasks } from "../api";
import { loadDismissed, saveDismissed } from "../dismissed";
import {
  AgentTask,
  STATUS_LABEL,
  STATUS_PRIORITY,
  TaskStatus,
  ageDescription,
  isStale,
} from "../types";

interface Props {
  config: AppConfig;
  onOpenSettings: () => void;
}

interface Section {
  title: TaskStatus;
  data: AgentTask[];
}

const STATUS_ORDER: TaskStatus[] = ["waiting", "working", "failed", "done"];

const STATUS_ICON: Record<TaskStatus, string> = {
  waiting: "help-circle",
  working: "dots-circle",
  done: "check-circle",
  failed: "alert-circle",
};

function groupByStatus(tasks: AgentTask[]): Section[] {
  const sorted = [...tasks].sort((a, b) => {
    const diff = STATUS_PRIORITY[a.status] - STATUS_PRIORITY[b.status];
    if (diff !== 0) return diff;
    return (b.updatedAt ?? "").localeCompare(a.updatedAt ?? "");
  });

  return STATUS_ORDER.map((status) => ({
    title: status,
    data: sorted.filter((t) => t.status === status),
  })).filter((section) => section.data.length > 0);
}

export default function HomeScreen({ config, onOpenSettings }: Props) {
  const theme = useTheme();
  const [tasks, setTasks] = useState<AgentTask[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [dismissed, setDismissed] = useState<Set<string>>(new Set());
  const [snackbar, setSnackbar] = useState<string | null>(null);
  const inFlight = useRef(false);

  useEffect(() => {
    loadDismissed().then(setDismissed);
  }, []);

  const refresh = useCallback(
    async (showSpinner: boolean) => {
      if (inFlight.current || !isConfigured(config)) {
        setLoading(false);
        return;
      }
      inFlight.current = true;
      if (showSpinner) setRefreshing(true);
      try {
        const since = new Date(Date.now() - config.lookbackHours * 3600 * 1000).toISOString();
        const fetched = await fetchTasks(config, since);
        setTasks(fetched);
        setError(null);
        setLastUpdated(new Date());

        // Forget dismissals for tasks that have aged out of the window -
        // nothing left to keep hidden once the backend no longer returns them.
        const live = new Set(fetched.map((t) => t.id));
        setDismissed((prev) => {
          const pruned = new Set([...prev].filter((id) => live.has(id)));
          if (pruned.size !== prev.size) {
            saveDismissed(pruned);
            return pruned;
          }
          return prev;
        });
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load");
      } finally {
        setLoading(false);
        setRefreshing(false);
        inFlight.current = false;
      }
    },
    [config]
  );

  useEffect(() => {
    refresh(false);
    const seconds = Math.max(2, config.pollSeconds);
    const id = setInterval(() => refresh(false), seconds * 1000);
    return () => clearInterval(id);
  }, [refresh, config.pollSeconds]);

  // Live tasks (working/waiting) are never dismissable - hiding one that
  // still needs attention or is still in progress would just be confusing.
  const visibleTasks = tasks.filter((t) => !dismissed.has(t.id));
  const clearableCount = visibleTasks.filter(
    (t) => t.status === "done" || t.status === "failed"
  ).length;

  function handleClear() {
    const toDismiss = tasks
      .filter((t) => t.status === "done" || t.status === "failed")
      .map((t) => t.id);
    const next = new Set(dismissed);
    let added = 0;
    for (const id of toDismiss) {
      if (!next.has(id)) {
        next.add(id);
        added++;
      }
    }
    if (added > 0) {
      setDismissed(next);
      saveDismissed(next);
    }
    setSnackbar(added > 0 ? `Cleared ${added} finished task${added === 1 ? "" : "s"}.` : "Nothing to clear.");
  }

  const waitingCount = tasks.filter((t) => t.status === "waiting").length;
  const workingCount = tasks.filter((t) => t.status === "working" && !isStale(t)).length;
  const sections = groupByStatus(visibleTasks);

  return (
    <View style={{ flex: 1, backgroundColor: theme.colors.background }}>
      <Appbar.Header>
        <Appbar.Content title="Agents" subtitle={lastUpdated ? lastUpdated.toLocaleTimeString() : undefined} />
        {waitingCount > 0 && (
          <View style={styles.bellWrap}>
            <Icon source="bell-alert" size={22} color={theme.colors.error} />
            <Badge size={16} style={[styles.bellBadge, { backgroundColor: theme.colors.error }]}>
              {waitingCount}
            </Badge>
          </View>
        )}
        <Appbar.Action icon="eraser" onPress={handleClear} disabled={clearableCount === 0} />
        <Appbar.Action icon="cog" onPress={onOpenSettings} />
      </Appbar.Header>

      {error && (
        <View style={[styles.banner, { backgroundColor: theme.colors.errorContainer }]}>
          <Icon source="alert" size={16} color={theme.colors.onErrorContainer} />
          <Text
            variant="bodySmall"
            style={{ color: theme.colors.onErrorContainer, marginLeft: 8, flex: 1 }}
          >
            {error}
          </Text>
        </View>
      )}

      {!isConfigured(config) ? (
        <View style={styles.centered}>
          <Icon source="cog-outline" size={32} color={theme.colors.onSurfaceVariant} />
          <Text variant="titleMedium" style={{ marginTop: 12 }}>
            Not configured
          </Text>
          <Text
            variant="bodySmall"
            style={{ color: theme.colors.onSurfaceVariant, textAlign: "center", marginTop: 4 }}
          >
            Add your Supabase project URL and anon key in Settings to see your
            agents' status here.
          </Text>
        </View>
      ) : loading ? (
        <View style={styles.centered}>
          <ActivityIndicator />
        </View>
      ) : sections.length === 0 ? (
        <View style={styles.centered}>
          <Icon
            source={tasks.length > 0 ? "check-all" : "moon-waning-crescent"}
            size={32}
            color={theme.colors.onSurfaceVariant}
          />
          <Text variant="bodyMedium" style={{ marginTop: 8, color: theme.colors.onSurfaceVariant }}>
            {tasks.length > 0 ? "All caught up" : "No agent activity"}
          </Text>
          <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }}>
            {tasks.length > 0 ? "Finished tasks cleared" : `in the last ${config.lookbackHours}h`}
          </Text>
        </View>
      ) : (
        <SectionList
          sections={sections}
          keyExtractor={(item) => item.id}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={() => refresh(true)} />
          }
          contentContainerStyle={styles.listContent}
          renderSectionHeader={({ section }) => (
            <View style={[styles.sectionHeader, { backgroundColor: theme.colors.background }]}>
              <Icon source={STATUS_ICON[section.title]} size={14} color={theme.colors.onSurfaceVariant} />
              <Text
                variant="labelMedium"
                style={{ color: theme.colors.onSurfaceVariant, marginLeft: 6 }}
              >
                {STATUS_LABEL[section.title].toUpperCase()}
              </Text>
            </View>
          )}
          renderItem={({ item }) => <TaskRow task={item} />}
        />
      )}

      <Snackbar visible={snackbar !== null} onDismiss={() => setSnackbar(null)} duration={3000}>
        {snackbar}
      </Snackbar>
    </View>
  );
}

function TaskRow({ task }: { task: AgentTask }) {
  const theme = useTheme();
  const stale = isStale(task);
  const note = task.question ?? task.detail;
  const age = ageDescription(task);

  const tint =
    task.status === "waiting"
      ? theme.colors.error
      : task.status === "failed"
        ? theme.colors.error
        : task.status === "done"
          ? "#2e7d32"
          : stale
            ? theme.colors.onSurfaceVariant
            : theme.colors.primary;

  return (
    <View style={styles.row}>
      <Icon
        source={stale ? "clock-alert-outline" : STATUS_ICON[task.status]}
        size={18}
        color={tint}
      />
      <View style={styles.rowBody}>
        <Text variant="bodyMedium" style={{ fontWeight: "600" }} numberOfLines={2}>
          {task.task}
        </Text>
        {note ? (
          <Text
            variant="bodySmall"
            numberOfLines={2}
            style={{
              color: task.status === "waiting" ? theme.colors.onSurface : theme.colors.onSurfaceVariant,
              marginTop: 2,
            }}
          >
            {note}
          </Text>
        ) : null}
        <Text variant="bodySmall" style={[styles.meta, { color: theme.colors.onSurfaceVariant }]}>
          {[
            task.agentLabel ?? task.agentId,
            task.repo,
            task.step && task.total ? `${task.step}/${task.total}` : null,
            age,
            stale ? "stale" : null,
          ]
            .filter(Boolean)
            .join(" · ")}
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  centered: { flex: 1, alignItems: "center", justifyContent: "center", padding: 24 },
  banner: { flexDirection: "row", alignItems: "center", padding: 10, paddingHorizontal: 16 },
  bellWrap: { width: 22, height: 22, marginRight: 8, alignItems: "center", justifyContent: "center" },
  bellBadge: { position: "absolute", top: -6, right: -8 },
  listContent: { paddingBottom: 24 },
  sectionHeader: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingTop: 16,
    paddingBottom: 6,
  },
  row: {
    flexDirection: "row",
    alignItems: "flex-start",
    paddingHorizontal: 16,
    paddingVertical: 10,
    gap: 10,
  },
  rowBody: { flex: 1 },
  meta: { marginTop: 4 },
});
