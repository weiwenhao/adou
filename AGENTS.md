# AGENTS.md

- Do not preserve backward compatibility.

## Project overview

This is a small project written in the Nature programming language.

- `main.n` is the current program entry point.
- `vendors/nature_cases/` contains Nature syntax and usage examples. Consult it when syntax is unclear.
- `main` is a generated executable produced by the compiler; do not edit it manually.

Nature is already installed in the development environment. Do not add compiler installation or bootstrap steps unless explicitly requested.

## Build and run

From the repository root, use the Make workflow. Make serializes the
memory-heavy Nature compiler and invokes Nature's own test runner for unit
tests:

```sh
make build
make run
make test
make e2e
```

`make build` produces `build/bin/adou`; a successful build exits with status
0 and may produce no terminal output. Use `make clean` to remove generated
artifacts. Do not introduce a second build system or an external test
harness for this project.

Nature compiler and test invocations must never run concurrently. This rule
applies across all agents and command sessions: do not use `Promise.all`,
background jobs, `xargs -P`, `make -j`, or multiple agents to invoke `nature`
at the same time. Run Nature work serially through the Make workflow (or one
guarded invocation at a time) because the compiler is memory-heavy and
concurrent invocations can corrupt generated artifacts and exhaust the host.

## Working guidelines

- Keep changes focused on the requested task.
- Follow the syntax and conventions demonstrated in `vendors/nature_cases/`.
- Do not run or depend on `nature fmt`. Write valid Nature syntax directly from the examples in `vendors/nature_cases/`, and do not track formatter-only defects as Adou blockers.
- Prefer editing Nature source files (`*.n`) instead of generated binaries.
- After changing Nature source code, run `make build` (or the relevant
  `make test` target) for the affected entry point.
- Do not run the full `make test` suite unless the task explicitly requires
  it: a full run takes ~2 hours and can exhaust the machine. Prefer targeted
  single-file tests, e.g.
  `NATURE_EXECUTABLE=/usr/local/nature/bin/nature ./scripts/nature-build-safe.sh test <absolute path to tests/xxx_test.n>`.
- When practical, run the generated executable and verify its observable output.
- Do not modify files under `vendors/` unless the task explicitly requires it.
