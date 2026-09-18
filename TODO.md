# Roadmap

Things known to be missing, roughly in the order they were identified. Not
prioritized against each other — pick whichever is useful to you. See
[`CONTRIBUTING.md`](CONTRIBUTING.md) before starting, especially the section
on adding hook support for a new runtime if you're tackling #3.

## 1. Windows app

Only macOS (native Swift menu bar app) and Android (Expo) exist today.
Windows needs a system tray app doing the same job: read the board, group by
status, notify on `waiting`/`done`/`failed`.

The macOS app's Swift/SwiftUI code isn't reusable here — this is a new
codebase. Worth deciding up front:

- **Native (WinUI 3 / WPF)** — best OS integration (real Windows Toast
  notifications, no notarization-style workaround needed), but a genuinely
  separate implementation to maintain, in a language nothing else in this
  repo uses.
- **Tauri or similar** — smaller binary, and the config/networking layer
  (reading `config.env`-equivalent, the backend fetch logic) could
  plausibly be shared with something else if this project ever needs a
  Linux tray app too. More new tooling to introduce for a first contribution
  to this repo, though.

Whichever direction, follow the same design already established:
read-only viewer, polls the backend, groups `waiting`/`working`/`failed`/`done`,
30-minute stale detection matching the other two apps. The desktop config
file lives at `~/.agent-status/config.env` on Mac/Linux; Windows will need
its own settings UI (there's no shared filesystem with the Mac) closer to
the mobile app's Settings screen than the menu bar app's file-based config.

## 2. Push notifications

Right now, "notify me" only works for apps that are open and polling. Real
push — notified even when the app is backgrounded or killed — needs actual
infrastructure, not just app code:

- A device token registration step (new column or table: which device wants
  pushes for which agent identity / board)
- **Android**: Firebase Cloud Messaging. Needs a Firebase project, the
  app registering for a token, and storing it server-side.
- **A trigger that fires on row changes** and calls FCM. Supabase supports
  this via a Database Webhook or an Edge Function reacting to
  `postgres_changes` — the table already has Realtime enabled
  (`backends/supabase/schema.sql`), which is the prerequisite piece already
  in place.
- Token revocation/cleanup when a device stops being reachable (invalid
  token errors from FCM should prune the registration, not retry forever).

This is meaningfully bigger than it sounds from the outside — it's the one
item here that's actual backend infrastructure, not just a new client. Since
`local` has no server to run a trigger on, this only makes sense for
`supabase` (or a future backend with the same shape) - not a limitation
worth working around, just worth being upfront about in a PR description.

## 3. Testing support on other agent harnesses (OpenCode, etc.)

Claude Code and Hermes are done. Every other harness (OpenCode, Aider,
Windsurf, whatever else) is currently either untested or, at best, gets a
`detect_kind()` label with no automatic reporting — the skill still teaches
the model to call the CLI by hand, which works but isn't automatic.

This is research-shaped, not implementation-shaped: nobody has checked what
hook or plugin mechanism these harnesses actually expose. The Hermes
integration is the template to follow (see `CONTRIBUTING.md`'s "Adding hook
support for another agent runtime" section) — the two traps that actually
bit during that work were trusting documentation over a captured real
payload, and not realizing the runtime's own diagnostic command genuinely
fires the hook (which is exactly the kind of thing you only find by testing
against the real thing).

If a harness turns out to have no hook mechanism at all, that's a valid
finding too — document it, and the skill-only fallback is still real
value.

**Concrete known gap, found this way: Hermes's `acp` launch mode.** Hermes
itself has multiple launch paths - CLI (`hermes chat`), the gateway
(Telegram/Slack/WhatsApp), Desktop/TUI, and `acp` (the Agent Communication
Protocol some hosts, like Buzz, use to launch Hermes as a subprocess).
Confirmed by comparing a live gateway process's logs (which log `shell hook
registered: pre_llm_call -> ...` explicitly at startup) against a live ACP
session's (which logs 60+ other plugin registrations individually, in the
same detail, but never once logs shell hooks, across multiple agent
workers): **`hermes acp` never registers Hermes's shell hooks at all,
regardless of how correctly `config.yaml` is set up.** The skill-only
fallback still works there (confirmed: skill tool calls fire normally in
an ACP session) - hooks just don't. This is inside Hermes's own code, not
this project's, so it's not directly fixable here; worth reporting
upstream. Anyone integrating with an ACP-based host should expect
skill-only reporting until Hermes's ACP adapter wires up shell hooks.

## 4. Real-time status updates

Everything currently polls (2s for `local`, 5s for `supabase`). `local` has
no way to push at all - it's a file, there's no server to notify anyone.
`supabase`'s underlying table already has **Realtime enabled**
(see the bottom of `backends/supabase/schema.sql`), so getting real push out
of it is mostly a client-side change - swap polling for a
`postgres_changes` subscription in each app. That makes this the
lowest-effort item on this whole list for the backend that matters most
(it's also the only one the Android app can use at all).

## 5. Support for other backends (Google Firestore, Azure Cosmos, etc.)

Implement `upsert`/`get`/`list` in the CLI, `fetchTasks` in the Swift app,
and the equivalent in the mobile app's `api.ts`, following the
`StatusBackend` pattern already in place. See `CONTRIBUTING.md`'s
["Adding a backend adapter"](CONTRIBUTING.md#adding-a-backend-adapter) for
the full walkthrough, including a complete, previously-tested Cosmos
implementation preserved there as a worked example - re-adding Cosmos is
largely "restore that code and re-verify it," not a from-scratch build (it
was removed to keep the default install small, not because it didn't work
- see the README's Backends section).

Firestore specifically is worth calling out because it has a real
`onSnapshot` listener API — genuine push, not polling — which nothing here
has today. If someone builds Firestore support, it's a natural candidate to
*also* pick up item #4 for that backend specifically, since the hard part
(a backend that can push) would already be done.

---

## Other known gaps (smaller, not requested above, still real)

- **No automated test suite.** Everything so far has been verified by hand
  against real backends and real devices. See `CONTRIBUTING.md`'s Testing
  section for the patterns used; turning those into an actual CI suite
  would be valuable on its own.
- **Codex has no hook integration.** Its one global `notify` slot in
  `config.toml` is often already claimed by something else, so the
  installer won't touch it. Reporting from Codex today is skill-only (the
  model has to remember to call the CLI).
- **No per-agent key revocation.** Every agent on `supabase` shares one anon
  key. Revoking one means rotating the shared key and reinstalling
  everywhere. Supabase Auth (per-agent JWTs) would fix this properly.
- **The menu bar app isn't notarized**, so notifications go through an
  `osascript` fallback attributed to Script Editor instead of the app
  itself. Needs a paid Apple Developer account and a signed release build.
