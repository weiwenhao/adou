#!/usr/bin/env python3
"""Pure-Python regressions for the shared PTY protocol (Batch 0 rework).

Env isolation: PtyCase execs with an exact allowlist env mapping. Sentinel
credentials/proxies injected into the PARENT environment must not reach the
child, while allowlisted entries (PATH carried, HOME/PI_CODING_AGENT_DIR/
TERM/locale fixed) must be present. The parent environment must not be
mutated by PtyCase.start.

Lifecycle: wait_exit reaps the child and clears self.pid so close() cannot
SIGKILL a reaped PID (no PID-reuse window); close() reliably kills and reaps
a still-running child.

Run: python3 pty_env_isolation_test.py
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pty_protocol import PtyCase, fixed_oracle_env  # noqa: E402

SENTINELS = {
    "DEEPSEEK_API_KEY": "sentinel-cred-deepseek",
    "ANTHROPIC_API_KEY": "sentinel-cred-anthropic",
    "OPENAI_API_KEY": "sentinel-cred-openai",
    "GITHUB_TOKEN": "sentinel-cred-github",
    "GH_TOKEN": "sentinel-cred-gh",
    "HF_TOKEN": "sentinel-cred-hf",
    "HTTP_PROXY": "http://sentinel-proxy.local:1",
    "HTTPS_PROXY": "https://sentinel-proxy.local:2",
    "ALL_PROXY": "sentinel-all-proxy",
    "NO_PROXY": "sentinel-no-proxy",
    "http_proxy": "http://sentinel-proxy.local:3",
    "https_proxy": "https://sentinel-proxy.local:4",
    "npm_config_registry": "https://sentinel-registry.local",
}


def _child_env(case: PtyCase) -> dict[str, str]:
    data = bytes(case.raw)
    entries = {}
    for item in data.split(b"\x00"):
        if not item:
            continue
        try:
            text = item.decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 - test code
            continue
        if "=" in text:
            key, _, value = text.partition("=")
            entries[key] = value
    return entries


def test_env_isolation() -> list[str]:
    failures: list[str] = []
    saved = {key: os.environ.get(key) for key in SENTINELS}
    os.environ.update(SENTINELS)
    try:
        fixture_home = "/tmp/pty-protocol-test-home"
        fixture_agent = "/tmp/pty-protocol-test-home/.pi/agent"
        env = fixed_oracle_env(fixture_home, agent_dir=fixture_agent)
        case = PtyCase(["/usr/bin/env", "-0"], env, "/tmp")
        case.start()
        case.drain(quiet=0.3, timeout=5.0)
        code = case.wait_exit(timeout=5.0)
        case.close()
        if code != 0:
            failures.append(f"env child exited {code}, want 0")
            return failures
        child = _child_env(case)
        for key in SENTINELS:
            if key in child:
                failures.append(f"sentinel {key} reached the child")
        if child.get("HOME") != fixture_home:
            failures.append(f"HOME={child.get('HOME')!r}, want {fixture_home!r}")
        if child.get("PI_CODING_AGENT_DIR") != fixture_agent:
            failures.append(f"PI_CODING_AGENT_DIR={child.get('PI_CODING_AGENT_DIR')!r}, want {fixture_agent!r}")
        for key, want in (("TERM", "xterm-256color"), ("LANG", "en_US.UTF-8"), ("LC_ALL", "en_US.UTF-8")):
            if child.get(key) != want:
                failures.append(f"{key}={child.get(key)!r}, want {want!r}")
        if "PATH" not in child:
            failures.append("PATH not carried into the child")
        for key in SENTINELS:
            if os.environ.get(key) != SENTINELS[key]:
                failures.append(f"parent env mutated for {key}")
        return failures
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_reaped_pid_never_killed() -> list[str]:
    """wait_exit must reap and clear pid; close() must then be a no-op."""
    failures: list[str] = []
    env = fixed_oracle_env("/tmp/pty-protocol-test-home")
    case = PtyCase(["/bin/sleep", "2"], env, "/tmp")
    case.start()
    code = case.wait_exit(timeout=8.0)
    if code != 0:
        failures.append(f"sleep exited {code}, want 0")
    if not case.reaped:
        failures.append("wait_exit did not mark the child reaped")
    if case.pid is not None:
        failures.append("wait_exit kept a reaped pid (PID-reuse kill window)")
    case.close()  # must not SIGKILL a reaped PID and must not raise
    return failures


def test_close_kills_running_child() -> list[str]:
    failures: list[str] = []
    env = fixed_oracle_env("/tmp/pty-protocol-test-home")
    case = PtyCase(["/bin/sleep", "30"], env, "/tmp")
    case.start()
    pid_before = case.pid
    case.close()
    if not case.reaped:
        failures.append("close() did not mark the child reaped")
    if case.pid is not None:
        failures.append("close() did not clear pid")
    try:
        os.kill(pid_before, 0)
        alive = True
    except ProcessLookupError:
        alive = False
    if alive:
        failures.append("child survived close() (kill+reap failed)")
    return failures


def test_exited_child_reaped_by_close() -> list[str]:
    """close() must also reap a child that exited but was never wait()ed."""
    failures: list[str] = []
    env = fixed_oracle_env("/tmp/pty-protocol-test-home")
    case = PtyCase(["/bin/true"], env, "/tmp")
    case.start()
    time.sleep(0.5)  # let the child exit; do NOT call wait_exit
    case.close()
    if not case.reaped:
        failures.append("close() did not reap the exited child")
    if case.pid is not None:
        failures.append("close() did not clear pid after reaping")
    return failures


def test_post_input_barrier_waits_for_output() -> list[str]:
    """B1-R5-01: drain_after_input must NOT return just because the stream
    was quiet BEFORE the input was written.  A child that delays its
    response (simulating render lag) must hold the barrier until its output
    actually arrives."""
    failures: list[str] = []
    env = fixed_oracle_env("/tmp/pty-protocol-test-home")
    # sh prints its first byte only after ~1.0s; the PTY is quiet before it.
    # stty -echo prevents the sent input from being echoed back (an echo
    # would count as post-mark output and defeat the fixture).
    case = PtyCase(["/bin/sh", "-c", "stty -echo; sleep 1; printf x"], env, "/tmp")
    case.start()
    time.sleep(0.3)  # the child is still sleeping: stream is quiet pre-input
    case.mark_input()
    case.send_bytes(b"ignored\n")  # not consumed, but marks the input batch
    started = time.time()
    # no_output_hold > the child's delay: the OUTPUT path must be what lets
    # the barrier through, not the hold.
    case.drain_after_input(quiet=0.2, timeout=6.0, no_output_hold=2.0)
    elapsed = time.time() - started
    case.wait_exit(timeout=6.0)
    case.close()
    # The barrier must not return before the delayed output (~1.0s) arrived.
    if elapsed < 0.7:
        failures.append(f"barrier returned early after {elapsed:.2f}s (pre-input quiet was treated as done)")
    return failures


def test_post_input_barrier_requires_post_mark_output() -> list[str]:
    """B1-R5-01: output that arrived BEFORE mark_input() must not satisfy
    the barrier instantly; only output beyond the mark (or the no-output
    hold with a live child) may pass it."""
    failures: list[str] = []
    env = fixed_oracle_env("/tmp/pty-protocol-test-home")
    case = PtyCase(["/bin/sh", "-c", "stty -echo; printf x; sleep 5"], env, "/tmp")
    case.start()
    deadline = time.time() + 5
    while time.time() < deadline and len(case.raw) == 0:
        case._read_available(0.05)
    if len(case.raw) == 0:
        failures.append("fixture child produced no initial output")
        case.close()
        return failures
    # The initial output already arrived; a new mark after it must NOT pass
    # the barrier just because the raw buffer is non-empty — the hold is the
    # only thing that may pass it, and only after the hold window.
    case.mark_input()
    case.send_bytes(b"ignored\n")
    started = time.time()
    case.drain_after_input(quiet=0.1, timeout=2.0, no_output_hold=0.5)
    elapsed = time.time() - started
    case.close()
    if elapsed < 0.35:
        failures.append(f"barrier passed on stale pre-mark output after only {elapsed:.2f}s")
    return failures


def test_post_input_barrier_noop_hold_passes_live_child() -> list[str]:
    """B1-R5-01: a genuinely no-op batch (no output at all, e.g. a page key
    on a one-line editor) must pass the barrier after the short hold — but
    only while the child is confirmed alive."""
    failures: list[str] = []
    env = fixed_oracle_env("/tmp/pty-protocol-test-home")
    case = PtyCase(["/bin/sh", "-c", "stty -echo; sleep 5"], env, "/tmp")
    case.start()
    time.sleep(0.3)
    case.mark_input()
    case.send_bytes(b"ignored\n")
    started = time.time()
    case.drain_after_input(quiet=0.5, timeout=3.0, no_output_hold=0.2)
    elapsed = time.time() - started
    case.close()
    if elapsed > 2.5:
        failures.append(f"no-op hold took too long ({elapsed:.2f}s)")
    return failures


def test_post_input_barrier_child_exit_not_swallowed() -> list[str]:
    """B1-R5-01: a child that exits during the no-output hold must surface
    as a failure, never be swallowed by the hold."""
    failures: list[str] = []
    env = fixed_oracle_env("/tmp/pty-protocol-test-home")
    case = PtyCase(["/bin/sh", "-c", "stty -echo; exit 3"], env, "/tmp")
    case.start()
    time.sleep(0.5)  # the child has already exited; no output was emitted
    case.mark_input()
    from pty_protocol import PtyTimeout  # noqa: E402

    try:
        case.drain_after_input(quiet=0.5, timeout=3.0, no_output_hold=0.2)
        failures.append("barrier passed for a dead child")
    except PtyTimeout:
        pass  # expected: the hold refuses to pass a dead child
    case.close()
    return failures


def main() -> int:
    failures: list[str] = []

    for name, fn in (
        ("env isolation", test_env_isolation),
        ("reaped pid never killed", test_reaped_pid_never_killed),
        ("close kills running child", test_close_kills_running_child),
        ("close reaps exited child", test_exited_child_reaped_by_close),
        ("post-input barrier waits for output", test_post_input_barrier_waits_for_output),
        ("post-input barrier requires post-mark output", test_post_input_barrier_requires_post_mark_output),
        ("post-input barrier no-op hold passes live child", test_post_input_barrier_noop_hold_passes_live_child),
        ("post-input barrier child exit not swallowed", test_post_input_barrier_child_exit_not_swallowed),
    ):
        errors = fn()
        if errors:
            print(f"pty_env_isolation FAILED [{name}]:")
            for error in errors:
                print(" -", error)
            failures.extend(errors)
        else:
            print(f"pty_env_isolation OK [{name}]")
    if failures:
        return 1
    print("pty_env_isolation self-test OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
