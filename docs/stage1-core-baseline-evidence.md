# Stage 1 Core Agent Baseline Evidence

Date: 2026-08-19

Baseline commit: `f22777b491363010b8e50c3a2452f053ef53e0e8`

## Scope

Stage 1 freezes the regression baseline for provider and agent-loop behavior,
built-in tools, sessions, compaction, CLI/config/context, skills, IPC/RPC, and
the deterministic eval harness. Interactive/TUI parity remains Stage 2 work.

## Nature Tests

The following targeted files were executed serially through
`scripts/nature-build-safe.sh`:

- `agent_loop_test.n`: 17/17
- `tools_test.n`: 24/24
- `builtins_test.n`: 3/3
- `session_test.n`: 27/27
- `session_actions_test.n`: 2/2
- `session_search_test.n`: 7/7
- `compaction_test.n`: 15/15
- `compaction_retained_tail_test.n`: 1/1
- `config_context_test.n`: 25/25
- `skills_test.n`: 22/22
- `ipc_protocol_test.n`: 8/8
- `rpc_process_test.n`: 2/2

Total: 153/153.

The full `make test` suite was intentionally not run, following the repository
rule that reserves the roughly two-hour full suite for explicit requests.

## Integration Gates

- `make e2e`: 58/58 offline scripts passed.
- Slash-menu evidence: three runs passed semantic assertions, produced
  identical normalized screens, and exited with status 0.
- `make eval`: 3/3 deterministic eval cases passed.
- `git diff --check`: passed before the stage commit.

The first `make e2e` attempt stopped at `rpc-over-ipc.sh` because its leftover
process audit correctly found the intentional Herdr Batch 7 Adou process in
`w7:pE`. That process was exited normally with `/quit`; the complete 58-script
suite was then rerun from the beginning and passed. The pane was restored with
the same build, debug options, cwd, and session directory after the gate.

No provider credential was printed or added to the repository. The pre-existing
`vendors/pi/packages/coding-agent/test/fixtures/before-compaction.jsonl` change
is outside this stage and is not included in the Adou commit.
