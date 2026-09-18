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
  (reading `config.env`-equivalent, the Supabase/Cosmos fetch logic) could
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
  in place. Cosmos would need its own path (a Function triggered off the
  Change Feed).
- Token revocation/cleanup when a device stops being reachable (invalid
  token errors from FCM should prune the registration, not retry forever).

This is meaningfully bigger than it sounds from the outside — it's the one
item here that's actual backend infrastructure, not just a new client.
Worth scoping down first: even "push notifications for Supabase only, no
Cosmos support" would be a real, useful contribution on its own.

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

## 4. Real-time status updates

Everything currently polls (every 2–5 seconds depending on backend). Cosmos
DB has no server push at all — its "change feed" is pull-based internally,
so there's genuinely no way to get real push out of it without adding
external infrastructure (Azure Web PubSub or similar sitting in front of
it). Supabase is a different story: **Realtime is already enabled** on the
table (see the bottom of `backends/supabase/schema.sql`), so this is mostly
a client-side change for that backend — swap polling for a
`postgres_changes` subscription in each app.

Worth being precise in a PR about which backend it covers. "Realtime for
Supabase, still polling for local/Cosmos" is an honest, shippable increment;
claiming full realtime when only one backend has it would be misleading to
users picking a backend based on this list.

## 5. Support for other backends (Google Firestore, etc.)

Same shape as adding Cosmos was: implement `upsert`/`get`/`list` in the CLI,
`fetchTasks` in the Swift app, and the equivalent in the mobile app's
`api.ts`, following the `StatusBackend` pattern already in place. See
`CONTRIBUTING.md`'s "Adding a backend" section.

Firestore specifically is worth calling out because it has a real
`onSnapshot` listener API — genuine push, not polling — which nothing else
here has today. If someone builds Firestore support, it's a natural
candidate to *also* pick up item #4 for that backend specifically, since
the hard part (a backend that can push) would already be done.

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
- **No per-agent key revocation.** Every agent on a given backend shares one
  key (Supabase anon key or Cosmos master key). Revoking one means rotating
  the shared key and reinstalling everywhere. Supabase Auth (per-agent JWTs)
  or Cosmos resource tokens would fix this properly.
- **The menu bar app isn't notarized**, so notifications go through an
  `osascript` fallback attributed to Script Editor instead of the app
  itself. Needs a paid Apple Developer account and a signed release build.
