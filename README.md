# Agent Status Monitor

See what every one of your AI coding agents is doing — Claude Code, Codex,
Hermes, or anything else that can run a shell command — whether it's running
on your laptop or on a server across the world. Get notified the moment one
finishes or needs you.

```
  [?2]  <- macOS menu bar: 2 agents are waiting on you

  NEEDS YOU
  ? Migrate billing tests to pytest
    Bump the minor version before I tag the release?
    Codex (macbook-air) · billing · 4m ago

  WORKING
  * Scrape competitor pricing pages
    42 of 120 pages fetched
    Hermes (vps-mumbai) · 3/5 · 12s ago
```

A macOS menu bar app and an Android app both read the same board. Agents
write to it with one CLI command, wherever they happen to be running.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/gigcompany/agent-status-monitor/main/install.sh | bash
```

Or clone it and pick a backend up front:

```bash
git clone https://github.com/gigcompany/agent-status-monitor.git
cd agent-status-monitor
cp .env.example .env   # edit it, then:
./install.sh --hooks --login
```

The installer links the skill into every agent runtime it finds on the
machine, installs the `agent-status` CLI, builds the menu bar app (macOS
only), and verifies the backend connection before finishing.

Run `./install.sh --help` for every flag.

## How it works

Three layers, in order of how much they can do without your help:

1. **`SKILL.md`** — Claude Code, Codex, Hermes, and Cursor all read the same
   frontmatter skill format, so one symlinked directory teaches all of them
   at once: *"here's how and when to report status."*
2. **The `agent-status` CLI** — the layer everything else is built on. A
   single Python file, stdlib only, no `pip install` needed. Any agent that
   can run a shell command can report, including ones this project has never
   heard of.
3. **Lifecycle hooks** — fully automatic reporting, no model cooperation
   required. Currently wired for **Claude Code** (`UserPromptSubmit` /
   `Notification` / `Stop`) and **every Hermes profile** (`pre_llm_call` /
   `post_llm_call`). Other runtimes fall back to layer 2: the skill teaches
   the model to call the CLI itself, which is reliable but not automatic.
   See [`TODO.md`](TODO.md) for hook support on other harnesses.

```
  agent ──(agent-status CLI)──> backend (Supabase / Cosmos / local SQLite)
                                     │
                       polled every few seconds by
                                     │
                     ┌───────────────┴───────────────┐
              macOS menu bar app              Android app
           (native notifications)          (pull to refresh)
