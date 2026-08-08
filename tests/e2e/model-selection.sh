#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

expected='anthropic/claude-sonnet-4-5-20250929'
actual=$($binary --list-models 'anthropic/claude-sonnet-4-5-20250929')
if [ "$actual" != "$expected" ]; then
    echo "e2e: exact model lookup mismatch" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
fi

# A bare SONNET partial now matches many providers in the full catalog.
case "$($binary --list-models SONNET)" in
    *'anthropic/claude-sonnet-4-5'*) ;;
    *)
        echo "e2e: partial model lookup did not include the canonical model" >&2
        exit 1
        ;;
esac

# openai/gpt-5.1-codex is also an OpenRouter routing id, so a bare-pattern
# listing is multi-line; assert it contains the canonical entry.
case "$($binary --list-models 'openai/gpt-5.1-codex')" in
    *'openai/gpt-5.1-codex'*) ;;
    *)
        echo "e2e: exact model lookup did not include openai/gpt-5.1-codex" >&2
        exit 1
        ;;
esac

# With the full catalog a `*/gpt-*` glob lists every provider's GPT models.
case "$($binary --list-models '*/gpt-*')" in
    *'openai/gpt-5.1-codex'*) ;;
    *)
        echo "e2e: glob model lookup did not include openai/gpt-5.1-codex" >&2
        exit 1
        ;;
esac

echo 'e2e: model selection OK'

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-model-e2e.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
state=$(printf '%s\n' '{"id":"1","type":"get_state"}' | \
    PI_CODING_AGENT_DIR="$tmp_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$tmp_dir/sessions" \
    "$binary" --model anthropic/claude-sonnet-4-5 --mode rpc --no-session)
case "$state" in
    *'"provider":"anthropic","id":"claude-sonnet-4-5"'*) ;;
    *)
        echo 'e2e: partial --model selector did not resolve to the canonical model' >&2
        echo "state: $state" >&2
        exit 1
        ;;
esac

echo 'e2e: canonical model resolution OK'

scope_dir=$(mktemp -d "${TMPDIR:-/tmp}/adou-model-scope.XXXXXX")
trap 'rm -rf "$tmp_dir" "$scope_dir"' EXIT HUP INT TERM
scope_output=$(printf '%s\n' \
    '{"id":"initial","type":"get_state"}' \
    '{"id":"cycle","type":"cycle_model"}' \
    '{"id":"after","type":"get_state"}' | \
    DEEPSEEK_API_KEY=scope-deepseek-key \
    OPENAI_API_KEY=scope-openai-key \
    ANTHROPIC_API_KEY=scope-anthropic-key \
    PI_CODING_AGENT_DIR="$scope_dir/agent" \
    PI_CODING_AGENT_SESSION_DIR="$scope_dir/sessions" \
    "$binary" --models 'anthropic/claude-sonnet-4-5:low,openai/gpt-5.1-codex:medium,deepseek/deepseek-v4-flash:max' --mode rpc --no-session)
python3 - "$scope_output" <<'PY'
import json
import sys

items = [json.loads(line) for line in sys.argv[1].splitlines() if line.strip()]
by_id = {item.get("id"): item for item in items if item.get("id")}
initial = by_id.get("initial", {}).get("data", {}).get("model", {})
if (initial.get("provider"), initial.get("id")) != ("anthropic", "claude-sonnet-4-5"):
    raise SystemExit(f"--models order was not preserved at startup: {initial!r}")
if by_id.get("initial", {}).get("data", {}).get("thinkingLevel") != "low":
    raise SystemExit(f"initial scoped thinking level was not applied: {by_id.get('initial')!r}")
cycle = by_id.get("cycle", {}).get("data", {})
model = cycle.get("model", {})
if (model.get("provider"), model.get("id")) != ("openai", "gpt-5.1-codex"):
    raise SystemExit(f"cycle_model did not follow scoped order: {cycle!r}")
if cycle.get("thinkingLevel") != "medium" or cycle.get("isScoped") is not True:
    raise SystemExit(f"per-entry scoped thinking/isScoped mismatch: {cycle!r}")
after = by_id.get("after", {}).get("data", {})
if (after.get("model", {}).get("provider"), after.get("model", {}).get("id")) != ("openai", "gpt-5.1-codex"):
    raise SystemExit(f"cycle_model did not update state: {after!r}")
if after.get("thinkingLevel") != "medium":
    raise SystemExit(f"cycled thinking level was not persisted: {after!r}")
PY
echo 'e2e: scoped model order and per-entry thinking OK'
