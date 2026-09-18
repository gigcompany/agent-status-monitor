#!/usr/bin/env bash
# Installs the agent-status reporter on a remote agent box over ssh.
#
#   ./install-remote.sh user@vps-mumbai
#   ./install-remote.sh user@vps-mumbai --kind codex --label "Codex (scraper)"
#
# The remote side needs only python3 and ssh - no pip, no cloud CLI.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$REPO/skill/agent-status"
CONFIG="$HOME/.agent-status/config.env"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
fail() { printf '\n\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

[[ $# -ge 1 ]] || fail "usage: $0 user@host [--kind hermes] [--id <agent-id>] [--label <label>]"

TARGET="$1"; shift
AGENT_ID=""
AGENT_LABEL=""
AGENT_KIND="hermes"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)    AGENT_ID="$2"; shift 2 ;;
        --label) AGENT_LABEL="$2"; shift 2 ;;
        --kind)  AGENT_KIND="$2"; shift 2 ;;
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
  Switch to supabase or cosmos first:  ./install.sh --backend supabase"

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
ssh "$TARGET" 'found=0
for dir in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.hermes/skills" "$HOME/.cursor/skills"; do
    [ -d "$(dirname "$dir")" ] || continue
    mkdir -p "$dir"
    ln -sfn "$HOME/.agent-status" "$dir/agent-status"
    echo "    linked $dir/agent-status"
    found=1
done
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
        cosmos)
            echo "AGENT_STATUS_COSMOS_ENDPOINT=$(read_cfg AGENT_STATUS_COSMOS_ENDPOINT)"
            echo "AGENT_STATUS_COSMOS_KEY=$(read_cfg AGENT_STATUS_COSMOS_KEY)"
            echo "AGENT_STATUS_COSMOS_DATABASE=$(read_cfg AGENT_STATUS_COSMOS_DATABASE)"
            echo "AGENT_STATUS_COSMOS_CONTAINER=$(read_cfg AGENT_STATUS_COSMOS_CONTAINER)"
            ;;
    esac
    echo "AGENT_STATUS_AGENT_ID=$AGENT_ID"
    echo "AGENT_STATUS_AGENT_KIND=$AGENT_KIND"
    echo "AGENT_STATUS_AGENT_LABEL=$AGENT_LABEL"
} | ssh "$TARGET" "cat > ~/.agent-status/config.env && chmod 600 ~/.agent-status/config.env"

say "Verifying from $TARGET"
ssh "$TARGET" 'PATH="$HOME/.local/bin:$PATH" agent-status setup'

say "Done"
info "$AGENT_LABEL now reports to your board."
info "If the remote shell cannot find it: export PATH=\"\$HOME/.local/bin:\$PATH\""
