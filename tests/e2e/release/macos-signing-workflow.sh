#!/bin/sh
set -eu

# Batch 2A local macOS signing workflow e2e (make signing-check).
#
# Coverage:
#   - signing-preflight behavior with zero Developer ID Application
#     identities: deterministic exit code (21) and a deterministic status
#     line (no-identity); with identities present it must exit 0 (ok)
#   - signed-dist fails closed without ADOU_CODESIGN_IDENTITY (exit 64),
#     with '-' (exit 64), and with an identity that is not a Developer ID
#     Application identity (exit 65); nothing in build/bin or the dist
#     staging may change
#   - fake-tool dry runs: a PATH-preprended fake codesign records the
#     invocation order and options (helper signed before the main binary;
#     --force --sign - --options runtime --timestamp=none) and passes
#     through to the real codesign
#   - a real local ad-hoc smoke on a scratch copy of the dist staging:
#     both signatures are replaced with hardened-runtime signatures and
#     pass codesign --verify --strict --deep, while build/bin and the
#     default dist hashes remain unchanged
#   - a no-op main-binary signer is rejected even though the untouched
#     linker signature still passes strict verification
#   - the RELEASE-README signing declaration matches the actual
#     codesign -d --verbose=4 state (ad-hoc: TeamIdentifier not set,
#     no Authority); a real TeamIdentifier or Authority line fails the
#     check marked as "非 Developer ID"
#
# Never creates a notary profile, never prints keychain credential contents,
# and never signs with a real identity. Native package signing/notarization
# orchestration is covered by macos-pkg-signing.sh.
#
# Requires the `make dist` staging (fails with exit 2 when missing, so it
# is safe for the make e2e glob).

# This script lives one directory below the plain `make e2e` glob
# (tests/e2e/release/), so the repository root is three levels up.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
adou_bin=${ADOU_BIN:-"$repo_root/build/bin/adou"}
helper_bin=${ADOU_PROCESS_GROUP_HELPER:-"$repo_root/build/bin/adou-process-group"}

tarball=$(ls "$repo_root"/build/dist/adou-*-darwin-arm64.tar.gz 2>/dev/null | head -n 1 || true)
if [ -z "$tarball" ] || [ ! -f "$tarball" ]; then
    echo "e2e: macos-signing-workflow: release tarball not found (run make dist)" >&2
    exit 2
fi
dist_dir=$(echo "$tarball" | sed 's|/[^/]*$||')
stage_dir=$(echo "$tarball" | sed 's|/adou-\(.*\)-darwin-arm64.tar.gz$|/adou-\1-darwin-arm64|')
if [ ! -d "$stage_dir" ]; then
    echo "e2e: macos-signing-workflow: dist staging missing: $stage_dir" >&2
    exit 2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adou-signing-workflow-XXXXXX")
fail() {
    echo "e2e: macos-signing-workflow failed: $*" >&2
    exit 1
}
cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

before_adou=$(sha256_of "$adou_bin")
before_helper=$(sha256_of "$helper_bin")
before_stage_adou=$(sha256_of "$stage_dir/adou")
before_stage_helper=$(sha256_of "$stage_dir/adou-process-group")

assert_originals_unchanged() {
    if [ "$(sha256_of "$adou_bin")" != "$before_adou" ] || [ "$(sha256_of "$helper_bin")" != "$before_helper" ] \
       || [ "$(sha256_of "$stage_dir/adou")" != "$before_stage_adou" ] || [ "$(sha256_of "$stage_dir/adou-process-group")" != "$before_stage_helper" ]; then
        fail "build/bin or dist staging artifacts changed during the workflow"
    fi
}

# --- 1. signing-preflight with zero Developer ID identities ----------------

devid_count=$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application' || true)
installer_count=$(security find-identity -v -p basic 2>/dev/null | grep -c 'Developer ID Installer' || true)
set +e
pre_out=$(ADOU_BIN="$adou_bin" "$repo_root/scripts/signing-preflight.sh" 2>&1)
pre_code=$?
set -e
if [ "$devid_count" -eq 0 ] || [ "$installer_count" -eq 0 ]; then
    if [ "$pre_code" -ne 21 ]; then
        fail "preflight with 0 Developer ID identities must exit 21, got $pre_code: $pre_out"
    fi
    case "$pre_out" in
        *'status=no-identity'*) ;;
        *) fail "preflight must print a deterministic no-identity status line: $pre_out" ;;
    esac
