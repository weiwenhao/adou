# Pi Core Module Map

状态：Pi `0.82.1` 全量可观察行为对齐仍在进行；唯一明确排除是 TypeScript/QuickJS extension runtime。2026-08-19 已完成当前 worktree 的干净构建、OAuth/auth/models/radius 定向测试、`make e2e`、`make eval`，并完成 slash/menu 三轮稳定性门禁。Interactive/TUI 的离线 Batch 0–7 组合门禁已通过；真实 provider/live smoke 因未设置显式开关和测试 key 跳过。图片完整处理、长会话 allocator 风险、远程 viewer 契约和真实 provider recovery 仍未闭合。

本文把 `vendors/pi` 中必须翻译到 Nature 的核心边界固定下来。判断标准是 Pi 的可观察 coding-agent 行为，而不是 TypeScript 文件是否已经有一个同名 Nature 文件。每个模块只有在完成源码差分、单元测试和至少一个跨模块集成测试后，才可标记为完成。

## 核心模块

| 模块 | Pi 行为来源 | Nature 当前边界 | 当前测试 | 状态 |
|---|---|---|---|---|
| AI 数据模型与流协议 | `packages/ai/src/types.ts`, `api/openai-responses.ts`, `api/openai-completions.ts`, `api/anthropic-messages.ts`, `utils/event-stream.ts`, `utils/json-parse.ts`, `utils/retry.ts` | `src/ai/types.n`, `src/ai/event_stream.n`, `src/ai/sse.n`, `src/ai/streaming_json.n`, `src/ai/providers/*` | request tests；OpenAI HTTP 8/8；Anthropic HTTP 6/6；SSE 8/8；streaming JSON 3/3 | 流式、重试、取消、malformed JSON 和图片输入已通过；OAuth provider lifecycle 仍为部分实现 |
| Agent loop | `packages/agent/src/agent-loop.ts`, `agent.ts`, `types.ts`, `stream-fn.ts`, `harness/messages.ts` | `src/agent/loop.n`, `types.n`, `schema.n`, `event_stream.n`, `session_stream.n` | agent loop 17/17；agent types 1/1；event stream 5/5；session 集成覆盖生命周期与工具结果 | 已通过：并发/顺序工具、队列、取消、prepare arguments、added tool names 已对齐 |
| 内置工具 | `packages/coding-agent/src/core/tools/{read,write,edit,bash,grep,find,ls,truncate,path-utils,file-mutation-queue}.ts`, `packages/agent/src/harness/tools/*` | `src/tools/{read,write,shell_tools,command,truncate,path_utils,mutation_queue,builtins}.n` | tools 24/24；builtins 3/3；tool-edge/tool-stream-repair e2e | 文本工具、PNG/JPEG/GIF/WebP 图片附件和无图像终端 fallback 已通过；BMP 转换、自动 resize 和剪贴板粘图仍开放 |
| Session 与 JSONL | `packages/coding-agent/src/core/session-manager.ts`, `core/session-cwd.ts`, `packages/agent/src/harness/session/{session,jsonl-repo,jsonl-storage}.ts`；Phase 7：`packages/storage/sqlite-node` | `src/session/{repository,jsonl,message_json,types,identity,export_html}.n`、`src/session/backend.n`、`src/storage/*.n` | session 27/27；RPC clone/new/tree/import/export 场景通过；Phase 7 三后端契约测试（JSONL/memory/SQLite） | 已通过：Pi v3 append-only 链、分支、恢复、fork/clone 和跨 cwd 语义覆盖；SQLite backend 已随 Phase 7 storage 段落落地 |
| Server IPC（Phase 7.1） | `packages/server/src/ipc/{protocol,server}.ts`, `supervisor.ts`, `handler.ts`, `rpc-process.ts` | `src/server/{protocol,rpc_process,supervisor,ipc_server}.n` + `src/server/{storage,radius}.n` + `src/app.n` run_serve/serve_command | `tests/ipc_protocol_test.n`、`tests/rpc_process_test.n`、`tests/server_storage_test.n`、`tests/radius_test.n`；`tests/e2e/rpc-over-ipc.sh`、`radius-pi-messages.sh` | IPC、实例表持久化、opt-in Radius presence、OAuth/discovery、404 重注册/恢复、SDK 最小 surface 和 `/share` 的 `gh gist` 路径已落地；远程 viewer 兼容性仍开放 |
| 自动压缩与分支摘要 | `packages/coding-agent/src/core/compaction/{compaction,branch-summarization,utils}.ts`, `packages/agent/src/harness/compaction/*` | `src/compaction/*.n`, `src/agent/session.n` | compaction 15/15；RPC compaction abort/retry/preprompt e2e | 已通过：cut point、retained tail、previous summary/file details、取消和重试覆盖 |
| 配置、认证、模型与项目上下文 | `packages/coding-agent/src/{config,core/auth-storage,core/model-{config,registry,resolver,runtime},core/settings-manager,core/resource-loader,core/system-prompt,core/project-trust}.ts`, `cli/args.ts` | `src/config/*.n`, `src/context/*.n`, `src/platform/cwd.n` | config context 25/25；auth/oauth/models/radius 定向测试；CLI validation/project-config/model-selection e2e | API-key、canonical credential ownership、provider-specific PKCE/device/browser callback、bearer token、refresh、dynamic Radius/Copilot models 和 capability-aware login 已通过；真实 live refresh recovery 仍待验证 |
| TUI、输入与终端渲染 | `packages/tui/src/{terminal,tui,stdin-buffer,keys,keybindings,editor-component,autocomplete,word-navigation,terminal-colors}.ts`, `packages/tui/src/components/*`, `packages/coding-agent/src/modes/interactive/components/*` | `src/tui/*.n` | 全量 Nature TUI tests；`make e2e` 58/58；slash/menu 3 轮屏幕一致 | 离线 Interactive/TUI Batch 0–7 组合门禁已通过，包含 settings/auth/session/tree/resize/cancel/job-control；真实 provider 长会话和完整交互式图片能力仍未验收 |
| CLI、print mode 与 RPC | `packages/coding-agent/src/{main,cli/*,modes/print-mode,modes/rpc/{rpc-mode,rpc-types,jsonl}}.ts` | `src/app.n`, `src/config/args.n`, `src/agent/event_json.n` | 45 个 e2e；event JSON 9/9 | 已通过：one-shot、JSON/RPC、abort/queue/retry/compact/session 命令、启动边界与事件顺序覆盖 |
| 导出与可观测性 | `packages/coding-agent/src/core/export-html/*`, `core/diagnostics.ts`, `core/timings.ts`, `core/output-guard.ts` | `src/session/export_html.n`, `src/debug.n`, `src/timings.n`, `src/output_guard.n`, `src/tui/virtual_terminal.n` | debug/observability 3/3；session/export assertions；`rpc-debug-stderr`、TUI/logging e2e | 当前 JSONL/静态 HTML 导出、诊断、启动计时和 RPC 输出隔离已覆盖；非 extension 的导出差异仍按全量目标审计 |

