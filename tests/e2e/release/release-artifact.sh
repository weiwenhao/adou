#!/bin/sh
set -eu

# Release artifact e2e: unpack the `make dist` tarball into a temp directory
# and exercise the binaries completely outside the repository cwd.
#
# Coverage:
#   - archive contains only the four expected files (no tests/, sessions,
#     porting-plan, JSONL or auth material) and SHA256SUMS verifies
#   - --version/--help exit 0 with non-empty stdout, version matches the
#     tarball name
#   - ADOU_CODING_AGENT_DIR / ADOU_SESSION_DIR point into the temp
#     dir; no network; no API keys are printed or packaged
#   - the adjacent adou-process-group exists, is executable, and is found by
#     runtime discovery (ADOU_PROCESS_GROUP_HELPER unset; adjacent path)
#     while actually running a bash tool command
#   - offline headless RPC smoke returns a deterministic failure response
#     (offline refusal or preflight error) instead of hanging
#   - RPC-over-IPC lifecycle: spawn -> status -> stop with the upstream
#     response shapes, and no leftover adou processes after server exit
#   - Mach-O audit: both binaries are arm64 and their dynamic dependencies
#     are restricted to /usr/lib and /System prefixes (no Node/Bun/QuickJS
#     or other non-system dylibs)
#
# The tarball is located via ADOU_TARBALL or the build/dist glob; the script
# is safe to be picked up by the `make e2e` glob (fails with exit 2 when the
# tarball has not been built).

# This script lives one directory below the plain `make e2e` glob
# (tests/e2e/release/), so the repository root is three levels up.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adou-release-artifact-XXXXXX")

tarball=${ADOU_TARBALL:-}
if [ -z "$tarball" ]; then
    tarball=$(ls "$repo_root"/build/dist/adou-*-darwin-arm64.tar.gz 2>/dev/null | head -n 1 || true)
fi
if [ -z "$tarball" ] || [ ! -f "$tarball" ]; then
    echo "e2e: release tarball not found (run make dist, or set ADOU_TARBALL): $tarball" >&2
    exit 2
fi

# External checksum: must exist next to the tarball, verify the archive
# before unpacking, and fail when the archive is tampered with.  The
# official build/dist tarball is READ-ONLY here: verification and the
# tamper check run against a copy in the temp dir.
checksum="$tarball.sha256"
if [ ! -f "$checksum" ]; then
    echo "e2e: external checksum missing: $checksum" >&2
    exit 2
fi
if ! (cd "$(dirname "$tarball")" && shasum -a 256 -c "$(basename "$checksum")") >/dev/null 2>&1; then
    echo "e2e: external checksum does not verify the tarball" >&2
    exit 1
fi
tarball_before=$(shasum -a 256 "$tarball" | awk '{print $1}')
tarball_copy="$tmp/$(basename "$tarball")"
cp "$tarball" "$tarball_copy"
cp "$checksum" "$tmp/"
if printf 'tampered' >> "$tarball_copy" 2>/dev/null; then
    if (cd "$tmp" && shasum -a 256 -c "$(basename "$checksum")") >/dev/null 2>&1; then
        echo "e2e: tampered tarball copy still verifies" >&2
        exit 1
    fi
else
    echo "e2e: could not tamper the tarball copy" >&2
    exit 1
fi
# The official artifact must be untouched.
if [ "$(shasum -a 256 "$tarball" | awk '{print $1}')" != "$tarball_before" ]; then
    echo "e2e: official tarball changed during the test" >&2
    exit 1
fi
rm -f "$tarball_copy" "$tmp/$(basename "$checksum")"


server_pid=

cleanup() {
    if [ -n "$server_pid" ]; then
        kill -9 "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
    echo "e2e: release artifact check failed: $*" >&2
    exit 1
}

# --- archive inventory -----------------------------------------------------

entries=$(tar -tzf "$tarball")
for forbidden in "tests/" "sessions/" "porting-plan" ".jsonl" "auth" "DEEPSEEK_API_KEY"; do
    if echo "$entries" | grep -q "$forbidden"; then
        fail "tarball contains forbidden entry matching '$forbidden':"$'\n'"$entries"
    fi
done

dist_dir=$(echo "$entries" | head -n 1 | tr -d '/')
case "$dist_dir" in
    adou-*-darwin-arm64) ;;
    *) fail "unexpected archive root: $dist_dir" ;;
esac
version=$(echo "$dist_dir" | sed 's/^adou-\(.*\)-darwin-arm64$/\1/')
if [ -z "$version" ]; then
    fail "could not derive version from archive root: $dist_dir"
fi

actual=$(echo "$entries" | sed "s|^$dist_dir/||" | grep -v '^$' | sort)
expected=$(printf 'RELEASE-README\nSHA256SUMS\nadou\nadou-process-group\nLICENSE\nTHIRD_PARTY_NOTICES.md\nNATURE-MIT-LICENSE.txt' | sort)
if [ "$actual" != "$expected" ]; then
    fail "archive file list is not the fixed set:"$'\n'"$(printf 'expected:\n%s\nactual:\n%s' "$expected" "$actual")"
