# Central DeepSeek test configuration for Adou e2e suites.
#
# This file is sourced by e2e scripts (and ad-hoc runs); it is never
# executed directly, and make e2e does not pick it up as a test because
# it lives under tests/e2e/lib/ while the Makefile globs tests/e2e/*.sh
# only.
#
# Project test model/key conventions (docs/porting-plan.md, "测试模型、
# 密钥与成本约束"): deterministic regressions stay offline or on local
# mocks; live DeepSeek requests are opt-in, one at a time, with thinking
# off, low max tokens and retries disabled.

DEEPSEEK_TEST_MODEL="deepseek-v4-flash"
DEEPSEEK_TEST_MODEL_REF="deepseek/deepseek-v4-flash"
DEEPSEEK_TEST_API_KEY="REDACTED-PUBLIC-HISTORY"

# Explicit live-smoke switch: ADOU_LIVE_SMOKE=1 enables exactly one live
# request; anything else keeps the suite offline/mocked.
DEEPSEEK_LIVE_SMOKE=${ADOU_LIVE_SMOKE:-0}

# DeepSeek smoke parameters: single request, no thinking, tiny output.
DEEPSEEK_SMOKE_THINKING="off"
DEEPSEEK_SMOKE_MAX_TOKENS="64"
DEEPSEEK_SMOKE_MAX_RETRIES="0"
DEEPSEEK_SMOKE_TIMEOUT_MS="60000"
DEEPSEEK_SMOKE_PROMPT="Reply with exactly: ok"

deepseek_live_smoke_enabled() {
    [ "${DEEPSEEK_LIVE_SMOKE}" = "1" ]
}

# Logging helpers never print the key itself.
deepseek_log_key_state() {
    if [ -n "${DEEPSEEK_TEST_API_KEY:-}" ]; then
        echo "deepseek-test-config: test key is configured"
    else
        echo "deepseek-test-config: test key is NOT configured"
    fi
}

deepseek_smoke_argv() {
    # Arguments for one live print-mode request honouring the cost
    # constraints in docs/porting-plan.md.  Callers append --prompt-free
    # positional text or use the default smoke prompt.
    echo "--print --thinking ${DEEPSEEK_SMOKE_THINKING} --max-tokens ${DEEPSEEK_SMOKE_MAX_TOKENS} --max-retries ${DEEPSEEK_SMOKE_MAX_RETRIES} --timeout-ms ${DEEPSEEK_SMOKE_TIMEOUT_MS}"
}