```

## Setting up your laptop

This is the machine you actually want to look at — where the menu bar app
(and/or the Android app) lives.

```bash
git clone https://github.com/gigcompany/agent-status-monitor.git
cd agent-status-monitor
./install.sh --hooks --login
```

- `--hooks` wires up automatic reporting for Claude Code and Hermes (see
  [below](#hermes-multiple-profiles) if you run more than one Hermes
  profile)
- `--login` starts the menu bar app at login
- The installer asks which backend to use if you haven't set one in `.env`
  first — **Supabase is the default** and the one to pick unless you already
  run Azure

Any agent you run *on this same laptop* — Claude Code, Codex, a local Hermes
instance — is wired up by this one command. Agents running elsewhere (a
cloud VPS, a spare machine) need the separate step below.

### Android app

A read-only companion app lives in [`mobile/`](mobile) — Expo, Material You
theming, same board. See [`mobile/README.md`](mobile/README.md) to build and
run it. It only supports the Supabase backend (a phone can't read a file on
your Mac, and a Cosmos master key doesn't belong on a mobile device — see
[Security](#security)).

## Setting up a cloud server or remote agent box

Anywhere your agents actually *run* — a VPS, a droplet, a spare Linux box —
needs the CLI, not the app. Two ways to get it there, depending on whether
you can SSH in from your laptop.

### From your laptop, over SSH (recommended)

```bash
./install-remote.sh user@your-server --kind hermes --label "Hermes (scraper)"
```

This reads the backend credentials already configured on your laptop, copies
just the CLI script and skill over SSH (no git clone needed on the far
side — python3 is the only requirement), and writes the remote's config.
Credentials are piped over the existing SSH session, never passed as CLI
arguments, so they never land in the remote's shell history or process list.

`--kind` sets what shows up on the board (`hermes`, `codex`, `claude-code`,
or anything else you want as a label prefix); `--label`/`--id` override the
auto-generated agent name if you want something more specific than
`hermes@your-server`.

> The `local` backend can't be used this way — it's a SQLite file on one
> machine, invisible to anywhere else. `install-remote.sh` refuses outright
> if your laptop is configured for `local`, rather than silently doing
> nothing.

### Directly on the server (no SSH access from your laptop)

```bash
git clone https://github.com/gigcompany/agent-status-monitor.git
cd agent-status-monitor
cp .env.example .env   # fill in the SAME Supabase (or Cosmos) credentials
./install.sh --backend supabase --hooks --no-app
```

`--no-app` skips the menu bar app build entirely — most servers don't have a
GUI, and even the ones that do don't need a second copy of the app running.

## Backends

Pick one with `AGENT_STATUS_BACKEND` in `.env` (or let the installer ask).

| Backend | Setup | Spans machines | Cost | Config needed |
|---|---|---|---|---|
| **`local`** | none | no | free | `AGENT_STATUS_LOCAL_PATH` (optional, has a default) |
| **`supabase`** *(default)* | run one SQL file | yes | free tier | `AGENT_STATUS_SUPABASE_URL`, `_KEY` |
| **`cosmos`** | Azure account | yes | ~$0.20–0.50/mo serverless | `AGENT_STATUS_COSMOS_ENDPOINT`, `_KEY` |

### `local` — no cloud account, no keys

SQLite at `~/.agent-status/status.db`. Every agent on that one machine
writes to it in WAL mode, so a dozen of them can report concurrently without
corrupting it. Since a local file read is free, the menu bar app polls it
every 2 seconds instead of 5. Use this only if every agent you want to see
runs on the same Mac as the app — it cannot span machines.

### `supabase` — the default, spans machines, free tier

1. Create a project at [supabase.com](https://supabase.com) — free tier, no
   card required.
2. Open **SQL Editor** → New query → paste
   [`backends/supabase/schema.sql`](backends/supabase/schema.sql) → Run.
3. **Project Settings → API** → copy the **Project URL** and the
   **anon / public** key (not `service_role` — see
   [Security](#security)).
4. Put both in `.env`, or answer the installer's prompts.

The schema enables Realtime on the table already, for when the polling
viewers become websocket-based (see [`TODO.md`](TODO.md)).

### `cosmos` — if you're already on Azure

```bash
./install.sh --backend cosmos --provision-azure
```

Creates a serverless Cosmos DB account, database, and container for you via
the `az` CLI (must already be logged in). Or point `AGENT_STATUS_COSMOS_*` at
an account you already have.

### Adding another backend

Three methods in `skill/agent-status/scripts/agent_status.py`
(`upsert`, `get`, `list`) plus a matching `fetchTasks` in the Swift app and
the TypeScript mobile app. See [`TODO.md`](TODO.md) for Firestore, which is
next in line.

## Connecting different agent runtimes

The CLI is universal (`agent-status start/update/wait/done/fail/list`,
same on every runtime — see [Reporting from an agent](#reporting-from-an-agent)),
but *automatic* reporting depends on each runtime's own hook system.

### Claude Code

`--hooks` wires three hooks into `~/.claude/settings.json` (backed up first):

| Hook | Effect |
|---|---|
| `UserPromptSubmit` | Creates the task from your own prompt text — the session shows up even if the model never calls the CLI |
| `Notification` | Claude needs permission or input → task becomes **waiting**, you get notified |
| `Stop` | Claude finished its turn → task becomes **done** (unless it's `waiting` — see below) |

`Stop` deliberately leaves a `waiting` task alone: you still owe it an
answer, and closing it would drop the question off the board.

**Self-healing for orphaned tasks:** if a `Stop` hook never fires for some
reason (a crashed process, hooks that changed mid-session), the next task
that agent starts will automatically close out anything still `working` and
untouched for 30+ minutes. It will *not* close a task that's still being
actively updated — two genuinely concurrent Claude Code windows on the same
machine don't fight over one board row.

### Hermes (multiple profiles)

Hermes profiles (`hermes profile create <name>`) are completely separate
trees, each with its own `config.yaml` and skill directory — the installer
loops over **every profile it finds**, not just `default`. Because Hermes
tracks hook approval by the script's file modification time, editing the
script (updating this project) invalidates every profile's approval until
you re-approve:

```bash
hermes -p <profile> --accept-hooks     # once per profile, after any update
hermes -p <profile> gateway restart    # if that profile's gateway is running
```

`hermes hooks doctor` will tell you if a profile's approval has gone stale.

One thing worth knowing: `hermes hooks doctor` / `hermes hooks test` **really
execute the hook** as a smoke test, using a canned payload with
`session_id: "test-session"`. This project filters that exact marker out, so
running diagnostics on your own wiring never pollutes the board — if an
agent runs `hooks doctor` on its own initiative (e.g. to answer "are you
wired up?"), that's a safe thing to do.

### Codex

Codex has exactly one global `notify` slot in `config.toml`, and it's often
already claimed by something else (Computer Use, another tool). The
installer will not touch it, so Codex currently reports through the skill
only (layer 2 above) — reliable, but the model has to remember to call the
CLI. PRs adding a safer Codex hook integration are welcome.

### Anything else

If it can run a shell command, it can report:

```bash
agent-status start "Add Stripe refund endpoint"
agent-status wait --question "Refund partial amounts, or full-only for v1?"
agent-status done --summary "POST /refunds live, 8 tests passing"
```

Add its skill directory to the loop in `install.sh` and it gets the same
one-command install everything else does.

## Reporting from an agent

```bash
agent-status start  "Add Stripe refund endpoint"
agent-status update --detail "Endpoint done, writing tests" --step 2 --total 3
agent-status wait   --question "Refund partial amounts, or full-only for v1?"
agent-status done   --summary "POST /refunds live, 8 tests passing"
agent-status fail   --error "Stripe webhook secret missing in staging"

