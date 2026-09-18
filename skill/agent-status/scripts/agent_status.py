#!/usr/bin/env python3
"""agent-status: report what an AI agent is working on to a shared status board.

Deliberately a single file with no third-party dependencies (Python 3.8+ stdlib
only), so it can be dropped onto any agent host with a single scp and no install
step.

Backends are pluggable - see BACKENDS at the bottom of the backend section:
  local     SQLite on this machine, no cloud account needed (the default)
  supabase  Postgres via PostgREST - only backend reachable from the Android app

See CONTRIBUTING.md for how to add another one (Azure Cosmos, Google
Firestore, ...) - the adapter interface is three methods.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import socket
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

STATE_DIR = Path(os.environ.get("AGENT_STATUS_HOME", Path.home() / ".agent-status"))
CONFIG_PATH = STATE_DIR / "config.env"
ENV_PREFIX = "AGENT_STATUS_"

STATUSES = ("working", "waiting", "done", "failed")

# Canonical (camelCase) field -> SQL column. The canonical shape is what the
# menu bar app consumes; SQL backends keep idiomatic snake_case columns.
FIELDS = {
    "id": "id",
    "agentId": "agent_id",
    "agentLabel": "agent_label",
    "agentKind": "agent_kind",
    "host": "host",
    "task": "task",
    "status": "status",
    "detail": "detail",
    "question": "question",
    "step": "step",
    "total": "total",
    "repo": "repo",
    "cwd": "cwd",
    "startedAt": "started_at",
    "updatedAt": "updated_at",
    "endedAt": "ended_at",
    "waitingSince": "waiting_since",
    "expiresAt": "expires_at",
}
COLUMNS = list(FIELDS.values())
TO_CANONICAL = {column: field for field, column in FIELDS.items()}

DEFAULTS = {
    "backend": "local",
    "local_path": str(STATE_DIR / "status.db"),
    "supabase_table": "agent_tasks",
    "ttl_hours": "168",       # 7 days for active tasks
    "done_ttl_hours": "48",   # finished tasks are history, expire them sooner
    "poll_seconds": "5",
    "lookback_hours": "12",
    "notify_waiting": "true",
    "notify_done": "true",
    # A "working" task untouched this long is presumed dead (crashed process,
    # a Stop hook that never fired) rather than a slow-but-live turn. Matches
    # the menu bar app's own staleness threshold.
    "stale_minutes": "30",
}


def die(msg: str, code: int = 1):
    print(f"agent-status: {msg}", file=sys.stderr)
    sys.exit(code)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def to_canonical(row: dict) -> dict:
    """Translate a SQL row into the canonical camelCase shape."""
    return {TO_CANONICAL.get(key, key): value for key, value in row.items()}


def to_columns(doc: dict) -> dict:
    return {FIELDS[key]: value for key, value in doc.items() if key in FIELDS}


# ==========================================================================
# config
# ==========================================================================

def parse_env_file(path: Path) -> dict:
    """Minimal .env reader: KEY=VALUE, # comments, optional surrounding quotes."""
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def load_config() -> dict:
    """Config precedence: process env > config.env file > built-in defaults."""
    raw = dict(DEFAULTS)

    if CONFIG_PATH.exists():
        for key, value in parse_env_file(CONFIG_PATH).items():
            if key.startswith(ENV_PREFIX) and value != "":
                raw[key[len(ENV_PREFIX):].lower()] = value

    for key, value in os.environ.items():
        if key.startswith(ENV_PREFIX) and value != "":
            raw[key[len(ENV_PREFIX):].lower()] = value

    raw["backend"] = raw.get("backend", "supabase").strip().lower()
    raw.setdefault("agent_kind", detect_kind())
    raw.setdefault("agent_id", f"{raw['agent_kind']}@{short_host()}")
    raw.setdefault("agent_label", default_label(raw["agent_kind"]))
    raw["local_path"] = os.path.expanduser(raw.get("local_path") or DEFAULTS["local_path"])
    return raw


