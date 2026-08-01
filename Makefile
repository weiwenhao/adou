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
SAFE_NATURE := $(CURDIR)/scripts/nature-build-safe.sh
NATIVE_OBJ := native/unicode_icu.o

ICU_INCLUDE ?= $(firstword $(wildcard /opt/homebrew/opt/icu4c/include /usr/local/opt/icu4c/include))
ICU_CFLAGS := $(if $(ICU_INCLUDE),-I$(ICU_INCLUDE),)

NATURE_SOURCES := main.n package.toml $(shell find src -type f -name '*.n' -print)
TEST_SOURCES := $(sort $(wildcard tests/*.n))

.PHONY: all build run test install clean help

all: build

build: $(ADOU_BIN)

$(NATIVE_OBJ): native/unicode_icu.c
	@mkdir -p "$(dir $@)"
	@$(CC) -std=c11 -O2 $(ICU_CFLAGS) -c "$<" -o "$@"

$(ADOU_BIN): $(NATURE_SOURCES) $(NATIVE_OBJ) $(SAFE_NATURE)
	@mkdir -p "$(BIN_DIR)"
	@NATURE_EXECUTABLE="$(NATURE)" BUILD_OUTPUT_DIR="$(BIN_DIR)" "$(SAFE_NATURE)" build -o adou "$(CURDIR)/main.n"

run: build
	@"$(ADOU_BIN)"

# Nature's own test runner is the test framework.  Run tests one at a time so
# each invocation gets the same stale-compiler cleanup and no two Nature
# processes can overlap.
test: $(SAFE_NATURE)
	@set -e; for test_file in $(TEST_SOURCES); do \
		echo "==> $$test_file"; \
		NATURE_EXECUTABLE="$(NATURE)" "$(SAFE_NATURE)" test "$(CURDIR)/$$test_file"; \
	done

PREFIX ?= /usr/local
DESTDIR ?=

install: build
	@mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	@cp "$(ADOU_BIN)" "$(DESTDIR)$(PREFIX)/bin/adou"
	@mkdir -p "$(DESTDIR)$(PREFIX)/share/adou/docs"
	@cp docs/mvp-implementation-spec.md docs/nature-issues.md "$(DESTDIR)$(PREFIX)/share/adou/docs/"

clean:
	@rm -rf "$(BUILD_DIR)"
	@rm -f "$(NATIVE_OBJ)"

help:
	@printf '%s\n' \
		'make build   Build Adou through the guarded Nature compiler' \
		'make run     Build and run Adou' \
		'make test    Run every Nature test serially through the guard' \
		'make install Install the binary and docs (PREFIX=/usr/local)' \
		'make clean   Remove generated build files'
