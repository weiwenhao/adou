# Pi Core Module Map

状态：Pi `0.82.1` 的非 extension 可观察行为收口完成；唯一明确排除是 TypeScript/QuickJS extension runtime。2026-08-20 已完成 OpenAI browser OAuth/live request/refresh recovery、用户图片全链路、Kitty/iTerm2/plain 图片 UI、Radius discovery/web endpoint、真实 `/share` viewer、长历史/重复 live 会话和 63/63 普通离线 e2e。

本文把 `vendors/pi` 中必须翻译到 Nature 的核心边界固定下来。判断标准是 Pi 的可观察 coding-agent 行为，而不是 TypeScript 文件是否已经有一个同名 Nature 文件。每个模块只有在完成源码差分、单元测试和至少一个跨模块集成测试后，才可标记为完成。

## 核心模块

| 模块 | Pi 行为来源 | Nature 当前边界 | 当前测试 | 状态 |
|---|---|---|---|---|
| AI 数据模型与流协议 | `packages/ai/src/types.ts`, `api/openai-responses.ts`, `api/openai-completions.ts`, `api/anthropic-messages.ts`, `utils/event-stream.ts`, `utils/json-parse.ts`, `utils/retry.ts` | `src/ai/types.n`, `src/ai/event_stream.n`, `src/ai/sse.n`, `src/ai/streaming_json.n`, `src/ai/providers/*` | request/HTTP/SSE/streaming JSON/provider image tests；live OpenAI | 流式、重试、取消、malformed JSON、用户/工具图片和 OAuth provider lifecycle 已通过 |
| Agent loop | `packages/agent/src/agent-loop.ts`, `agent.ts`, `types.ts`, `stream-fn.ts`, `harness/messages.ts` | `src/agent/loop.n`, `types.n`, `schema.n`, `event_stream.n`, `session_stream.n` | agent loop 17/17；agent types 1/1；event stream 5/5；session 集成覆盖生命周期与工具结果 | 已通过：并发/顺序工具、队列、取消、prepare arguments、added tool names 已对齐 |
| 内置工具 | `packages/coding-agent/src/core/tools/{read,write,edit,bash,grep,find,ls,truncate,path-utils,file-mutation-queue}.ts`, `packages/agent/src/harness/tools/*` | `src/tools/{read,write,shell_tools,command,truncate,path_utils,mutation_queue,builtins}.n` | tools 27/27；builtins 3/3；tool-edge/tool-stream-repair、initial-messages、rpc-images、tui-images e2e | 文本工具、PNG/JPEG/GIF/WebP/BMP、自动 resize、macOS 剪贴板、用户/工具图片传递和 Kitty/iTerm2/plain 渲染已通过 |
| Session 与 JSONL | `packages/coding-agent/src/core/session-manager.ts`, `core/session-cwd.ts`, `packages/agent/src/harness/session/{session,jsonl-repo,jsonl-storage}.ts`；Phase 7：`packages/storage/sqlite-node` | `src/session/{repository,jsonl,message_json,types,identity,export_html}.n`、`src/session/backend.n`、`src/storage/*.n` | session 27/27；RPC clone/new/tree/import/export 场景通过；Phase 7 三后端契约测试（JSONL/memory/SQLite） | 已通过：Pi v3 append-only 链、分支、恢复、fork/clone 和跨 cwd 语义覆盖；SQLite backend 已随 Phase 7 storage 段落落地 |
| Server IPC（Phase 7.1） | `packages/server/src/ipc/{protocol,server}.ts`, `supervisor.ts`, `handler.ts`, `rpc-process.ts` | `src/server/{protocol,rpc_process,supervisor,ipc_server}.n` + `src/server/{storage,radius}.n` + `src/app.n` run_serve/serve_command | `tests/ipc_protocol_test.n`、`tests/rpc_process_test.n`、`tests/server_storage_test.n`、`tests/radius_test.n`；`rpc-over-ipc.sh`、`radius-pi-messages.sh`、`radius-presence.sh`、`share-fake-gh.sh`；live Radius/GitHub | IPC、持久化、heartbeat、404 重注册、Radius discovery/web endpoint、secret Gist artifact 和 `pi.dev` fragment viewer 已通过 |
| 自动压缩与分支摘要 | `packages/coding-agent/src/core/compaction/{compaction,branch-summarization,utils}.ts`, `packages/agent/src/harness/compaction/*` | `src/compaction/*.n`, `src/agent/session.n` | compaction 15/15；RPC compaction abort/retry/preprompt e2e | 已通过：cut point、retained tail、previous summary/file details、取消和重试覆盖 |
| 配置、认证、模型与项目上下文 | `packages/coding-agent/src/{config,core/auth-storage,core/model-{config,registry,resolver,runtime},core/settings-manager,core/resource-loader,core/system-prompt,core/project-trust}.ts`, `cli/args.ts` | `src/config/*.n`, `src/context/*.n`, `src/platform/cwd.n` | config context 25/25；auth/oauth/models/radius 定向测试；CLI/TUI auth e2e；live OpenAI OAuth | API-key、credential ownership、PKCE/device/browser callback、bearer、refresh、dynamic models 已通过；真实 OpenAI browser login/request/refresh recovery 已验证 |
| TUI、输入与终端渲染 | `packages/tui/src/{terminal,tui,stdin-buffer,keys,keybindings,editor-component,autocomplete,word-navigation,terminal-colors}.ts`, `packages/tui/src/components/*`, `packages/coding-agent/src/modes/interactive/components/*` | `src/tui/*.n` | Nature TUI tests；普通离线 e2e；slash/menu 3 轮；tui-images；long-session-history；live OpenAI journey | settings/auth/session/tree/resize/cancel/job-control、Kitty/iTerm2/plain 图片、320-message history 和真实三轮 follow-up 已验收 |
| CLI、print mode 与 RPC | `packages/coding-agent/src/{main,cli/*,modes/print-mode,modes/rpc/{rpc-mode,rpc-types,jsonl}}.ts` | `src/app.n`, `src/config/args.n`, `src/agent/event_json.n` | 45 个 e2e；event JSON 9/9 | 已通过：one-shot、JSON/RPC、abort/queue/retry/compact/session 命令、启动边界与事件顺序覆盖 |
| 导出与可观测性 | `packages/coding-agent/src/core/export-html/*`, `core/diagnostics.ts`, `core/timings.ts`, `core/output-guard.ts` | `src/session/export_html.n`, `src/debug.n`, `src/timings.n`, `src/output_guard.n`, `src/tui/virtual_terminal.n` | debug/observability；session/export assertions；export_html_images；`rpc-debug-stderr`、TUI/logging e2e | JSONL/HTML（含用户与工具图片）、诊断、启动计时和 RPC 输出隔离已覆盖 |

