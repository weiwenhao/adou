#!/bin/sh
set -eu

# Phase 7.1 RPC-over-IPC e2e: line-delimited JSON over a localhost TCP socket
# with the upstream packages/server ipc protocol shapes (spawn_result/
# list_result/status_result/stop_result/rpc_result/rpc_ready/error).  Two
# spawned instances must be fully isolated: distinct ids/cwd/label, per-id
# status and rpc routing, stop A leaves B online, unknown ids error, and an
# rpc_stream connection answers a sequence of commands on one connection
# before closing.  Offline prompt rejection is preserved.
binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

ADOU_BIN="$binary" python3 - <<'PY'
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

binary = os.path.realpath(os.environ["ADOU_BIN"])
root = tempfile.mkdtemp(prefix="adou-ipc-")
port = 18951

env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
        "DEEPSEEK_API_KEY": "sk-ipc-test",
    }
)
os.makedirs(os.path.join(root, "agent"), exist_ok=True)

proj_a = os.path.join(root, "proj-a")
proj_b = os.path.join(root, "proj-b")
os.makedirs(proj_a, exist_ok=True)
os.makedirs(proj_b, exist_ok=True)

proc = subprocess.Popen(
    [binary, "--serve-port", str(port), "--offline", "--no-context-files", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--thinking", "off"],
    env=env,
)


def request(line, timeout=10.0):
    # Non-stream requests are answered with one framed line, then the
    # server closes the connection.
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.sendall((line + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                raise SystemExit(f"server closed before replying; got: {data!r}")
            data += chunk
        return json.loads(data.split(b"\n")[0])


def recv_line(sock):
    data = b""
    while b"\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            raise SystemExit(f"connection closed while reading line; got: {data!r}")
        data += chunk
    return json.loads(data.split(b"\n")[0])


def send_line(sock, line):
    sock.sendall((line + "\n").encode())


def wait_online(instance_id, timeout=10.0):
    deadline = time.time() + timeout
    while True:
        resp = request(json.dumps({"type": "status", "instanceId": instance_id}))
        if resp.get("type") == "status_result" and resp["instance"].get("status") == "online":
            return resp["instance"]
        if time.time() > deadline:
            raise SystemExit(f"instance {instance_id} did not become online: {resp!r}")
        time.sleep(0.05)


def child_pids():
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True
    ).stdout
    result = set()
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        pid, ppid, command = fields
        if int(ppid) == proc.pid and command.startswith(binary + " ") and "--mode rpc" in command:
            result.add(int(pid))
    return result


def wait_child_pids(expected_count, timeout=5.0):
    deadline = time.time() + timeout
    while True:
        current = child_pids()
        if len(current) == expected_count:
            return current
        if time.time() > deadline:
            raise SystemExit(
                f"expected {expected_count} RPC child processes, got {sorted(current)}"
            )
        time.sleep(0.05)


def assert_session_cwd(instance, expected_cwd):
    canonical_cwd = os.path.realpath(expected_cwd)
    session_file = instance.get("sessionFile")
    # B2.3 deferred flush: until the child's first assistant entry the JSONL
    # file does not exist yet (Pi _persist); the coordinator summary still
    # carries the child's spawn cwd for verification.
    if not session_file or not os.path.exists(session_file):
        reported = instance.get("cwd") or ""
        if os.path.realpath(reported) != canonical_cwd:
            raise SystemExit(
                f"RPC child did not enter requested cwd {canonical_cwd!r}: {instance!r}"
            )
        return
    with open(session_file, encoding="utf-8") as handle:
        header = json.loads(handle.readline())
    if header.get("cwd") != canonical_cwd:
        raise SystemExit(
            f"RPC child did not enter requested cwd {canonical_cwd!r}: {header!r}"
        )


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

    # Two spawns: distinct ids, cwd, label.  Spawn answers synchronously with
    # the starting state; status polling observes the transition to online.
    spawn_a = request(json.dumps({"type": "spawn", "cwd": proj_a, "label": "alpha"}))
    if spawn_a.get("type") != "spawn_result" or spawn_a.get("ok") is not True:
        raise SystemExit(f"spawn A failed: {spawn_a!r}")
    inst_a = spawn_a["instance"]
    if not inst_a.get("id") or inst_a.get("status") != "starting":
        raise SystemExit(f"spawn A summary wrong: {spawn_a!r}")
    if inst_a.get("cwd") != proj_a or inst_a.get("label") != "alpha":
        raise SystemExit(f"spawn A cwd/label wrong: {spawn_a!r}")
    if "sessionId" in inst_a:
        raise SystemExit(f"spawn A must not report sessionId while starting: {spawn_a!r}")
    online_a = wait_online(inst_a["id"])
    if not online_a.get("sessionId"):
        raise SystemExit(f"online instance A missing sessionId: {online_a!r}")
    assert_session_cwd(online_a, proj_a)
    children_after_a = wait_child_pids(1)
    pid_a = next(iter(children_after_a))

    spawn_b = request(json.dumps({"type": "spawn", "cwd": proj_b, "label": "beta"}))
    if spawn_b.get("type") != "spawn_result" or spawn_b.get("ok") is not True:
        raise SystemExit(f"spawn B failed: {spawn_b!r}")
    inst_b = spawn_b["instance"]
    if inst_b.get("id") == inst_a.get("id"):
        raise SystemExit(f"spawn returned the same id twice: {inst_a.get('id')}")
    if inst_b.get("cwd") != proj_b or inst_b.get("label") != "beta":
        raise SystemExit(f"spawn B cwd/label wrong: {spawn_b!r}")
    online_b = wait_online(inst_b["id"])
    assert_session_cwd(online_b, proj_b)
    children_after_b = wait_child_pids(2)
    new_children = children_after_b - children_after_a
    if len(new_children) != 1:
        raise SystemExit(
            f"spawn B did not create one distinct RPC child: before={children_after_a}, after={children_after_b}"
        )
    pid_b = next(iter(new_children))
    id_a, id_b = inst_a["id"], inst_b["id"]
    sess_a, sess_b = online_a["sessionId"], online_b["sessionId"]
    # B2.3 deferred flush: without an assistant entry the children's session
    # files stay unmaterialized (Pi _persist); the coordinator itself must
    # never own a session file either.
    session_files = [
        name
        for name in os.listdir(os.path.join(root, "sessions"))
        if name.endswith(".jsonl")
    ]
    if session_files:
        raise SystemExit(
            f"server coordinator or idle children flushed a session file: {session_files!r}"
        )

    # list: two instances with both ids.
    listed = request('{"type":"list"}')
    if listed.get("type") != "list_result" or listed.get("ok") is not True:
        raise SystemExit(f"list failed: {listed!r}")
    ids = [i["id"] for i in listed.get("instances", [])]
    if sorted(ids) != sorted([id_a, id_b]):
        raise SystemExit(f"list instances wrong: {listed!r}")

    # status routes per instanceId.
    status_a = request(json.dumps({"type": "status", "instanceId": id_a}))
    if status_a.get("type") != "status_result" or status_a["instance"]["cwd"] != proj_a or status_a["instance"]["label"] != "alpha":
        raise SystemExit(f"status A wrong: {status_a!r}")
    status_b = request(json.dumps({"type": "status", "instanceId": id_b}))
    if status_b.get("type") != "status_result" or status_b["instance"]["cwd"] != proj_b or status_b["instance"]["label"] != "beta":
        raise SystemExit(f"status B wrong: {status_b!r}")

    # rpc get_state routes per instanceId (non-network command).
    state_a = request(json.dumps({"type": "rpc", "instanceId": id_a, "command": {"type": "get_state", "id": "g-a"}}))
    if state_a.get("type") != "rpc_result" or state_a.get("ok") is not True:
        raise SystemExit(f"rpc get_state A failed: {state_a!r}")
    resp_a = state_a["response"]
    if resp_a.get("command") != "get_state" or resp_a.get("success") is not True or resp_a.get("id") != "g-a":
        raise SystemExit(f"rpc get_state A response wrong: {state_a!r}")
    if resp_a.get("data", {}).get("sessionId") != sess_a:
        raise SystemExit(f"rpc get_state A routed to wrong instance: {state_a!r}")
    state_b = request(json.dumps({"type": "rpc", "instanceId": id_b, "command": {"type": "get_state", "id": "g-b"}}))
    if state_b.get("response", {}).get("data", {}).get("sessionId") != sess_b:
        raise SystemExit(f"rpc get_state B routed to wrong instance: {state_b!r}")
    if state_a.get("response", {}).get("data", {}).get("sessionId") == state_b.get("response", {}).get("data", {}).get("sessionId"):
        raise SystemExit("instances share the same session; isolation broken")

    # Pi's process bridge allocates an id when clients omit one.
    generated = request(
        json.dumps(
            {"type": "rpc", "instanceId": id_a, "command": {"type": "get_state"}}
        )
    )
    generated_id = generated.get("response", {}).get("id", "")
    if not generated_id.startswith("server_"):
        raise SystemExit(f"server-generated RPC id missing: {generated!r}")

    # Multiple IPC clients can have requests pending against either child at
    # once.  Responses must stay associated with their command ids and their
    # target instance session.
    def concurrent_state(index):
        target_id, target_session = (id_a, sess_a) if index % 2 == 0 else (id_b, sess_b)
        command_id = f"parallel-{index}"
        response = request(
            json.dumps(
                {
                    "type": "rpc",
                    "instanceId": target_id,
                    "command": {"type": "get_state", "id": command_id},
                }
            )
        )
        return command_id, target_session, response

    with ThreadPoolExecutor(max_workers=8) as pool:
        parallel_results = list(pool.map(concurrent_state, range(24)))
    for command_id, target_session, response in parallel_results:
        child_response = response.get("response", {})
        if child_response.get("id") != command_id:
            raise SystemExit(
                f"concurrent response id mismatch for {command_id}: {response!r}"
            )
        if child_response.get("data", {}).get("sessionId") != target_session:
            raise SystemExit(
                f"concurrent response crossed instance boundary for {command_id}: {response!r}"
            )

    # Unknown instance ids error for status/rpc/rpc_stream.
    for kind in ("status", "rpc", "rpc_stream"):
        line = json.dumps({"type": kind, "instanceId": "nope"})
        if kind == "rpc":
            line = json.dumps({"type": "rpc", "instanceId": "nope", "command": {"type": "get_state", "id": "x"}})
        resp = request(line)
        if resp.get("type") != "error" or resp.get("ok") is not False or "Unknown instance" not in resp.get("error", ""):
            raise SystemExit(f"unknown id for {kind} should error: {resp!r}")

    # Offline prompt rejection preserved through the rpc bridge, and it must
    # fail fast: the bridge no longer waits out a fixed 30s budget.
    t0 = time.time()
    offline = request(json.dumps({"type": "rpc", "instanceId": id_a, "command": {"type": "prompt", "id": "p1", "message": "hello"}}))
    elapsed = time.time() - t0
    if offline.get("type") != "rpc_result" or offline.get("response", {}).get("success") is not False or "Offline mode" not in offline.get("response", {}).get("error", ""):
        raise SystemExit(f"offline prompt should be rejected: {offline!r}")
    if elapsed > 5.0:
        raise SystemExit(f"offline prompt must fail fast instead of waiting, took {elapsed:.1f}s: {offline!r}")

    # rpc_stream: one connection, rpc_ready first, then two consecutive
    # non-network commands, then the extension guard, then close.
    stream = socket.create_connection(("127.0.0.1", port), timeout=10)
    send_line(stream, json.dumps({"type": "rpc_stream", "instanceId": id_b}))
    ready = recv_line(stream)
    if ready.get("type") != "rpc_ready" or ready.get("ok") is not True or ready.get("instance", {}).get("id") != id_b:
        raise SystemExit(f"rpc_stream ready wrong: {ready!r}")
    send_line(stream, json.dumps({"type": "get_state", "id": "s1"}))
    resp1 = recv_line(stream)
    if resp1.get("type") != "response" or resp1.get("command") != "get_state" or resp1.get("success") is not True:
        raise SystemExit(f"rpc_stream first command wrong: {resp1!r}")
    send_line(stream, json.dumps({"type": "get_last_assistant_text", "id": "s2"}))
    resp2 = recv_line(stream)
    if resp2.get("type") != "response" or resp2.get("command") != "get_last_assistant_text" or resp2.get("success") is not True:
        raise SystemExit(f"rpc_stream second command wrong: {resp2!r}")
    send_line(stream, json.dumps({"type": "extension_ui_response", "id": "s3", "requestId": "r1", "data": {}}))
    guard = recv_line(stream)
    if guard.get("type") != "error" or guard.get("ok") is not False or guard.get("error") != "extensions disabled":
        raise SystemExit(f"extension_ui_response should be deterministically refused: {guard!r}")
    stream.close()

    # Stop A; B must remain online and A stays observable as 'stopped'.
    stop_a = request(json.dumps({"type": "stop", "instanceId": id_a}))
    if stop_a.get("type") != "stop_result" or stop_a.get("ok") is not True or stop_a.get("instanceId") != id_a:
        raise SystemExit(f"stop A failed: {stop_a!r}")
    remaining_children = wait_child_pids(1)
    if remaining_children != {pid_b} or pid_a in remaining_children:
        raise SystemExit(
            f"stop A must reap only child A: pid_a={pid_a}, pid_b={pid_b}, remaining={remaining_children}"
        )
    status_b = request(json.dumps({"type": "status", "instanceId": id_b}))
    if status_b.get("type") != "status_result" or status_b["instance"]["id"] != id_b:
        raise SystemExit(f"stop A broke B: {status_b!r}")
    status_a = request(json.dumps({"type": "status", "instanceId": id_a}))
    if status_a.get("type") != "status_result" or status_a["instance"].get("status") != "stopped":
        raise SystemExit(f"stopped instance should report status 'stopped': {status_a!r}")
    stop_a_again = request(json.dumps({"type": "stop", "instanceId": id_a}))
    if stop_a_again.get("type") != "stop_result" or stop_a_again.get("ok") is not True:
        raise SystemExit(f"stopping a stopped instance must be idempotent: {stop_a_again!r}")

    # rpc/rpc_stream on a stopped instance error with 'not running'.
    rpc_stopped = request(json.dumps({"type": "rpc", "instanceId": id_a, "command": {"type": "get_state", "id": "g-dead"}}))
    if rpc_stopped.get("type") != "error" or rpc_stopped.get("ok") is not False or "not running" not in rpc_stopped.get("error", ""):
        raise SystemExit(f"rpc on a stopped instance must error: {rpc_stopped!r}")
    stream_dead = socket.create_connection(("127.0.0.1", port), timeout=10)
    send_line(stream_dead, json.dumps({"type": "rpc_stream", "instanceId": id_a}))
    dead_ready = recv_line(stream_dead)
    if dead_ready.get("type") != "error" or "not running" not in dead_ready.get("error", ""):
        raise SystemExit(f"rpc_stream on a stopped instance must error: {dead_ready!r}")
    stream_dead.close()

    listed = request('{"type":"list"}')
    listed_by_id = {i["id"]: i.get("status") for i in listed.get("instances", [])}
    if listed_by_id != {id_a: "stopped", id_b: "online"}:
        raise SystemExit(f"list after stop wrong: {listed!r}")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

    # Parent stdin closure must terminate every surviving RPC child.  Check
    # both the known child PID and the executable command line so an orphaned
    # replacement cannot hide behind a changed PID.
    deadline = time.time() + 5
    leftover = []
    while time.time() < deadline:
        out = subprocess.run(
            ["ps", "-axo", "pid=,command="], capture_output=True, text=True
        ).stdout
        leftover = []
        for line in out.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) == 2 and fields[1].startswith(binary):
                leftover.append(line)
        if not leftover:
            break
        time.sleep(0.1)
    if leftover:
        raise SystemExit(f"leftover adou processes after server exit: {leftover}")
    shutil.rmtree(root, ignore_errors=True)
PY

echo "e2e: RPC-over-IPC multi-instance lifecycle and rpc_stream pass"