## 当前明确排除与开放边界

下列边界必须区分“extension 明确排除”和“非 extension 尚未完成”，不能被
“已有文件数”或当前局部测试结果掩盖：

- `packages/coding-agent/src/core/extensions/**`、`src/extensions/**`：TypeScript extension ABI、加载器、事件总线和扩展 UI。早期 QuickJS 实验源码暂留，但生产入口、TUI/RPC 接线和默认链接已停用。
- `packages/coding-agent/src/extensions/**`：Llama 等扩展 provider。
- 动态 `.pi/extensions` 资源加载和扩展包管理。`.pi/skills`、`.pi/prompts`、slash commands 已作为核心功能实现，不属于本排除项。
- `packages/server/**` 中完整远程 viewer 互操作仍有开放 parity 工作；IPC、rpc-process、supervisor、实例表、opt-in presence、Radius OAuth/discovery、404 重注册/跨重启 presence 恢复、SDK 最小 surface、gist 分享路径和 Pi fragment viewer URL 已实现。`packages/evals/**` 只代表当前已有的 eval harness，不应被误读为完整工作区 parity。
- Pi 的图片自动处理仍是开放 parity 工作；当前实现包含图片类型检测、PNG/JPEG/GIF/WebP 附件、消息/session/provider 传递、Kitty/iTerm2 渲染和无能力 fallback。BMP 转换、自动 resize、剪贴板粘图和完整交互式图片 UI 尚未完成。

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
- 2026-08-19 当前 HEAD：`make clean && make build`、`make test`（全量串行）、`make e2e`（全量离线/PTY）、`make eval` 均通过；live smoke/journey 未运行，因为 `ADOU_LIVE_*` 未开启且未设置 `DEEPSEEK_*_API_KEY`。`slash-menu.sh --runs 3` 三轮均通过且屏幕一致；`tui-settings.sh`、`rpc-over-ipc.sh`、`radius-pi-messages.sh`、`tui-auth-overlay.sh`、`local-coding-journey.sh` 均通过。
- 2026-08-11 第二批：`read_piped_stdin()` 增加 native poll 前置探测（`native/stdin_peek.c`），空但未关闭的 FIFO 不再阻塞等 EOF；offline 守卫移到 piped/@file prompt 摄入之后。实跑：`/bin/sh -c 'out=$(printf "" | ./build/bin/adou --offline --no-context-files --no-session --print)'` 返回，`cli-startup-boundaries.sh` 覆盖 /dev/null、空 pipe、有内容 pipe、regular file 与损坏/缺失 session，自然退出通过（不再依赖 timeout）。
- 2026-08-11 第三批：`auth print-api-key` 失败路径统一 stdout 为空、`Error: ` 写 stderr、退出码非零；`auth-print.sh` 断言成功仅 stdout、失败三要素。
- 2026-08-11 第四批：Phase 5 收尾——`tui-tree-fork.sh` PTY 闭环覆盖 `/tree`（打开/取消/重开/过滤导航）、branch summary（`Summarize branch?` → `No summary` → `Navigated to selected point`）、`/fork`（`Forked to new session`）与 `/quit` 终端恢复（退出码 0）。该批记录为历史证据；**Phase 4 的 Interactive/TUI 交互子项与 Phase 5 已于 2026-08-14 重新打开**（`docs/pi-interactive-parity-audit-plan.md`），Batch 0 已由主代理验收通过（协议含 env 隔离、语义断言、三轮一致性，证据 `docs/pi-batch0-evidence/`）；Batch 1 实施中。
- 历史上的全量 `make test` 通过记录早于最新 Phase 5/6 提交，不代表当前 137 个单测文件已在同一 HEAD 全量重跑。
- 常规模型与测试密钥的项目约定维护在 `docs/porting-plan.md` 的“测试模型、密钥与成本约束”章节；集中实现于 `tests/e2e/lib/deepseek-test-config.sh`（被 source、不会被 `make e2e` 的 `tests/e2e/*.sh` glob 匹配）；普通回归优先 offline/local mock，live smoke 显式开启（`ADOU_LIVE_SMOKE=1`）并限制消费。
- 2026-08-11 live smoke 实跑：`ADOU_LIVE_SMOKE=1 ADOU_BIN=./build/bin/adou sh tests/e2e/live/live-smoke.sh` 通过（`deepseek/deepseek-v4-flash`，thinking off、64 max tokens、0 retries、60s timeout）；日志只输出 key 的配置状态，不打印 key 本身。
- 若 `nature --version` 已更新但 `/usr/local/nature/lib/darwin_arm64/libruntime.a` 仍是旧文件，Adou 仍会链接旧 runtime；需用管理员权限覆盖该静态库后再重新 `make clean && make build`。
- TUI 退出路径使用 Nature 标准输入接口；输入读取在独立协程中阻塞等待 `fs/libuv` 数据，解析协程通过 Nature channel 接收字节并用定时协程处理 ESC 超时，不修改 stdin fd flags。退出时先恢复终端再结束 CLI，避免后台监听协程拖住进程。

表中“已通过”只表示对应模块当前已验收的行为已经有源码差分和测试证据；它不表示全量 parity 已完成。Pi extension 是明确排除项，真实 provider OAuth recovery、图片完整处理、远程 viewer 契约、长会话 allocator 风险和其他未覆盖非 extension 能力仍属于开放工作。