def detect_kind() -> str:
    """Guess the agent runtime from environment fingerprints.

    Unknown runtimes fall back to 'agent'; set AGENT_STATUS_AGENT_KIND to be
    explicit rather than extending this for every new tool.
    """
    env = os.environ
    if env.get("CLAUDE_CODE") or env.get("CLAUDECODE") or env.get("CLAUDE_SESSION_ID"):
        return "claude-code"
    if any(key.startswith("CODEX_") for key in env):
        return "codex"
    if any(key.startswith("HERMES_") for key in env):
        return "hermes"
    if env.get("CURSOR_TRACE_ID") or env.get("CURSOR_SESSION_ID"):
        return "cursor"
    if env.get("AIDER_MODEL"):
        return "aider"
    return "agent"


def default_label(kind: str) -> str:
    pretty = {
        "claude-code": "Claude Code",
        "codex": "Codex",
        "hermes": "Hermes",
        "cursor": "Cursor",
        "aider": "Aider",
        "agent": "Agent",
    }.get(kind, kind.replace("-", " ").title())
    return f"{pretty} ({short_host()})"


def short_host() -> str:
    return socket.gethostname().split(".")[0].replace(" ", "-").lower()


def as_bool(value) -> bool:
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def require(cfg: dict, *keys: str):
    missing = [ENV_PREFIX + key.upper() for key in keys if not cfg.get(key)]
    if missing:
        die(
            f"backend '{cfg['backend']}' needs: {', '.join(missing)}\n"
            f"  set them in {CONFIG_PATH} (see .env.example) or as environment variables"
        )


# ==========================================================================
# backends
# ==========================================================================

def http(url: str, method: str = "GET", headers: dict | None = None,
         body: dict | list | None = None, timeout: int = 15) -> tuple[int, str]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)

    last_error = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:400]
            if exc.code in (429, 503) and attempt < 3:
                retry_after = exc.headers.get("x-ms-retry-after-ms") or exc.headers.get("Retry-After")
                try:
                    delay = float(retry_after) / (1000.0 if "ms" in str(exc.headers).lower() else 1.0)
                except (TypeError, ValueError):
                    delay = 0
                time.sleep(max(delay, 0.5 * (2 ** attempt)))
                last_error = f"HTTP {exc.code}: {detail}"
                continue
            return exc.code, detail
        except (urllib.error.URLError, socket.timeout, TimeoutError) as exc:
            last_error = str(exc)
            if attempt < 3:
                time.sleep(0.5 * (2 ** attempt))
                continue
            die(f"cannot reach backend: {exc}")
    die(f"backend request failed after retries: {last_error}")


class Backend:
    """Storage interface. Documents move in and out in canonical camelCase."""

    name = "base"

    def upsert(self, doc: dict) -> None:
        raise NotImplementedError

    def get(self, task_id: str, agent_id: str) -> dict | None:
        raise NotImplementedError

    def list(self, since: str) -> list:
        raise NotImplementedError

    def check(self) -> str:
        """Verify connectivity; return a one-line description of the target."""
        self.list(now_iso())
        return self.name


# -------------------------------------------------------------- local

