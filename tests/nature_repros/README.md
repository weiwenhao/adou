# Nature allocation reproductions

These are focused Nature programs for the memory pressure observed in Adou's
model selector and long streamed TUI responses.

## Short dynamic string pool leak (#331)

`short_string_pool_leak.n` is the standalone reproduction for
[`nature-lang/nature#331`](https://github.com/nature-lang/nature/issues/331).
Two million one-byte `string.slice` operations leave about 92 MB of dirty,
non-reclaimable Darwin `MALLOC_NANO` memory after two settled Nature GC
cycles; changing the slice length to eight bypasses the runtime's
`capacity <= 8` pool path and leaves only about 160 KB in that zone. Adou's
Unicode and Markdown wrappers amplified this native leak during long streamed
responses, so the TUI keeps offset-based plain-Unicode wrapping as a local
mitigation until the runtime fix is available.

## Streamed render GC failure (#332)

`growing_render_gc_pressure.n` reduces the streamed transcript shape to
immutable string growth plus rebuilding and dropping fixed-width row vectors.
It is the standalone reproduction for
[`nature-lang/nature#332`](https://github.com/nature-lang/nature/issues/332).
On upstream Nature `1f840ec0`, repeated forced GC cycles eventually make
`runtime.malloc_bytes()` negative; the program stops at the first negative
sample. The measured upstream run stopped at frame 2,450 with
`-1319468015`, after reaching a 9.16 GB peak physical footprint. Removing the
5 ms scheduler pause makes GC stop completing after several cycles and grows
physical footprint to 18 GB in under a minute.

`string_concat_gc_accounting.n` is the control for the string-concatenation
path alone. It keeps `runtime.malloc_bytes()` positive, narrowing #332 to the
slice-heavy row rebuild plus repeated sweep lifecycle.

Build and run either program serially from the repository root:

```sh
/usr/local/nature/bin/nature build -o /tmp/nature_growing_render_gc_pressure \
  "$PWD/tests/nature_repros/growing_render_gc_pressure.n"
/tmp/nature_growing_render_gc_pressure
```

## Model-selector pressure

`rm_tui_registry.n` calls `registry.find_def('missing-provider')` 1,200 times
per round. `find_def` falls through to `registry.defs()`, which reconstructs
the complete provider definition list on every call. This is the allocation
shape that the old model selector hit once for every catalog model.

Build and run it serially from the repository root:

```sh
/usr/local/nature/bin/nature build -o /tmp/nature_rm_tui_registry \
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
