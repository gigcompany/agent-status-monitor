#!/usr/bin/env bash
# agent-monitor installer.
#
#   ./install.sh                      interactive: asks which backend
#   ./install.sh --backend local      no cloud account, no keys
#   curl -fsSL <raw-url>/install.sh | bash
#
# Reads .env if present, otherwise asks (or defaults to local when there is no
# terminal to ask with).
set -euo pipefail

REPO_URL="${AGENT_MONITOR_REPO:-https://github.com/gigcompany/agent-status-monitor.git}"
STATE_DIR="$HOME/.agent-status"
CONFIG="$STATE_DIR/config.env"
BIN_DIR="$HOME/.local/bin"

BACKEND=""
WITH_HOOKS=0
WITH_LOGIN=0
SKIP_APP=0

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    \033[33m%s\033[0m\n' "$1"; }
fail() { printf '\n\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)         BACKEND="$2"; shift 2 ;;
        --backend=*)       BACKEND="${1#*=}"; shift ;;
        --hooks)           WITH_HOOKS=1; shift ;;
        --login)           WITH_LOGIN=1; shift ;;
        --no-app)          SKIP_APP=1; shift ;;
        -h|--help)
            sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            cat <<'USAGE'

options:
  --backend local|supabase   skip the prompt
  --hooks                    auto-report via lifecycle hooks (Claude Code + every Hermes profile)
  --login                    start the menu bar app at login
  --no-app                   CLI + skill only (for servers)
USAGE
            exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

# ------------------------------------------------------------------ locate repo
# When piped from curl there is no repo on disk, so fetch one.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    REPO=""
fi

if [[ -z "$REPO" || ! -d "$REPO/skill/agent-status" ]]; then
    REPO="$HOME/.agent-monitor"
    say "Fetching agent-monitor"
    command -v git >/dev/null 2>&1 || fail "git is required to bootstrap from curl"
    if [[ -d "$REPO/.git" ]]; then
        git -C "$REPO" pull --ff-only --quiet || warn "could not update $REPO, using what is there"
    else
        git clone --depth 1 --quiet "$REPO_URL" "$REPO" \
            || fail "clone failed. Set AGENT_MONITOR_REPO to your fork's URL."
    fi
    info "using $REPO"
fi

SKILL_SRC="$REPO/skill/agent-status"
[[ -f "$SKILL_SRC/scripts/agent_status.py" ]] || fail "repo looks incomplete: $SKILL_SRC"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

RUN_CLI() { python3 "$SKILL_SRC/scripts/agent_status.py" "$@"; }

# ------------------------------------------------------------------ config
say "Configuration"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

if [[ -f "$CONFIG" && -z "$BACKEND" ]]; then
    BACKEND="$(grep -E '^AGENT_STATUS_BACKEND=' "$CONFIG" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ' || true)"
    info "existing config at $CONFIG (backend: ${BACKEND:-unset})"
elif [[ -f "$REPO/.env" ]]; then
    info "using $REPO/.env"
    cp "$REPO/.env" "$CONFIG"
    [[ -n "$BACKEND" ]] || BACKEND="$(grep -E '^AGENT_STATUS_BACKEND=' "$CONFIG" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ' || true)"
fi

if [[ -z "$BACKEND" ]]; then
    if [[ -t 0 ]]; then
        echo
        echo "  Where should agent status be stored?"
        echo "    1) local     SQLite on this Mac. No account, no keys.        (default)"
        echo "    2) supabase  Free Postgres. Works across machines - required"
        echo "                 if you want the Android app to see anything."
        echo
        read -r -p "  Choose [1-2, default 1]: " choice
        case "${choice:-1}" in
            1) BACKEND="local" ;;
            2) BACKEND="supabase" ;;
            *) fail "invalid choice: $choice" ;;
        esac
    else
        # Piped install with nothing to ask: local needs no keys, so it is
        # always the safe unattended default.
        BACKEND="local"
    fi
