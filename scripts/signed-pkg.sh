#!/bin/sh
# Build a Developer ID signed flat installer package. FAILS CLOSED before
# creating an artifact unless both required identities are explicit and valid:
# Developer ID Application for payload executables, Developer ID Installer for
# the outer package.

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=${ADOU_VERSION:-}
adou_bin=${ADOU_BIN:-"$repo_root/build/bin/adou"}
helper_bin=${PROCESS_GROUP_HELPER:-"$repo_root/build/bin/adou-process-group"}
artifact=${ADOU_SIGNED_PKG:-}
app_identity=${ADOU_CODESIGN_IDENTITY:-}
installer_identity=${ADOU_INSTALLER_IDENTITY:-}
identifier=${ADOU_PKG_IDENTIFIER:-dev.adou.cli}

if [ -z "$app_identity" ] || [ "$app_identity" = "-" ] || \
   [ -z "$installer_identity" ] || [ "$installer_identity" = "-" ]; then
    echo "signed-pkg: ADOU_CODESIGN_IDENTITY and ADOU_INSTALLER_IDENTITY are required and must not be '-'" >&2
    exit 64
fi

app_id_line=$(security find-identity -v -p codesigning 2>/dev/null | \
    grep -F "$app_identity" | grep -F 'Developer ID Application' || true)
if [ -z "$app_id_line" ]; then
    echo "signed-pkg: application identity '$app_identity' is not a Developer ID Application identity" >&2
    exit 65
fi
installer_id_line=$(security find-identity -v -p basic 2>/dev/null | \
    grep -F "$installer_identity" | grep -F 'Developer ID Installer' || true)
if [ -z "$installer_id_line" ]; then
    echo "signed-pkg: installer identity '$installer_identity' is not a Developer ID Installer identity" >&2
    exit 67
fi

if [ -z "$version" ] || [ -z "$artifact" ] || \
   [ ! -x "$adou_bin" ] || [ ! -x "$helper_bin" ]; then
    echo "signed-pkg: version, output path, or required binaries missing" >&2
    exit 66
fi
for tool in codesign pkgbuild productsign pkgutil; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "signed-pkg: required tool missing: $tool" >&2
        exit 69
    }
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adou-signed-pkg-XXXXXX")
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
install -m 0644 "$repo_root/CHANGELOG.md" "$root/usr/local/share/adou/CHANGELOG.md"

verify_payload_signature() {
    path=$1
    codesign --verify --strict --deep "$path"
    signature=$(codesign -d --verbose=4 "$path" 2>&1 || true)
    case "$signature" in
        *'Authority=Developer ID Application'*) ;;
        *) echo "signed-pkg: missing Developer ID Application authority: $path" >&2; return 1 ;;
    esac
    case "$signature" in
        *'TeamIdentifier='*) ;;
        *) echo "signed-pkg: missing Developer ID team: $path" >&2; return 1 ;;
    esac
    case "$signature" in
        *'TeamIdentifier=not set'*) echo "signed-pkg: missing Developer ID team: $path" >&2; return 1 ;;
    esac
    case "$signature" in
        *'flags='*'runtime'*) ;;
        *) echo "signed-pkg: hardened runtime is disabled: $path" >&2; return 1 ;;
    esac
    case "$signature" in
        *'Timestamp='*) ;;
        *) echo "signed-pkg: secure timestamp is missing: $path" >&2; return 1 ;;
    esac
}

echo "signed-pkg: sign-order=helper,main,installer"
codesign --force --sign "$app_identity" --options runtime --timestamp \
    "$root/usr/local/bin/adou-process-group"
codesign --force --sign "$app_identity" --options runtime --timestamp \
    "$root/usr/local/bin/adou"
verify_payload_signature "$root/usr/local/bin/adou-process-group"
verify_payload_signature "$root/usr/local/bin/adou"

unsigned="$tmp/adou-unsigned.pkg"
signed="$tmp/$(basename -- "$artifact")"
pkgbuild --root "$root" --identifier "$identifier" --version "$version" \
    --install-location / "$unsigned"
productsign --sign "$installer_identity" --timestamp "$unsigned" "$signed"

package_signature=$(pkgutil --check-signature "$signed" 2>&1 || true)
case "$package_signature" in
    *'Developer ID Installer'*) ;;
    *) echo "signed-pkg: outer package has no Developer ID Installer signature" >&2; exit 1 ;;
esac

mkdir -p "$(dirname -- "$artifact")"
mv -f "$signed" "$artifact"
echo "signed-pkg: status=ok artifact=$artifact identifier=$identifier version=$version"
