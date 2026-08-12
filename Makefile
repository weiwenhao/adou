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

ICU_INCLUDE ?= $(firstword $(wildcard /opt/homebrew/opt/icu4c/include /usr/local/opt/icu4c/include))
ICU_CFLAGS := $(if $(ICU_INCLUDE),-I$(ICU_INCLUDE),)

NATURE_SOURCES := main.n package.toml $(shell find src -type f -name '*.n' -print)
TEST_SOURCES := $(sort $(wildcard tests/*.n))
E2E_SOURCES := $(sort $(wildcard tests/e2e/*.sh))
EVAL_ENTRY := tests/evals/smoke_evals.n
EVAL_BIN := $(BIN_DIR)/adou-evals
ADOU_VERSION := $(shell sed -n "s/^pub const VERSION = '\([^']*\)'.*/\1/p" $(CURDIR)/src/app.n)
DIST_DIR := $(BUILD_DIR)/dist
DIST_NAME := adou-$(ADOU_VERSION)-darwin-arm64
DIST_STAGE := $(DIST_DIR)/$(DIST_NAME)
DIST_TARBALL := $(DIST_DIR)/$(DIST_NAME).tar.gz

.PHONY: all build run test e2e eval check install dist release-check clean help

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

$(ADOU_BIN): $(NATURE_SOURCES) $(NATIVE_OBJ) $(TERM_OBJ) $(REGEX_OBJ) $(STDIN_PEEK_OBJ) $(SAFE_NATURE)
	@mkdir -p "$(BIN_DIR)"
	@NATURE_EXECUTABLE="$(NATURE)" "$(SAFE_NATURE)" build -o "$(ADOU_BIN)" "$(CURDIR)/main.n"

run: build
	@ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(ADOU_BIN)"

# Nature's own test runner is the test framework.  Run tests one at a time so
# each invocation gets the same stale-compiler cleanup and no two Nature
# processes can overlap.
test: $(SAFE_NATURE) $(NATIVE_OBJ) $(TERM_OBJ) $(REGEX_OBJ) $(STDIN_PEEK_OBJ) $(PROCESS_GROUP_HELPER)
	@set -e; for test_file in $(TEST_SOURCES); do \
		echo "==> $$test_file"; \
		ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" NATURE_EXECUTABLE="$(NATURE)" "$(SAFE_NATURE)" test "$(CURDIR)/$$test_file"; \
	done

e2e: build
	@set -e; for test_file in $(E2E_SOURCES); do \
		echo "==> $$test_file"; \
		ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/$$test_file"; \
	done

# Phase 8 eval harness: one guarded build of the smoke eval entry point, then
# a serial run of its cases against local scripted HTTP mocks.
eval: build $(EVAL_BIN)
	@"$(EVAL_BIN)"

$(EVAL_BIN): $(NATURE_SOURCES) $(NATIVE_OBJ) $(TERM_OBJ) $(REGEX_OBJ) $(STDIN_PEEK_OBJ) $(SAFE_NATURE) $(EVAL_ENTRY)
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

# Serial release gate: build, evals, dist, artifact e2e, RPC-over-IPC e2e and
# the bash-stream e2e (covers bash execution through the process-group
# helper).  Deliberately does not run the full make test / make e2e suites.
release-check: build eval dist
	@set -e; \
	ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/release-artifact.sh"; \
	ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/rpc-over-ipc.sh"; \
	ADOU_BIN="$(ADOU_BIN)" ADOU_PROCESS_GROUP_HELPER="$(CURDIR)/$(PROCESS_GROUP_HELPER)" "$(CURDIR)/tests/e2e/rpc-bash-stream.sh"; \
	echo "release-check: build+eval+dist+artifact+ipc+bash OK"

clean:
	@rm -rf "$(BUILD_DIR)"
	@rm -f "$(NATIVE_OBJ)" "$(TERM_OBJ)" "$(REGEX_OBJ)" "$(STDIN_PEEK_OBJ)"

help:
	@printf '%s\n' \
		'make build   Build Adou through the guarded Nature compiler' \
		'make run     Build and run Adou' \
		'make test    Run every Nature test serially through the guard' \
		'make e2e     Build once, then run CLI end-to-end tests' \
		'make eval    Run the Phase 8 smoke evals against local mocks' \
		'make check   Run unit tests followed by end-to-end tests' \
		'make dist    Package build/dist/adou-<version>-darwin-arm64.tar.gz' \
		'make release-check  Serial release gate: build, eval, dist, artifact e2e, IPC e2e, bash e2e' \
		'make install Install the binary and docs (PREFIX=/usr/local)' \
		'make clean   Remove generated build files'
