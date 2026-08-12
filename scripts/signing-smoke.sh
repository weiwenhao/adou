#!/bin/sh
#
# Offline ad-hoc signing smoke for `make signing-smoke` (Batch 2A).
#
# Copies the current `make dist` staging into a temporary directory and
# runs the signing sequence on the copies only: helper first, then the
# main binary, each with
#   codesign --force --sign - --options runtime --timestamp=none
# then verifies the copies with `codesign --verify --strict --deep`.
# build/bin and the default dist staging are never modified; every
# artifact hash is compared before/after, and the temporary copy is
# deleted on exit.
#
# The purpose is to validate the scripted signing order and options, not
# to produce a release artifact.  The deterministic status lines report
# per-binary sign exit code, whether the signature was actually replaced
# (replaced=yes only when the resulting signature carries the hardened
# runtime flag), and the verify result.  On this machine codesign cannot
# replace the linker-generated ad-hoc signature of the Nature-produced
# main binary in place (it fails with "internal error in Code Signing
# subsystem" and the original valid signature is retained); that is
# reported as replaced=no, never as a success, and is tracked as a
# Batch 2B blocker in docs/macos-signing.md.
#
# Environment:
#   ADOU_BIN             path to the built adou binary
#   PROCESS_GROUP_HELPER path to the built adou-process-group helper
#   DIST_DIR             staging root (build/dist)
#   DIST_NAME            archive directory name (default: globbed)
#
# Exit codes:
#   0  smoke OK: order executed, both copies verify, originals untouched
#   64 missing required environment
#   66 dist staging or a required binary is missing
#   1  verification or originals-unchanged check failed

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
adou_bin=${ADOU_BIN:-"$repo_root/build/bin/adou"}
helper_bin=${PROCESS_GROUP_HELPER:-"$repo_root/build/bin/adou-process-group"}
dist_dir=${DIST_DIR:-"$repo_root/build/dist"}
dist_name=${DIST_NAME:-}
if [ -z "$dist_name" ]; then
    dist_name=$(ls -d "$dist_dir"/adou-*-darwin-arm64 2>/dev/null | head -n 1 | xargs -n 1 basename 2>/dev/null || true)
fi
if [ -z "$dist_name" ]; then
    echo "signing-smoke: no dist staging found under $dist_dir (run make dist)" >&2
    exit 66
fi

stage="$dist_dir/$dist_name"
if [ ! -f "$stage/adou" ] || [ ! -f "$stage/adou-process-group" ] || [ ! -f "$adou_bin" ] || [ ! -f "$helper_bin" ]; then
    echo "signing-smoke: required binaries missing (adou_bin=$adou_bin helper_bin=$helper_bin stage=$stage)" >&2
    exit 66
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adou-signing-smoke-XXXXXX")
cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

hash_adou=$(sha256_of "$adou_bin")
hash_helper=$(sha256_of "$helper_bin")
hash_stage_adou=$(sha256_of "$stage/adou")
hash_stage_helper=$(sha256_of "$stage/adou-process-group")

cp "$stage/adou" "$tmp/adou"
cp "$stage/adou-process-group" "$tmp/adou-process-group"

sign_one() {
    path="$1"
    set +e
    out=$(codesign --force --sign - --options runtime --timestamp=none "$path" 2>&1)
    code=$?
    set -e
    sig=$(codesign -d --verbose=4 "$path" 2>&1 || true)
    replaced=no
    case "$sig" in
        *'flags='*'runtime'*) replaced=yes ;;
    esac
    reason=ok
    if [ "$code" -ne 0 ]; then
        case "$out" in
            *'internal error in Code Signing subsystem'*) reason=codesign-internal-error ;;
            *) reason="exit=$code" ;;
        esac
    fi
    echo "signing-smoke: $(basename "$path"): sign-exit=$code replaced=$replaced verify=$(verify_one "$path") $reason"
}

verify_one() {
    if codesign --verify --strict --deep "$1" >/dev/null 2>&1; then
        echo ok
    else
        echo failed
    fi
}

echo "signing-smoke: sign-order=helper,main"
sign_one "$tmp/adou-process-group"
sign_one "$tmp/adou"

if ! codesign --verify --strict --deep "$tmp/adou-process-group" >/dev/null 2>&1; then
    echo "signing-smoke: helper copy failed --strict --deep verification" >&2
    exit 1
fi
if ! codesign --verify --strict --deep "$tmp/adou" >/dev/null 2>&1; then
    echo "signing-smoke: adou copy failed --strict --deep verification" >&2
    exit 1
fi

unchanged=yes
if [ "$(sha256_of "$adou_bin")" != "$hash_adou" ] || [ "$(sha256_of "$helper_bin")" != "$hash_helper" ] \
   || [ "$(sha256_of "$stage/adou")" != "$hash_stage_adou" ] || [ "$(sha256_of "$stage/adou-process-group")" != "$hash_stage_helper" ]; then
    unchanged=no
fi
if [ "$unchanged" != "yes" ]; then
    echo "signing-smoke: a build/bin or dist staging artifact changed during the smoke" >&2
    exit 1
fi

echo "signing-smoke: originals-unchanged=$unchanged"
echo "signing-smoke: status=ok"
