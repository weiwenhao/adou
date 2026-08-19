#!/bin/sh
set -eu

binary=${ADOU_BIN:-$(CDPATH= cd -- "$(dirname -- "$0")/../../build/bin" && pwd)/adou}
if [ ! -x "$binary" ]; then
    echo "e2e: Adou binary not found: $binary" >&2
    exit 2
fi

ADOU_BIN="$binary" python3 - <<'PY'
import http.server
import json
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time

binary = os.path.realpath(os.environ["ADOU_BIN"])
root = tempfile.mkdtemp(prefix="adou-radius-presence-")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class RadiusState:
    def __init__(self):
        self.lock = threading.Lock()
        self.machine_registers = []
        self.pi_registers = []
        self.machine_one_not_found = 0
        self.pi_one_not_found = 0
        self.pi_disconnects = []
        self.errors = []

    def handle(self, path, body, authorization):
        with self.lock:
            if authorization != "Bearer radius-presence-key":
                self.errors.append(f"wrong authorization for {path}: {authorization!r}")
                return 401, {"error": "unauthorized"}

            if path == "/v1/machines/register":
                required = {"machineId", "label", "hostname", "platform", "arch", "version", "capabilities"}
                if not required.issubset(body):
                    self.errors.append(f"machine registration missing fields: {body!r}")
                expected_existing = "" if not self.machine_registers else "machine-1"
                if body.get("machineId", "") != expected_existing:
                    self.errors.append(f"machine registration did not reuse id: {body!r}")
                self.machine_registers.append(body)
                index = len(self.machine_registers)
                return 200, {
                    "id": f"machine-{index}",
                    "heartbeatIntervalMs": 25,
                    "expiresInMs": 1000,
                }

            if path == "/v1/pis/register":
                required = {
                    "machineId", "label", "cwd", "hostname", "pid",
                    "transport", "capabilities", "sessionId",
                }
                if not required.issubset(body):
                    self.errors.append(f"Pi registration missing fields: {body!r}")
                if body.get("machineId") not in {"machine-1", "machine-2"}:
                    self.errors.append(f"Pi registration used unknown machine: {body!r}")
                if body.get("transport") != "local-rpc":
                    self.errors.append(f"Pi registration transport mismatch: {body!r}")
                self.pi_registers.append(body)
                index = len(self.pi_registers)
                return 200, {
                    "id": f"pi-{index}",
                    "heartbeatIntervalMs": 25,
                    "expiresInMs": 1000,
                }

            if path == "/v1/machines/machine-1/heartbeat":
                # First exercise Pi recovery, then expire the machine and
                # require it to restore the live instance.
                if len(self.pi_registers) >= 2 and self.machine_one_not_found < 3:
                    self.machine_one_not_found += 1
                    return 404, {"error": "machine expired"}
                return 200, {}

            if path == "/v1/machines/machine-2/heartbeat":
                expected_cwd = os.path.join(root, "server")
                if body.get("cwd") != expected_cwd:
                    self.errors.append(f"machine heartbeat cwd mismatch: {body!r}")
                if body.get("socketPath") != os.path.join(expected_cwd, "server.sock"):
                    self.errors.append(f"machine heartbeat socket mismatch: {body!r}")
                return 200, {}

            if path == "/v1/pis/pi-1/heartbeat" and self.pi_one_not_found < 3:
                self.pi_one_not_found += 1
                return 404, {"error": "Pi expired"}

            if path.startswith("/v1/pis/") and path.endswith("/heartbeat"):
                return 200, {}

            if path.startswith("/v1/pis/") and path.endswith("/disconnect"):
                self.pi_disconnects.append(path.split("/")[-2])
                return 200, {}

            if path.startswith("/v1/machines/") and path.endswith("/disconnect"):
                return 200, {}

            self.errors.append(f"unexpected Radius endpoint: {path}")
            return 404, {"error": "unexpected endpoint"}


state = RadiusState()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception as error:
            state.errors.append(f"invalid JSON for {self.path}: {error}")
            body = {}
        status, response = state.handle(
            self.path, body, self.headers.get("Authorization", "")
        )
        encoded = json.dumps(response).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, _format, *_args):
        pass


radius_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
radius_port = radius_server.server_address[1]
radius_thread = threading.Thread(target=radius_server.serve_forever, daemon=True)
radius_thread.start()