fi
info "backend: $BACKEND"

set_cfg() {
    local key="$1" value="$2"
    touch "$CONFIG"
    if grep -qE "^${key}=" "$CONFIG"; then
        python3 - "$CONFIG" "$key" "$value" <<'PY'
import sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
out = [f"{key}={value}" if line.startswith(f"{key}=") else line for line in lines]
open(path, "w").write("\n".join(out) + "\n")
PY
    else
        printf '%s=%s\n' "$key" "$value" >> "$CONFIG"
    fi
}

[[ -f "$CONFIG" ]] || printf '# agent-monitor configuration\n' > "$CONFIG"
set_cfg AGENT_STATUS_BACKEND "$BACKEND"

case "$BACKEND" in
    local)
        set_cfg AGENT_STATUS_LOCAL_PATH "$STATE_DIR/status.db"
        # A local file read is free, so poll fast.
        grep -qE '^AGENT_STATUS_POLL_SECONDS=' "$CONFIG" || set_cfg AGENT_STATUS_POLL_SECONDS 2
        ;;
    supabase)
        if ! grep -qE '^AGENT_STATUS_SUPABASE_URL=.+' "$CONFIG"; then
            if [[ -n "${AGENT_STATUS_SUPABASE_URL:-}" && -n "${AGENT_STATUS_SUPABASE_KEY:-}" ]]; then
                # Real env vars, e.g. for a one-shot `curl | bash` on a
                # headless box where there's no TTY to prompt on.
                set_cfg AGENT_STATUS_SUPABASE_URL "$AGENT_STATUS_SUPABASE_URL"
                set_cfg AGENT_STATUS_SUPABASE_KEY "$AGENT_STATUS_SUPABASE_KEY"
            elif [[ -t 0 ]]; then
                echo
                info "Create a project at supabase.com, run backends/supabase/schema.sql"
                info "in its SQL Editor, then paste the values from Settings -> API."
                echo
                read -r -p "  Project URL (https://xxx.supabase.co): " sb_url
                read -r -p "  anon key: " sb_key
                [[ -n "$sb_url" && -n "$sb_key" ]] || fail "both values are required"
                set_cfg AGENT_STATUS_SUPABASE_URL "$sb_url"
                set_cfg AGENT_STATUS_SUPABASE_KEY "$sb_key"
            else
                fail "supabase needs AGENT_STATUS_SUPABASE_URL and _KEY - set them as env vars for a piped install, or in $CONFIG"
            fi
        fi
        grep -qE '^AGENT_STATUS_SUPABASE_TABLE=' "$CONFIG" || set_cfg AGENT_STATUS_SUPABASE_TABLE agent_tasks
        ;;
    *) fail "unknown backend: $BACKEND" ;;
esac

chmod 600 "$CONFIG"
info "config at $CONFIG"

# ------------------------------------------------------------------ skill
say "Installing skill"
FOUND_AGENT=0

