#!/bin/sh
#
# Stage and archive the darwin-arm64 release artifact for `make dist`.
# Environment-driven so the Makefile stays the single entry point:
#
#   ADOU_VERSION         version from src/app.n (source of truth)
#   PACKAGE_VERSION      version from package.toml (must match ADOU_VERSION)
#   ADOU_BIN             path to the built adou binary
#   PROCESS_GROUP_HELPER path to the built adou-process-group helper
#   DIST_DIR             staging root (build/dist)
#   DIST_NAME            archive directory name, adou-<version>-darwin-arm64
#
# Output: $DIST_DIR/$DIST_NAME/ (adou, adou-process-group, RELEASE-README,
# SHA256SUMS) and $DIST_DIR/$DIST_NAME.tar.gz.  File list and permissions are
# fixed; byte-level reproducibility is not claimed.

set -eu

adou_version=${ADOU_VERSION:-}
package_version=${PACKAGE_VERSION:-}
adou_bin=${ADOU_BIN:-}
helper_bin=${PROCESS_GROUP_HELPER:-}
dist_dir=${DIST_DIR:-}
dist_name=${DIST_NAME:-}

if [ -z "$adou_version" ] || [ -z "$package_version" ] || [ -z "$adou_bin" ] || [ -z "$helper_bin" ] || [ -z "$dist_dir" ] || [ -z "$dist_name" ]; then
    echo "make-dist: missing required environment (ADOU_VERSION, PACKAGE_VERSION, ADOU_BIN, PROCESS_GROUP_HELPER, DIST_DIR, DIST_NAME)" >&2
    exit 64
fi
if [ "$adou_version" != "$package_version" ]; then
    echo "make-dist: version mismatch: src/app.n VERSION=$adou_version, package.toml=$package_version" >&2
    exit 1
fi

stage="$dist_dir/$dist_name"

rm -rf "$dist_dir"
mkdir -p "$stage"

cp "$adou_bin" "$stage/adou"
cp "$helper_bin" "$stage/adou-process-group"

cat > "$stage/RELEASE-README" <<EOF
Adou $adou_version - darwin-arm64
=================================

Adou is a Pi-derived coding agent implemented in the Nature programming
language.  This archive is a minimal, self-contained macOS arm64 build.

Contents
--------
  adou                 The Adou CLI (Mach-O arm64)
  adou-process-group   Process-group helper used by the bash tool
  RELEASE-README       This file
  SHA256SUMS           SHA-256 manifest of the files above

Requirements
------------
  macOS on Apple silicon (arm64).  No other runtime, interpreter, or
  system library beyond /usr/lib/libSystem.B.dylib is required.

Install
-------
  tar -xzf adou-$adou_version-darwin-arm64.tar.gz
  cd adou-$adou_version-darwin-arm64
  # optional: copy the two binaries into a directory on your PATH
  cp adou adou-process-group ~/bin/

Run
---
  adou --version
  adou --help
  # one-shot with a provider API key exported from the provider's console,
  # then:
  #   adou --print "hello"

Verification
------------
  shasum -a 256 -c SHA256SUMS

Sources and build
-----------------
  Repository: Adou (Nature), https://github.com/anomalyco/opencode
  Phase 1-8 porting complete; see docs/porting-plan.md and
  docs/release-hardening-plan.md in the source tree.
  Build: make build && make dist (guarded serial Nature compiler workflow).

Scope and signing
-----------------
  This batch of the release hardening plan only ships darwin-arm64.
  The binary is NOT codesigned or notarized; on first launch Gatekeeper
  may warn about an unidentified developer.  Linux builds, installers,
  and notarization are future batches (see docs/release-hardening-plan.md).
EOF

chmod 0755 "$stage/adou" "$stage/adou-process-group"
chmod 0644 "$stage/RELEASE-README"

(cd "$stage" && shasum -a 256 adou adou-process-group RELEASE-README > SHA256SUMS)

tar -C "$dist_dir" -czf "$dist_dir/$dist_name.tar.gz" "$dist_name"

ls -la "$stage"
echo "make-dist: $dist_dir/$dist_name.tar.gz"
