#!/bin/sh

# Run one model-reviewed supervision pass for the Adou OpenCode agent.
# launchd invokes this script hourly. Every invocation collects fresh Herdr
# evidence and submits it to a new, ephemeral Codex run; shell code never
# decides that a healthy-looking agent can skip model review.

set -u

umask 077

ADOU_ROOT=/Users/liulianfuren/Code/adou
SUPERVISOR_RULES="$ADOU_ROOT/.agents/adou-opencode-supervisor.md"
HERDR_BIN=/Users/liulianfuren/.local/bin/herdr
CODEX_BIN=/Users/liulianfuren/.local/bin/codex
TARGET_PANE=w7:p3
LOCK_FILE=/tmp/dev.adou.opencode-supervisor.lock
LAST_REPORT=/Users/liulianfuren/Library/Logs/adou-opencode-supervisor-last.md

# The LaunchAgent is not an interactive pane, so carry the exact socket of
# the Herdr session containing w7:p3 instead of relying on UI focus.
HERDR_ENV=1
HERDR_SOCKET_PATH=${HERDR_SOCKET_PATH:-/Users/liulianfuren/.config/herdr/herdr.sock}
export HERDR_ENV HERDR_SOCKET_PATH

if ! /usr/bin/shlock -p "$$" -f "$LOCK_FILE"; then
    printf '%s supervisor already running; skipping overlapping launch\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >&2
    exit 0
fi

cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT HUP INT TERM

if [ ! -x "$HERDR_BIN" ]; then
    echo "Herdr executable not found: $HERDR_BIN" >&2
fi
if [ ! -x "$CODEX_BIN" ]; then
    echo "Codex executable not found: $CODEX_BIN" >&2
    exit 127
fi
if [ ! -r "$SUPERVISOR_RULES" ]; then
    echo "Supervisor rules not readable: $SUPERVISOR_RULES" >&2
    exit 66
fi

capture_section() {
    section_name=$1
    shift

    printf '\n## %s\n\n```text\n' "$section_name"
    "$@" 2>&1
    command_status=$?
    printf '\n[exit_code=%s]\n```\n' "$command_status"
}

{
    cat "$SUPERVISOR_RULES"
    printf '\n--- BEGIN HOURLY HERDR SNAPSHOT ---\n'
    printf 'captured_at_utc: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'repository: %s\n' "$ADOU_ROOT"
    printf 'target_pane: %s\n' "$TARGET_PANE"
    printf 'herdr_socket: %s\n' "$HERDR_SOCKET_PATH"

    capture_section "herdr agent list" "$HERDR_BIN" agent list
    capture_section "herdr agent get $TARGET_PANE" "$HERDR_BIN" agent get "$TARGET_PANE"
    capture_section "herdr agent read $TARGET_PANE (visible, text)" \
        "$HERDR_BIN" agent read "$TARGET_PANE" --source visible --format text

    printf '\n--- END HOURLY HERDR SNAPSHOT ---\n'
} | "$CODEX_BIN" exec \
    --ephemeral \
    --cd "$ADOU_ROOT" \
    --sandbox workspace-write \
    --approve-for-me \
    --color never \
    --json \
    --output-last-message "$LAST_REPORT" \
    -