else
    if [ "$pre_code" -ne 0 ]; then
        fail "preflight with identities must exit 0, got $pre_code: $pre_out"
    fi
    case "$pre_out" in
        *'status=ok'*) ;;
        *) fail "preflight must print status=ok with identities: $pre_out" ;;
    esac
fi
echo "e2e: preflight behavior OK (application=$devid_count installer=$installer_count exit=$pre_code)"

# --- 2. fail-closed signed-dist --------------------------------------------

set +e
out=$(env -u ADOU_CODESIGN_IDENTITY DIST_DIR="$repo_root/build/dist" "$repo_root/scripts/signed-dist.sh" 2>&1)
code=$?
set -e
if [ "$code" -ne 64 ] || ! echo "$out" | grep -q "ADOU_CODESIGN_IDENTITY"; then
    fail "signed-dist without identity must fail closed (64 + message), got $code: $out"
fi

set +e
out=$(ADOU_CODESIGN_IDENTITY=- DIST_DIR="$repo_root/build/dist" "$repo_root/scripts/signed-dist.sh" 2>&1)
code=$?
set -e
if [ "$code" -ne 64 ] || ! echo "$out" | grep -q "must not be '-'"; then
    fail "signed-dist with identity '-' must fail closed (64), got $code: $out"
fi

set +e
out=$(ADOU_CODESIGN_IDENTITY=0000000000000000000000000000000000000000 DIST_DIR="$repo_root/build/dist" "$repo_root/scripts/signed-dist.sh" 2>&1)
code=$?
set -e
if [ "$code" -ne 65 ] || ! echo "$out" | grep -q "not a Developer ID Application identity"; then
    fail "signed-dist with a non-Developer-ID identity must fail (65), got $code: $out"
fi

assert_originals_unchanged
echo "e2e: fail-closed signed-dist OK"

# --- 3. fake-tool signing dry run (order and options) ----------------------

fake="$tmp/fake"
mkdir -p "$fake"
codesign_log="$tmp/fake/codesign.log"
: > "$codesign_log"

real_codesign=$(command -v codesign)

cat > "$fake/codesign" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$codesign_log"
exec "$real_codesign" "\$@"
EOF

chmod +x "$fake/codesign"

smoke_env="ADOU_BIN=$adou_bin PROCESS_GROUP_HELPER=$helper_bin DIST_DIR=$repo_root/build/dist DIST_NAME=$(basename "$stage_dir")"
set +e
out=$(PATH="$fake:$PATH" env $smoke_env "$repo_root/scripts/signing-smoke.sh" 2>&1)
code=$?
set -e
if [ "$code" -ne 0 ]; then
    fail "signing-smoke under fake codesign must exit 0, got $code: $out"
fi
if ! echo "$out" | grep -q "sign-order=helper,main"; then
    fail "signing-smoke must report sign-order=helper,main: $out"
fi
if ! echo "$out" | grep -q "originals-unchanged=yes"; then
    fail "signing-smoke must report originals-unchanged=yes: $out"
fi
if ! echo "$out" | grep -q "status=ok"; then
    fail "signing-smoke must report status=ok: $out"
fi

sign_lines=$(grep -- '--force --sign' "$codesign_log" || true)
sign_count=$(printf '%s\n' "$sign_lines" | grep -c . || true)
if [ "$sign_count" -ne 2 ]; then
    fail "fake codesign must record exactly two --sign invocations, got $sign_count: $codesign_log"
fi
first=$(printf '%s\n' "$sign_lines" | sed -n '1p')
second=$(printf '%s\n' "$sign_lines" | sed -n '2p')
case "$first" in
    *"/adou-process-group"*) ;;
    *) fail "the first --sign invocation must target the helper: $first" ;;
