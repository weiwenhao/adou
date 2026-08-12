#!/bin/sh
#
# Developer ID signed distribution artifact for `make signed-dist`.
# FAILS CLOSED: without an explicit ADOU_CODESIGN_IDENTITY (non-empty and
# not '-') nothing is built, signed or touched.  A real identity that is
# not a Developer ID Application identity in the keychain is also rejected.
#
# With a real identity this would: copy the `make dist` staging into a
# temporary directory, sign the helper first and the main binary second
# (each with --options runtime --timestamp=none), verify authority/team/
# strict, and archive build/dist/adou-<version>-darwin-arm64-signed.tar.gz
# without touching build/bin or the default dist staging.  Batch 2B may
# need --timestamp (secure timestamp) instead of --timestamp=none before
# notarization; see docs/macos-signing.md.
#
# In this batch no Developer ID Application identity exists, so only the
# fail-closed paths are exercised (exit 64/65 before any side effect).
#
# Exit codes:
#   64 ADOU_CODESIGN_IDENTITY missing, empty or '-'
#   65 identity not found as a Developer ID Application identity
#   66 dist staging or required binaries missing
#   1  signing or verification failed

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
identity=${ADOU_CODESIGN_IDENTITY:-}
if [ -z "$identity" ] || [ "$identity" = "-" ]; then
    echo "signed-dist: ADOU_CODESIGN_IDENTITY is required and must not be '-' (refusing to sign with a placeholder identity)" >&2
    exit 64
fi

id_line=$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$identity" || true)
case "$id_line" in
    *'Developer ID Application'*) ;;
    *) echo "signed-dist: identity '$identity' is not a Developer ID Application identity in the keychain" >&2; exit 65 ;;
esac

adou_version=${ADOU_VERSION:-}
dist_dir=${DIST_DIR:-"$repo_root/build/dist"}
dist_name=${DIST_NAME:-}
if [ -z "$dist_name" ]; then
    dist_name=$(ls -d "$dist_dir"/adou-*-darwin-arm64 2>/dev/null | head -n 1 | xargs -n 1 basename 2>/dev/null || true)
fi
if [ -z "$adou_version" ] || [ -z "$dist_name" ] || [ ! -f "$dist_dir/$dist_name/adou" ] || [ ! -f "$dist_dir/$dist_name/adou-process-group" ]; then
    echo "signed-dist: dist staging missing (run make dist first)" >&2
    exit 66
fi

stage="$dist_dir/$dist_name"
signed_stage="$dist_dir/adou-$adou_version-darwin-arm64-signed"
rm -rf "$signed_stage"
mkdir -p "$signed_stage"
cp "$stage/adou" "$signed_stage/adou"
cp "$stage/adou-process-group" "$signed_stage/adou-process-group"

echo "signed-dist: sign-order=helper,main identity=$identity"
codesign --force --sign "$identity" --options runtime --timestamp=none "$signed_stage/adou-process-group"
codesign --force --sign "$identity" --options runtime --timestamp=none "$signed_stage/adou"

for bin_name in adou-process-group adou; do
    bin_path="$signed_stage/$bin_name"
    if ! codesign --verify --strict --deep "$bin_path" >/dev/null 2>&1; then
        echo "signed-dist: $bin_name failed --verify --strict --deep" >&2
        exit 1
    fi
    sig=$(codesign -d --verbose=4 "$bin_path" 2>&1 || true)
    case "$sig" in
        *'Authority=Developer ID Application'*) ;;
        *) echo "signed-dist: $bin_name has no Developer ID Application authority: $(echo "$sig" | grep '^Authority=' || echo none)" >&2; exit 1 ;;
    esac
    case "$sig" in
        *'TeamIdentifier='*'not set'*) echo "signed-dist: $bin_name has TeamIdentifier=not set (expected a Developer ID team)" >&2; exit 1 ;;
        *'TeamIdentifier='*) ;;
        *) echo "signed-dist: $bin_name has no TeamIdentifier" >&2; exit 1 ;;
    esac
    case "$sig" in
        *'flags='*'runtime'*) ;;
        *) echo "signed-dist: $bin_name lacks the hardened runtime flag" >&2; exit 1 ;;
    esac
done

cp "$stage/RELEASE-README" "$signed_stage/RELEASE-README"
(cd "$signed_stage" && shasum -a 256 adou adou-process-group RELEASE-README > SHA256SUMS)
tar -C "$dist_dir" -czf "$dist_dir/adou-$adou_version-darwin-arm64-signed.tar.gz" "adou-$adou_version-darwin-arm64-signed"

echo "signed-dist: status=ok artifact=$dist_dir/adou-$adou_version-darwin-arm64-signed.tar.gz"
