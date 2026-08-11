# Phase 7 Storage Design（2026-08-11 batch 1）

## 目标

在不替换默认 JSONL 存储的前提下，把 repository 的 backend 边界固定下来，
为 SQLite backend 预留清晰接口；双后端行为由共享契约测试保证。

## 上游文件矩阵（vendors/pi）

| 上游 | 角色 | 本批状态 |
|---|---|---|
| `packages/agent/src/harness/types.ts` `SessionRepo` | 契约：create/open/list/delete/fork | 已映射（见 adapter API） |
| `packages/agent/src/harness/session/jsonl-repo.ts` | JSONL 实现 | 对应 `src/session/repository.n`（既有） |
| `packages/agent/src/harness/session/jsonl-storage.ts` | 文件读写 | 对应 `src/session/jsonl.n`（既有） |
| `packages/storage/sqlite-node/src/sqlite/migrations.ts` | schema 迁移 | 下一批 |
| `packages/storage/sqlite-node/src/sqlite/repo.ts` | SQLite SessionRepo | 下一批 |
| `packages/storage/sqlite-node/src/sqlite/storage/{sessions,session-entries,branch-entries,session-sequences,session-materialized}.ts` | 表访问层 | 下一批 |

## Adapter API（本批落地：`src/session/backend.n`）

```nature
type backend_kind_t = enum { JSONL, MEMORY }
type backend_t = struct { backend_kind_t kind; ref<repository.manager_t> manager; string session_dir }

create_jsonl(cwd, session_dir): backend_t!   // SessionRepo.create（持久化）
open_memory(cwd): backend_t!                 // SessionRepo.create（内存，无文件）
open_jsonl(file_path): backend_t!            // SessionRepo.open
list_session_paths(session_dir): [string]    // SessionRepo.list（按 mtime 最新优先）
delete_session(file_path, cwd): (bool, string) // SessionRepo.delete（trash → unlink fallback）
```

fork 语义复用既有 `manager_t`：`fork_before`/`fork_at`/`fork_to`（完整 fork 含
`header.parent_session` 血缘）。TUI 调用点（resume picker 扫描、
`session_actions.delete_session_file`）本批**不切换**，后续批次统一迁移到
backend helper。

## 双后端契约测试（`tests/repository_contract_test.n`）

一套 `run_contract_suite(backend, persisted)` 断言分别驱动 JSONL 与内存后端，
覆盖：create header、append 顺序、parent lineage、缺失 entry 错误、
fork before（不含目标）/ fork at（含目标）、完整 fork 的 entry 数一致与
parent_session 血缘、重复 id 错误、list/delete（持久化后端）与缺失文件删除；
另加 JSONL reopen 持久化（顺序与 lineage 跨 reopen 保留）。2026-08-11 实跑
3/3 通过。

## SQLite 后端（2026-08-11 batch 2 已落地）

- 绑定来源：`https://github.com/weiwenhao/nature-sqlite`（SQLite 3.50.4
  amalgamation + 4 平台预编译 .o + Nature 绑定）。集成：`native/sqlite3/`
  （sqlite3.c/h + sqlite3_*.o），`package.toml [links] libsqlite3` 按
  darwin_arm64/darwin_amd64/linux_arm64/linux_amd64 映射。适配本编译器
  （v0.7.4）：`rawptr<T>` 非关键字，已全局替换为内置 `ptr<T>`；绑定函数与
  常量改为 `pub`。不依赖 Node、QuickJS 或 `sqlite3` CLI；静态链接随
  平台 .o 打包，无需系统库安装。
- 实现：`src/storage/sqlite_migrations.n`（上游 001_initial.sql 全套表，
  含 sessions/session_entries/session_sequences/branch_entries/
  session_materialized/entry_materialized）、`src/storage/sqlite_repo.n`
  （open_db/close_db/create_session/append_entry/load_manager/list_sessions/
  delete_session，entry_seq 取 MAX+1 等价 sequences 表；branch/materialized
  表已建未填，属后续批次）、`src/session/backend.n` 增加 `open_sqlite` /
  `open_sqlite_session` / 后端级 `append_message`/`list_sessions`/
  `delete_session`/`fork_to` 分发。
- 契约：`tests/repository_contract_test.n` 5/5 通过——同一套
  `run_contract_suite` 驱动 JSONL / memory / SQLite 三后端（create、append
  顺序、parent lineage、缺失/重复错误、fork before/at、完整 fork 血缘、
  list/delete），外加 SQLite 与 JSONL 各自的 reopen 持久化（顺序与 lineage
  跨 reopen 保留）。

## 下一批边界

- SQLite 分支语义：`branch_entries`/`session_materialized`/`entry_materialized`
  填充与 branch 查询对齐 `repo.ts`；`session_sequences` 表接入（当前 MAX+1）。
- RPC-over-IPC server（Phase 7 另一半）：IPC protocol、rpc process、
  supervisor、handler、serve、radius；不得破坏现有进程内 RPC 协议。
- TUI list/delete 调用点迁移到 backend helper。
- 若系统 SQLite 头/库需要动态链接（如降级打包），单独验证 Darwin/Linux ABI，
  本批静态 .o 链接不改变。

## 与既有约束的关系

- 默认存储保持 JSONL（`--no-session` 走内存后端）不变。
- 扩展运行时继续屏蔽；SQLite 不引入 Node/QuickJS 运行时。
- 契约测试通过 guarded 单文件测试串行执行，不进入全量 make test 批次。
