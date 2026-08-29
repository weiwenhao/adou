# Reproducers

These scripts are manual, platform-specific reproductions. They are not part
of the normal offline `make e2e` run.

## macOS: single-prompt Qin Shi Huang / polar bear crash

This reproduces the exact sequence reported on macOS:

```text
adou
画一个秦始皇骑北极熊
[while it is Thinking] press Escape once
```

It uses the normal DeepSeek configuration, so the machine must already have
the same provider credentials that a normal `adou` launch uses. The harness
waits until `Thinking...` appears, then sends one Escape byte while the
request is running. Run it from the same project directory as the report, for
example:

```sh
cd ~/Code/adou-test
ADOU_BIN="$HOME/.local/bin/adou" \
  /Users/liulianfuren/Code/adou/tests/repros/macos-live-qin-polar-bear.sh
```

The script starts a fresh PTY process, sends exactly one prompt and Escape,
saves the raw PTY output, and records newly created macOS crash-report paths
under `/tmp`. Exit code `0` means `SIGSEGV` or `SIGABRT` was reproduced; exit
code `1` means Escape did not crash the process (including a normal exit); exit
code `2` means the test setup is incomplete. Set
`ADOU_REPRO_ESCAPE_DELAY=<seconds>` to change when Escape is sent (the default
is 10 seconds after `Thinking...`), or set `ADOU_REPRO_CTRL_C_FIRST=1` to run
the earlier Ctrl+C-then-Escape variant.
