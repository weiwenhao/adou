#!/bin/sh
#
# Read-only macOS signing readiness preflight for `make signing-preflight`.
# It only inspects the environment, the keychain identity list and the
# current artifact; it never modifies artifacts, never signs and never
# touches the network.
#
# Deterministic status line:
#   signing-preflight: status=<ok|missing-tools|no-identity|artifact-error> ...
#
# Deterministic exit codes (documented in docs/macos-signing.md):
#   0   ready: required tools present and both Developer ID Application and
#       Developer ID Installer identities exist in the keychain
#   20  a required Apple signing/packaging/notarization tool is missing
#   21  Developer ID Application or Installer identity is missing
#   22  artifact missing, not runnable, or version mismatch
#
# Environment:
#   ADOU_BIN   path to the built adou binary (default build/bin/adou)

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
adou_bin=${ADOU_BIN:-"$repo_root/build/bin/adou"}
version_src=$(sed -n "s/^pub const VERSION = '\([^']*\)'.*/\1/p" "$repo_root/src/app.n")

tool_missing=""
for tool in codesign security xcrun pkgbuild productsign pkgutil spctl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        tool_missing="$tool_missing $tool"
    fi
done
if [ -n "$tool_missing" ]; then
    echo "signing-preflight: status=missing-tools missing:$tool_missing" >&2
    exit 20
fi

notarytool=no
if xcrun --find notarytool >/dev/null 2>&1; then
    notarytool=yes
fi
stapler=no
if xcrun --find stapler >/dev/null 2>&1; then
    stapler=yes
fi

id_list=$(security find-identity -v -p codesigning 2>/dev/null || true)
basic_id_list=$(security find-identity -v -p basic 2>/dev/null || true)
id_total=$(printf '%s\n' "$id_list" | grep -c '^[[:space:]]*[0-9]*)' || true)
id_devid=$(printf '%s\n' "$id_list" | grep -c 'Developer ID Application' || true)
id_installer=$(printf '%s\n' "$basic_id_list" | grep -c 'Developer ID Installer' || true)

if [ ! -f "$adou_bin" ] || [ ! -x "$adou_bin" ]; then
    echo "signing-preflight: status=artifact-error artifact=$adou_bin missing-or-not-executable" >&2
    exit 22
fi

version_out=$( "$adou_bin" --version 2>/dev/null | sed 's/^adou[[:space:]]*//' || true )
if [ -z "$version_out" ] || [ "$version_out" != "$version_src" ]; then
    echo "signing-preflight: status=artifact-error artifact=$adou_bin version=$version_out expected=$version_src" >&2
    exit 22
fi

sig=$(codesign -d --verbose=4 "$adou_bin" 2>&1 || true)
signature=unknown
team=unknown
case "$sig" in
    *'Signature=adhoc'*)
        signature=adhoc
        case "$sig" in
            *'flags=0x20002(adhoc,linker-signed)'*) signature=adhoc-linker-signed ;;
        esac
        ;;
esac
case "$sig" in
    *'TeamIdentifier=not set'*) team=not-set ;;
    *'TeamIdentifier='*) team=set ;;
esac
authority=no
case "$sig" in
    *'Authority='*) authority=yes ;;
esac

if [ "$id_devid" -eq 0 ] || [ "$id_installer" -eq 0 ]; then
    echo "signing-preflight: status=no-identity identities=$id_total developer-id-application=$id_devid developer-id-installer=$id_installer notarytool=$notarytool stapler=$stapler artifact=$adou_bin version=$version_out signature=$signature team-identifier=$team authority=$authority" >&2
    exit 21
fi

echo "signing-preflight: status=ok identities=$id_total developer-id-application=$id_devid developer-id-installer=$id_installer notarytool=$notarytool stapler=$stapler artifact=$adou_bin version=$version_out signature=$signature team-identifier=$team authority=$authority"
exit 0
