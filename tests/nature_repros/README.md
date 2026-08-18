# RM-TUI-005 allocation repro

These are focused Nature programs for the memory pressure observed while
opening Adou's `/model` selector.

## Application-shaped pressure

`rm_tui_registry.n` calls `registry.find_def('missing-provider')` 1,200 times
per round. `find_def` falls through to `registry.defs()`, which reconstructs
the complete provider definition list on every call. This is the allocation
shape that the old model selector hit once for every catalog model.

Build and run it serially from the repository root:

```sh
NATURE_EXECUTABLE=/usr/local/nature/bin/nature \
  ./scripts/nature-build-safe.sh build -o /tmp/nature_rm_tui_registry \
  "$PWD/tests/nature_repros/rm_tui_registry.n"
/tmp/nature_rm_tui_registry
```

The program completes, but `runtime.malloc_bytes()` shows large transient
allocation spikes. A higher-frequency 500-round version used during diagnosis
reached about 23.7 GB of allocation pressure without aborting.

## Runtime GC control

`rm_tui_one_vec_gc_wait.n` allocates the same small vector shape in a function,
then gives the scheduler time after `runtime.gc()`. Its live allocation stays
flat, demonstrating that ordinary short-lived vectors are reclaimed by the
runtime when a collection can complete.

The real Herdr failure was reproduced separately with the old installed Adou
binary (`/usr/local/bin/adou`, SHA-256 prefix `ceebb911`): after ten successful
model-selector opens, the eleventh exited with
`runtime: out of memory: page allocation failed`. The current build (SHA-256
prefix `505856`) survived 100 equivalent opens; the raw samples and debug logs
are in `/tmp/rm-tui-005-memory-20260818.log`,
`/tmp/rm-tui-005-memory-built-20260818.log`, and
`/tmp/adou-built-rm-tui-005.log`.
