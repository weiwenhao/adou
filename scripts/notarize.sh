#!/bin/sh
#
# Notarize and staple the signed flat installer for `make notarize`.
# FAILS CLOSED: without
# an explicit ADOU_NOTARY_PROFILE (non-empty and not '-') nothing is
# submitted and no network call happens.
#
# xcrun is resolved through PATH so tests can prepend a fake xcrun that
# records the invocation instead of submitting. Real use waits for the
# notary result, staples and validates the ticket, then runs the Gatekeeper
# installer assessment.
#
# Exit codes:
#   64 ADOU_NOTARY_PROFILE missing, empty or '-'
#   66 signed package not found
#   67 package lacks a Developer ID Installer signature
#   otherwise the failing notarytool/stapler/spctl status

set -eu

profile=${ADOU_NOTARY_PROFILE:-}
if [ -z "$profile" ] || [ "$profile" = "-" ]; then
    echo "notarize: ADOU_NOTARY_PROFILE is required and must not be '-' (refusing to submit without an explicit notary profile)" >&2
    exit 64
fi

package=${ADOU_SIGNED_PKG:-}
if [ -z "$package" ]; then
    repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    package=$(ls "$repo_root"/build/dist/adou-*-darwin-arm64-signed.pkg 2>/dev/null | head -n 1 || true)
fi
if [ -z "$package" ] || [ ! -f "$package" ]; then
    echo "notarize: signed installer package not found (run make signed-pkg, or set ADOU_SIGNED_PKG)" >&2
    exit 66
fi

package_signature=$(pkgutil --check-signature "$package" 2>&1 || true)
case "$package_signature" in
    *'Developer ID Installer'*) ;;
    *) echo "notarize: package lacks a Developer ID Installer signature" >&2; exit 67 ;;
esac

echo "notarize: submitting $package with keychain profile '$profile'"
xcrun notarytool submit "$package" --keychain-profile "$profile" --wait
xcrun stapler staple "$package"
xcrun stapler validate "$package"
spctl --assess --verbose=4 --type install "$package"
echo "notarize: status=ok artifact=$package"
