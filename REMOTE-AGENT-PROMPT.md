Paste the block below into a chat with any agent that has shell access on
the remote machine (a Hermes profile, Claude Code, Codex, whatever's
running there). It downloads and installs
[agent-status-monitor](https://github.com/gigcompany/agent-status-monitor),
wires up lifecycle hooks for every Hermes profile on that machine, and
verifies the whole thing actually fired - all in one turn, without the human
typing a dozen commands by hand.

Fill in your Supabase URL and anon key before pasting - see
[Backends](README.md#backends) if you don't have them yet
(Project Settings → API in your Supabase dashboard).

---

Set up cross-machine status reporting on this box. Here's the full context,
follow it in order and report back what actually happened at each step -
don't just say "done," show the real command output.

**1. Install it.**

```bash
curl -fsSL https://raw.githubusercontent.com/gigcompany/agent-status-monitor/main/install.sh -o /tmp/agent-status-install.sh
AGENT_STATUS_SUPABASE_URL="<PASTE_YOUR_SUPABASE_URL>" AGENT_STATUS_SUPABASE_KEY="<PASTE_YOUR_SUPABASE_ANON_KEY>" bash /tmp/agent-status-install.sh --backend supabase --hooks --no-app
```

`--no-app` skips the menu bar app (macOS-only, this is a server). `--hooks`
wires `pre_llm_call`/`post_llm_call` into every Hermes profile's
`config.yaml` it finds under `~/.hermes/profiles/*/`, not just `default` -
confirm in the output that it actually found and processed more than one if
this box runs more than one profile.

**2. Approve the hooks it just wrote.** Hermes requires explicit per-profile
consent before a hook can fire - the install step above only writes the
config, it doesn't approve it. List every profile on this machine
(`hermes profile list`), then for each one:

```bash
hermes -p <profile> --accept-hooks
```

**3. Restart any profile whose gateway is already running.** A gateway
process that was already up keeps its old consent state in memory - approval
alone won't reach it. Check `hermes gateway list` (or `hermes profile list`,
which also shows gateway status) and for anything shown as running:

```bash
hermes -p <profile> gateway restart
```

**4. Verify, per profile, don't just assume it worked:**

```bash
hermes -p <profile> hooks doctor
```

Every profile should come back "All shell hooks look healthy." If any show
"not allowlisted" or "script modified since approval," that profile's step 2
or 3 didn't actually take effect - go back and redo it for that one
specifically, don't move on.

**5. Confirm the pipeline end to end:**

```bash
agent-status list --hours 1
```

**If anything looks unexpected** - install.sh reports it found an existing
`hooks:` block it won't touch, a profile's `hooks doctor` won't go clean
after a retry, or the Supabase connectivity check in step 1 fails - stop and
report the exact output rather than working around it or re-running blindly.

When you're done, summarize: how many Hermes profiles were found, how many
got hooks approved successfully, which (if any) needed a gateway restart,
and the final `hooks doctor` status for each one.
