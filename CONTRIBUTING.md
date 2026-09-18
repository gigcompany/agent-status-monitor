# Contributing

Thanks for looking. This project is young and the easiest way to help right
now is picking something off [`TODO.md`](TODO.md) or fixing something you
hit while actually using it.

## Project layout

```
skill/agent-status/scripts/agent_status.py   the CLI - single file, stdlib only, no pip install
skill/agent-status/SKILL.md                  what it teaches an agent to do and when
backends/supabase/schema.sql                 Postgres schema for the default backend
install.sh                                   the installer - local machine or remote, same script
.env.example                                 every config key, with defaults and comments
menubar/                                     macOS menu bar app (Swift / SwiftUI)
mobile/                                      Android app (Expo / React Native / TypeScript)
REMOTE-AGENT-PROMPT.md                       paste-able prompt for an agent-driven remote install
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

## How backend adapters work

There is no shared runtime between the three surfaces that read and write
status — the CLI is Python, the menu bar app is Swift, the mobile app is
TypeScript. Each implements the *same* small interface independently, in
its own language, against a **canonical shape** they all agree on:

```
id, agentId, agentLabel, agentKind, host, task, status, detail, question,
step, total, repo, cwd, startedAt, updatedAt, endedAt, waitingSince
```

Two things make this work without the three implementations drifting apart:

1. **One canonical shape, translated at the edges.** SQL backends store
   `snake_case` columns (`agent_id`, `updated_at`, ...) because that is
   idiomatic SQL and what you'd want to query by hand in a SQL console. Each
   adapter translates canonical ↔ column-name at its own boundary
   (`FIELDS`/`TO_CANONICAL` in `agent_status.py`; `COLUMN_TO_FIELD` in the
   mobile app's `api.ts`). Nothing above the adapter layer ever sees a
   backend-specific field name.
2. **`local` is the reference for "what does a read actually need to
   handle."** Every backend has to tolerate a slightly different set of
   quirks (a NULL vs an empty string, a missing column on an old row, a
   type coercion) - decode leniently and skip the one bad row rather than
   fail the whole poll. See `toTask` in `mobile/src/api.ts` or `to_task` in
   `LocalBackend` for the pattern: known keys mapped explicitly, unknown
   status values fall back to `"working"` rather than crashing the list.

### The interface

Three methods, same shape in every language:

| Method | Does |
|---|---|
| `upsert(doc)` | Write one task, insert-or-update by `id` |
| `get(id, agentId)` | Read one task by id (used to retitle/patch the session's active task) |
| `list(since)` | All tasks updated after a timestamp (the CLI's `list` command and every poller use this) |

The CLI's version (`skill/agent-status/scripts/agent_status.py`) is the one
to implement first and treat as the source of truth - it is also the one
every install actually depends on for reporting to work at all. The Swift
(`menubar/Sources/AgentMonitor/Backend.swift`, conforming to
`StatusBackend`) and TypeScript (`mobile/src/api.ts`) versions are
read-only viewers, so they only need `list`.

### Adding a backend adapter

1. **Implement `upsert`/`get`/`list` in `agent_status.py`** as a class
   extending `Backend`, added to the `BACKENDS` dict at the bottom of the
   backend section. This is the one that unblocks reporting; everything
   else can follow later.
2. **A dependency the stdlib doesn't have must degrade gracefully, not
   become a hard requirement of the single-file CLI.** See the `pyyaml`
   handling in `install.sh`'s config-writing step: validated when
   available, silently skipped when not, never a hard failure. If your
   backend's auth scheme genuinely needs a package stdlib doesn't have
   (a JWT library for a service-account flow, say), gate the import inside
   the class so the rest of the CLI still works without it installed.
3. **Add `fetchTasks` to the Swift app**, conforming to `StatusBackend` in
   `Backend.swift`, and wire it into `AppConfig.makeBackend()`.
4. **If it should be reachable from a phone**, add the equivalent to
   `mobile/src/api.ts` and wire it into `mobile/src/config.ts`.
5. **Test against a real account**, not just a mock - see [Testing](#testing)
   above. A wire-format bug (wrong header, wrong date format, a filter your
   mock didn't exercise) is exactly the kind of thing that only shows up
   against the genuine service.
6. **Document it**: add a row to the README's backend table and a setup
   section, matching the existing `local`/`supabase` sections.

### Worked example: Azure Cosmos DB

This project shipped Cosmos support for a while, built and verified against
a real account, then removed it to keep the default install small (see the
README's Backends section for why). The implementation is preserved here as
a real, tested starting point - not a sketch - for whoever picks this back
up.

Cosmos's NoSQL REST API signs every request with the account's master key,
HMAC-SHA256 over a fixed string:

```python
def _auth(self, verb, resource_type, link, date):
    # Cosmos signs verb\nresourceType\nresourceLink\nx-ms-date\ndate\n
    # The resource link is case-sensitive; everything else is lowercased.
    payload = f"{verb.lower()}\n{resource_type.lower()}\n{link}\n{date.lower()}\n\n"
    signature = base64.b64encode(
        hmac.new(base64.b64decode(self.key), payload.encode("utf-8"), hashlib.sha256).digest()
    ).decode("utf-8")
    return urllib.parse.quote(f"type=master&ver=1.0&sig={signature}", safe="")
