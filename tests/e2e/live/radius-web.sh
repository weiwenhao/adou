#!/bin/sh
set -eu

if [ "${ADOU_LIVE_RADIUS:-0}" != 1 ]; then
    echo 'e2e: live Radius web contract skipped (set ADOU_LIVE_RADIUS=1)'
    exit 0
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo 'e2e: live Radius web contract requires curl and jq' >&2
    exit 2
fi

gateway=${ADOU_RADIUS_URL:-https://radius.pi.dev}
oauth=$(curl -fsS --max-time 20 "${gateway%/}/v1/oauth")
printf '%s' "$oauth" | jq -e '.authorizationEndpoint | type == "string" and startswith("https://")' >/dev/null
status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "${gateway%/}/")
[ "$status" = 200 ]
echo 'e2e: live Radius OAuth discovery and web endpoint passed'