fi

stage="$tmp/$dist_dir"
tar -xzf "$tarball" -C "$tmp"
if [ ! -x "$stage/adou" ] || [ ! -x "$stage/adou-process-group" ]; then
    fail "unpacked binaries missing or not executable"
fi

# --- manifest, README hygiene ---------------------------------------------

if ! (cd "$stage" && shasum -a 256 -c SHA256SUMS) >/dev/null; then
    fail "SHA256SUMS verification failed"
fi
if grep -Eq "sk-[A-Za-z0-9]{16,}|DEEPSEEK_API_KEY=[^ ]" "$stage/RELEASE-README"; then
    fail "RELEASE-README contains key material"
fi

# --- isolated environment --------------------------------------------------

export ADOU_CODING_AGENT_DIR="$tmp/agent"
export ADOU_SESSION_DIR="$tmp/sessions"
mkdir -p "$ADOU_CODING_AGENT_DIR" "$ADOU_SESSION_DIR"

# --- CLI smoke outside the repo cwd ---------------------------------------

version_out=$(cd "$stage" && ./adou --version)
if [ "$(echo "$version_out" | sed 's/^adou[[:space:]]*//')" != "$version" ]; then
    fail "--version printed '$version_out', expected 'adou $version'"
fi

help_out=$(cd "$stage" && ./adou --help)
if [ -z "$help_out" ]; then
    fail "--help printed nothing"
fi

# --- adjacent process-group helper discovery -------------------------------

# Prove runtime discovery without the environment variable: adou must find
# adou-process-group next to argv[0].  A real bash tool command must succeed
# and produce the Pi response shape.
adj_out=$(cd "$stage" && env -u ADOU_PROCESS_GROUP_HELPER sh -c '
    printf "%s\n" "{\"id\":\"b1\",\"type\":\"bash\",\"command\":\"printf adj-ok\"}" |
    ./adou --mode rpc --no-session --no-context-files \
        --provider deepseek --model deepseek-v4-flash --thinking off \
        --api-key dummy
')
adj_response=$(echo "$adj_out" | grep '"id":"b1"' | tail -n 1 || true)
case "$adj_response" in
    *'"success":true'*'"output":"adj-ok"'*) ;;
    *) fail "bash tool via adjacent helper failed: $adj_out" ;;
esac

# --- offline headless RPC smoke --------------------------------------------

rpc_out=$(python3 - "$stage/adou" <<'PY'
import json
import os
import subprocess
import sys
import time

binary = sys.argv[1]
env = os.environ.copy()
start = time.monotonic()
proc = subprocess.run(
    [binary, "--mode", "rpc", "--offline", "--no-session", "--no-context-files",
     "--provider", "deepseek", "--model", "deepseek-v4-flash", "--thinking", "off"],
    input='{"id":"r1","type":"prompt","message":"hi"}\n',
    capture_output=True, text=True, timeout=20, env=env,
)
elapsed = time.monotonic() - start
for line in proc.stdout.splitlines():
    if '"r1"' not in line:
        continue
    try:
        item = json.loads(line)
    except ValueError:
        continue
    if item.get("type") != "response" or item.get("command") != "prompt":
        continue
    if item.get("id") != "r1" or item.get("success") is not False or not item.get("error"):
        sys.exit(f"rpc offline prompt response shape wrong: {item!r}")
    break
else:
    sys.exit(f"rpc offline prompt did not answer id r1 in {elapsed:.1f}s: {proc.stdout!r}")
if elapsed > 15.0:
    sys.exit(f"rpc offline prompt must fail fast, took {elapsed:.1f}s")
if "sk-" in proc.stdout + proc.stderr:
    sys.exit("rpc smoke leaked a key-like string")
print("rpc-offline-smoke-ok")
PY
)
if [ "$rpc_out" != "rpc-offline-smoke-ok" ]; then
    fail "offline RPC smoke: $rpc_out"
fi

# --- RPC-over-IPC lifecycle -------------------------------------------------

