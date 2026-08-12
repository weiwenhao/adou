#!/bin/sh
set -eu

# Offline macOS flat-package verification. This never invokes installer and
# never changes the receipt database or /usr/local.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
version=${ADOU_VERSION:-}
package=${ADOU_PKG:-}
adou_bin=${ADOU_BIN:-"$repo_root/build/bin/adou"}
helper_bin=${ADOU_PROCESS_GROUP_HELPER:-"$repo_root/build/bin/adou-process-group"}

fail() {
    echo "e2e: macos-pkg failed: $*" >&2
    exit 1
}

if [ -z "$version" ] || [ -z "$package" ] || [ ! -f "$package" ]; then
    echo "e2e: macos-pkg: package/version missing (run make pkg)" >&2
    exit 2
fi

for tool in pkgutil cpio gzip; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool missing: $tool"
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adou-pkg-e2e-XXXXXX")
cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

expanded="$tmp/expanded"
pkgutil --expand "$package" "$expanded"
package_info="$expanded/PackageInfo"
[ -f "$package_info" ] || fail "expanded package has no PackageInfo"
grep -q 'identifier="dev.adou.cli"' "$package_info" || fail "wrong package identifier"
grep -q "version=\"$version\"" "$package_info" || fail "wrong package version"
grep -q 'install-location="/"' "$package_info" || fail "wrong install location"

raw_payload_list="$tmp/raw-payload-files"
payload_list="$tmp/payload-files"
pkgutil --payload-files "$package" | sed 's|^\./||' | sort -u > "$raw_payload_list"
# pkgbuild represents extended attributes as AppleDouble sidecars in the raw
# cpio stream. Installer consumes these as metadata rather than installing
# literal `._*` files. Every sidecar must correspond to a real payload path;
# exclude them when checking the logical installed-file whitelist.
grep -E '(^|/)\._' "$raw_payload_list" > "$tmp/appledouble-files" || true
while IFS= read -r sidecar; do
    [ -n "$sidecar" ] || continue
    target=$(printf '%s\n' "$sidecar" | sed 's|^\._||; s|/\._|/|g')
    grep -qx "$target" "$raw_payload_list" || fail "orphan AppleDouble metadata: $sidecar"
done < "$tmp/appledouble-files"
grep -vE '(^|/)\._' "$raw_payload_list" > "$payload_list"
for required in \
    usr/local/bin/adou \
    usr/local/bin/adou-process-group \
    usr/local/share/adou/docs/mvp-implementation-spec.md; do
    grep -qx "$required" "$payload_list" || fail "payload missing $required"
done
unexpected=$(grep -vE '^\.?$|^usr/?$|^usr/local/?$|^usr/local/bin/?$|^usr/local/share/?$|^usr/local/share/adou/?$|^usr/local/share/adou/docs/?$|^usr/local/bin/adou$|^usr/local/bin/adou-process-group$|^usr/local/share/adou/docs/mvp-implementation-spec.md$' "$payload_list" || true)
[ -z "$unexpected" ] || fail "unexpected payload paths: $unexpected"

payload_root="$tmp/payload-root"
mkdir -p "$payload_root"
(cd "$payload_root" && gzip -dc "$expanded/Payload" | cpio -idm --quiet)
[ -x "$payload_root/usr/local/bin/adou" ] || fail "packaged adou is not executable"
[ -x "$payload_root/usr/local/bin/adou-process-group" ] || fail "packaged helper is not executable"
[ -r "$payload_root/usr/local/share/adou/docs/mvp-implementation-spec.md" ] || fail "packaged docs are unreadable"
[ "$(stat -f '%Lp' "$payload_root/usr/local/bin/adou")" = 755 ] || fail "packaged adou mode is not 0755"
[ "$(stat -f '%Lp' "$payload_root/usr/local/bin/adou-process-group")" = 755 ] || fail "packaged helper mode is not 0755"
[ "$(stat -f '%Lp' "$payload_root/usr/local/share/adou/docs/mvp-implementation-spec.md")" = 644 ] || fail "packaged docs mode is not 0644"

expected_version="adou  $version"
actual_version=$(ADOU_PROCESS_GROUP_HELPER="$payload_root/usr/local/bin/adou-process-group" \
    "$payload_root/usr/local/bin/adou" --version)
[ "$actual_version" = "$expected_version" ] || fail "packaged CLI version mismatch: $actual_version"

if pkgutil --check-signature "$package" >/dev/null 2>&1; then
    fail "unsigned package unexpectedly carries a trusted installer signature"
fi

# A higher-version package keeps the same stable identifier and install root,
# which is the receipt/upgrade boundary used by Installer. Do not perform an
# actual install in E2E.
upgrade_package="$tmp/adou-upgrade.pkg"
ADOU_VERSION=0.1.1 ADOU_BIN="$adou_bin" PROCESS_GROUP_HELPER="$helper_bin" \
    ADOU_PKG="$upgrade_package" "$repo_root/scripts/make-pkg.sh" >/dev/null
pkgutil --expand "$upgrade_package" "$tmp/upgrade-expanded"
grep -q 'identifier="dev.adou.cli"' "$tmp/upgrade-expanded/PackageInfo" || fail "upgrade package identifier changed"
grep -q 'version="0.1.1"' "$tmp/upgrade-expanded/PackageInfo" || fail "upgrade package version did not advance"
grep -q 'install-location="/"' "$tmp/upgrade-expanded/PackageInfo" || fail "upgrade install location changed"

echo "e2e: macos-pkg OK (metadata, exact payload, modes, extracted CLI, unsigned state, upgrade boundary)"
