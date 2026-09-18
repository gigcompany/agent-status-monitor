# Contributing

Thanks for looking. This project is young and the easiest way to help right
now is picking something off [`TODO.md`](TODO.md) or fixing something you
hit while actually using it.

## Project layout

```
skill/agent-status/scripts/agent_status.py   the CLI - single file, stdlib only, no pip install
skill/agent-status/SKILL.md                  what it teaches an agent to do and when
backends/supabase/schema.sql                 Postgres schema for the default backend
install.sh / install-remote.sh               installers (local machine / remote SSH)
.env.example                                 every config key, with defaults and comments
menubar/                                     macOS menu bar app (Swift / SwiftUI)
mobile/                                      Android app (Expo / React Native / TypeScript)
```

Each surface is documented where it lives: [`README.md`](README.md) for the
overall system, [`mobile/README.md`](mobile/README.md) for the Android app.

## Ground rules for the CLI specifically

`agent_status.py` has one hard constraint that shapes everything else: **it
stays a single file with zero third-party dependencies.** The entire point
is that it can be `scp`'d onto a bare remote box and just work with whatever
Python 3.8+ is already there — no `pip install`, no virtualenv, no lockfile.
If your change needs a dependency, it probably needs a different file
(a backend adapter is a natural place for that, still gated behind an
import inside its own class so the rest of the CLI is unaffected if it's
missing).

## Testing

There's no automated test suite yet — that's a real gap and a good place to
contribute (see [`TODO.md`](TODO.md)). Until one exists, the patterns that
were actually used while building this are worth following:

- **Backend changes**: exercise the real thing, not just the code. A local
  `mock_postgrest.py`-style stand-in (asserting on headers, filters, and
  body shape) catches wire-format bugs before you touch a real project; then
  confirm against an actual free-tier Supabase project before calling it
  done, since RLS behavior and exact Postgres error shapes don't show up in
  a mock.
- **Menu bar app changes**: you can link `StatusStore.swift` (or any other
  source file) into a throwaway command-line harness and run real assertions
  against it — no simulator or screen access needed. `UNUserNotificationCenter`
  specifically needs a real, Launch-Services-registered `.app` bundle to
  even initialize (it crashes outside one), so notification-path testing
  needs the full `build-app.sh` bundle, not a bare binary.
- **Hook integrations** (see below): don't guess a runtime's hook payload
  shape from documentation alone if you can get the real thing — add
  temporary logging, fire the runtime's own diagnostic/test command if it
  has one, and read the actual JSON.
- Whatever you build, if it talks to a real backend, clean up your test
  rows before calling it done — the shared board this project produces is
  meant to be trustworthy, including during development.

## Adding hook support for another agent runtime

Claude Code and Hermes are the two done so far, and Hermes's is the more
instructive one to read (`install.sh`'s "Adding Hermes hooks" section, and
`cmd_hook` in `agent_status.py`) because it surfaces the traps a new
integration is likely to hit:

1. **Find the real hook mechanism**, not just a plugin API. Hermes has a
   Python plugin system *and* a `hooks:` shell-command block in
   `config.yaml` — only the latter lets an external script like this one
   subscribe without becoming a Python dependency of the host project.
2. **Read the actual payload**, don't assume it matches another runtime's
   shape. Claude Code sends `{"prompt": ...}`; Hermes sends
   `{"extra": {"user_message": ...}}`. Add temporary logging
   (`AGENT_STATUS_DEBUG=1` already does this — see `cmd_hook`) and capture a
   real event rather than guessing from docs, which are often incomplete.
3. **Find the runtime's own diagnostic/test command** and check what it
   sends. Hermes's `hooks doctor` and `hooks test` genuinely execute the
   hook with a canned payload carrying `session_id: "test-session"` — a
   detail nowhere in the docs, found by capturing the real payload. Filter
   whatever the equivalent synthetic marker is for your runtime, or a user
   running their own diagnostics will pollute their board.
4. **Respect the runtime's consent/security model.** Hermes requires
   explicit per-hook approval and invalidates it when the hook script's
   mtime changes — don't try to route around that; document how to
   re-approve after an update instead (see the README's Hermes section).
5. **Multiple identities on one host.** If the runtime supports running
   several distinct agent profiles/instances from one install (Hermes
   profiles), loop over all of them in the installer, not just the default
   one — and use `--agent-id` / `--agent-label` on the hook command so they
   don't collide on the board under one generic name.
6. Wire the installer to **install into every instance it finds**, and
   make sure a hook failure can never block the user's actual work: no
   stdout (some runtimes inject a hook's stdout into the model's context),
   never a non-zero exit that the runtime treats as a block, and every
   error swallowed with a log line instead of a crash.

## Adding a backend

Three methods on the CLI side (`upsert`, `get`, `list` in
`agent_status.py`), matched by a `fetchTasks` conforming to `StatusBackend`
in `menubar/Sources/AgentMonitor/Backend.swift`, and — if the backend should
be reachable from a phone — the equivalent in `mobile/src/api.ts`. Look at
the Supabase implementation in each as the reference: it's the one that's
been run against a real project the most.

Backends that need a dependency the stdlib doesn't have should still degrade
gracefully if that dependency is genuinely optional (see the `pyyaml`
handling in `install.sh`'s config-writing step: validated when available,
silently skipped when not, never a hard failure).

## Sending a PR

- Keep it scoped — one backend, one runtime integration, one fix. Easier to
  review, easier to revert if something's wrong.
- Say what you tested it against and how (a real Supabase project? a real
  device? which OS?) — given there's no CI yet, that's the reviewer's only
  signal.
- If you're touching `agent_status.py`, run `python3 -c "import ast;
  ast.parse(open('skill/agent-status/scripts/agent_status.py').read())"` at
  minimum before opening the PR — cheap, catches syntax errors immediately.
- No dependency additions to the CLI script. Ever. (See above.)

## Questions

Open an issue. There's no separate chat/forum for this project yet.