## 当前明确排除边界

下列 extension 边界明确排除，不能被“已有文件数”或局部测试结果掩盖：

- `packages/coding-agent/src/core/extensions/**`、`src/extensions/**`：TypeScript extension ABI、加载器、事件总线和扩展 UI。早期 QuickJS 实验源码暂留，但生产入口、TUI/RPC 接线和默认链接已停用。
- `packages/coding-agent/src/extensions/**`：Llama 等扩展 provider。
- 动态 `.pi/extensions` 资源加载和扩展包管理。`.pi/skills`、`.pi/prompts`、slash commands 已作为核心功能实现，不属于本排除项。
- `packages/server/**` 的核心 remote viewer artifact/URL 已通过真实 Gist 与 `pi.dev` viewer；Radius 的公开 discovery/web endpoint 已 live 验证。Radius 页面只提供 Email/Google，是否创建第三方账号是外部账号状态，不是 Adou 代码缺口。
- Pi 图片链路已覆盖类型检测、PNG/JPEG/GIF/WebP/BMP、resize、macOS clipboard、CLI/RPC/session、全部原生 provider、SDK/HTML、Kitty/iTerm2 和 plain fallback。

## 验收规则

每个核心模块必须有：

1. 固定的 Pi 源码文件和测试 fixture 引用。
2. Nature 实现的逐项行为差分记录。
3. Nature 单元测试，覆盖正常、错误、取消、边界和顺序语义。
4. 至少一个跨模块集成测试；provider/agent/session/TUI 不得只用孤立 mock 证明完成。
5. `make build`、相关 `make test` 或 Nature feature test，以及受影响的 `make e2e` 通过。

