# Adou

A Pi-derived coding agent implemented in the Nature programming language.
Adou runs a single native binary — no Node.js, no npm, no runtime
dependencies beyond macOS system libraries.

Source repository: <https://github.com/weiwenhao/adou>

## Install (macOS arm64, unsigned direct distribution)

1. Download `adou-<version>-darwin-arm64.tar.gz` from the GitHub Releases
   page for this repository.
2. Verify the archive before unpacking:

   ```sh
   cd <download-directory>
   shasum -a 256 -c adou-<version>-darwin-arm64.tar.gz.sha256
   ```

   The `.sha256` file is published next to the archive and its contents are
   verified by the release artifact test suite.
3. Unpack and run:

   ```sh
   tar -xzf adou-<version>-darwin-arm64.tar.gz
   cd adou-<version>-darwin-arm64
   ./adou --version
   ```

   The archive contains `adou`, `adou-process-group` (a helper that must
   stay next to the main binary), `RELEASE-README`, and `SHA256SUMS`.
4. macOS Gatekeeper may block the unsigned binary on first launch:

   ```sh
   xattr -cr ./adou
   ```

   The binaries carry only a linker-generated ad-hoc signature; they are
   **not** Developer ID signed and **not** notarized. Developer ID signing
   and notarization are optional future enhancements, not a release
   blocker for this distribution channel.

## Usage

- Interactive terminal UI: run `adou` in a TTY (first run shows a setup
  prompt; credentials come from `DEEPSEEK_API_KEY` or `/login`).
- One-shot: `adou --print "your prompt"`.
- JSON/RPC over stdin: `adou --mode json|rpc`.
- RPC over IPC: `adou --serve-port <port>` (line-delimited JSON on a
  localhost TCP socket).
- Sessions are stored as Pi v3 JSONL files (see `--session-dir`,
  `--resume`, `--fork`).

Run `adou --help` for the full option list.

## Building from source

Requirements: the Nature toolchain (`nature`), `make`, `cc`.

```sh
make build          # build/bin/adou (guarded serial Nature build)
make run            # run the TUI
make test           # Nature unit tests (serial; ~2h full suite)
make e2e            # offline/mocked end-to-end tests (needs only build)
make e2e-live       # opt-in live DeepSeek scenarios (ADOU_LIVE_*=1)
make eval           # local deterministic eval harness (make eval output)
make dist           # build/dist/adou-<version>-darwin-arm64(.tar.gz,.sha256)
make release-check  # serial gate: build + eval + dist + release artifacts
make signing-check  # serial local signing-readiness gate (no real signing)
```

All Nature compiler/test invocations run strictly serially; never run them
concurrently.

## Test layering

- `make e2e`: deterministic offline/mocked scenarios only (no network, no
  API keys required).
- `tests/e2e/live/`: opt-in real DeepSeek journeys (`ADOU_LIVE_SMOKE=1`,
  `ADOU_LIVE_JOURNEY=1`, `ADOU_LIVE_TUI_JOURNEY=1`).
- `tests/e2e/release/`: release packaging and macOS signing-readiness
  scenarios, invoked by `make release-check` / `make signing-check`.
- `make eval`: local deterministic eval harness (3 smoke cases against a
  local mock provider).

## Explicitly not supported (current scope)

- Pi extensions remain disabled (no extension runtime, no QuickJS/Node).
- Linux builds and cross-compilation are deferred.
- OAuth login flows and interactive image rendering are not claimed.
- Real Developer ID signing, notarization, and `.pkg` packaging are
  optional future enhancements.

## License

MIT. This project derives from Pi; see `LICENSE` for the upstream
copyright and `THIRD_PARTY_NOTICES.md` for bundled components.
