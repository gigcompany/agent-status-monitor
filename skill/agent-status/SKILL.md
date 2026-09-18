---
name: agent-status
description: Report what you are working on to the shared agent status board so the user can see it in their Mac menu bar. Use at the START of any multi-step or long-running task, whenever you need the user to answer a question or approve something, and when you finish or fail. Also use when asked "what are the agents doing", "what is my status", or "report status".
---

# Agent Status Board

You share a status board with the user's other AI agents, local and remote. The
user's Mac menu bar app watches that board in near real time. When you mark a
task `waiting`, they get a desktop notification — that is the fastest way to
unblock yourself.

Where the board actually lives (a local SQLite file, or Supabase for a board
that spans machines) is configured on the machine and is not your concern; the
commands are the same either way.

The command is `agent-status` (or `python3 <skill>/scripts/agent_status.py`).

## When to report

Report on these four moments. Do not report anything else.

| Moment | Command |
|---|---|
| Starting work that will take more than a minute or two | `agent-status start "<one line>"` |
| Crossing a meaningful milestone in a long task | `agent-status update --detail "<one line>" --step N --total M` |
| You need the user to decide, approve, or answer | `agent-status wait --question "<the actual question>"` |
| Work is complete | `agent-status done --summary "<what you delivered>"` |
| Work failed and you are stopping | `agent-status fail --error "<what broke>"` |

You do not need to pass a task id. The script remembers the active task for your
session, so `update` / `wait` / `done` attach to whatever you last started.

## Rules

- **One line, plain language, user's vocabulary.** The user reads these in a menu
  bar dropdown roughly 40 characters wide. Write `Fix double-charge on checkout`,
  not `Refactoring PaymentIntentHandler.process() to correct idempotency key reuse`.
- **`wait` is a promise.** Only use it when you have genuinely stopped and cannot
  proceed without the user. It fires a notification on their desktop. If you can
  reasonably pick a sensible default and keep going, do that instead.
- **Put the real question in `--question`.** The user should be able to answer from
  the notification alone. `Need your input` is useless; `Deploy to prod or staging
  first?` is answerable.
- **Always close the loop.** Every `start` gets a `done` or `fail`. A task left in
  `working` forever makes the board untrustworthy, and the user's app will flag it
  as stale after 30 minutes of silence.
- **Never block on it.** This is telemetry. If the command errors, mention it once
  and carry on with the actual task. Do not retry in a loop or let it derail work.
- **Skip the trivial.** Answering a question, reading one file, or a two-line edit
  needs no board entry. Chatter is worse than silence here.

## Reading the board

To see what every agent is doing — useful when the user asks "what's running?" or
before you start something another agent may already own:

```bash
agent-status list            # last 24h, all agents
agent-status list --hours 2
agent-status list --json     # for programmatic use
```

## Example of a full task

```bash
agent-status start "Add Stripe refund endpoint"
# ... implement ...
agent-status update --detail "Endpoint done, writing tests" --step 2 --total 3
# ... hit a real decision ...
agent-status wait --question "Refund partial amounts, or full-only for v1?"
# ... user answers "full-only" ...
agent-status update --detail "Full-only refunds, running tests"
agent-status done --summary "POST /refunds live, 8 tests passing"
```

## Setup (only if the command is missing)

If `agent-status` is not found or reports it is not configured, the user needs to
run the installer once on this machine:

```bash
<repo>/install.sh                     # this machine
<repo>/install-remote.sh user@host    # a remote agent box
```

Tell the user that rather than trying to configure the backend yourself.