# Every runtime here reads the same SKILL.md format, so one symlinked source
# serves all of them and a single edit updates every agent.
SKILL_TARGETS=(
    "$HOME/.claude/skills"
    "$HOME/.codex/skills"
    "$HOME/.hermes/skills"
    "$HOME/.cursor/skills"
    "$HOME/.config/agent-skills"
)
# A Hermes profile (hermes profile create <name>) is a fully separate tree
# under ~/.hermes/profiles/<name>/ with its own skills/ and config.yaml - the
# default profile's install does not reach it.
if [[ -d "$HOME/.hermes/profiles" ]]; then
    for profile_dir in "$HOME/.hermes/profiles"/*/; do
        [[ -d "$profile_dir" ]] || continue
        SKILL_TARGETS+=("${profile_dir%/}/skills")
    done
fi

for dir in "${SKILL_TARGETS[@]}"; do
    parent="$(dirname "$dir")"
    [[ -d "$parent" ]] || continue
    mkdir -p "$dir"
    case "$dir" in
        *.hermes*)
            # Hermes builds a cached skill manifest and its symlink handling is
            # not documented, so hand it a real directory. Restart Hermes (or
            # that profile's gateway) to pick it up.
            rm -rf "$dir/agent-status"
            cp -R "$SKILL_SRC" "$dir/agent-status"
            info "copied  $dir/agent-status"
            ;;
        *)
            ln -sfn "$SKILL_SRC" "$dir/agent-status"
            info "linked  $dir/agent-status"
            ;;
    esac
    FOUND_AGENT=1
done
[[ "$FOUND_AGENT" == "1" ]] || warn "no agent directories found - the CLI still works standalone"

# ------------------------------------------------------------------ cli
say "Installing agent-status CLI"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/agent-status" <<WRAPPER
#!/usr/bin/env bash
exec python3 "$SKILL_SRC/scripts/agent_status.py" "\$@"
WRAPPER
chmod +x "$BIN_DIR/agent-status"
info "installed $BIN_DIR/agent-status"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ------------------------------------------------------------------ verify
say "Verifying backend"
RUN_CLI setup || fail "backend check failed - fix $CONFIG and re-run"

# ------------------------------------------------------------------ hooks
if [[ "$WITH_HOOKS" == "1" ]]; then
    say "Adding Claude Code hooks"
    if [[ ! -d "$HOME/.claude" ]]; then
        warn "no ~/.claude directory - skipping"
    else
        python3 - "$SKILL_SRC" <<'PYHOOK'
import json, shutil, sys
from pathlib import Path

cmd = f'python3 "{sys.argv[1]}/scripts/agent_status.py"'
settings = Path.home() / ".claude" / "settings.json"
settings.parent.mkdir(parents=True, exist_ok=True)

data = {}
if settings.exists():
    shutil.copy(settings, settings.with_suffix(".json.bak"))
    try:
        data = json.loads(settings.read_text() or "{}")
    except json.JSONDecodeError:
        print("    existing settings.json is not valid JSON - skipping")
        raise SystemExit(0)
    print(f"    backed up to {settings.with_suffix('.json.bak')}")

hooks = data.setdefault("hooks", {})
for event, command in {
    # Creates the task from the user's own prompt, so a session shows up even
    # if the model never calls the CLI itself.
    "UserPromptSubmit": f"{cmd} hook prompt",
    "Notification":     f"{cmd} hook notification",   # needs input -> waiting
    "Stop":             f"{cmd} hook stop",           # turn ended  -> done
}.items():
    entries = hooks.setdefault(event, [])
    if any(h.get("command") == command for e in entries for h in e.get("hooks", [])):
        print(f"    {event} hook already present")
        continue
    entries.append({"hooks": [{"type": "command", "command": command}]})
    print(f"    added {event} hook")

settings.write_text(json.dumps(data, indent=2) + "\n")
PYHOOK
    fi
fi

# ------------------------------------------------------------------ hermes hooks
if [[ "$WITH_HOOKS" == "1" && -d "$HOME/.hermes" ]]; then
    say "Adding Hermes hooks"
    python3 - "$SKILL_SRC" <<'PYHERMES'
import re, shutil, sys
from pathlib import Path

script = f'{sys.argv[1]}/scripts/agent_status.py'
home = Path.home() / ".hermes"

# The default profile's config.yaml, plus every `hermes profile create`
# profile - each is a fully separate tree with its own config.yaml, and
# installing into "default" alone leaves the others silently unreported.
configs = []
if (home / "config.yaml").exists():
    configs.append(("default", home / "config.yaml"))
profiles_dir = home / "profiles"
if profiles_dir.is_dir():
    for profile_dir in sorted(profiles_dir.iterdir()):
        cfg = profile_dir / "config.yaml"
        if cfg.exists():
            configs.append((profile_dir.name, cfg))

if not configs:
    print("    no Hermes config.yaml found - skipping")
    raise SystemExit(0)

def install_into(name: str, config: Path) -> None:
    text = config.read_text()

    if "agent_status.py" in text:
        print(f"    [{name}] hooks already present")
        return

    # A second top-level `hooks:` key would shadow the first, so refuse rather
    # than corrupt a working config.
    if re.search(r"^hooks:", text, flags=re.MULTILINE):
        print(f"    [{name}] a 'hooks:' block already exists - add these entries by hand:")
        print(f"        pre_llm_call  -> python3 '{script}' hook prompt --kind hermes")
        print(f"        post_llm_call -> python3 '{script}' hook stop --kind hermes")
        return

    backup = config.with_suffix(".yaml.bak")
    shutil.copy(config, backup)

    # pre_llm_call fires before the turn's tool loop (carries extra.user_message);
    # post_llm_call fires once the turn's final output is ready.
    block = f"""
# --- agent-monitor -----------------------------------------------------------
# Reports this agent's activity to the shared status board. Both hooks print
# nothing to stdout and always exit 0, so they cannot block or alter a turn.
hooks:
  pre_llm_call:
    - command: 'python3 "{script}" hook prompt --kind hermes --agent-label "{name}"'
      timeout: 20
  post_llm_call:
    - command: 'python3 "{script}" hook stop --kind hermes --agent-label "{name}"'
      timeout: 20
"""

    merged = text.rstrip("\n") + "\n" + block
    try:
        import yaml  # optional; only present in some environments
        yaml.safe_load(merged)
    except ImportError:
        pass
    except Exception as exc:
        print(f"    [{name}] generated YAML is invalid, leaving config untouched: {exc}")
        return

    config.write_text(merged)
    print(f"    [{name}] added pre_llm_call + post_llm_call hooks (backed up to {backup.name})")

for name, cfg in configs:
    install_into(name, cfg)

print(f"    {len(configs)} profile(s) processed - Hermes asks for consent on each hook's first run per profile")
print("    run: hermes --accept-hooks   (once per profile you actually use), then restart Hermes")
PYHERMES
fi

# ------------------------------------------------------------------ app
if [[ "$SKIP_APP" == "0" && "$(uname -s)" == "Darwin" ]]; then
    if command -v swift >/dev/null 2>&1; then
        say "Building the menu bar app"
        "$REPO/menubar/build-app.sh" >/dev/null || fail "app build failed"
        rm -rf "/Applications/AgentMonitor.app"
        cp -R "$REPO/menubar/build/AgentMonitor.app" /Applications/
        info "installed /Applications/AgentMonitor.app"

        if [[ "$WITH_LOGIN" == "1" ]]; then
            PLIST="$HOME/Library/LaunchAgents/com.gofloaters.agentmonitor.plist"
            mkdir -p "$(dirname "$PLIST")"
            cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.gofloaters.agentmonitor</string>
    <key>ProgramArguments</key>
    <array><string>/Applications/AgentMonitor.app/Contents/MacOS/AgentMonitor</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
PL
            launchctl unload "$PLIST" 2>/dev/null || true
            launchctl load "$PLIST"
            info "will start at login"
        fi

        pkill -f "AgentMonitor" 2>/dev/null || true
        sleep 1
        open -a /Applications/AgentMonitor.app
        info "launched - look for the icon in your menu bar"
    else
        warn "swift not found - skipping the app (install Xcode command line tools)"
    fi
elif [[ "$SKIP_APP" == "0" ]]; then
    info "not macOS - skipping the menu bar app"
fi

say "Done"
cat <<'NEXT'
Try it:
  agent-status start "my first task"
  agent-status wait --question "does the notification arrive?"
  agent-status done --summary "it does"

Remote agents:
  ./install-remote.sh user@host --kind hermes
NEXT