class LocalBackend(Backend):
    """SQLite on this machine. No account, no network, no cost.

    WAL mode so several agents on the same host can write concurrently without
    blocking each other or corrupting the file.
    """

    name = "local"

    def __init__(self, cfg: dict):
        self.path = Path(cfg["local_path"])
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_schema(self):
        columns = ",\n                ".join(
            f"{column} {'INTEGER' if column in ('step', 'total') else 'TEXT'}"
            + (" PRIMARY KEY" if column == "id" else "")
            for column in COLUMNS
        )
        with self._connect() as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute(f"CREATE TABLE IF NOT EXISTS agent_tasks (\n                {columns}\n            )")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_agent_tasks_updated ON agent_tasks(updated_at)")

    def upsert(self, doc: dict) -> None:
        row = to_columns(doc)
        placeholders = ", ".join("?" for _ in row)
        assignments = ", ".join(f"{column}=excluded.{column}" for column in row if column != "id")
        with self._connect() as conn:
            conn.execute(
                f"INSERT INTO agent_tasks ({', '.join(row)}) VALUES ({placeholders}) "
                f"ON CONFLICT(id) DO UPDATE SET {assignments}",
                list(row.values()),
            )
            # Cheap opportunistic TTL sweep - no cron needed.
            conn.execute("DELETE FROM agent_tasks WHERE expires_at IS NOT NULL AND expires_at < ?", (now_iso(),))

    def get(self, task_id: str, agent_id: str) -> dict | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM agent_tasks WHERE id = ?", (task_id,)).fetchone()
        return to_canonical(dict(row)) if row else None

    def list(self, since: str) -> list:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM agent_tasks WHERE updated_at > ? ORDER BY updated_at DESC", (since,)
            ).fetchall()
        return [to_canonical(dict(row)) for row in rows]

    def check(self) -> str:
        self.list(now_iso())
        return f"local sqlite at {self.path}"


# -------------------------------------------------------------- supabase

class SupabaseBackend(Backend):
    """Postgres through PostgREST. Works with the anon key under RLS."""

    name = "supabase"

    def __init__(self, cfg: dict):
        require(cfg, "supabase_url", "supabase_key")
        self.url = cfg["supabase_url"].rstrip("/")
        self.key = cfg["supabase_key"]
        self.table = cfg.get("supabase_table") or DEFAULTS["supabase_table"]

    def _headers(self, extra: dict | None = None) -> dict:
        headers = {
            "apikey": self.key,
            "Authorization": f"Bearer {self.key}",
            "Content-Type": "application/json",
        }
        headers.update(extra or {})
        return headers

    @property
    def _endpoint(self) -> str:
        return f"{self.url}/rest/v1/{self.table}"

    def upsert(self, doc: dict) -> None:
        status, body = http(
            self._endpoint,
            method="POST",
            headers=self._headers({"Prefer": "resolution=merge-duplicates,return=minimal"}),
            body=[to_columns(doc)],
        )
        if status >= 300:
            die(f"supabase upsert failed - HTTP {status}: {body}")

        # Opportunistic TTL sweep; failure here is not worth interrupting work.
        http(
            f"{self._endpoint}?expires_at=lt.{urllib.parse.quote(now_iso())}",
            method="DELETE",
            headers=self._headers({"Prefer": "return=minimal"}),
        )

    def get(self, task_id: str, agent_id: str) -> dict | None:
        status, body = http(
            f"{self._endpoint}?id=eq.{urllib.parse.quote(task_id)}&select=*&limit=1",
            headers=self._headers(),
        )
        if status >= 300:
            die(f"supabase read failed - HTTP {status}: {body}")
        rows = json.loads(body or "[]")
        return to_canonical(rows[0]) if rows else None

    def list(self, since: str) -> list:
        status, body = http(
            f"{self._endpoint}?updated_at=gt.{urllib.parse.quote(since)}"
            f"&select=*&order=updated_at.desc&limit=200",
            headers=self._headers(),
        )
        if status >= 300:
            hint = ""
            if status in (401, 403):
                hint = "\n  check the key, and that RLS policies allow it to read/write the table"
            elif status == 404:
                hint = f"\n  table '{self.table}' not found - run backends/supabase/schema.sql first"
            die(f"supabase query failed - HTTP {status}: {body}{hint}")
        return [to_canonical(row) for row in json.loads(body or "[]")]

    def check(self) -> str:
        self.list(now_iso())
        return f"supabase {self.url} (table: {self.table})"


BACKENDS = {
    "local": LocalBackend,
    "supabase": SupabaseBackend,
}


def make_backend(cfg: dict) -> Backend:
    backend = cfg.get("backend", "local")
    if backend not in BACKENDS:
        die(f"unknown backend '{backend}'. Choose one of: {', '.join(sorted(BACKENDS))}")
    return BACKENDS[backend](cfg)