ipc_out=$(python3 - "$stage/adou" <<'PY'
import json
import os
import shutil
import socket
import subprocess
import sys
import time

binary = sys.argv[1]
root = os.environ["ADOU_SESSION_DIR"]
port = 18952
proj = os.path.join(root, "proj-artifact")
os.makedirs(proj, exist_ok=True)

env = os.environ.copy()
proc = subprocess.Popen(
    [binary, "--serve-port", str(port), "--offline", "--no-context-files",
     "--provider", "deepseek", "--model", "deepseek-v4-flash", "--thinking", "off"],
    env=env,
)


def request(line, timeout=10.0):
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.sendall((line + "\n").encode())
        data = b""
        while b"\n" not in data:
            data += sock.recv(65536)
        return json.loads(data.split(b"\n")[0])


try:
    deadline = time.time() + 10
    while True:
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=1)
            sock.close()
            break
        except OSError:
            if time.time() > deadline:
                raise SystemExit("ipc server did not come up")
            time.sleep(0.1)

    spawn = request(json.dumps({"type": "spawn", "cwd": proj, "label": "artifact"}))
    if spawn.get("type") != "spawn_result" or spawn.get("ok") is not True:
        raise SystemExit(f"spawn failed: {spawn!r}")
    inst = spawn["instance"]
    if not inst.get("id") or inst.get("status") != "starting":
        raise SystemExit(f"spawn_result shape wrong: {spawn!r}")
    if inst.get("cwd") != proj or inst.get("label") != "artifact":
        raise SystemExit(f"spawn cwd/label wrong: {spawn!r}")
    if inst.get("sessionId"):
        raise SystemExit(f"starting instance must not report sessionId: {spawn!r}")

    deadline = time.time() + 10
    while True:
        status = request(json.dumps({"type": "status", "instanceId": inst["id"]}))
        if status.get("type") == "status_result" and status["instance"].get("status") == "online":
            break
        if time.time() > deadline:
            raise SystemExit(f"instance did not become online: {status!r}")
        time.sleep(0.05)
    if not status["instance"].get("sessionId"):
        raise SystemExit(f"online instance missing sessionId: {status!r}")

    stop = request(json.dumps({"type": "stop", "instanceId": inst["id"]}))
    if stop.get("type") != "stop_result" or stop.get("ok") is not True or stop.get("instanceId") != inst["id"]:
        raise SystemExit(f"stop failed: {stop!r}")

    status_after = request(json.dumps({"type": "status", "instanceId": inst["id"]}))
    if status_after.get("type") != "status_result" or status_after["instance"].get("status") != "stopped":
        raise SystemExit(f"stopped instance should report stopped: {status_after!r}")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

    deadline = time.time() + 2
    leftover = []
    while time.time() < deadline:
        out = subprocess.run(
            ["ps", "-axo", "pid=,command="], capture_output=True, text=True
        ).stdout
        leftover = [l for l in out.splitlines() if l.lstrip().startswith(binary)]
        if not leftover:
            break
        time.sleep(0.1)
    if leftover:
        raise SystemExit(f"leftover adou processes after server exit: {leftover}")

print("ipc-lifecycle-ok")
PY
)
if [ "$ipc_out" != "ipc-lifecycle-ok" ]; then
    fail "RPC-over-IPC lifecycle: $ipc_out"
fi

# --- Mach-O architecture and dynamic dependency audit ----------------------

for bin_name in adou adou-process-group; do
    bin_path="$stage/$bin_name"
    if ! file "$bin_path" | grep -q "arm64"; then
        fail "$bin_name is not an arm64 Mach-O: $(file "$bin_path")"
    fi
    deps=$(otool -L "$bin_path" | tail -n +2)
    if echo "$deps" | grep -qi "node\|bun\|quickjs\|v8"; then
        fail "$bin_name links a forbidden runtime: $deps"
    fi
    bad=$(echo "$deps" | grep -Ev '^[[:space:]]*/usr/lib/|^[[:space:]]*/System/' || true)
    if [ -n "$bad" ]; then
        fail "$bin_name has non-system dynamic dependencies: $bad"
    fi
done

# --- signing state consistency ---------------------------------------------
#
# The RELEASE-README declares an ad-hoc/linker-generated signature only
# (not Developer ID signed, not notarized).  The actual codesign state of
# every released binary must match: Signature=adhoc, TeamIdentifier not
# set (or absent), and no Authority lines.  An ad-hoc binary is never
# passed off as Developer ID signed; a real TeamIdentifier or Authority
# fails this check marked as "非 Developer ID".

for phrase in "ad-hoc/linker-generated signature" "not Developer ID signed" "not notarized"; do
    if ! grep -q "$phrase" "$stage/RELEASE-README"; then
        fail "RELEASE-README must declare '$phrase'"
    fi
done
# Gatekeeper guidance must be context-correct: run inside the unpacked
# directory (xattr -cr .), not a path that only exists outside it.
if ! grep -q "xattr -cr ." "$stage/RELEASE-README"; then
    fail "RELEASE-README must give the in-directory xattr -cr . guidance"
fi

for bin_name in adou adou-process-group; do
    bin_path="$stage/$bin_name"
    sig=$(codesign -d --verbose=4 "$bin_path" 2>&1 || true)
    case "$sig" in
        *'Signature=adhoc'*) ;;
        *) fail "$bin_name is not ad-hoc signed: $sig" ;;
    esac
    case "$sig" in
        *'TeamIdentifier=not set'*) ;;
        *'TeamIdentifier='*) fail "$bin_name carries a Developer ID TeamIdentifier while the release declares ad-hoc only (非 Developer ID): $sig" ;;
        *) ;;
    esac
    auth=$(echo "$sig" | grep '^Authority=' || true)
    if [ -n "$auth" ]; then
        fail "$bin_name has signing Authority while the release declares ad-hoc only (非 Developer ID): $auth"
    fi
done

echo "e2e: release artifact OK (archive, CLI, helper discovery, offline RPC, IPC lifecycle, Mach-O audit, signing consistency)"
