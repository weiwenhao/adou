# Phase 7 Storage Design（2026-08-11 batch 1）

> 范围更新：本文记录 Phase 7 当时的实现边界；其中 Radius/OAuth 和实例表
> 持久化不再是产品排除项，而是全量 Pi parity 的开放工作。唯一明确排除仍是
> TypeScript/QuickJS extension runtime。

## 目标

在不替换默认 JSONL 存储的前提下，把 repository 的 backend 边界固定下来，
为 SQLite backend 预留清晰接口；双后端行为由共享契约测试保证。

## 上游文件矩阵（vendors/pi）

| 上游 | 角色 | 本批状态 |
|---|---|---|
| `packages/agent/src/harness/types.ts` `SessionRepo` | 契约：create/open/list/delete/fork | 已映射（见 adapter API） |
| `packages/agent/src/harness/session/jsonl-repo.ts` | JSONL 实现 | 对应 `src/session/repository.n`（既有） |
| `packages/agent/src/harness/session/jsonl-storage.ts` | 文件读写 | 对应 `src/session/jsonl.n`（既有） |
| `packages/storage/sqlite-node/src/sqlite/migrations.ts` | schema 迁移 | 已完成（batch 2 落地） |
| `packages/storage/sqlite-node/src/sqlite/repo.ts` | SQLite SessionRepo | 已完成（batch 2 落地） |
| `packages/storage/sqlite-node/src/sqlite/storage/{sessions,session-entries,branch-entries,session-sequences,session-materialized}.ts` | 表访问层 | 已完成（batch 2 落地） |

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
backend helper（该迁移已由 batch 4 落地，见下）。

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

## RPC-over-IPC（2026-08-11 batch 3 已落地最小 slice；已由下方 Phase 7.1 取代）

> 本节为历史中间态：单实例 + `"stream":true` 标记 + serve_with_stream 的
> 旧切片。Phase 7.1 已按上游双向 rpc_stream 连接态重写（见下），本节保留
> 仅作演进记录，不再代表当前实现。

- `src/server/ipc_server.n`：localhost TCP + 逐行 JSON 帧（与上游
  `ipc/protocol.ts` encodeMessage 一致），连接级协程处理。
- `adou --serve-port <port>`：app.n 分支构建 runner 后进入 serve 循环；
  命令表面：spawn/list/status/stop（单实例）+ `rpc` 非流式 prompt（offline
  守卫生效，返回 success/error 响应行）+ `rpc_stream` 最小切片。
- e2e `rpc-over-ipc.sh`：spawn → list → status → offline prompt 拒绝 →
  offline rpc_stream 拒绝 → offline 流式 prompt 拒绝 → stop → 未知命令
  拒绝，全通过。现有进程内 RPC（--mode rpc）未改动。

## Phase 7 batch 4 已落地（2026-08-11；其中 rpc_stream 旧切片已由 Phase 7.1 取代）

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

## 下一批边界（2026-08-12 复核：均已收口）

- radius（OAuth/遥测）：本批未移植，现作为开放 parity 工作继续实施。
- IPC 多实例 supervisor：已由下方 Phase 7.1 落地；2026-08-16 在 Nature stdin
  pipe 修复后进一步替换为与上游一致的每实例 RPC 子进程。
- 系统 SQLite 动态链接：维持静态 .o 链接不变，本批不引入系统库依赖。

## Phase 7.1：server 协议与多进程 parity（2026-08-12 首验，2026-08-16 多进程复验）

### 上游 → Nature 实现映射

| 上游（vendors/pi） | Nature 实现 |
|---|---|
| `packages/server/src/ipc/protocol.ts`（ServerRequest/ServerResponse 形状） | `src/server/protocol.n`（响应序列化器 + instance_summary_t） |
| `packages/server/src/ipc/server.ts`（TCP 逐行帧、rpc_stream 连接态） | `src/server/ipc_server.n`（连接级 `go handler(conn)` + `read_line`）+ `src/app.n` 连接处理器 |
| `packages/server/src/supervisor.ts`（实例表 + 生命周期） | `src/server/supervisor.n`（实例表、spawn/list/stop/status 路由、subscriber 扇出） |
| `packages/server/src/handler.ts`（命令面与错误形状） | `src/app.n` `serve_command` 重写（按响应类型分发 + `Unknown instance: <id>`） |
| `packages/server/src/rpc-process.ts`（子进程 + 行分帧） | `src/server/rpc_process.n`（真实 stdin/stdout/stderr pipe、JSONL 分帧、pending id 关联、事件转发、退出/终止） |
| `packages/server/src/{serve,config,storage,radius,cli}.ts` | 本批仅实现核心 server；Radius 和实例表持久化仍为开放 parity 工作 |

### 协议响应形状（每行一个 JSON，逐行帧与上游 encodeMessage 一致）

```json
{"type":"spawn_result","ok":true,"instance":{"id":"<uuid>","status":"online","cwd":"/tmp","label":"a"}}
{"type":"list_result","ok":true,"instances":[{"id":"<uuid>","status":"online","cwd":"/tmp","label":"a"},{"id":"<uuid>","status":"online","cwd":"/tmp","label":"b"}]}
{"type":"status_result","ok":true,"instance":{"id":"<uuid>","status":"online","cwd":"/tmp"}}
{"type":"stop_result","ok":true,"instanceId":"<uuid>"}
{"type":"rpc_result","ok":true,"response":{"id":"g1","type":"response","command":"get_state","success":true,"data":{...}}}
{"type":"rpc_ready","ok":true,"instance":{"id":"<uuid>","status":"online","cwd":"/tmp"}}
{"type":"error","ok":false,"error":"Unknown instance: nope"}
```

