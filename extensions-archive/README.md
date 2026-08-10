# Extension runtime archive

Adou's Pi agent extension runtime (QuickJS) is disabled and archived for
future redesign.  Nothing in this directory is compiled, linked, or run by
the default build/test/e2e workflow:

- `agent/extension_js.n` — QuickJS extension bridge (adou.register* JS API)
- `agent/quickjs_ffi.n` — Nature `#linkid` declarations for QuickJS
- `agent/extension_loader.n` — .js/.ts extension discovery
- `native/quickjs_bridge.c` — static-inline wrapper shims
- `tests/*` — extension-specific tests (require the QuickJS link)

The QuickJS sources remain vendored at `vendors/quickjs/` (untouched).
Reactivating this feature requires: relinking `build/libquickjs.a` via
`package.toml [links]`, restoring the load/bind/event wiring, and moving
these tests back into `tests/`.
