#!/usr/bin/env bash
# Installs the agent-status reporter on a remote agent box over ssh.
#
#   ./install-remote.sh user@vps-mumbai
#   ./install-remote.sh user@vps-mumbai --kind codex --label "Codex (scraper)"
#   ./install-remote.sh user@vps-mumbai --hooks   # also wire Hermes lifecycle hooks
#
# The remote side needs only python3 and ssh - no pip, no cloud CLI.
#
# NOTE on hooks: Hermes only fires shell hooks for CLI (`hermes chat`), the
# gateway (Telegram/Slack/WhatsApp), and Desktop/TUI sessions. It does NOT
# fire them for `hermes acp` (the protocol Buzz and some IDE integrations use
# to launch Hermes) - confirmed by comparing a live gateway process's logs
# (which show "shell hook registered") against a live ACP session's (which
# log 60+ other plugin registrations individually but never shell hooks, no
# matter how the config is set). If your remote Hermes is driven via ACP,
# --hooks will install cleanly but never actually fire; the skill (which this
# script always installs) is the only reporting path that will work there.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$REPO/skill/agent-status"
CONFIG="$HOME/.agent-status/config.env"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    \033[33m%s\033[0m\n' "$1"; }
fail() { printf '\n\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

[[ $# -ge 1 ]] || fail "usage: $0 user@host [--kind hermes] [--id <agent-id>] [--label <label>] [--hooks]"

TARGET="$1"; shift
AGENT_ID=""
AGENT_LABEL=""
AGENT_KIND="hermes"
WITH_HOOKS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)    AGENT_ID="$2"; shift 2 ;;
        --label) AGENT_LABEL="$2"; shift 2 ;;
        --kind)  AGENT_KIND="$2"; shift 2 ;;
        --hooks) WITH_HOOKS=1; shift ;;
        *) fail "unknown option: $1" ;;
    esac
done

[[ -f "$CONFIG" ]] || fail "no config at $CONFIG - run ./install.sh here first"

read_cfg() { grep -E "^$1=" "$CONFIG" | tail -1 | cut -d= -f2- | tr -d "\"' "; }
BACKEND="$(read_cfg AGENT_STATUS_BACKEND)"

# A remote box writing to its own SQLite file is invisible to this Mac, so the
# local backend cannot span machines.
[[ "$BACKEND" != "local" ]] || fail \
"this Mac is configured for the 'local' backend, which cannot reach other machines.
  Switch to supabase first:  ./install.sh --backend supabase"

HOST_SHORT="${TARGET#*@}"
[[ -n "$AGENT_ID" ]]    || AGENT_ID="$AGENT_KIND@$HOST_SHORT"
[[ -n "$AGENT_LABEL" ]] || AGENT_LABEL="$(tr '[:lower:]' '[:upper:]' <<< "${AGENT_KIND:0:1}")${AGENT_KIND:1} ($HOST_SHORT)"

say "Checking $TARGET"
ssh "$TARGET" 'command -v python3 >/dev/null || { echo "python3 missing on remote" >&2; exit 1; }' \
    || fail "cannot reach $TARGET, or python3 is missing there"
info "python3 present"

say "Copying reporter"
ssh "$TARGET" 'mkdir -p ~/.local/bin ~/.agent-status/scripts && chmod 700 ~/.agent-status'
scp -q "$SKILL_SRC/scripts/agent_status.py" "$TARGET:.agent-status/scripts/agent_status.py"
scp -q "$SKILL_SRC/SKILL.md" "$TARGET:.agent-status/SKILL.md"

ssh "$TARGET" "cat > ~/.local/bin/agent-status <<'W'
#!/usr/bin/env bash
exec python3 \"\$HOME/.agent-status/scripts/agent_status.py\" \"\\\$@\"
W
chmod +x ~/.local/bin/agent-status"
info "installed agent-status"

