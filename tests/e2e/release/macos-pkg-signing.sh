#!/bin/sh
set -eu

# Offline signed-pkg/notarization orchestration tests. Fake tools exercise the
# successful command path without using identities, credentials, network, the
# receipt database, or /usr/local.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
version=${ADOU_VERSION:-}
package=${ADOU_PKG:-}
adou_bin=${ADOU_BIN:-"$repo_root/build/bin/adou"}
helper_bin=${ADOU_PROCESS_GROUP_HELPER:-"$repo_root/build/bin/adou-process-group"}

fail() {
    echo "e2e: macos-pkg-signing failed: $*" >&2
    exit 1
}

if [ -z "$version" ] || [ -z "$package" ] || [ ! -f "$package" ]; then
    echo "e2e: macos-pkg-signing: package/version missing (run make pkg)" >&2
    exit 2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adou-pkg-signing-e2e-XXXXXX")
cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

hash_adou=$(shasum -a 256 "$adou_bin" | awk '{print $1}')
hash_helper=$(shasum -a 256 "$helper_bin" | awk '{print $1}')
hash_package=$(shasum -a 256 "$package" | awk '{print $1}')
assert_originals_unchanged() {
    [ "$(shasum -a 256 "$adou_bin" | awk '{print $1}')" = "$hash_adou" ] || fail "build/bin/adou changed"
    [ "$(shasum -a 256 "$helper_bin" | awk '{print $1}')" = "$hash_helper" ] || fail "helper changed"
    [ "$(shasum -a 256 "$package" | awk '{print $1}')" = "$hash_package" ] || fail "unsigned package changed"
}

set +e
out=$(env -u ADOU_CODESIGN_IDENTITY -u ADOU_INSTALLER_IDENTITY \
    ADOU_SIGNED_PKG="$tmp/missing.pkg" "$repo_root/scripts/signed-pkg.sh" 2>&1)
code=$?
set -e
[ "$code" -eq 64 ] || fail "signed-pkg without identities must exit 64: $code $out"
[ ! -e "$tmp/missing.pkg" ] || fail "missing-identity path created an artifact"

set +e
out=$(ADOU_CODESIGN_IDENTITY=__adou_missing_identity__ \
    ADOU_INSTALLER_IDENTITY=__adou_missing_installer__ \
    ADOU_SIGNED_PKG="$tmp/invalid.pkg" "$repo_root/scripts/signed-pkg.sh" 2>&1)
code=$?
set -e
[ "$code" -eq 65 ] || fail "invalid Application identity must exit 65: $code $out"
[ ! -e "$tmp/invalid.pkg" ] || fail "invalid-identity path created an artifact"

set +e
out=$(env -u ADOU_NOTARY_PROFILE ADOU_SIGNED_PKG="$package" \
    "$repo_root/scripts/notarize.sh" 2>&1)
code=$?
set -e
[ "$code" -eq 64 ] || fail "notarize without profile must exit 64: $code $out"

set +e
out=$(ADOU_NOTARY_PROFILE=fake-profile ADOU_SIGNED_PKG="$package" \
    "$repo_root/scripts/notarize.sh" 2>&1)
code=$?
set -e
[ "$code" -eq 67 ] || fail "notarize must reject an unsigned package with 67: $code $out"

fake="$tmp/fake"
mkdir -p "$fake"
tool_log="$tmp/tool.log"
: > "$tool_log"

cat > "$fake/security" <<EOF
#!/bin/sh
printf 'security %s\n' "\$*" >> "$tool_log"
case "\$*" in
    *'-p codesigning'*) printf '%s\n' '  1) APP-ID "Developer ID Application: Adou Test (TEAMID)"' ;;
    *'-p basic'*)
        if [ "\${FAKE_INSTALLER_IDENTITY:-yes}" = yes ]; then
            printf '%s\n' '  1) INSTALLER-ID "Developer ID Installer: Adou Test (TEAMID)"'
        fi
        ;;
esac
EOF
cat > "$fake/codesign" <<EOF
#!/bin/sh
printf 'codesign %s\n' "\$*" >> "$tool_log"
case "\$*" in
    *'-d --verbose=4'*)
        printf '%s\n' 'flags=0x10000(runtime)' 'Authority=Developer ID Application: Adou Test (TEAMID)' 'TeamIdentifier=TEAMID' 'Timestamp=Aug 12, 2026' >&2
        ;;
