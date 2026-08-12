# Pi Core Module Map

状态：MVP 核心路径已完成逐模块核对（Pi 基线 `0.82.1`, commit `cced6a21da273b26ee4a23a803680614bbe8dd1e`）；Phase 1–8 全部完成（8/8，与 `docs/porting-plan.md` 一致），release hardening 进行中（见 `docs/release-hardening-plan.md`），Pi extension 运行时已停用。

本文把 `vendors/pi` 中必须翻译到 Nature 的核心边界固定下来。判断标准是 Pi 的可观察 coding-agent 行为，而不是 TypeScript 文件是否已经有一个同名 Nature 文件。每个模块只有在完成源码差分、单元测试和至少一个跨模块集成测试后，才可标记为完成。

## 核心模块

| 模块 | Pi 行为来源 | Nature 当前边界 | 当前测试 | 状态 |
|---|---|---|---|---|
| AI 数据模型与流协议 | `packages/ai/src/types.ts`, `api/openai-responses.ts`, `api/openai-completions.ts`, `api/anthropic-messages.ts`, `utils/event-stream.ts`, `utils/json-parse.ts`, `utils/retry.ts` | `src/ai/types.n`, `src/ai/event_stream.n`, `src/ai/sse.n`, `src/ai/streaming_json.n`, `src/ai/providers/*` | request tests；OpenAI HTTP 8/8；Anthropic HTTP 6/6；SSE 8/8；streaming JSON 3/3 | MVP 已通过：DeepSeek/OpenAI Responses/Anthropic 流式、重试、取消和 malformed JSON 覆盖 |
| Agent loop | `packages/agent/src/agent-loop.ts`, `agent.ts`, `types.ts`, `stream-fn.ts`, `harness/messages.ts` | `src/agent/loop.n`, `types.n`, `schema.n`, `event_stream.n`, `session_stream.n` | agent loop 17/17；agent types 1/1；event stream 5/5；session 集成覆盖生命周期与工具结果 | MVP 已通过：并发/顺序工具、队列、取消、prepare arguments、added tool names 已对齐 |
| 内置工具 | `packages/coding-agent/src/core/tools/{read,write,edit,bash,grep,find,ls,truncate,path-utils,file-mutation-queue}.ts`, `packages/agent/src/harness/tools/*` | `src/tools/{read,write,shell_tools,command,truncate,path_utils,mutation_queue,builtins}.n` | tools 20/20；builtins 3/3；tool-edge/tool-stream-repair e2e | MVP 已通过：读写、编辑、bash、grep/find/ls 边界和 UTF-16 截断语义覆盖 |
| Session 与 JSONL | `packages/coding-agent/src/core/session-manager.ts`, `core/session-cwd.ts`, `packages/agent/src/harness/session/{session,jsonl-repo,jsonl-storage}.ts`；Phase 7：`packages/storage/sqlite-node` | `src/session/{repository,jsonl,message_json,types,identity,export_html}.n`、`src/session/backend.n`、`src/storage/*.n` | session 27/27；RPC clone/new/tree/import/export 场景通过；Phase 7 三后端契约测试（JSONL/memory/SQLite） | MVP 已通过：Pi v3 append-only 链、分支、恢复、fork/clone 和跨 cwd 语义覆盖；SQLite backend 已随 Phase 7 storage 段落落地 |
| Server IPC（Phase 7.1） | `packages/server/src/ipc/{protocol,server}.ts`, `supervisor.ts`, `handler.ts`, `rpc-process.ts`（进程管理按隔离方案排除） | `src/server/{protocol,supervisor,ipc_server}.n` + `src/app.n` run_serve/serve_command | `tests/ipc_protocol_test.n`；`tests/e2e/rpc-over-ipc.sh` 多实例/rpc_stream e2e | 已完成：spawn/list/status/stop/rpc/rpc_stream 响应形状与多实例生命周期已按上游协议落地，e2e 全绿（Phase 7.1 于 2026-08-12 关闭）；radius 继续排除；实例隔离采用进程内 runner（子进程 stdin 管道硬阻塞，证据见 phase7-storage-design） |
| 自动压缩与分支摘要 | `packages/coding-agent/src/core/compaction/{compaction,branch-summarization,utils}.ts`, `packages/agent/src/harness/compaction/*` | `src/compaction/*.n`, `src/agent/session.n` | compaction 15/15；RPC compaction abort/retry/preprompt e2e | MVP 已通过：cut point、retained tail、previous summary/file details、取消和重试覆盖 |
| 配置、认证、模型与项目上下文 | `packages/coding-agent/src/{config,core/auth-storage,core/model-{config,registry,resolver,runtime},core/settings-manager,core/resource-loader,core/system-prompt,core/project-trust}.ts`, `cli/args.ts` | `src/config/*.n`, `src/context/*.n`, `src/platform/cwd.n` | config context 22/22；model/settings/auth 全部通过；CLI validation/project-config/model-selection e2e | MVP 已通过：`.pi` 优先级、API key、模型 scope/thinking、session cwd 和启动错误语义覆盖 |
| TUI、输入与终端渲染 | `packages/tui/src/{terminal,tui,stdin-buffer,keys,keybindings,editor-component,autocomplete,word-navigation,terminal-colors}.ts`, `packages/tui/src/components/*`, `packages/coding-agent/src/modes/interactive/components/*` | `src/tui/*.n` | 10 个 TUI PTY e2e（含 `tui-tree-fork.sh`）；renderer/editor/input/model/session/settings/config/setup/theme/chat 等单测 | MVP 已通过：差分渲染、配色、输入序列、认证/模型 overlay、tree/fork/branch-summary、终端恢复；图片/扩展 UI 排除 |
| CLI、print mode 与 RPC | `packages/coding-agent/src/{main,cli/*,modes/print-mode,modes/rpc/{rpc-mode,rpc-types,jsonl}}.ts` | `src/app.n`, `src/config/args.n`, `src/agent/event_json.n` | 45 个 e2e；event JSON 9/9 | MVP 已通过：one-shot、JSON/RPC、abort/queue/retry/compact/session 命令、启动边界与事件顺序覆盖 |
| 导出与可观测性 | `packages/coding-agent/src/core/export-html/*`, `core/diagnostics.ts`, `core/timings.ts`, `core/output-guard.ts` | `src/session/export_html.n`, `src/debug.n`, `src/timings.n`, `src/output_guard.n`, `src/tui/virtual_terminal.n` | debug/observability 3/3；session/export assertions；`rpc-debug-stderr`、TUI/logging e2e | MVP 核心链路已覆盖：JSONL/静态 HTML 导出、诊断、启动计时和 RPC 输出隔离；Pi 的交互式导出模板、主题解析和扩展工具渲染器仍明确排除 |