say "Linking the skill into whatever agents are installed there"
# Link rather than assume a runtime - the remote may run any of them, or none.
# A Hermes profile (hermes profile create <name>) is a fully separate tree
# under ~/.hermes/profiles/<name>/ with its own skills/ - loop over all of
# them too, not just the default profile.
ssh "$TARGET" 'found=0
for dir in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.hermes/skills" "$HOME/.cursor/skills"; do
    [ -d "$(dirname "$dir")" ] || continue
    mkdir -p "$dir"
    ln -sfn "$HOME/.agent-status" "$dir/agent-status"
    echo "    linked $dir/agent-status"
    found=1
done
if [ -d "$HOME/.hermes/profiles" ]; then
    for profile_dir in "$HOME/.hermes/profiles"/*/; do
        [ -d "$profile_dir" ] || continue
        dir="${profile_dir%/}/skills"
        mkdir -p "$dir"
        ln -sfn "$HOME/.agent-status" "$dir/agent-status"
        echo "    linked $dir/agent-status"
        found=1
    done
fi
[ "$found" = "1" ] || echo "    no agent directories found - CLI still works standalone"'

say "Writing remote config"
# Piped over the existing ssh session rather than passed as arguments, so keys
# never land in the remote process list or shell history.
{
    echo "# agent-monitor - written by install-remote.sh"
    echo "AGENT_STATUS_BACKEND=$BACKEND"
    case "$BACKEND" in
        supabase)
            echo "AGENT_STATUS_SUPABASE_URL=$(read_cfg AGENT_STATUS_SUPABASE_URL)"
            echo "AGENT_STATUS_SUPABASE_KEY=$(read_cfg AGENT_STATUS_SUPABASE_KEY)"
            echo "AGENT_STATUS_SUPABASE_TABLE=$(read_cfg AGENT_STATUS_SUPABASE_TABLE)"
            ;;
    esac
    echo "AGENT_STATUS_AGENT_ID=$AGENT_ID"
    echo "AGENT_STATUS_AGENT_KIND=$AGENT_KIND"
    echo "AGENT_STATUS_AGENT_LABEL=$AGENT_LABEL"
} | ssh "$TARGET" "cat > ~/.agent-status/config.env && chmod 600 ~/.agent-status/config.env"

say "Verifying from $TARGET"
ssh "$TARGET" 'PATH="$HOME/.local/bin:$PATH" agent-status setup'

if [[ "$WITH_HOOKS" == "1" ]]; then
    say "Wiring Hermes hooks on $TARGET"
    # Same logic as install.sh's local Hermes-hooks step, run remotely over
    # ssh: loop over the default profile plus every named profile, register
    # pre_llm_call/post_llm_call pointing at the just-installed remote CLI.
    ssh "$TARGET" "python3 -" <<'PYHERMES'
import os, re, shutil, sys
from pathlib import Path

script = str(Path.home() / ".agent-status" / "scripts" / "agent_status.py")
home = Path.home() / ".hermes"

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
    print("    no Hermes config.yaml found on this host - skipping")
    raise SystemExit(0)

def install_into(name: str, config: Path) -> None:
    text = config.read_text()

    if "agent_status.py" in text:
        print(f"    [{name}] hooks already present")
        return

    if re.search(r"^hooks:", text, flags=re.MULTILINE):
        print(f"    [{name}] a 'hooks:' block already exists - add these entries by hand:")
        print(f"        pre_llm_call  -> python3 '{script}' hook prompt --kind hermes --agent-label \"{name}\"")
        print(f"        post_llm_call -> python3 '{script}' hook stop --kind hermes --agent-label \"{name}\"")
        return

    backup = config.with_suffix(".yaml.bak")
    shutil.copy(config, backup)

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
        import yaml
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

print(f"    {len(configs)} profile(s) processed")
print("    NOTE: these only fire for CLI/gateway/Desktop sessions - NOT for")
print("    `hermes acp` (Buzz, some IDE integrations). Run on the remote host:")
print("      hermes -p <profile> --accept-hooks   (once per profile)")
print("      hermes -p <profile> gateway restart   (if that profile's gateway is running)")
PYHERMES
fi

say "Done"
info "$AGENT_LABEL now reports to your board."
info "If the remote shell cannot find it: export PATH=\"\$HOME/.local/bin:\$PATH\""