esac
exit 0
EOF
cat > "$fake/pkgbuild" <<EOF
#!/bin/sh
printf 'pkgbuild %s\n' "\$*" >> "$tool_log"
for argument do output=\$argument; done
printf '%s\n' fake-unsigned-package > "\$output"
EOF
cat > "$fake/productsign" <<EOF
#!/bin/sh
printf 'productsign %s\n' "\$*" >> "$tool_log"
previous=
last=
for argument do previous=\$last; last=\$argument; done
cp "\$previous" "\$last"
EOF
cat > "$fake/pkgutil" <<EOF
#!/bin/sh
printf 'pkgutil %s\n' "\$*" >> "$tool_log"
printf '%s\n' 'Status: signed by a developer certificate issued by Apple for distribution' '1. Developer ID Installer: Adou Test (TEAMID)'
EOF
cat > "$fake/xcrun" <<EOF
#!/bin/sh
printf 'xcrun %s\n' "\$*" >> "$tool_log"
exit 0
EOF
cat > "$fake/spctl" <<EOF
#!/bin/sh
printf 'spctl %s\n' "\$*" >> "$tool_log"
exit 0
EOF
chmod +x "$fake/security" "$fake/codesign" "$fake/pkgbuild" \
    "$fake/productsign" "$fake/pkgutil" "$fake/xcrun" "$fake/spctl"

set +e
out=$(PATH="$fake:$PATH" FAKE_INSTALLER_IDENTITY=no \
    ADOU_CODESIGN_IDENTITY=APP-ID ADOU_INSTALLER_IDENTITY=INSTALLER-ID \
    ADOU_VERSION="$version" ADOU_BIN="$adou_bin" PROCESS_GROUP_HELPER="$helper_bin" \
    ADOU_SIGNED_PKG="$tmp/no-installer.pkg" "$repo_root/scripts/signed-pkg.sh" 2>&1)
code=$?
set -e
[ "$code" -eq 67 ] || fail "missing Installer identity must exit 67: $code $out"
[ ! -e "$tmp/no-installer.pkg" ] || fail "missing Installer identity created an artifact"

signed_package="$tmp/adou-signed.pkg"
PATH="$fake:$PATH" ADOU_CODESIGN_IDENTITY=APP-ID \
    ADOU_INSTALLER_IDENTITY=INSTALLER-ID ADOU_VERSION="$version" \
    ADOU_BIN="$adou_bin" PROCESS_GROUP_HELPER="$helper_bin" \
    ADOU_SIGNED_PKG="$signed_package" "$repo_root/scripts/signed-pkg.sh" >/dev/null
[ -f "$signed_package" ] || fail "fake signed-pkg path produced no artifact"

sign_lines=$(grep '^codesign --force --sign' "$tool_log" || true)
[ "$(printf '%s\n' "$sign_lines" | grep -c . || true)" -eq 2 ] || fail "expected exactly two payload signing calls"
printf '%s\n' "$sign_lines" | sed -n '1p' | grep -q 'adou-process-group$' || fail "helper was not signed first"
printf '%s\n' "$sign_lines" | sed -n '2p' | grep -q '/adou$' || fail "main binary was not signed second"
grep -q '^productsign --sign INSTALLER-ID --timestamp ' "$tool_log" || fail "outer package was not signed last with timestamp"

: > "$tool_log"
PATH="$fake:$PATH" ADOU_NOTARY_PROFILE=fake-profile \
    ADOU_SIGNED_PKG="$signed_package" "$repo_root/scripts/notarize.sh" >/dev/null
expected_notary="xcrun notarytool submit $signed_package --keychain-profile fake-profile --wait"
grep -qx "$expected_notary" "$tool_log" || fail "notarytool submit shape/order missing"
grep -qx "xcrun stapler staple $signed_package" "$tool_log" || fail "stapler staple missing"
grep -qx "xcrun stapler validate $signed_package" "$tool_log" || fail "stapler validate missing"
grep -qx "spctl --assess --verbose=4 --type install $signed_package" "$tool_log" || fail "Gatekeeper install assessment missing"

assert_originals_unchanged
echo "e2e: macos-pkg-signing OK (fail-closed identities/profile, signing order, notarize+staple orchestration)"