serve_port = free_port()
project = os.path.join(root, "project")
os.makedirs(project)
os.makedirs(os.path.join(root, "server"))
with open(os.path.join(root, "server", "instances.json"), "w", encoding="utf-8") as seed:
    json.dump(
        [
            {
                "id": "restored-instance",
                "status": "online",
                "cwd": project,
                "label": "restored",
                "sessionId": "restored-session",
                "sessionFile": os.path.join(root, "sessions", "restored.jsonl"),
                "radiusPiId": "stale-pi",
                "createdAt": 1,
                "lastSeenAt": 1,
            }
        ],
        seed,
    )
env = os.environ.copy()
env.update(
    {
        "ADOU_CODING_AGENT_DIR": os.path.join(root, "agent"),
        "ADOU_SESSION_DIR": os.path.join(root, "sessions"),
        "ADOU_SERVER_DIR": os.path.join(root, "server"),
        "ADOU_RADIUS_SERVER_URL": f"http://127.0.0.1:{radius_port}/v1",
        "ADOU_RADIUS_ENABLED": "1",
        "RADIUS_API_KEY": "radius-presence-key",
        "DEEPSEEK_API_KEY": "sk-radius-presence-test",
    }
)
proc = subprocess.Popen(
    [
        binary, "--serve-port", str(serve_port), "--offline",
        "--no-context-files", "--provider", "deepseek",
        "--model", "deepseek-v4-flash", "--thinking", "off",
    ],
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    start_new_session=True,
)


def request(payload, timeout=5.0):
    with socket.create_connection(("127.0.0.1", serve_port), timeout=timeout) as sock:
        sock.sendall((json.dumps(payload) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                raise RuntimeError(f"IPC server closed before replying: {data!r}")
            data += chunk
        return json.loads(data.split(b"\n", 1)[0])


def wait_until(predicate, description, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        if proc.poll() is not None:
            stdout, stderr = proc.communicate()
            raise RuntimeError(
                f"Adou server exited while waiting for {description}\nstdout={stdout}\nstderr={stderr}"
            )
        time.sleep(0.025)
    raise RuntimeError(f"timed out waiting for {description}")


instance_id = ""
try:
    deadline = time.time() + 10
    while True:
        try:
            response = request({"type": "spawn", "cwd": project, "label": "radius-e2e"})
            break
        except OSError:
            if time.time() >= deadline:
                raise
            time.sleep(0.05)
    if response.get("type") != "spawn_result" or response.get("ok") is not True:
        raise RuntimeError(f"spawn failed: {response!r}")
    instance_id = response["instance"]["id"]

    def online():
        response = request({"type": "status", "instanceId": instance_id})
        return response.get("instance", {}).get("status") == "online"

    wait_until(online, "local Pi to become online")

    def recovered():
        with state.lock:
            return (
                len(state.machine_registers) >= 2
                and len(state.pi_registers) >= 3
                and state.machine_one_not_found >= 3
                and state.pi_one_not_found >= 3
            )

    wait_until(recovered, "machine and Pi 404 recovery")

    instances_path = os.path.join(root, "server", "instances.json")

    def persisted_new_pi_id():
        try:
            with open(instances_path, encoding="utf-8") as handle:
                records = json.load(handle)
        except (OSError, json.JSONDecodeError):
            return False
        return any(
            record.get("id") == instance_id and record.get("radiusPiId") == "pi-3"
            for record in records
        )

    wait_until(persisted_new_pi_id, "recovered Radius Pi id persistence")

    stopped = request({"type": "stop", "instanceId": instance_id})
    if stopped.get("type") != "stop_result" or stopped.get("ok") is not True:
        raise RuntimeError(f"stop failed: {stopped!r}")

    def disconnected():
        with state.lock:
            return "stale-pi" in state.pi_disconnects and "pi-3" in state.pi_disconnects

    wait_until(disconnected, "recovered Pi disconnect")

    with state.lock:
        if state.errors:
            raise RuntimeError("; ".join(state.errors))
        if len(state.machine_registers) != 2:
            raise RuntimeError(f"machine registration count mismatch: {len(state.machine_registers)}")
        if len(state.pi_registers) != 3:
            raise RuntimeError(f"Pi registration count mismatch: {len(state.pi_registers)}")
        if state.pi_registers[-1].get("machineId") != "machine-2":
            raise RuntimeError(f"machine recovery did not restore Pi: {state.pi_registers!r}")
finally:
    if instance_id and proc.poll() is None:
        try:
            request({"type": "stop", "instanceId": instance_id}, timeout=1)
        except Exception:
            pass
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=3)
    radius_server.shutdown()
    radius_server.server_close()
    shutil.rmtree(root, ignore_errors=True)

print("e2e: Radius machine/Pi heartbeat, 404 recovery and disconnect pass")
PY
