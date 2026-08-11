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
  delete_session/record_branch_entry）、`src/session/backend.n` 增加
  `open_sqlite` / `open_sqlite_session` / 后端级 `append_message`/
  `list_sessions`/`delete_session`/`fork_to` 分发。
- 契约：`tests/repository_contract_test.n` 5/5 通过——同一套
  `run_contract_suite` 驱动 JSONL / memory / SQLite 三后端（create、append
  顺序、parent lineage、缺失/重复错误、fork before/at、完整 fork 血缘、
  list/delete），外加 SQLite 与 JSONL 各自的 reopen 持久化（顺序与 lineage
  跨 reopen 保留）。

## RPC-over-IPC（2026-08-11 batch 3 已落地最小 slice）

- `src/server/ipc_server.n`：localhost TCP + 逐行 JSON 帧（与上游
  `ipc/protocol.ts` encodeMessage 一致），连接级协程处理。
- `adou --serve-port <port>`：app.n 分支构建 runner 后进入 serve 循环；
  命令表面：spawn/list/status/stop（单实例）+ `rpc` 非流式 prompt（offline
  守卫生效，返回 success/error 响应行）+ `rpc_stream` 最小切片。
- e2e `rpc-over-ipc.sh`：spawn → list → status → offline prompt 拒绝 →
  offline rpc_stream 拒绝 → offline 流式 prompt 拒绝 → stop → 未知命令
  拒绝，全通过。现有进程内 RPC（--mode rpc）未改动。

## Phase 7 batch 4 已落地（2026-08-11）

- `session_sequences` 表接入：`sqlite_repo.append_entry` 不再用
  `MAX(entry_seq)+1`，改为读取 `session_sequences.next_seq`（无行视为 0），
  写入成功后用 `ON CONFLICT(session_id) DO UPDATE SET next_seq =
  excluded.next_seq` 自增（对应上游 storage/session-sequences.ts）。单进程
  串行写入，无需事务锁。
- materialized 表填充：每次 append 成功后同步写入
  `entry_materialized (session_id, entry_seq, type, payload)`（payload 为
  entry 原始 JSON）与 `session_materialized`（payload 为
  `{"leaf":"<leaf_id>"}`，upsert 覆盖，对应上游
  storage/entry-materialized.ts / session-materialized.ts）。
- fork 语义：`backend.fork_to` SQLITE 分支在复制每个 entry 后写一条
  `branch_entries (session_id=new, branch_id='main', entry_id, entry_seq)`，
  entry_seq 按复制顺序递增计数（对应上游 storage/branch-entries.ts）。
- rpc_stream 最小切片：`ipc_server.serve_with_stream` 增加 stream handler；
  请求 handler 返回带 `"stream":true` 标记的响应时，连接切到流模式，把
  stream handler 返回的事件行逐行写出。`rpc` prompt 带
  `streamingBehavior:"stream"` 与 `rpc_stream` 请求均走该路径：一行
  `{"type":"stream_start",...}` + 完整非流式响应（文档化差异：上游
  rpc_stream 是持续连接的双向协议，本批不做连接态切换）；offline 下两者都
  立即返回 offline 错误（确定性）。未使用 runner 事件 sink。
- TUI 迁移：`session_actions.delete_session_file` 改为调用
  `backend.delete_session_file` 的薄包装（行为不变：trash → unlink）；
  `session_view.show_session_overlay` 的目录扫描改用
  `backend.list_session_paths`（同样 .jsonl 过滤 + mtime 最新优先；listdir
  失败的差异：原实现显示 error message，现静默空列表并走
  “No persisted sessions are available” 分支）。tui-session-selector.sh /
  tui-tree-fork.sh 回归通过。

## 下一批边界

- radius（OAuth/遥测）按排除项评估。
- IPC 多实例 supervisor：上游 `rpc-process.ts`/`supervisor.ts` 的
  spawn 进程管理、多实例实例表与 handler.ts 命令面（rpc_stream 双向
  连接态协议依赖它）。
- 若系统 SQLite 头/库需要动态链接（如降级打包），单独验证 Darwin/Linux ABI，
  本批静态 .o 链接不改变。

## 与既有约束的关系

- 默认存储保持 JSONL（`--no-session` 走内存后端）不变。
- 扩展运行时继续屏蔽；SQLite 不引入 Node/QuickJS 运行时。
- 契约测试通过 guarded 单文件测试串行执行，不进入全量 make test 批次。