sessionId/sessionFile/label 仅在非空时出现（与上游 InstanceSummary 可选字段一致）。

### 实例生命周期（每实例一个 RPC 子进程）

每 `spawn{cwd,label?}` 创建：

1. `id = identity.uuid_v7()`，先记录 `starting`；后台启动同一 Adou executable 的
   `--mode rpc` 子进程，并通过 `get_state` 握手取得 sessionId/sessionFile 后切到
   `online`。启动或进程异常退出切到 `exited`，stderr 会进入可观察的 error。
2. 子进程继承 server 环境，并像 Pi 一样在目标 cwd 重新解析 settings、trust、
   model、tools、skills 和持久化 session；不再复制父进程内的 runner/config。
3. 父进程为每个 child 保留独立 stdin reader、stdout JSONL framer、stderr 上限缓冲
   和 pending request 表；缺失 command id 时生成 `server_<uuid>`，并发响应按 id
   回到正确客户端，其他 stdout 行作为 AgentSessionEvent 扇出。

`stop{instanceId}`：实例切到 `stopped`，关闭 stdin 并发送 SIGTERM；3 秒未退出则
SIGKILL。Adou 当前仍保留 stopped 记录供 status/list 查询，这是相对 Pi
“停止后删除 live record”的明确协议差异。stop A 不影响 B，因为 runner、session、
管道和 PID 都在不同进程。server 被信号直接终止时，父端 pipe 关闭使剩余 child
stdin EOF 并自然退出；`supervisor.shutdown()` 也可逐实例执行有界清理。

### rpc_stream 交互序列（同一连接，上游 server.ts 连接态）

```
C→S: {"type":"rpc_stream","instanceId":"<id>"}
S→C: {"type":"rpc_ready","ok":true,"instance":{...}}        # 连接保持打开
C→S: {"id":"g1","type":"get_state"}
S→C: {"id":"g1","type":"response","command":"get_state","success":true,"data":{...}}
C→S: {"id":"g2","type":"get_last_assistant_text"}
S→C: {"id":"g2","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":null}}
C→S: {"type":"extension_ui_response",...}
S→C: {"type":"error","ok":false,"error":"extensions disabled"}   # 禁用边界确定性
C   : 断开连接
S   : 解除订阅（不再向该连接扇出事件）
```

连接存活期间实例的 AgentSessionEvent（event_json 编码，如
`{"type":"message_start",...}`）实时逐行扇出；prompt 等异步命令的响应与事件
顺序与 `--mode rpc` 一致（先 response 行，后事件流）。非 rpc_stream 请求
上游 `socket.end()` 语义：响应一行后关闭连接。

### 旧 stdin blocker 已解除（2026-08-16）

2026-08-12 的旧 Nature runtime 确实把 child stdin 配成 `UV_IGNORE`，因此当时的
进程内 runner 是有证据的临时方案。nature-lang/nature issue #308 / PR #309 已把
runtime 改成真实的 `UV_CREATE_PIPE | UV_READABLE_PIPE`，`process.command_t.spawn()`
现在会消费调用方赋给 `cmd.stdin` 的 `io.reader` 并持续写入 child stdin。安装版
Nature 已更新为该 master 构建，Adou 因而在 2026-08-16 移除了临时 runner。

Nature PR #310 已让 runtime 把 `command_t.cwd` 传给 `uv_process_options_t.cwd`。
Adou 现在在 spawn 前直接设置 `command.cwd = cwd`，e2e 会读取每个 session header
验证 child 的工作目录。另一个实现细节是必须让
`ref<process.command_t>` 与 child 同寿命：Nature process context 是未类型化 GC
分配，若只保留 process_t，快速多实例下 command 内的 io interface 可能被回收。
`rpc_process_t.command` 是该生命周期锚点，压力 e2e 覆盖了这一回归。

### e2e 与单测（2026-08-16 多进程复验）

- `tests/ipc_protocol_test.n` 7/7：协议响应形状序列化断言（spawn/list/status/
  stop/rpc_result/rpc_ready/error + InstanceSummary 可选字段省略）。
- `tests/backend_list_session_paths_test.n` 2/2：resume picker 扫描失败的
  TUI 回归守卫（目录不存在 → throw；空目录 → 空列表）。
- `tests/rpc_process_test.n` 2/2：stdout split/combined JSONL 恢复与无换行尾帧 flush。
- `tests/e2e/rpc-over-ipc.sh`：两个不同 RPC child PID、目标 cwd/session header、
  并发 24 请求的 id/instance 关联、缺失 id 自动生成、rpc_stream、offline prompt、
  stop A 只回收 PID A、server 退出回收剩余 PID B——全通过。
- 同一多进程 e2e 连续 5 轮通过；完整 `make e2e` 54 个脚本串行执行 exit 0。
- 回归：`rpc-shape-parity.sh`、`rpc-empty-messages.sh`（进程内 --mode rpc 形状
  与空消息语义）、`rpc-new-session.sh`、`rpc-tree-corrupt.sh`、
  `repository_contract_test.n` 5/5、`setup_test.n` 2/2 全绿，证明 run_rpc →
  rpc_dispatch 重构未改变进程内协议。

## 与既有约束的关系

- 默认存储保持 JSONL（`--no-session` 走内存后端）不变。
- 扩展运行时继续屏蔽；SQLite 不引入 Node/QuickJS 运行时。
- 契约测试通过 guarded 单文件测试串行执行，不进入全量 make test 批次。