```

Three things that only surfaced by testing against a real account, not from
reading the docs:

- **The Cosmos gateway refuses a cross-partition `ORDER BY` over the REST
  API** (works fine from the SDKs, not from raw REST). `list()` therefore
  has to omit `ORDER BY` from the query entirely and sort the result
  client-side after the fact.
- **TTL is a native per-document field** (`ttl`, an integer number of
  seconds), not a queryable column like Supabase's `expires_at` - the
  adapter has to convert the canonical `expiresAt` timestamp into a
  relative `ttl` on every write.
- **The partition key has to travel with every request**, including reads
  and upserts, not just at container-creation time - Cosmos needs it in an
  `x-ms-documentdb-partitionkey` header to route the request at all.

Full adapter (this is real code that ran against a serverless Cosmos
account, not pseudocode):

```python
class CosmosBackend(Backend):
    """Azure Cosmos DB NoSQL API, signed with the account master key."""

    name = "cosmos"
    API_VERSION = "2018-12-31"

    def __init__(self, cfg: dict):
        require(cfg, "cosmos_endpoint", "cosmos_key")
        self.endpoint = cfg["cosmos_endpoint"].rstrip("/")
        self.key = cfg["cosmos_key"]
        self.database = cfg.get("cosmos_database") or "agentmonitor"
        self.container = cfg.get("cosmos_container") or "tasks"

    @property
    def _link(self) -> str:
        return f"dbs/{self.database}/colls/{self.container}"

    def _auth(self, verb: str, resource_type: str, link: str, date: str) -> str:
        payload = f"{verb.lower()}\n{resource_type.lower()}\n{link}\n{date.lower()}\n\n"
        signature = base64.b64encode(
            hmac.new(base64.b64decode(self.key), payload.encode("utf-8"), hashlib.sha256).digest()
        ).decode("utf-8")
        return urllib.parse.quote(f"type=master&ver=1.0&sig={signature}", safe="")

    def _headers(self, verb: str, resource_type: str, link: str, extra: dict | None = None) -> dict:
        date = formatdate(timeval=None, localtime=False, usegmt=True)
        headers = {
            "Authorization": self._auth(verb, resource_type, link, date),
            "x-ms-date": date,
            "x-ms-version": self.API_VERSION,
            "Content-Type": "application/json",
        }
        headers.update(extra or {})
        return headers

    @staticmethod
    def _to_cosmos(doc: dict) -> dict:
        """Cosmos keeps the canonical shape, but expiry is its native `ttl`."""
        out = {key: value for key, value in doc.items() if key != "expiresAt"}
        expires = doc.get("expiresAt")
        if expires:
            remaining = datetime.fromisoformat(expires.replace("Z", "+00:00")) - datetime.now(timezone.utc)
            out["ttl"] = max(int(remaining.total_seconds()), 60)
        return out

    def upsert(self, doc: dict) -> None:
        status, body = http(
            f"{self.endpoint}/{self._link}/docs",
            method="POST",
            headers=self._headers("POST", "docs", self._link, {
                "x-ms-documentdb-is-upsert": "true",
                "x-ms-documentdb-partitionkey": json.dumps([doc["agentId"]]),
            }),
            body=self._to_cosmos(doc),
        )
        if status >= 300:
            die(f"cosmos upsert failed - HTTP {status}: {body}")

    def get(self, task_id: str, agent_id: str) -> dict | None:
        link = f"{self._link}/docs/{task_id}"
        status, body = http(
            f"{self.endpoint}/{link}",
            headers=self._headers("GET", "docs", link, {
                "x-ms-documentdb-partitionkey": json.dumps([agent_id]),
            }),
        )
        if status == 404:
            return None
        if status >= 300:
            die(f"cosmos read failed - HTTP {status}: {body}")
        return json.loads(body)

    def list(self, since: str) -> list:
        # No ORDER BY: the Cosmos gateway will not serve a cross-partition sort
        # over the REST API. Callers sort the result themselves.
        status, body = http(
            f"{self.endpoint}/{self._link}/docs",
            method="POST",
            headers=self._headers("POST", "docs", self._link, {
                "Content-Type": "application/query+json",
                "x-ms-documentdb-isquery": "true",
                "x-ms-documentdb-query-enablecrosspartition": "true",
                "x-ms-max-item-count": "200",
            }),
            body={
                "query": "SELECT * FROM c WHERE c.updatedAt > @since",
                "parameters": [{"name": "@since", "value": since}],
            },
        )
        if status >= 300:
            die(f"cosmos query failed - HTTP {status}: {body}")
        docs = json.loads(body or "{}").get("Documents", [])
        docs.sort(key=lambda d: d.get("updatedAt") or "", reverse=True)
        return docs

    def check(self) -> str:
        self.list(now_iso())
        return f"cosmos {self.endpoint} ({self.database}/{self.container})"
