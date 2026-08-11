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

## SQLite 下一批边界（本批不实现）

- schema/migration：`migrations.ts` 的 sessions / session_entries /
  branch_entries / session_sequences / session_materialized 表结构与迁移
  版本号对齐；行为对齐 `repo.ts` 的 SessionRepo 实现。
- 一致性：SQLite backend 接入同一套 `run_contract_suite`（persisted 语义），
  并补 JSONL↔SQLite 行为一致性测试与 RPC-over-IPC 验收。
- 链接约束：不得依赖 Node、QuickJS 或 `sqlite3` CLI。系统 SQLite C ABI
  （`sqlite3.h` + `libsqlite3`）在 Darwin/Linux 的可用性、动态链接
  （`-lsqlite3`/`dlopen`）或静态打包方式必须单独验证后再引入，本批不引入
  任何不可移植的链接；若 ABI 不可用则退回纯 JSONL 并记录阻塞。

## 与既有约束的关系

- 默认存储保持 JSONL（`--no-session` 走内存后端）不变。
- 扩展运行时继续屏蔽；SQLite 不引入 Node/QuickJS 运行时。
- 契约测试通过 guarded 单文件测试串行执行，不进入全量 make test 批次。