agent-status list --hours 6    # what every agent is doing
agent-status config            # resolved settings, keys redacted
```

No task ID to track — the CLI remembers the active task per session, keyed
on the runtime's own session ID (falling back to the working directory), so
parallel agents in one repo don't clobber each other.

## Configuration

One file, `~/.agent-status/config.env`, read by the CLI **and** both apps —
they can never disagree. The menu bar app re-reads it every poll, so edits
take effect without restarting anything. Copy `.env.example` to `.env` and
edit before installing, or let the installer write it from your answers.

Any value can be overridden by a real environment variable, which is how one
machine reports as several distinct agent identities:

```bash
AGENT_STATUS_AGENT_ID=hermes@scraper \
AGENT_STATUS_AGENT_LABEL="Hermes (scraper)" \
  agent-status start "Crawl pricing pages"
```

See [`.env.example`](.env.example) for the full list with defaults.

## Status model

| Status | Meaning | Notifies |
|---|---|---|
| `working` | Actively running | no |
| `waiting` | Blocked on you | **yes** |
| `done` | Finished | yes (configurable) |
| `failed` | Stopped on an error | **yes** |

A task still `working` with no update for 30 minutes shows as **stale**
rather than trusted — an agent that crashes cannot report its own death.

Finished tasks are kept 48h and active ones 7 days by default
(`AGENT_STATUS_TTL_HOURS`, `AGENT_STATUS_DONE_TTL_HOURS`). Agents sweep
expired rows opportunistically on write, so there's no cleanup job to run.

## Notifications

The menu bar app requests native notification permission first. macOS
refuses that to apps it hasn't notarized, so it falls back to `osascript`,
which always works — notifications then appear attributed to Script Editor
rather than Agent Status Monitor. Notification text is passed to `osascript`
as arguments, never interpolated into script source, so agent-authored text
can't inject AppleScript.

Sign and notarize the bundle with a Developer ID and the native path takes
over automatically, no code change needed.

## Security

- **Keys are shared with every agent host.** For `supabase` that's the anon
  key under a permissive RLS policy; for `cosmos` it's the account master
  key. Both grant read/write to anyone holding them. Use a dedicated project
  or account, not one with anything sensitive already in it.
- Config files are written `0600`; `install-remote.sh` pipes keys over the
  existing SSH session rather than passing them as arguments, so they never
  land in the remote process list or shell history.
- **Task text leaves your machine** on the cloud backends. Keep secrets out
  of task descriptions, or use the `local` backend.
- Revoking one remote agent means rotating the shared key and re-running the
  installers. For per-agent revocation, switch to Supabase Auth or Cosmos
  resource tokens (not built yet — see [`TODO.md`](TODO.md)).

## Development

```bash
cd menubar
swift build -c release
./build-app.sh              # assemble + sign AgentMonitor.app

log stream --predicate 'subsystem == "com.gofloaters.agentmonitor"' --info --debug
```

`build-app.sh` signs with an Apple Development identity when it finds one
and falls back to ad-hoc.

For the mobile app, see [`mobile/README.md`](mobile/README.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Roadmap

See [`TODO.md`](TODO.md) for what's planned and up for grabs.

## License

MIT
