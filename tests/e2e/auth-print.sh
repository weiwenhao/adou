#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

# Provider-prefixed model prints the configured key.
out=$(DEEPSEEK_API_KEY=sk-print-test "$binary" auth print-api-key --model deepseek/deepseek-v4-flash)
[ "$out" = "sk-print-test" ] || { echo "e2e: unexpected output: $out" >&2; exit 1; }

# Explicit provider works for bare model ids.
out=$(DEEPSEEK_API_KEY=sk-print-test "$binary" auth print-api-key --model deepseek-v4-flash --provider deepseek)
[ "$out" = "sk-print-test" ] || { echo "e2e: unexpected output: $out" >&2; exit 1; }

# Missing provider is an explicit error.
if "$binary" auth print-api-key --model deepseek-v4-flash >/dev/null 2>&1; then
    echo "e2e: missing provider must fail" >&2
    exit 1
fi

# Unconfigured provider fails with a clear message.
if DEEPSEEK_API_KEY= "$binary" auth print-api-key --model deepseek/deepseek-v4-flash 2>/dev/null; then
    echo "e2e: unconfigured provider must fail" >&2
    exit 1
fi

# --api-key is rejected like Pi.
if DEEPSEEK_API_KEY=sk-print-test "$binary" auth print-api-key --model deepseek-v4-flash --api-key x >/dev/null 2>&1; then
    echo "e2e: --api-key must be rejected" >&2
    exit 1
fi

echo "e2e: auth print-api-key resolves configured credentials like Pi"