# ==========================================================================
# per-session active-task tracking
# ==========================================================================

def session_slug() -> str:
    """Key for 'the task this session owns'.

    Prefers the runtime's own session id so parallel agents in one repo do not
    clobber each other's pointer; falls back to the working directory.
    """
    for var in ("AGENT_STATUS_SESSION", "CLAUDE_SESSION_ID", "CODEX_SESSION_ID", "HERMES_SESSION_ID"):
        value = os.environ.get(var)
        if value:
            return hashlib.sha1(value.encode()).hexdigest()[:12]
    return hashlib.sha1(os.getcwd().encode()).hexdigest()[:12]


def current_path() -> Path:
    return STATE_DIR / f"current-{session_slug()}.json"


def save_current(task_id: str, task: str):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    current_path().write_text(json.dumps({"id": task_id, "task": task}))


def load_current() -> dict | None:
    path = current_path()
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def clear_current():
    path = current_path()
    if path.exists():
        path.unlink()


def git_repo() -> str | None:
    """Nearest enclosing repo name, without shelling out to git."""
    path = Path.cwd().resolve()
    for candidate in [path, *path.parents]:
        if (candidate / ".git").exists():
            return candidate.name
    return None


def expiry(cfg: dict, key: str) -> str:
    hours = float(cfg.get(key) or DEFAULTS[key])
    return (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat(
        timespec="seconds"
    ).replace("+00:00", "Z")


# ==========================================================================
# commands
# ==========================================================================

def cmd_setup(args, cfg):
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    existing = parse_env_file(CONFIG_PATH) if CONFIG_PATH.exists() else {}
    for field in ("backend", "supabase_url", "supabase_key", "supabase_table",
                  "local_path", "agent_id", "agent_kind", "agent_label"):
        value = getattr(args, field, None)
        if value:
            existing[ENV_PREFIX + field.upper()] = value

    if existing:
        lines = ["# agent-status configuration", f"# written {now_iso()}", ""]
        lines += [f"{key}={value}" for key, value in sorted(existing.items())]
        CONFIG_PATH.write_text("\n".join(lines) + "\n")
        CONFIG_PATH.chmod(0o600)
        print(f"wrote {CONFIG_PATH}")

    fresh = load_config()
    target = make_backend(fresh).check()
    print(f"backend     ->  {target}")
    print(f"agent_id    ->  {fresh['agent_id']}")
    print(f"agent_label ->  {fresh['agent_label']}")


def cmd_start(args, cfg):
    backend = make_backend(cfg)

    # If this session already has an open task (usually created by the
    # UserPromptSubmit hook from the raw prompt), reuse its id and just retitle
    # it. Otherwise the board shows the prompt and the model's description as
    # two separate rows, and the hook's row is never closed.
    if not args.id:
        existing = load_current()
        if existing:
            args.id = existing["id"]
            patch(args, cfg, "working", detail=args.detail,
                  step=args.step, total=args.total, task_title=args.task)
            return

        # No local pointer for this session - but this agent might still have
        # a dangling "working" task from an earlier turn whose Stop hook never
        # fired (crashed process, a session-id that changed mid-conversation,
        # a hook that errored). The local pointer file cannot detect that on
        # its own, so ask the backend directly.
        #
        # Only supersede tasks that are also STALE (untouched past the
        # threshold) - a second genuinely concurrent Claude Code window
        # reporting under the same agent identity will keep refreshing its own
        # task well within that window, so this must not close it out just
        # because a sibling session started something new.
        stale_cutoff = (datetime.now(timezone.utc) - timedelta(
            minutes=float(cfg.get("stale_minutes") or DEFAULTS["stale_minutes"])
        )).isoformat(timespec="seconds").replace("+00:00", "Z")
        for doc in backend.list("2000-01-01T00:00:00Z"):
            if (
                doc.get("agentId") == cfg["agent_id"]
                and doc.get("status") == "working"
                and (doc.get("updatedAt") or "") < stale_cutoff
            ):
                doc["status"] = "done"
                doc["updatedAt"] = now_iso()
                doc["detail"] = "Closed automatically - abandoned without a final status"
                doc["question"] = None
                doc["waitingSince"] = None
                doc["expiresAt"] = expiry(cfg, "done_ttl_hours")
                backend.upsert({k: v for k, v in doc.items() if k in FIELDS})

    task_id = args.id or f"t_{uuid.uuid4().hex[:16]}"
    stamp = now_iso()
    doc = {
        "id": task_id,
        "agentId": cfg["agent_id"],
        "agentKind": cfg["agent_kind"],
        "agentLabel": cfg["agent_label"],
        "host": socket.gethostname(),
        "task": args.task,
        "status": "working",
        "detail": args.detail,
        "question": None,
        "step": args.step,
        "total": args.total,
        "cwd": os.getcwd(),
        "repo": git_repo(),
        "startedAt": stamp,
        "updatedAt": stamp,
        "endedAt": None,
        "waitingSince": None,
        "expiresAt": expiry(cfg, "ttl_hours"),
    }
    backend.upsert(doc)
    save_current(task_id, args.task)
    emit(args, {"id": task_id, "status": "working", "task": args.task})


def patch(args, cfg, status: str, **fields):
    backend = make_backend(cfg)

    task_id = getattr(args, "id", None)
    current = None
    if not task_id:
        current = load_current()
        if not current:
            die('no active task for this session. Start one first:\n'
                '  agent-status start "what you are working on"')
        task_id = current["id"]

    doc = backend.get(task_id, cfg["agent_id"])
    if doc is None:
        # Expired, pruned, or a hook fired before any task was started.
        stamp = now_iso()
        doc = {
            "id": task_id,
            "agentId": cfg["agent_id"],
            "agentKind": cfg["agent_kind"],
            "agentLabel": cfg["agent_label"],
            "host": socket.gethostname(),
            "task": (current or {}).get("task") or fields.get("detail") or "Untitled task",
            "cwd": os.getcwd(),
            "repo": git_repo(),
            "startedAt": stamp,
        }

    doc["status"] = status
    doc["updatedAt"] = now_iso()
    title = fields.pop("task_title", None) or getattr(args, "task", None)
    if title:
        doc["task"] = title

    for key, value in fields.items():
        if value is not None:
            doc[key] = value

    if status == "waiting":
        if not doc.get("waitingSince"):
            doc["waitingSince"] = doc["updatedAt"]
    else:
        # Any non-waiting status means the open question is no longer open.
        doc["waitingSince"] = None
        doc["question"] = None

    if status in ("done", "failed"):
        doc["endedAt"] = doc["updatedAt"]
        doc["expiresAt"] = expiry(cfg, "done_ttl_hours")
    else:
        doc["expiresAt"] = expiry(cfg, "ttl_hours")

    backend.upsert({key: value for key, value in doc.items() if key in FIELDS})

    if status in ("done", "failed"):
        clear_current()
    else:
        save_current(task_id, doc["task"])

    emit(args, {"id": task_id, "status": status, "task": doc["task"]})


def cmd_update(args, cfg):
    patch(args, cfg, "working", detail=args.detail, step=args.step, total=args.total)


def cmd_wait(args, cfg):
    patch(args, cfg, "waiting", question=args.question, detail=args.detail)


def cmd_done(args, cfg):
    patch(args, cfg, "done", detail=args.summary or args.detail)


def cmd_fail(args, cfg):
    patch(args, cfg, "failed", detail=args.error or args.detail)


def cmd_list(args, cfg):
    since = (datetime.now(timezone.utc) - timedelta(hours=args.hours)).isoformat(
        timespec="seconds"
    ).replace("+00:00", "Z")
    docs = make_backend(cfg).list(since)
    docs.sort(key=lambda d: d.get("updatedAt") or "", reverse=True)

    if args.json:
        print(json.dumps(docs, indent=2))
        return
    if not docs:
        print(f"no agent activity in the last {args.hours}h")
        return

    icons = {"working": "*", "waiting": "?", "done": "+", "failed": "!"}
    for doc in docs:
        icon = icons.get(doc.get("status"), "-")
        label = doc.get("agentLabel") or doc.get("agentId")
        line = f"{icon} [{str(doc.get('status')):7}] {label}: {doc.get('task')}"
        if doc.get("step") and doc.get("total"):
            line += f"  ({doc['step']}/{doc['total']})"
        print(line)
        note = doc.get("question") or doc.get("detail")
        if note:
            print(f"           {note}")


def cmd_hook(args, cfg):
    """Lifecycle hook entrypoint; the payload arrives as JSON on stdin.

    Two hard rules, because this runs inside the user's session:

    * Never write to stdout. On UserPromptSubmit, Claude Code feeds a hook's
      stdout straight into the model's context, so a stray status line would be
      injected into every single prompt.
    * Never fail. A non-zero exit is reported to the user, and exit code 2
      actively blocks their prompt. Telemetry must never cost someone a turn.

    main() enforces both; this function just decides what to record.
    """
    try:
        raw = sys.stdin.read() or "{}"
        payload = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        raw, payload = "{}", {}

    if os.environ.get("AGENT_STATUS_DEBUG"):
        # Temporary, opt-in only - writes the raw payload so a hook mechanism
        # can be inspected directly instead of guessed at.
        with open(STATE_DIR / "hook-debug.log", "a") as fh:
            fh.write(f"{now_iso()} event={args.event} argv={sys.argv[1:]}\n{raw}\n\n")

    # The hook subparser does not define the flags the command handlers read,
    # so supply the full set they expect.
    args.task = None
    args.id = None
    args.detail = None
    args.step = None
    args.total = None
    args.question = None
    args.summary = None
    args.error = None

    # Runtimes disagree on field names but all carry the same facts.
    #   Claude Code: {"prompt": ..., "session_id": ..., "cwd": ...}
    #   Hermes:      {"extra": {"user_message": ...}, "session_id": ..., "cwd": ...}
    extra = payload.get("extra") or {}

    # Bind to the runtime's own session id so concurrent sessions in one repo
    # keep separate tasks. Hook subprocesses often do not inherit the parent's
    # session environment, so the payload is the reliable source.
    session_id = payload.get("session_id") or extra.get("session_id")

    # Hermes's own `hooks test` / `hooks doctor` fire the hook for real, with
    # this exact literal session id, to verify it runs cleanly - a diagnostic
    # an agent might run on its own initiative (e.g. to answer "are you wired
    # up?"). Faithfully reporting that as real activity would overwrite
    # whatever genuine task the agent was actually doing, so treat it as a
    # no-op rather than board noise.
    if session_id == "test-session":
        return

    if session_id:
        os.environ["AGENT_STATUS_SESSION"] = str(session_id)

    # Report the repo the agent is actually working in, not wherever the hook ran.
    cwd = payload.get("cwd") or extra.get("cwd")
    if cwd and os.path.isdir(cwd):
        try:
            os.chdir(cwd)
        except OSError:
            pass

    if getattr(args, "kind", None):
        cfg["agent_kind"] = args.kind
        if not os.environ.get(ENV_PREFIX + "AGENT_ID"):
            cfg["agent_id"] = f"{args.kind}@{short_host()}"
        if not os.environ.get(ENV_PREFIX + "AGENT_LABEL"):
            cfg["agent_label"] = default_label(args.kind)

    # A runtime that hosts several distinct agent identities under one install
    # (Hermes profiles, for example) needs to tell them apart on the board -
    # otherwise every profile reports as the same generic "Hermes (host)".
    if getattr(args, "agent_label", None) and not os.environ.get(ENV_PREFIX + "AGENT_LABEL"):
        cfg["agent_label"] = args.agent_label
    if getattr(args, "agent_id", None) and not os.environ.get(ENV_PREFIX + "AGENT_ID"):
        cfg["agent_id"] = args.agent_id
    elif getattr(args, "agent_label", None) and not os.environ.get(ENV_PREFIX + "AGENT_ID"):
        # Derive a stable id from the label so tasks from this profile land in
        # one partition/session lineage instead of colliding with others.
        slug = re.sub(r"[^a-z0-9]+", "-", args.agent_label.lower()).strip("-") or "agent"
        cfg["agent_id"] = f"{slug}@{short_host()}"

    if args.event == "prompt":
        # The user asked for something, so a unit of work starts now. This is
        # what makes a session visible without the model reporting anything.
        prompt = (
            payload.get("prompt")
            or extra.get("user_message")
            or payload.get("user_message")
            or ""
        )
        prompt = prompt.strip() if isinstance(prompt, str) else ""
        if not prompt:
            return
        title = summarize_prompt(prompt)
        if not title:
            # Purely synthetic content (a replayed system/tool notification,
            # empty after stripping known wrappers) - not a real user ask.
            return
        args.task = title
        cmd_start(args, cfg)
        return

    if not load_current():
        # Nothing open - a mid-session hook should not invent a task.
        return

    if args.event == "notification":
        message = payload.get("message") or "Agent needs your input"
        patch(args, cfg, "waiting", question=message)

    elif args.event == "stop":
        # Stop fires at every turn end. A task already waiting on the user still
        # owes them an answer, so closing it would drop the question off the board.
        current = load_current()
        if current:
            doc = make_backend(cfg).get(current["id"], cfg["agent_id"])
            if doc and doc.get("status") == "waiting":
                return
        patch(args, cfg, "done", detail="Agent finished its turn")


def summarize_prompt(prompt: str, limit: int = 90) -> str | None:
    """Condense a raw user prompt into one board-sized line.

    Runtimes routinely prepend machine context to the user's text - injected
    <context> blocks, system reminders, relay metadata, background-task
    notifications replayed as the next turn's "prompt". Strip that out.

    Returns None when nothing survives stripping - a prompt that is *entirely*
    wrapper content is not a real user ask, and showing the raw markup on the
    board (git commit hashes, tool-call ids, XML soup) is worse than showing
    nothing. Callers should skip the update rather than invent a task.
    """
    text = re.sub(r"```.*?```", " ", prompt, flags=re.DOTALL)

    # Known non-request preambles that precede injected system content.
    text = re.sub(
        r"^\s*\[SYSTEM NOTIFICATION[^\]]*\].*?(?=<|\Z)", " ", text,
        flags=re.DOTALL | re.IGNORECASE,
    )

    # Paired XML-ish wrappers, then any leftover stray tags.
    stripped = re.sub(r"<(\w[\w.-]*)\b[^>]*>.*?</\1\s*>", " ", text, flags=re.DOTALL)
    stripped = re.sub(r"</?\w[\w.-]*\b[^>]*/?>", " ", stripped)

    # Relay headers such as "Scope: thread" or "Channel: marketing-tribe".
    stripped = re.sub(r"^\s*[A-Z][\w ]{0,24}:\s*\S+\s*$", " ", stripped, flags=re.MULTILINE)

    cleaned = " ".join(stripped.split())
    if len(cleaned) < 8:
        # Nothing meaningful survived stripping - this was not a real request.
        return None

    return cleaned if len(cleaned) <= limit else cleaned[:limit].rsplit(" ", 1)[0] + "..."


def cmd_config(args, cfg):
    redacted = dict(cfg)
    for key in list(redacted):
        if "key" in key and redacted[key]:
            redacted[key] = redacted[key][:6] + "..." + f"({len(redacted[key])} chars)"
    if args.json:
        print(json.dumps(redacted, indent=2))
        return
    print(f"config file: {CONFIG_PATH}{'' if CONFIG_PATH.exists() else '  (absent)'}")
    for key in sorted(redacted):
        print(f"  {ENV_PREFIX}{key.upper()} = {redacted[key]}")


def emit(args, data: dict):
    if getattr(args, "json", False):
        print(json.dumps(data))
    else:
        print(f"{data['status']}: {data['task']}  [{data['id']}]")


# ==========================================================================
# cli
# ==========================================================================

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agent-status",
        description="Report AI agent task status to a shared board.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p, with_task=True):
        p.add_argument("--id", help="task id (defaults to this session's active task)")
        p.add_argument("--detail", help="short human-readable detail line")
        p.add_argument("--json", action="store_true", help="machine-readable output")
        if with_task:
            p.add_argument("--task", help="rename the task")

    p_setup = sub.add_parser("setup", help="write config and verify the backend")
    for flag in ("backend", "supabase-url", "supabase-key", "supabase-table",
                 "local-path", "agent-id", "agent-kind", "agent-label"):
        p_setup.add_argument(f"--{flag}", dest=flag.replace("-", "_"))
    p_setup.set_defaults(func=cmd_setup)

    p_start = sub.add_parser("start", help="begin a task")
    p_start.add_argument("task", help="what you are working on, in one line")
    p_start.add_argument("--step", type=int)
    p_start.add_argument("--total", type=int)
    common(p_start, with_task=False)
    p_start.set_defaults(func=cmd_start)

    p_update = sub.add_parser("update", help="report progress on the active task")
    p_update.add_argument("--step", type=int)
    p_update.add_argument("--total", type=int)
    common(p_update)
    p_update.set_defaults(func=cmd_update)

    p_wait = sub.add_parser("wait", help="mark the task as blocked on the user")
    p_wait.add_argument("--question", required=True, help="what you need from the user")
    common(p_wait)
    p_wait.set_defaults(func=cmd_wait)

    p_done = sub.add_parser("done", help="mark the task complete")
    p_done.add_argument("--summary", help="one line on what you delivered")
    common(p_done)
    p_done.set_defaults(func=cmd_done)

    p_fail = sub.add_parser("fail", help="mark the task failed")
    p_fail.add_argument("--error", help="what went wrong")
    common(p_fail)
    p_fail.set_defaults(func=cmd_fail)

    p_list = sub.add_parser("list", help="show recent activity across all agents")
    p_list.add_argument("--hours", type=float, default=24)
    p_list.add_argument("--json", action="store_true")
    p_list.set_defaults(func=cmd_list)

    p_config = sub.add_parser("config", help="show resolved configuration")
    p_config.add_argument("--json", action="store_true")
    p_config.set_defaults(func=cmd_config)

    p_hook = sub.add_parser("hook", help="lifecycle hook entrypoint (stdin JSON)")
    p_hook.add_argument("event", choices=["prompt", "notification", "stop"])
    p_hook.add_argument("--kind", help="agent runtime, when the hook subprocess cannot detect it")
    p_hook.add_argument("--agent-id", dest="agent_id", help="override agent_id, e.g. to tell apart profiles sharing one install")
    p_hook.add_argument("--agent-label", dest="agent_label", help="override agent_label, shown on the board")
    p_hook.add_argument("--json", action="store_true")
    p_hook.set_defaults(func=cmd_hook)

    return parser


def main():
    args = build_parser().parse_args()
    if not hasattr(args, "task"):
        args.task = None

    if args.command == "hook":
        # Silence stdout and swallow every failure: this runs inside the user's
        # session, where output pollutes the model's context and a non-zero exit
        # can block their prompt.
        import contextlib, io
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                args.func(args, load_config())
        except BaseException as exc:  # noqa: BLE001 - telemetry must never break a turn
            print(f"agent-status hook: {exc}", file=sys.stderr)
        sys.exit(0)

    try:
        args.func(args, load_config())
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