```

To bring this back: drop it into `agent_status.py`, add `"cosmos":
CosmosBackend` to `BACKENDS`, restore the `cosmos_*` fields to `DEFAULTS`
and the `--cosmos-*` flags to the `setup` subcommand's argparse list, port
it to Swift and (optionally) TypeScript following the pattern above, and -
importantly - actually provision a Cosmos account and run the full
lifecycle (`start` → `update` → `wait` → `done`) against it before calling
it done. `az cosmosdb create ... --capabilities EnableServerless` gets you
a throwaway account for about $0.20-0.50/month to test against.

### Sketch: Google Firestore

Not built, so treat this as a starting point to verify against the real
API, not a spec to implement blindly - exactly the trap this project's own
`CLAUDE.md`-equivalent warns about for Expo, and the same lesson applies
here.

What's true with reasonable confidence:

- Firestore's REST API takes documents at
  `https://firestore.googleapis.com/v1/projects/{project}/databases/(default)/documents/{collection}`,
  authenticated either with an API key (simplest, matches this project's
  existing anon-key-on-every-host trade-off) or a service account JWT
  (more setup, scoped credentials - a better fit if per-agent revocation
  ever gets built, see `TODO.md`).
- Firestore's wire format wraps every field in a type tag rather than
  storing plain JSON values - a task's `step` would be sent/received as
  `{"integerValue": "3"}`, not `3`. The adapter's canonical-to-wire mapping
  has real work to do here, more than either existing backend.
- **This is the one worth building**: Firestore has a genuine server-push
  listener (`onSnapshot`), which neither `local` nor `supabase` currently
  wire up on the client side (Supabase's Realtime is enabled on the schema
  already but unused by the apps - see `TODO.md` item 4). A Firestore
  adapter is a natural place to *also* pick up real-time updates for that
  backend specifically, since the hard part - a backend that can push -
  would already be done.

Verify the exact request/response shapes against Firestore's own REST API
docs before writing the adapter; do not assume the sketch above is
complete.

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
