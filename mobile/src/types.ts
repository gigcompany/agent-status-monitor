export type TaskStatus = "working" | "waiting" | "done" | "failed";

/**
 * Canonical shape, matching what the CLI and menu bar app already agree on.
 * Supabase returns snake_case columns; mapping happens in api.ts so nothing
 * downstream has to think about it twice.
 */
export interface AgentTask {
  id: string;
  agentId: string;
  agentLabel: string | null;
  agentKind: string | null;
  host: string | null;
  task: string;
  status: TaskStatus;
  detail: string | null;
  question: string | null;
  step: number | null;
  total: number | null;
  repo: string | null;
  cwd: string | null;
  startedAt: string | null;
  updatedAt: string | null;
  endedAt: string | null;
  waitingSince: string | null;
}

export const STATUS_PRIORITY: Record<TaskStatus, number> = {
  waiting: 0,
  working: 1,
  failed: 2,
  done: 3,
};

export const STATUS_LABEL: Record<TaskStatus, string> = {
  waiting: "Needs you",
  working: "Working",
  failed: "Failed",
  done: "Done",
};

/** A "working" task untouched this long has probably died - an agent that
 * crashes cannot report its own death. Matches the menu bar app's threshold. */
export const STALE_MS = 30 * 60 * 1000;

export function isStale(task: AgentTask): boolean {
  if (task.status !== "working" || !task.updatedAt) return false;
  return Date.now() - Date.parse(task.updatedAt) > STALE_MS;
}

export function displayReference(task: AgentTask): string | null {
  return task.waitingSince ?? task.updatedAt;
}

export function ageDescription(task: AgentTask): string | null {
  const reference = displayReference(task);
  if (!reference) return null;
  const seconds = (Date.now() - Date.parse(reference)) / 1000;
  if (seconds < 0) return "just now";
  if (seconds < 5) return "just now";
  if (seconds < 60) return `${Math.floor(seconds)}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}