“有同名文件”或“已有一条 happy-path 测试”不满足完成条件。

## 当前测试口径与验收证据

- 当前有 241 个 Nature 源文件、161 个 Nature 单测文件、63 个普通离线 e2e 脚本和 7 个 opt-in live 脚本。项目没有 line/branch coverage instrumentation，不把文件触达率表述成代码覆盖率。
- 2026-08-20 当前 worktree：串行 `make build`、受影响的 12 个 Nature test 文件和 `make e2e` 63/63 通过。live OpenAI browser OAuth、真实请求、隔离强制过期 refresh recovery、持久化三轮 follow-up 和 Radius discovery/web endpoint 通过；真实 secret Gist 已由 `pi.dev` viewer 渲染并随后删除。
- 2026-08-11 第二批：`read_piped_stdin()` 增加 native poll 前置探测（`native/stdin_peek.c`），空但未关闭的 FIFO 不再阻塞等 EOF；offline 守卫移到 piped/@file prompt 摄入之后。实跑：`/bin/sh -c 'out=$(printf "" | ./build/bin/adou --offline --no-context-files --no-session --print)'` 返回，`cli-startup-boundaries.sh` 覆盖 /dev/null、空 pipe、有内容 pipe、regular file 与损坏/缺失 session，自然退出通过（不再依赖 timeout）。
- 2026-08-11 第三批：`auth print-api-key` 失败路径统一 stdout 为空、`Error: ` 写 stderr、退出码非零；`auth-print.sh` 断言成功仅 stdout、失败三要素。
- 2026-08-11 第四批的 TUI 结论曾于 2026-08-14 重新打开；2026-08-20 已由图片 UI、320-message history、真实 OpenAI 三轮 journey 和本轮 63/63 普通离线 e2e 再次闭合。
- 本轮按项目约束运行受影响的定向 Nature tests，未重复耗时的全量 `make test`；全量 Nature 历史记录为 2026-08-19，当前源码增量由定向测试与完整离线 e2e 覆盖。
- 常规模型与测试密钥的项目约定维护在 `docs/porting-plan.md` 的“测试模型、密钥与成本约束”章节；集中实现于 `tests/e2e/lib/deepseek-test-config.sh`（被 source、不会被 `make e2e` 的 `tests/e2e/*.sh` glob 匹配）；普通回归优先 offline/local mock，live smoke 显式开启（`ADOU_LIVE_SMOKE=1`）并限制消费。
- 2026-08-11 live smoke 实跑：`ADOU_LIVE_SMOKE=1 ADOU_BIN=./build/bin/adou sh tests/e2e/live/live-smoke.sh` 通过（`deepseek/deepseek-v4-flash`，thinking off、64 max tokens、0 retries、60s timeout）；日志只输出 key 的配置状态，不打印 key 本身。
- 若 `nature --version` 已更新但 `/usr/local/nature/lib/darwin_arm64/libruntime.a` 仍是旧文件，Adou 仍会链接旧 runtime；需用管理员权限覆盖该静态库后再重新 `make clean && make build`。
- TUI 退出路径使用 Nature 标准输入接口；输入读取在独立协程中阻塞等待 `fs/libuv` 数据，解析协程通过 Nature channel 接收字节并用定时协程处理 ESC 超时，不修改 stdin fd flags。退出时先恢复终端再结束 CLI，避免后台监听协程拖住进程。

表中“已通过”表示对应模块已有源码差分和测试证据。本轮此前列出的 OAuth recovery、图片链路、remote viewer/server API 和长会话四类缺口已经闭合，当前 worktree 的完整离线 e2e 与 diff 审计也已通过。Pi extension 是唯一明确排除项。