esac
case "$second" in
    *"/adou-process-group"*) fail "the second --sign invocation must target the main binary, not the helper: $second" ;;
    *"/adou"*) ;;
    *) fail "the second --sign invocation must target the main binary: $second" ;;
esac
for line in "$first" "$second"; do
    case "$line" in
        *"--force"*"--sign"*"-"*"--options"*"runtime"*"--timestamp=none"*) ;;
        *) fail "--sign invocation missing required options: $line" ;;
    esac
done
echo "e2e: fake codesign order/options OK"

# --- 4. unchanged valid signature must fail closed --------------------------

noop_fake="$tmp/noop-fake"
mkdir -p "$noop_fake"
cat > "$noop_fake/codesign" <<EOF
#!/bin/sh
case "\$*" in
    *"--sign"*"/adou-process-group"*) exec "$real_codesign" "\$@" ;;
    *"--sign"*) exit 0 ;;
    *) exec "$real_codesign" "\$@" ;;
esac
EOF
chmod +x "$noop_fake/codesign"

set +e
out=$(PATH="$noop_fake:$PATH" env $smoke_env "$repo_root/scripts/signing-smoke.sh" 2>&1)
code=$?
set -e
if [ "$code" -ne 1 ]; then
    fail "signing-smoke must reject a main signature that was not replaced, got $code: $out"
fi
case "$out" in
    *"adou: sign-exit=0 replaced=no verify=ok signature-not-replaced"*) ;;
    *) fail "unchanged main signature failure must be explicit: $out" ;;
esac
assert_originals_unchanged
echo "e2e: unchanged valid main signature fails closed"

# --- 5. real local ad-hoc smoke on a scratch copy ---------------------------

set +e
out=$(env $smoke_env "$repo_root/scripts/signing-smoke.sh" 2>&1)
code=$?
set -e
if [ "$code" -ne 0 ]; then
    fail "real signing-smoke must exit 0, got $code: $out"
fi
for line in "sign-order=helper,main" "originals-unchanged=yes" "status=ok"; do
    if ! echo "$out" | grep -q "$line"; then
        fail "real signing-smoke missing status line '$line': $out"
    fi
done
helper_line=$(echo "$out" | grep 'adou-process-group:' | head -n 1 || true)
main_line=$(echo "$out" | grep ': adou:' | head -n 1 || true)
case "$helper_line" in
    *"sign-exit=0"*"replaced=yes"*"verify=ok"*) ;;
    *) fail "helper copy must be re-signed with hardened runtime and verify: $out" ;;
esac
case "$main_line" in
    *"sign-exit=0"*"replaced=yes"*"verify=ok"*) ;;
    *) fail "adou copy must be re-signed with hardened runtime and verify: $out" ;;
esac
assert_originals_unchanged
echo "e2e: real ad-hoc signing-smoke OK (signatures replaced, copies verify, originals untouched)"

# --- 6. RELEASE-README declaration vs actual signing state ------------------

readme="$stage_dir/RELEASE-README"
for phrase in "ad-hoc/linker-generated signature" "not Developer ID signed" "not notarized"; do
    if ! grep -q "$phrase" "$readme"; then
        fail "RELEASE-README must declare '$phrase'"
    fi
done

for bin_name in adou adou-process-group; do
    bin_path="$stage_dir/$bin_name"
    sig=$(codesign -d --verbose=4 "$bin_path" 2>&1 || true)
    case "$sig" in
        *'Signature=adhoc'*) ;;
        *) fail "$bin_name is not ad-hoc signed: $sig" ;;
    esac
    case "$sig" in
        *'TeamIdentifier=not set'*) ;;
        *'TeamIdentifier='*) fail "$bin_name carries a Developer ID TeamIdentifier while the release declares ad-hoc only (非 Developer ID): $sig" ;;
        *) ;;
    esac
    auth=$(echo "$sig" | grep '^Authority=' || true)
    if [ -n "$auth" ]; then
        fail "$bin_name has signing Authority while the release declares ad-hoc only (非 Developer ID): $auth"
    fi
done
echo "e2e: RELEASE-README declaration matches actual ad-hoc signature state"

echo "e2e: macos-signing-workflow OK (preflight, signed-dist fail-closed, signing smoke, README consistency)"
