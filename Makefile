SHELL := /bin/sh

# Nature compilation is memory-heavy.  Keep the build graph serial even when
# make is invoked with -j, and route every compiler/test invocation through
# the stale-process guard.
.NOTPARALLEL:

NATURE ?= nature
CC ?= cc
BUILD_DIR ?= build
BIN_DIR := $(BUILD_DIR)/bin
ADOU_BIN := $(BIN_DIR)/adou
PROCESS_GROUP_HELPER := $(BIN_DIR)/adou-process-group
SAFE_NATURE := $(CURDIR)/scripts/nature-build-safe.sh
NATIVE_OBJ := native/unicode_icu.o
TERM_OBJ := native/term.o
REGEX_OBJ := native/regex.o
STDIN_PEEK_OBJ := native/stdin_peek.o
AUTH_STORE_OBJ := native/auth_store.o
CLIPBOARD_IMAGE_OBJ := native/clipboard_image.o

ICU_INCLUDE ?= $(firstword $(wildcard /opt/homebrew/opt/icu4c/include /usr/local/opt/icu4c/include))
ICU_CFLAGS := $(if $(ICU_INCLUDE),-I$(ICU_INCLUDE),)

NATURE_SOURCES := main.n package.toml $(shell find src -type f -name '*.n' -print)
TEST_SOURCES := $(sort $(wildcard tests/*.n))
E2E_SOURCES := $(sort $(wildcard tests/e2e/*.sh))
# Opt-in live suites live under tests/e2e/live/ and are never picked up by
# the plain e2e glob above (make e2e stays offline/mocked and consumes no
# provider quota).  The list is explicit: a new live script must be
# registered here to join make e2e-live.  Each live script self-gates
# behind an ADOU_LIVE_* switch, so this target is safe to invoke without
# any switch set.
E2E_LIVE_SOURCES := tests/e2e/live/live-smoke.sh tests/e2e/live/live-coding-journey.sh tests/e2e/live/live-tui-coding-journey.sh tests/e2e/live/share-github.sh
EVAL_ENTRY := tests/evals/smoke_evals.n
EVAL_BIN := $(BIN_DIR)/adou-evals
ADOU_VERSION := $(shell sed -n "s/^pub const VERSION = '\([^']*\)'.*/\1/p" $(CURDIR)/src/app.n)
DIST_DIR := $(BUILD_DIR)/dist
DIST_NAME := adou-$(ADOU_VERSION)-darwin-arm64
DIST_STAGE := $(DIST_DIR)/$(DIST_NAME)
DIST_TARBALL := $(DIST_DIR)/$(DIST_NAME).tar.gz
PKG_ARTIFACT := $(DIST_DIR)/$(DIST_NAME).pkg
SIGNED_PKG_ARTIFACT := $(DIST_DIR)/$(DIST_NAME)-signed.pkg

.PHONY: all build run test e2e e2e-live eval check install dist pkg pkg-check release-check clean signing-preflight signing-smoke signed-dist signed-pkg notarize signing-check help

all: build

build: $(ADOU_BIN) $(PROCESS_GROUP_HELPER)

$(PROCESS_GROUP_HELPER): native/process_group_helper.c
	@mkdir -p "$(dir $@)"
	@$(CC) -std=c11 -O2 "$<" -o "$@"

$(NATIVE_OBJ): native/unicode_icu.c
	@mkdir -p "$(dir $@)"
	@$(CC) -std=c11 -O2 $(ICU_CFLAGS) -c "$<" -o "$@"

$(TERM_OBJ): native/term.c
	@mkdir -p "$(dir $@)"
	@$(CC) -std=c11 -O2 -c "$<" -o "$@"

$(REGEX_OBJ): native/regex.c
	@mkdir -p "$(dir $@)"
	@$(CC) -std=c11 -O2 -c "$<" -o "$@"

$(STDIN_PEEK_OBJ): native/stdin_peek.c
	@mkdir -p "$(dir $@)"
	@$(CC) -std=c11 -O2 -c "$<" -o "$@"

$(AUTH_STORE_OBJ): native/auth_store.c
	@mkdir -p "$(dir $@)"
	@$(CC) -std=c11 -O2 -c "$<" -o "$@"

$(CLIPBOARD_IMAGE_OBJ): native/clipboard_image.c
	@mkdir -p "$(dir $@)"
	@$(CC) -std=c11 -O2 -c "$<" -o "$@"

$(ADOU_BIN): $(NATURE_SOURCES) $(NATIVE_OBJ) $(TERM_OBJ) $(REGEX_OBJ) $(STDIN_PEEK_OBJ) $(AUTH_STORE_OBJ) $(CLIPBOARD_IMAGE_OBJ) $(SAFE_NATURE)
	@mkdir -p "$(BIN_DIR)"
	@NATURE_EXECUTABLE="$(NATURE)" "$(SAFE_NATURE)" build -o "$(ADOU_BIN)" "$(CURDIR)/main.n"

run: build
	@ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(ADOU_BIN)"

# Nature's own test runner is the test framework.  Run tests one at a time so
# each invocation gets the same stale-compiler cleanup and no two Nature
# processes can overlap.
test: $(SAFE_NATURE) $(NATIVE_OBJ) $(TERM_OBJ) $(REGEX_OBJ) $(STDIN_PEEK_OBJ) $(AUTH_STORE_OBJ) $(CLIPBOARD_IMAGE_OBJ) $(PROCESS_GROUP_HELPER)
	@set -e; for test_file in $(TEST_SOURCES); do \
		echo "==> $$test_file"; \
		ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" NATURE_EXECUTABLE="$(NATURE)" "$(SAFE_NATURE)" test "$(CURDIR)/$$test_file"; \
	done

e2e: build
	@set -e; for test_file in $(E2E_SOURCES); do \
		echo "==> $$test_file"; \
		ADOU_BIN="$(abspath $(ADOU_BIN))" ADOU_PROCESS_GROUP_HELPER="$(abspath $(PROCESS_GROUP_HELPER))" "$(CURDIR)/$$test_file"; \
	done

# Serial opt-in live suite against the real model.  Individual scripts gate
# themselves behind ADOU_LIVE_SMOKE / ADOU_LIVE_JOURNEY so this target is
# safe to invoke without the switch set; with the switches on it consumes
# provider quota (see docs/e2e-journey-matrix.md).
e2e-live: build
	@set -e; for test_file in $(E2E_LIVE_SOURCES); do \
		echo "==> $$test_file"; \
		ADOU_BIN="$(abspath $(ADOU_BIN))" ADOU_PROCESS_GROUP_HELPER="$(abspath $(PROCESS_GROUP_HELPER))" "$(CURDIR)/$$test_file"; \
	done

# Phase 8 eval harness: one guarded build of the smoke eval entry point, then
# a serial run of its cases against local scripted HTTP mocks.
eval: build $(EVAL_BIN)
	@"$(EVAL_BIN)"

$(EVAL_BIN): $(NATURE_SOURCES) $(NATIVE_OBJ) $(TERM_OBJ) $(REGEX_OBJ) $(STDIN_PEEK_OBJ) $(AUTH_STORE_OBJ) $(CLIPBOARD_IMAGE_OBJ) $(SAFE_NATURE) $(EVAL_ENTRY)
	@mkdir -p "$(BIN_DIR)"
	@NATURE_EXECUTABLE="$(NATURE)" "$(SAFE_NATURE)" build -o "$(EVAL_BIN)" "$(CURDIR)/$(EVAL_ENTRY)"

check: test e2e

PREFIX ?= /usr/local
DESTDIR ?=

install: build
	@mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	@cp "$(ADOU_BIN)" "$(DESTDIR)$(PREFIX)/bin/adou"
	@cp "$(PROCESS_GROUP_HELPER)" "$(DESTDIR)$(PREFIX)/bin/adou-process-group"
	@mkdir -p "$(DESTDIR)$(PREFIX)/share/adou/docs"
	@cp docs/mvp-implementation-spec.md "$(DESTDIR)$(PREFIX)/share/adou/docs/"

# darwin-arm64 release tarball.  src/app.n's VERSION is the single source of
# truth; package.toml must agree or dist fails.  File list and permissions are
# fixed; byte-level reproducibility is not claimed (see
# docs/release-hardening-plan.md).  The staging/archiving work lives in
# scripts/make-dist.sh (same convention as the guarded Nature wrapper).
dist: build
	@ADOU_VERSION="$(ADOU_VERSION)" ADOU_BIN="$(ADOU_BIN)" PROCESS_GROUP_HELPER="$(PROCESS_GROUP_HELPER)" DIST_DIR="$(DIST_DIR)" DIST_NAME="$(DIST_NAME)" PACKAGE_VERSION="$(shell sed -n 's/^version = "\([^"]*\)".*/\1/p' $(CURDIR)/package.toml)" "$(CURDIR)/scripts/make-dist.sh"

# Unsigned flat macOS installer package.  The payload matches `make install`:
# /usr/local/bin/{adou,adou-process-group} and the installed Adou docs.
# Signing/notarization are separate, explicit fail-closed targets.
pkg: build
	@ADOU_VERSION="$(ADOU_VERSION)" ADOU_BIN="$(ADOU_BIN)" PROCESS_GROUP_HELPER="$(PROCESS_GROUP_HELPER)" ADOU_PKG="$(PKG_ARTIFACT)" "$(CURDIR)/scripts/make-pkg.sh"

# Offline package artifact gate: inspect metadata, exact payload and modes,
# then extract the payload and run the packaged binary from scratch space.
pkg-check: pkg
	@ADOU_VERSION="$(ADOU_VERSION)" ADOU_PKG="$(PKG_ARTIFACT)" ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/release/macos-pkg.sh"
	@ADOU_VERSION="$(ADOU_VERSION)" ADOU_PKG="$(PKG_ARTIFACT)" ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/release/macos-pkg-signing.sh"

# Serial release gate: build, evals, dist, artifact e2e, RPC-over-IPC e2e and
# the bash-stream e2e (covers bash execution through the process-group
# helper).  Deliberately does not run the full make test / make e2e suites.
# Batch 2A signing targets (signing-preflight/signing-smoke/signing-check)
# are not part of this gate; they are local readiness checks only and are
# documented in docs/macos-signing.md.
release-check: build eval dist pkg
	@set -e; \
	ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/release/release-artifact.sh"; \
	ADOU_VERSION="$(ADOU_VERSION)" ADOU_PKG="$(PKG_ARTIFACT)" ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/release/macos-pkg.sh"; \
	ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/rpc-over-ipc.sh"; \
	ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/rpc-bash-stream.sh"; \
	echo "release-check: build+eval+dist+pkg+artifacts+ipc+bash OK"

# Batch 2A: read-only macOS signing readiness preflight (no artifacts or
# keychain state are modified; documented exit codes in
# docs/macos-signing.md).
signing-preflight: build
	@ADOU_BIN="$(ADOU_BIN)" "$(CURDIR)/scripts/signing-preflight.sh"

# Batch 2A: offline ad-hoc signing smoke on a scratch copy of the dist
# staging (helper first, then the main binary; --options runtime
# --timestamp=none), verified with --strict --deep.  build/bin and the
# default dist staging are never modified and their hashes are checked.
signing-smoke: dist
	@ADOU_BIN="$(ADOU_BIN)" PROCESS_GROUP_HELPER="$(PROCESS_GROUP_HELPER)" DIST_DIR="$(DIST_DIR)" DIST_NAME="$(DIST_NAME)" "$(CURDIR)/scripts/signing-smoke.sh"

# Fail-closed Developer ID signed artifact: requires ADOU_CODESIGN_IDENTITY
# (non-empty, not '-', a Developer ID Application identity).  Never invoked
# by release-check or signing-smoke; in this batch no such identity exists,
# so only the fail-closed paths run.
signed-dist: dist
	@ADOU_VERSION="$(ADOU_VERSION)" DIST_DIR="$(DIST_DIR)" DIST_NAME="$(DIST_NAME)" "$(CURDIR)/scripts/signed-dist.sh"

# Fail-closed native installer signing.  Requires both a Developer ID
# Application identity for the payload executables and a Developer ID
# Installer identity for the outer flat package.
signed-pkg: build
	@ADOU_VERSION="$(ADOU_VERSION)" ADOU_BIN="$(ADOU_BIN)" PROCESS_GROUP_HELPER="$(PROCESS_GROUP_HELPER)" ADOU_SIGNED_PKG="$(SIGNED_PKG_ARTIFACT)" "$(CURDIR)/scripts/signed-pkg.sh"

# Fail-closed native installer notarization: requires an existing Developer
# ID Installer signed pkg and ADOU_NOTARY_PROFILE. This explicit target is the
# only release path that contacts Apple; it waits, staples, validates and runs
# the Gatekeeper installer assessment.
notarize:
	@ADOU_SIGNED_PKG="$(SIGNED_PKG_ARTIFACT)" "$(CURDIR)/scripts/notarize.sh"

# Serial Batch 2A gate: dist, then the local signing workflow e2e (preflight
# behavior, fail-closed paths, fake-tool dry-runs, ad-hoc copy smoke and
# README/signature consistency).
signing-check: dist pkg
	@set -e; \
	ADOU_VERSION="$(ADOU_VERSION)" ADOU_PKG="$(PKG_ARTIFACT)" ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/release/macos-pkg.sh"; \
	ADOU_VERSION="$(ADOU_VERSION)" ADOU_PKG="$(PKG_ARTIFACT)" ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/release/macos-pkg-signing.sh"; \
	ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/release/macos-signing-workflow.sh"; \
	echo "signing-check: dist+pkg+package/signing workflows OK"

clean:
	@rm -rf "$(BUILD_DIR)"
	@rm -f "$(NATIVE_OBJ)" "$(TERM_OBJ)" "$(REGEX_OBJ)" "$(STDIN_PEEK_OBJ)" "$(AUTH_STORE_OBJ)" "$(CLIPBOARD_IMAGE_OBJ)"

help:
	@printf '%s\n' \
		'make build   Build Adou through the guarded Nature compiler' \
		'make run     Build and run Adou' \
		'make test    Run every Nature test serially through the guard' \
		'make e2e     Build once, then run CLI end-to-end tests (offline/mocked)' \
		'make e2e-live Build once, then run opt-in live DeepSeek tests serially (scripts self-gate on ADOU_LIVE_SMOKE / ADOU_LIVE_JOURNEY; consumes quota)' \
		'make eval    Run the Phase 8 smoke evals against local mocks' \
		'make check   Run unit tests followed by end-to-end tests' \
		'make dist    Package build/dist/adou-<version>-darwin-arm64.tar.gz' \
		'make pkg     Build the unsigned native macOS flat installer package' \
		'make pkg-check  Build and inspect/extract/run the macOS installer payload' \
		'make release-check  Serial macOS release gate: build, eval, tar/pkg artifacts, IPC e2e, bash e2e' \
		'make signing-preflight  Read-only macOS signing readiness check (Batch 2A)' \
		'make signing-smoke  Ad-hoc re-sign a scratch copy of the dist staging and verify' \
		'make signed-dist    Developer ID signed artifact (fail-closed; needs ADOU_CODESIGN_IDENTITY)' \
		'make signed-pkg     Developer ID signed native installer (needs Application + Installer identities)' \
		'make notarize       Submit, staple and assess signed pkg (needs ADOU_NOTARY_PROFILE)' \
		'make signing-check  Serial macOS package and signing-readiness gate' \
		'make install Install the binary and docs (PREFIX=/usr/local)' \
		'make clean   Remove generated build files'
