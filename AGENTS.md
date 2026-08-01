# AGENTS.md

## Project overview

This is a small project written in the Nature programming language.

- `main.n` is the current program entry point.
- `vendors/nature_cases/` contains Nature syntax and usage examples. Consult it when syntax is unclear.
- `main` is a generated executable produced by the compiler; do not edit it manually.

Nature is already installed in the development environment. Do not add compiler installation or bootstrap steps unless explicitly requested.

## Build and run

From the repository root:

```sh
nature build main.n
./main
```

A successful build exits with status 0 and may produce no terminal output.

## Working guidelines

- Keep changes focused on the requested task.
- Follow the syntax and conventions demonstrated in `vendors/nature_cases/`.
- Do not run or depend on `nature fmt`. Write valid Nature syntax directly from the examples in `vendors/nature_cases/`, and do not track formatter-only defects as Adou blockers.
- Prefer editing Nature source files (`*.n`) instead of generated binaries.
- After changing Nature source code, run `nature build` for the affected entry point.
- When practical, run the generated executable and verify its observable output.
- Do not modify files under `vendors/` unless the task explicitly requires it.
