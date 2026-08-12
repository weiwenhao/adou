#!/bin/sh
set -eu

# Minimal opt-in live smoke against DeepSeek.  Skipped by default (make e2e
# stays offline/mocked): set ADOU_LIVE_SMOKE=1 to run exactly one request
# with thinking off, low max tokens and retries disabled.  The API key is
# supplied via environment and never printed.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

# shellcheck source=../lib/deepseek-test-config.sh
. "$(dirname -- "$0")/../lib/deepseek-test-config.sh"

if [ "${ADOU_LIVE_SMOKE:-0}" != "1" ]; then
    echo "e2e: live smoke skipped (set ADOU_LIVE_SMOKE=1 to enable)"
    exit 0
fi

if [ "${DEEPSEEK_TEST_API_KEY_IS_EXPLICIT:-0}" != "1" ]; then
    echo "e2e: live smoke requires DEEPSEEK_TEST_API_KEY or DEEPSEEK_API_KEY" >&2
    exit 1
fi
deepseek_log_key_state

out=$(DEEPSEEK_API_KEY="${DEEPSEEK_TEST_API_KEY}" "$binary" \
    --no-context-files \
    $(deepseek_smoke_argv) \
    --provider deepseek --model "${DEEPSEEK_TEST_MODEL}" \
    "${DEEPSEEK_SMOKE_PROMPT}" 2>"${TMPDIR:-/tmp}/adou-live-smoke.err")

if ! printf '%s' "$out" | rg -qi 'ok'; then
    echo "e2e: live smoke response unexpected: $out" >&2
    cat "${TMPDIR:-/tmp}/adou-live-smoke.err" >&2
    exit 1
fi
echo "e2e: live smoke passed with ${DEEPSEEK_TEST_MODEL_REF}"
