#!/bin/sh

# Run one Nature compiler command after removing stale Nature compiler
# processes owned by the current user. Nature's compiler can retain several
# GiB while compiling Adou; allowing an interrupted build to overlap with a
# new one can exhaust the machine before either build finishes.

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <nature-subcommand> [args...]" >&2
    exit 64
fi

NATURE_BIN=${NATURE_EXECUTABLE:-}
if [ -z "$NATURE_BIN" ]; then
    NATURE_BIN=$(command -v nature || true)
fi
if [ -z "$NATURE_BIN" ]; then
    echo "nature compiler not found; set NATURE_EXECUTABLE or add nature to PATH" >&2
    exit 127
fi

current_uid=$(id -u)

list_nature_pids() {
    # `comm` is the executable name on macOS and Linux.  Match both the
    # absolute compiler path and the basename because macOS may report either
    # form depending on how the process was launched.
    ps -axo pid=,uid=,comm= 2>/dev/null | awk -v uid="$current_uid" '
        $2 == uid && ($3 == "nature" || $3 ~ /\/nature$/) {print $1}
    '
}

kill_stale_nature() {
    pids=$(list_nature_pids)
    if [ -z "$pids" ]; then
        return 0
    fi

    echo "adou: stopping stale Nature process(es): $pids" >&2
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    # Give the compiler a short opportunity to release its allocator and
    # child processes before escalating.  This loop is intentionally bounded.
    i=0
    while [ "$i" -lt 20 ]; do
        remaining=$(list_nature_pids)
        if [ -z "$remaining" ]; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.05
    done

    remaining=$(list_nature_pids)
    if [ -n "$remaining" ]; then
        echo "adou: force-stopping Nature process(es): $remaining" >&2
        for pid in $remaining; do
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
}

kill_stale_nature
exec "$NATURE_BIN" "$@"