## 明确不翻译

以下目录不是核心移植目标，不能被“已有文件数”计入完成度：

- `packages/coding-agent/src/core/extensions/**`、`src/extensions/**`：TypeScript extension ABI、加载器、事件总线和扩展 UI。早期 QuickJS 实验源码暂留，但生产入口、TUI/RPC 接线和默认链接已停用。
- `packages/coding-agent/src/extensions/**`：Llama 等扩展 provider。
- 动态 `.pi/extensions` 资源加载和扩展包管理。`.pi/skills`、`.pi/prompts`、slash commands 已作为核心功能实现，不属于本排除项。
- `packages/server/**`（radius/OAuth 与子进程隔离方案按 Phase 7.1 决定排除，IPC 协议/supervisor/rpc_stream 已按 Phase 7.1 落地）、`packages/evals/**` 不属于当前 MVP 核心验收；若继续全量工作区移植，分别在 Phase 7–8 处理。OAuth/account 登录、远程分享、npm/Bun 发布和安装器继续排除。
- Pi 的图片读取、图片渲染和 image processing；MVP 的 `read` 仅承诺 UTF-8 文本分支。

## 验收规则

每个核心模块必须有：

1. 固定的 Pi 源码文件和测试 fixture 引用。
2. Nature 实现的逐项行为差分记录。
3. Nature 单元测试，覆盖正常、错误、取消、边界和顺序语义。
4. 至少一个跨模块集成测试；provider/agent/session/TUI 不得只用孤立 mock 证明完成。
5. `make build`、相关 `make test` 或 Nature feature test，以及受影响的 `make e2e` 通过。

