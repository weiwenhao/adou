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

- radius（OAuth/遥测）：已按排除项评估并排除，不移植。
- IPC 多实例 supervisor：已由下方 Phase 7.1 落地（进程内隔离 runner 方案；
  上游 `rpc-process.ts` 子进程方案因 Nature 运行时硬阻塞被否决，证据见下）。
- 系统 SQLite 动态链接：维持静态 .o 链接不变，本批不引入系统库依赖。

## Phase 7.1：server 协议 parity closeout（2026-08-11 落地，2026-08-12 已完成验收）

### 上游 → Nature 实现映射

| 上游（vendors/pi） | Nature 实现 |
|---|---|
| `packages/server/src/ipc/protocol.ts`（ServerRequest/ServerResponse 形状） | `src/server/protocol.n`（响应序列化器 + instance_summary_t） |
| `packages/server/src/ipc/server.ts`（TCP 逐行帧、rpc_stream 连接态） | `src/server/ipc_server.n`（连接级 `go handler(conn)` + `read_line`）+ `src/app.n` 连接处理器 |
| `packages/server/src/supervisor.ts`（实例表 + 生命周期） | `src/server/supervisor.n`（实例表、spawn/list/stop/status 路由、subscriber 扇出） |
| `packages/server/src/handler.ts`（命令面与错误形状） | `src/app.n` `serve_command` 重写（按响应类型分发 + `Unknown instance: <id>`） |
| `packages/server/src/rpc-process.ts`（子进程 + 行分帧） | 按隔离方案排除（见下）；命令面复用 `src/app.n` 的进程内 `rpc_dispatch`（原 run_rpc 循环体提取，--mode rpc 行为不变） |
| `packages/server/src/{serve,config,storage,radius,cli}.ts` | 不移植：radius 排除；实例表保持内存态（不持久化 instances 记录） |

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

### 实例生命周期（进程内隔离 runner）

每 `spawn{cwd,label?}` 创建：

1. `id = identity.uuid_v7()`；`status = "online"`（runner 创建成功后入表，上游
   starting→online 的中间态在表内不可观测，等价于创建成功前的失败直接回 error）。
2. 独立 runner：`repository.in_memory(cwd)`（--no-session 语义，无文件）；
   sessionId/sessionFile 取自该 repository；label/cwd 原样保留。
3. 实例继承 server 进程已解析的模型/流选项/compaction/重试配置；工具集与
   system prompt（AGENTS.md/CLAUDE.md/skills）按实例 cwd 重新构建。

`stop{instanceId}`：从表移除后 `runner.abort_and_wait()`（放弃该 runner）。
`status/list`：按表路由。未知 instanceId（spawn 未成功/已 stop/从未存在）一律
返回 `error{ok:false,error:"Unknown instance: <id>"}`（与上游 handler.ts
unknownInstanceError 一致）。stop A 不影响 B：每实例独立 runner 与锁。
server 关闭：无子进程（隔离方案），进程退出即释放全部 runner；`supervisor.shutdown()`
逐实例 abort，供未来优雅退出接线。

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

### 为什么子进程方案被否决（硬阻塞证据，2026-08-12 复核）

- 审计对象：`/Users/liulianfuren/Code/nature/std/process/process.n`，与安装版
  `/usr/local/nature/std/process/process.n` diff 完全一致（同一版本，v0.7.4）。
- `command_t` 声明了 `stdin io.reader` 字段，但唯一两个构造入口
  `process.run()` 与 `process.command()` 都把 stdin 硬编码为
  `fs.discard()`（即 `open(/dev/null)`）；模块没有任何写子进程 stdin 的 API，
  只有 `read_stdout`/`read_stderr`/`wait`，也没有 kill/terminate
  （仅 `syscall.kill(pid, sig)`）。
- 运行时 `runtime/nutils/process.c` `uv_async_process_spawn`：
  `stdio[0].flags = UV_IGNORE`（stdin 恒 /dev/null），stdout/stderr 才是
  `UV_CREATE_PIPE | UV_WRITABLE_PIPE`（子→父单向管道）。即 `command_t.stdin`
  字段从未被运行时使用。
- 结论：`adou --mode rpc` 子进程的 stdin 读端立即 EOF，run_rpc 循环直接退出，
  spawn 出的实例无法接收任何命令——子进程管道方案存在硬阻塞。

因此采用任务决策点的备选方案：进程内等价隔离 runner。差异文档化：实例与
server 同进程（崩溃互相影响）、无进程级强制终止（abort 为协作取消）、无
`RPC process exited` 异常路径（error 状态由 spawn 失败承担）。

### e2e 与单测（2026-08-12 实跑全绿）

- `tests/ipc_protocol_test.n` 7/7：协议响应形状序列化断言（spawn/list/status/
  stop/rpc_result/rpc_ready/error + InstanceSummary 可选字段省略）。
- `tests/backend_list_session_paths_test.n` 2/2：resume picker 扫描失败的
  TUI 回归守卫（目录不存在 → throw；空目录 → 空列表）。
- `tests/e2e/rpc-over-ipc.sh`（重写，python 客户端）：两次 spawn 不同 id/cwd/
  label、list 两项、分别 status、rpc get_state 按 instanceId 路由（data.sessionId
  不同）、stop A 后 B 仍在线、未知 id error、同一 rpc_stream 连接连续两条非联网
  命令 + extension_ui_response 确定性 error、连接关闭、server 退出后无遗留
  adou 子进程、offline prompt 拒绝——全通过。
- 回归：`rpc-shape-parity.sh`、`rpc-empty-messages.sh`（进程内 --mode rpc 形状
  与空消息语义）、`rpc-new-session.sh`、`rpc-tree-corrupt.sh`、
  `repository_contract_test.n` 5/5、`setup_test.n` 2/2 全绿，证明 run_rpc →
  rpc_dispatch 重构未改变进程内协议。

## 与既有约束的关系

- 默认存储保持 JSONL（`--no-session` 走内存后端）不变。
- 扩展运行时继续屏蔽；SQLite 不引入 Node/QuickJS 运行时。
- 契约测试通过 guarded 单文件测试串行执行，不进入全量 make test 批次。
