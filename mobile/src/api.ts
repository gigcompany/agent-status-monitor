import { AppConfig } from "./config";
import { AgentTask, TaskStatus } from "./types";

export class ApiError extends Error {}

const COLUMN_TO_FIELD: Record<string, keyof AgentTask> = {
  id: "id",
  agent_id: "agentId",
  agent_label: "agentLabel",
  agent_kind: "agentKind",
  host: "host",
  task: "task",
  status: "status",
  detail: "detail",
  question: "question",
  step: "step",
  total: "total",
  repo: "repo",
  cwd: "cwd",
  started_at: "startedAt",
  updated_at: "updatedAt",
  ended_at: "endedAt",
  waiting_since: "waitingSince",
};

const VALID_STATUSES: TaskStatus[] = ["working", "waiting", "done", "failed"];

/** Tolerant on purpose: one malformed row should not blank the whole list. */
function toTask(row: Record<string, unknown>): AgentTask | null {
  if (typeof row.id !== "string" || typeof row.task !== "string") return null;
  const out: Record<string, unknown> = {
    agentId: "unknown",
    agentLabel: null,
    agentKind: null,
    host: null,
    detail: null,
    question: null,
    step: null,
    total: null,
    repo: null,
    cwd: null,
    startedAt: null,
    updatedAt: null,
    endedAt: null,
    waitingSince: null,
    status: "working",
  };
  for (const [column, value] of Object.entries(row)) {
    const field = COLUMN_TO_FIELD[column];
    if (field) out[field] = value;
  }
  if (typeof out.status !== "string" || !VALID_STATUSES.includes(out.status as TaskStatus)) {
    out.status = "working";
  }
  return out as unknown as AgentTask;
}

/**
 * Mirrors SupabaseBackend.swift's query exactly: same endpoint shape, same
 * headers, same filter - so the menu bar app and this app can never disagree
 * about what "recent activity" means.
 */
export async function fetchTasks(config: AppConfig, sinceIso: string): Promise<AgentTask[]> {
  const base = config.supabaseUrl.replace(/\/+$/, "");
  if (!base) throw new ApiError("Supabase URL not configured");

  const url = new URL(`${base}/rest/v1/${config.supabaseTable}`);
  url.searchParams.set("updated_at", `gt.${sinceIso}`);
  url.searchParams.set("select", "*");
  url.searchParams.set("order", "updated_at.desc");
  url.searchParams.set("limit", "200");

  let response: Response;
  try {
    response = await fetch(url.toString(), {
      headers: {
        apikey: config.supabaseKey,
        Authorization: `Bearer ${config.supabaseKey}`,
      },
    });
  } catch (error) {
    throw new ApiError(
      error instanceof Error ? `Network error: ${error.message}` : "Network error"
    );
  }

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    const hint =
      response.status === 401 || response.status === 403
        ? " (check the anon key, and that RLS allows reads)"
        : response.status === 404
          ? ` (table "${config.supabaseTable}" not found)`
          : "";
    throw new ApiError(`Supabase HTTP ${response.status}${hint}: ${body.slice(0, 200)}`);
  }

  const rows = (await response.json()) as Record<string, unknown>[];
  return rows.map(toTask).filter((task): task is AgentTask => task !== null);
}
