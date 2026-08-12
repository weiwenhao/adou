#!/bin/sh
# Build an unsigned flat macOS installer package whose payload matches
# `make install`. Signing and notarization are deliberately separate.

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=${ADOU_VERSION:-}
adou_bin=${ADOU_BIN:-"$repo_root/build/bin/adou"}
helper_bin=${PROCESS_GROUP_HELPER:-"$repo_root/build/bin/adou-process-group"}
artifact=${ADOU_PKG:-}
identifier=${ADOU_PKG_IDENTIFIER:-dev.adou.cli}

if [ -z "$version" ] || [ -z "$artifact" ]; then
    echo "make-pkg: ADOU_VERSION and ADOU_PKG are required" >&2
    exit 64
fi
if [ ! -x "$adou_bin" ] || [ ! -x "$helper_bin" ]; then
    echo "make-pkg: required binaries are missing or not executable" >&2
    exit 66
fi
if ! command -v pkgbuild >/dev/null 2>&1; then
    echo "make-pkg: pkgbuild is required" >&2
    exit 69
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adou-make-pkg-XXXXXX")
cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

root="$tmp/root"
mkdir -p "$root/usr/local/bin" "$root/usr/local/share/adou/docs"
install -m 0755 "$adou_bin" "$root/usr/local/bin/adou"
install -m 0755 "$helper_bin" "$root/usr/local/bin/adou-process-group"
install -m 0644 "$repo_root/docs/mvp-implementation-spec.md" \
    "$root/usr/local/share/adou/docs/mvp-implementation-spec.md"

mkdir -p "$(dirname -- "$artifact")"
package="$tmp/$(basename -- "$artifact")"
pkgbuild \
    --root "$root" \
    --identifier "$identifier" \
    --version "$version" \
    --install-location / \
    "$package"
mv -f "$package" "$artifact"

echo "make-pkg: status=ok artifact=$artifact identifier=$identifier version=$version"