“有同名文件”或“已有一条 happy-path 测试”不满足完成条件。

## 当前测试口径与验收证据

- 当前有 218 个 Nature 源文件、41,925 行 Nature 源码、137 个 Nature 单测文件、656 个 test case、2,685 个 `assert` 和 45 个 e2e 脚本。
- 项目没有 line/branch coverage instrumentation。156/218 个源码模块被单测直接 import（71.6% 直接模块触达率），不得把该数字表述成代码覆盖率；extension 的 4 个测试文件/9 个 case 不计生产功能覆盖。
- 2026-08-11 定向实跑：`chat_test.n`、`model_search_test.n`、`session_search_test.n`、`settings_persistence_test.n`、`setup_test.n`、`theme_test.n` 共 26/26 通过；model/settings/config/setup 四个 PTY e2e 与 `auth-print.sh` 通过。
- 2026-08-11 第二批：`read_piped_stdin()` 增加 native poll 前置探测（`native/stdin_peek.c`），空但未关闭的 FIFO 不再阻塞等 EOF；offline 守卫移到 piped/@file prompt 摄入之后。实跑：`/bin/sh -c 'out=$(printf "" | ./build/bin/adou --offline --no-context-files --no-session --print)'` 返回，`cli-startup-boundaries.sh` 覆盖 /dev/null、空 pipe、有内容 pipe、regular file 与损坏/缺失 session，自然退出通过（不再依赖 timeout）。
- 2026-08-11 第三批：`auth print-api-key` 失败路径统一 stdout 为空、`Error: ` 写 stderr、退出码非零；`auth-print.sh` 断言成功仅 stdout、失败三要素。
- 2026-08-11 第四批：Phase 5 收尾——`tui-tree-fork.sh` PTY 闭环覆盖 `/tree`（打开/取消/重开/过滤导航）、branch summary（`Summarize branch?` → `No summary` → `Navigated to selected point`）、`/fork`（`Forked to new session`）与 `/quit` 终端恢复（退出码 0）。
- 历史上的全量 `make test` 通过记录早于最新 Phase 5/6 提交，不代表当前 137 个单测文件已在同一 HEAD 全量重跑。
- 常规模型与测试密钥的项目约定维护在 `docs/porting-plan.md` 的“测试模型、密钥与成本约束”章节；集中实现于 `tests/e2e/lib/deepseek-test-config.sh`（被 source、不会被 `make e2e` 的 `tests/e2e/*.sh` glob 匹配）；普通回归优先 offline/local mock，live smoke 显式开启（`ADOU_LIVE_SMOKE=1`）并限制消费。
- 2026-08-11 live smoke 实跑：`ADOU_LIVE_SMOKE=1 ADOU_BIN=./build/bin/adou sh tests/e2e/live-smoke.sh` 通过（`deepseek/deepseek-v4-flash`，thinking off、64 max tokens、0 retries、60s timeout）；日志只输出 key 的配置状态，不打印 key 本身。
- 若 `nature --version` 已更新但 `/usr/local/nature/lib/darwin_arm64/libruntime.a` 仍是旧文件，Adou 仍会链接旧 runtime；需用管理员权限覆盖该静态库后再重新 `make clean && make build`。
- TUI 退出路径使用 Nature 标准输入接口；输入读取在独立协程中阻塞等待 `fs/libuv` 数据，解析协程通过 Nature channel 接收字节并用定时协程处理 ESC 超时，不修改 stdin fd flags。退出时先恢复终端再结束 CLI，避免后台监听协程拖住进程。

表中“已通过”只表示 MVP 范围内的核心行为已经有源码差分和测试证据，不表示 Pi 的扩展机制、图片能力、OAuth 或其他第 4.2 节排除项已经移植。
