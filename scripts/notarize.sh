#!/bin/sh
#
# notarize the release tarball for `make notarize`.  FAILS CLOSED: without
# an explicit ADOU_NOTARY_PROFILE (non-empty and not '-') nothing is
# submitted and no network call happens.
#
# Boundary (accurate, see docs/macos-signing.md): a tar.gz can be
# notarized by notarytool, but a tar.gz cannot be stapled (stapling is
# only possible for containers such as dmg/pkg).  This target therefore
# only submits the ticket request and never runs the stapler; dmg/pkg
# packaging is a later batch.
#
# xcrun is resolved through PATH so tests can prepend a fake xcrun that
# records the invocation instead of submitting; this batch never executes
# a real `xcrun notarytool submit`.
#
# Exit codes:
#   64 ADOU_NOTARY_PROFILE missing, empty or '-'
#   66 tarball not found
#   otherwise the exit status of `xcrun notarytool submit`

set -eu

profile=${ADOU_NOTARY_PROFILE:-}
if [ -z "$profile" ] || [ "$profile" = "-" ]; then
    echo "notarize: ADOU_NOTARY_PROFILE is required and must not be '-' (refusing to submit without an explicit notary profile)" >&2
    exit 64
fi

tarball=${ADOU_TARBALL:-}
if [ -z "$tarball" ]; then
    repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    tarball=$(ls "$repo_root"/build/dist/adou-*-darwin-arm64.tar.gz 2>/dev/null | head -n 1 || true)
fi
if [ -z "$tarball" ] || [ ! -f "$tarball" ]; then
    echo "notarize: release tarball not found (run make dist, or set ADOU_TARBALL)" >&2
    exit 66
fi

echo "notarize: submitting $tarball with keychain profile '$profile'"
xcrun notarytool submit "$tarball" --keychain-profile "$profile"
