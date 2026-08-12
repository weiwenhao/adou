# Adou 全量移植计划（Pi 0.82.1，扩展机制暂缓）

状态：Phase 5、Phase 6、Phase 7、Phase 8 已完成 — 2026-08-12
基线：Pi `0.82.1`，commit `cced6a21da273b26ee4a23a803680614bbe8dd1e`（`vendors/pi`）
release hardening：进行中（Batch 1、Batch 2A 已完成；Batch 2B 需 Developer ID/notary 新权限，见 `docs/release-hardening-plan.md` 与 `docs/macos-signing.md`）
RC 稳定性门禁：2026-08-12 已跑（完整 `make e2e`、`make eval`、`make release-check`、`make signing-check` 证据见下）；历史 runtime blocker `nature#302` 已由上游 PR #303 修复并用专用 toolchain 验证，后续 PTY 冷启动失败也已定位为测试在 raw mode 前过早发键的同步缺陷并修复

## 当前进度快照

- Adou 当前有 218 个 `src/**/*.n` 文件、41,925 行 Nature 源码、138 个 Nature 单元测试文件（665 个 test case、2,724 个 `assert`）和 46 个 e2e 脚本。
- Phase 1–6 已完成并有源码差分、单元测试和跨模块验收记录；137 个单测文件在 2026-08-11 全量串行通过（7 个 OOM abort 单独重跑全过，deepseek fixture 回归已修复）。
- Phase 7（storage + server）已完成：storage 已完成（JSONL/memory/SQLite 三后端契约测试 + migrations + materialized 表），server supervisor/protocol/rpc_stream 已验收（Phase 7.1 于 2026-08-12 关闭）。
- 历史失败记录（cli-startup-boundaries 挂起、auth stdout 泄漏、ESC 10ms、deepseek fixture、全量 7 文件 OOM）均已由后续修复或重跑覆盖，见各批实跑证据。
- Phase 8（evals harness）已完成：`make eval` 3/3 绿（2026-08-12），见 `docs/evals-design.md`。
- Pi extension 已在生产入口停用：不扫描扩展目录、不初始化 QuickJS、不注册扩展工具/命令、不派发生命周期事件；默认构建不再链接 QuickJS。相关源码暂留作未来重新设计的参考。

| 阶段 | 状态 | 当前结论 |
|---|---|---|
| Phase 1：AI 层 | 已完成 | 39 个 provider、请求/流协议、模型兼容、图片 API、重试与认证主链已覆盖 |
| Phase 2：Agent harness | 已完成 | agent loop、工具、memory repo、shell 捕获、取消和 tool context 已覆盖 |
| Phase 3：coding-agent core | 已完成（排除扩展） | session、compaction、配置、skills、prompts、模型目录、诊断与导出已覆盖 |
| Phase 4：TUI 基础 | 已完成 | renderer、editor、autocomplete、fuzzy、路径补全、markdown、terminal image 逻辑已覆盖 |
| Phase 5：Interactive UI | 已完成 | 39 组件全部有结论；tree/fork/branch-summary PTY 闭环通过（tui-tree-fork.sh），终端恢复验证 |
| Phase 6：CLI | 已完成 | 9 个上游模块逐项对照；空 stdin 挂起、credential 输出隔离、help/参数矩阵、启动边界均通过（help-matrix/cli-startup-boundaries/auth-print/rpc-shape-parity 等 45 个 e2e） |
| Phase 7：storage + server | 已完成 | SQLite backend 已落地（nature-sqlite 绑定 + migrations/repo + 三后端契约测试 5/5）；server supervisor/协议/rpc_stream 已按上游 ipc/protocol.ts 重写，多实例生命周期与 rpc_stream e2e 通过（Phase 7.1 于 2026-08-12 关闭） |
| Phase 8：evals | 已完成 | pi-harness/smoke.eval 已移植（本地脚本化 HTTP mock），`make eval` 3/3 绿；extensions.eval 明确排除；见 `docs/evals-design.md` |

阶段完成度按行为验收判断，不用 Pi TypeScript 文件数推算百分比。当前严格确认 8/8 阶段关闭（Phase 1–8）。

## 目标与范围

目标是用 Nature 实现 Pi 的可观察 coding-agent 行为，并保持 Adou 的单一 Make/Nature 构建链。模块可以合并实现，不要求 TypeScript 文件与 Nature 文件一一对应。

当前明确排除或暂缓：

- Pi extension ABI、动态 TypeScript/ESM 加载、npm/git 扩展包管理、扩展工具/命令/UI/provider。
- OAuth/account 登录；当前认证边界为 API key、环境变量和已有 credential store 形状。
- 图片读取/交互式图片渲染；当前仅保留图片类型检测、图片 API 和文本工具占位语义。
- 远程分享服务；`/share` 当前只生成本地可分享 session artifact。

`.pi/skills`、`.pi/prompts`、slash commands、项目上下文和信任门控属于核心功能，已经实现，不在排除范围。

## 已完成阶段

### Phase 1｜AI 层

- 已注册全部 39 个 provider，并覆盖 OpenAI Responses/Completions、Anthropic Messages、Google、Mistral、Bedrock、Codex WebSocket、pi-messages 等协议分支。
- 已补齐 model compat、thinking 配置、constrained sampling、deferred tools、temperature/tool choice、provider retry、错误体截断、remote catalog、models.json overlay 和运行时认证解析。
- provider 使用 HTTP/协议单测验证；radius/pi-messages 有 e2e。
- OAuth 与运行时 lazy import 按范围排除；Nature 使用静态 provider registry。

### Phase 2｜Agent harness

- agent loop、并发/顺序工具、队列、取消、schema 校验、tool stream repair 和 session stream 生命周期已对齐。
- 内置 read/write/edit/bash/grep/find/ls、mutation queue、截断、输出清洗、流式 shell 捕获、完整输出落盘和临时文件能力已覆盖。
- memory repo 已覆盖 create/open/list/delete/fork、游标查询、active tools change 和 `position: "at"`。
- 图片工具维持 MVP 占位行为，不在本阶段继续扩展。

### Phase 3｜coding-agent core

- Pi v3 JSONL session、恢复/导入/导出、fork/clone/tree、自动压缩、branch summary、retained tail 与 usage/cost 统计已覆盖。
- settings/auth/trust/model resolution、remote catalog、project context、skills、prompt templates、slash commands、system prompt 和 git metadata 已接线。
- diagnostics、timings、output guard、静态 HTML/Markdown export 与 ANSI 转 HTML 已覆盖。
- SDK、扩展 package manager、交互式 HTML 模板和全局 HTTP dispatcher 按架构边界不移植。
- 早期 QuickJS 扩展实验已由 `98eef79` 停用：生产主链与默认构建不再依赖扩展运行时；`tests/e2e/rpc-extension-loading.sh` 现验证扩展 fixture 保持惰性。

### Phase 4｜TUI 基础

- differential renderer、终端恢复、输入序列、Unicode/grapheme、视觉行折行与跨行移动已覆盖。
- keybinding registry、kill ring、undo/history 快照、word navigation、Shift+Space 与滚动指示器已覆盖。
- Tab 路径补全、`@` 附件搜索、fd 式递归模糊匹配、命令/skill/prompt completion 已接入。
- Markdown 表格/引用/inline 样式和 terminal image 能力检测/协议编码/尺寸计算已覆盖。
- 已有 editor wrapping 与 auth overlay 两条 PTY e2e；IME 原生集成和 extension UI 不在本阶段范围。

## 下一阶段实施计划

### Phase 5｜Interactive UI 组件全量

当前已有：assistant/user/tool/bash/summary/status/footer 渲染，model/scoped-model/settings/login/logout/session/tree/fork/name/branch-summary/help/hotkeys/path-completion overlay，resume picker，以及外部编辑器入口。

逐组件 parity 审计（2026-08-11 更新）：对照 `modes/interactive` 下 39 个组件，全部非排除实现项已经收口。等价或合并实现包括 user/assistant/tool/bash、footer/status/keybinding-hints、login API-key 分支、session-selector、model/scoped-model selector、settings/config selector、visual truncate、countdown timer、theme selector、diff 行级着色、first-time setup、tree 搜索/过滤/折叠、custom editor、branch/compaction/custom message。明确排除项保持不变：OAuth 登录、extension-*、交互式图片渲染和纯装饰组件。

已实现批次（2026-08-10）：bash 完成态输出管理——render_bash_lines 接入 tool_output_expanded 折叠（视觉行末 20 行 + "N more lines, press Ctrl+O to expand"）、bash.truncated/full_output_path 渲染 "Output truncated. Full output: <path>"、退出码短格式 "(exit N)"（错误色）、活动 bash 视觉行截断 + 跳过计数、chat status 行不再重复 echo 退出码。新增 text_utils.truncate_visual_lines（Pi visual-truncate 语义）与 PTY e2e tui-bash-output.sh。

已实现批次（2026-08-10）：session selector/resume 主路径——session_search.n（Pi session-selector-search 对齐：搜索文本覆盖 id/名称/全部消息文本/cwd、re: 正则、引号短语、fuzzy token、relevance 排序 + recent 模式保序 + named 过滤）；OVERLAY_SESSION 搜索/排序接入（ctrl+s 循环 recent→alpha→relevance）；session_actions.delete_session_file（trash CLI 优先、unlink 回退、按实际方法报告状态，对齐 Pi deleteSessionFile）；单测 session_search 4/4、session_actions 2/2；PTY e2e tui-session-selector.sh（启动 picker 列出 fixture 会话、消息文本搜索过滤、空结果空态、escape 取消、终端恢复退出）。

补齐批次（2026-08-10）：完整对齐——Tab 作用域切换（Current Folder / All，options 合并集按 scope 过滤）；ctrl+s 四档排序（recent→alpha→relevance→threaded，threaded 按 parentSessionPath 树形排序 + │/├─/└─ 前缀渲染）；会话行元数据（消息数 + 相对时间 now/5m/3h/2d/w/mo/y + 路径视图 cwd，对齐 Pi formatSessionDate）；四种分场景空态文案（named/all/current 变体）；re: 查询走 native POSIX regex 桥（libc regcomp/regexec，REG_EXTENDED|ICASE，native/regex.o 接入 Makefile 与 package.toml [links]），替换子串近似；删除确认闭环的 PTY e2e 完整跑通（确认→取消→再确认→enter 删除→列表刷新→状态消息；此前失败为 e2e 自身 query 污染，非渲染竞态）。单测 session_search 6/6（含 threaded 树序与正则语义）、session_actions 2/2；PTY e2e 连跑 3 次稳定。

已收口：session-selector（含 PTY e2e）、bash-execution、visual-truncate、login API key 分支、tree 主体、footer/status。

已收口：model-selector / scoped-models-selector（当前模型 ✓、Tab All/Scoped、id/provider/名称搜索、详情行、空态、目录刷新反馈和默认模型保存）；settings/config selector（thinking/theme 子菜单、skills/prompts 资源启停和持久化）；theme、diff、countdown、first-time setup、tree 搜索/过滤/折叠均有对应实现和单测或 PTY 证据。

Phase 5 验收结果（2026-08-11 关闭）：`tui-tree-fork.sh` PTY 闭环覆盖 `/tree` 打开/搜索过滤/取消/重开、非 leaf 导航进入 branch summary（`No summary` 完成）、`/fork` 选择与 `Forked to new session`、`/quit` 终端恢复退出码 0；39 个组件矩阵全部有结论。历史“剩余验收项”已由该闭环覆盖。

### Phase 6｜CLI 补全

当前已有：参数解析与校验、`--list-models`、`@file`、piped stdin、initial messages、text/json/rpc/print 模式、session/continue/resume/fork、export、project trust 和启动时 session picker。

已关闭（2026-08-11）：

1. `/bin/sh` command substitution 下空 FIFO stdin 挂起：native `poll()` 前置探测（`native/stdin_peek.c`），写端未关闭且无数据时停止而非阻塞等 EOF；offline 守卫移到 piped/@file prompt 摄入之后。e2e 覆盖 /dev/null、空 pipe、有内容 pipe、regular file，自然退出通过。
2. `auth print-api-key` 输出隔离：成功仅 stdout；失败 stdout 空、`Error: ` 写 stderr、退出码非零；`auth-print.sh` 断言成功与全部失败模式的通道分离。
3. 9 个上游 CLI 文件逐项对照完成（args/config-selector/credential-print/file-processor/initial-message/list-models/project-trust/session-picker/startup-ui），HELP 覆盖全参数矩阵（`help-matrix.sh`）。
4. 每类 CLI 行为有针对性 e2e；text/JSON/RPC stdout 不受诊断日志污染。

Phase 6 完成标准已满足：9 个上游 CLI 文件逐项有结论；帮助文本与参数行为一致；`help-matrix.sh`、`cli-startup-boundaries.sh`、`auth-print.sh`、`rpc-shape-parity.sh` 及相关 CLI/RPC e2e 全绿（2026-08-11 实跑）。

### Phase 7｜storage + server

- 移植 SQLite storage 的 repo、migration、session/branch entry、sequence 和 materialized view。
- 在不替换现有 JSONL 默认存储前，先定义 repository 适配边界和双后端一致性测试。
- 移植 server 的 IPC protocol、rpc process、supervisor、handler、serve 和 radius；不得破坏现有进程内 RPC 协议。

Phase 7 完成标准：SQLite migration/storage 单测、JSONL/SQLite 行为一致性测试和 RPC-over-IPC e2e 通过。

Phase 7.1（server 协议 parity closeout，2026-08-11 落地，2026-08-12 已完成验收）：

- storage 段落关闭；server 段按上游 `packages/server/src/ipc/protocol.ts` 重写：
  `src/server/protocol.n`（响应形状）、`src/server/supervisor.n`（多实例表）、
  `src/server/ipc_server.n`（连接级逐行 TCP serve）、`src/app.n` run_serve/serve_command。
- 响应形状：spawn_result/list_result/status_result/stop_result/rpc_result/rpc_ready/error
  （ok/instance/instances/response 字段），不再使用旧 response/success 包装。
- 多实例：每 spawn 一个独立进程内 runner（独立 in-memory repository），id 为 uuid；
  stop=abort+移除；list/status 按实例表路由；未知 instanceId 返回
  `error{ok:false,error:"Unknown instance: <id>"}`；stop A 不影响 B。
- rpc_stream：同一连接 rpc_ready → 持续多命令 → 逐行 RpcResponse/AgentSessionEvent；
  连接断开即解除订阅；`extension_ui_response` 确定性返回
  `error{ok:false,error:"extensions disabled"}`。
- 实例隔离采用进程内 runner 而非子进程：审计
  `std/process/process.n`（`/Users/liulianfuren/Code/nature` 与安装版一致）——
  `command_t.stdin` 恒为 `fs.discard()`（/dev/null），无写 stdin API、无
  kill/terminate；运行时 `runtime/nutils/process.c` stdio[0] 固定 UV_IGNORE，
  无法给 `--mode rpc` 子进程喂命令流，子进程方案存在硬阻塞（证据与方案选择见
  `docs/phase7-storage-design.md` Phase 7.1 章节）。该差异已文档化。
- 验收（2026-08-12 串行实跑）：`make build` 退出 0；`tests/ipc_protocol_test.n`
  7/7、`tests/backend_list_session_paths_test.n` 2/2、
  `tests/repository_contract_test.n` 5/5、`tests/setup_test.n` 2/2；
  e2e `rpc-over-ipc.sh`（多实例生命周期 + rpc_stream 连接态 + 无遗留子进程）、
  `rpc-shape-parity.sh`、`rpc-empty-messages.sh`、`rpc-new-session.sh`、
  `rpc-tree-corrupt.sh` 全绿。

### Phase 8｜evals 基建

- 已移植 `pi-harness` 和 `smoke.eval`（`src/evals/harness.n` + `tests/evals/smoke_evals.n`）；`extensions.eval` 继续排除（Pi extension 已停用）。
- 统一验收入口 `make eval`：guarded 串行构建 smoke eval 入口并运行，每 case 一行 PASS/FAIL + 汇总；不改变 build/test/e2e 行为。
- smoke 集合：`basic-prompt`（mock 固定文本 Paris）、`tool-call-read`（mock 触发内置 read 工具并断言结果进入上下文、回传 provider）、`provider-error-handling`（HTTP 500 被标记为 run 失败且不崩溃）。
- 本地脚本化 HTTP mock provider（参照 anthropic/deepseek HTTP fixture server 模式），离线确定性，不用真实 API；结构设计与上游映射见 `docs/evals-design.md`。

Phase 8 验收结果（2026-08-12 关闭）：`make build` 退出 0；`make eval` 连续多次全绿（3 passed, 0 failed, exit 0；人为注入断言失败时输出 FAIL 行并 exit 1）；e2e 抽查 `rpc-shape-parity.sh`、`help-matrix.sh` 通过。

## 测试模型、密钥与成本约束

- 常规模型统一使用 `deepseek-v4-flash`；需要 provider-qualified reference 时使用 `deepseek/deepseek-v4-flash`。
- 项目测试用 DeepSeek API key：`REDACTED-PUBLIC-HISTORY`。
- 允许把该测试 key 保存在本私人项目的文档和测试源码中；测试实现应集中定义，避免在多个 fixture 中重复散落。
- 确定性 unit/e2e 默认使用 offline 或本地 mock，不因为 key 可用就把普通回归测试改成公网调用。
- Live DeepSeek smoke 必须显式开启，使用 `thinking=off`、低 `max-tokens`、单请求、禁用重试和非必要工具，避免并发和重复消费。
- 测试日志、失败信息和提交说明不得打印完整 key；credential-print 测试只断言输出通道和匹配结果。

## 2026-08-11 第二批实跑证据

- `make build`：退出 0；`make clean` 已删除 `native/regex.o` 与新增的 `native/stdin_peek.o`（Makefile clean 目标补齐）。
- 空 stdin 挂起修复：`/bin/sh -c 'out=$(printf "" | ./build/bin/adou --offline --no-context-files --no-session --print 2>&1 || true); echo DONE'` 立即返回 DONE（修复前卡死）；`echo -n "" | ./build/bin/adou --offline --no-context-files --no-session --print` 同样返回（POSIX sh 的 `echo -n ""` 输出字面 `-n`，测试统一改用 `printf ''`）。
- offline 守卫：`printf 'hello' | ./build/bin/adou --offline --no-context-files --no-session --print` → `Offline mode cannot send prompts to a provider`，退出码 0。
- `cli-startup-boundaries.sh`：7 个断言（no-TTY 诊断、/dev/null、空 pipe、有内容 pipe、regular file、损坏 session `Error: session file has no valid header` + 非零退出、缺失 session）全部自然退出通过。
- `auth-print.sh`：成功路径 stdout 仅 credential；失败路径 stdout 空、stderr `Error:` 前缀、退出码非零。
- Phase 5 收尾：`ADOU_BIN=./build/bin/adou sh tests/e2e/tui-tree-fork.sh` 通过（/tree 打开与 label、ESC 取消与重开、过滤导航 → `Summarize branch?` → `No summary` → `Navigated to selected point`、`/fork` → `Forked to new session`、`/quit` 退出码 0）。
- live smoke：`ADOU_LIVE_SMOKE=1 ADOU_BIN=./build/bin/adou sh tests/e2e/live/live-smoke.sh` 通过（`deepseek/deepseek-v4-flash`、thinking off、64 max tokens、0 retries、60s timeout）；默认（无开关）跳过。日志只输出 key 配置状态，不打印 key。live 集合统一由 `make e2e-live` 串行展开，普通 `make e2e` 不包含。
- 遗留：`tui-tree-fork.sh` 中 up 方向键（`[A`）经 PTY 输入会被拆包并在 10ms ESC 窗口外判定为 escape，测试改用 tree 的 `f` 过滤键选择非 leaf entry；真实键盘单次传输不受影响。该项记录为测试基础设施限制，不作为 Adou 缺陷。

## 2026-08-11 第三批实跑证据（剩余风险收口）

- 风险 1（无凭据快速失败 + 网络挂死）：完全无凭据（`PI_CODING_AGENT_DIR` 隔离 + env 清空）时 piped prompt 0.03s 内 `Error: No API key found for deepseek.` 退出——preflight 已存在。真正的挂死根因是 Nature TLS runtime：TCP 连接成功后停止超时 timer，mbedtls 握手阶段无超时（坏代理下永久挂）。应用层 watchdog（headless print/json，超时后 stderr 报错并 exit 1）作为兜底已实现；**根因已修复并发布**：issue `nature-lang/nature#300` → PR #301 `fix(runtime): time out stalled TLS handshakes` 已合并，系统 `libruntime.a` 已更新（2026-08-11 15:55）。验证：黑洞代理 + `--timeout-ms 8000` 默认构建 8s 有限退出；`api.deepseek.com` 正常握手 ~330-450ms；baidu 200。RPC 模式（watchdog 不覆盖）在黑洞下 46s 有限退出（DNS 解析亦慢），此前永久挂；watchdog 现为纯兜底。
- 风险 2（help 文本核对）：adou HELP 覆盖解析器全部参数（此前 `--debug` 已解析但未列出，已补行）；extension/skill/prompt-template/theme 参数按排除/等价（/config 资源启停）记录。9 个 CLI 上游模块对照：args.ts → `src/config/args.n`（含 help-matrix.sh 参数矩阵 e2e）；config-selector.ts → /config 资源启停（tui-config.sh）；credential-print.ts → `run_auth_print_api_key`（auth-print.sh，本批 stderr 隔离）；file-processor.ts → `load_file_arguments`（initial-messages.sh）；initial-message.ts → 启动消息合并；list-models.ts → `models.list_filtered`（model-selection.sh）；project-trust.ts → `--approve/--no-approve`（project-config.sh）；session-picker.ts → `--resume` picker（tui-session-selector.sh）；startup-ui.ts → setup overlay（tui-setup.sh）。`help-matrix.sh` 断言 HELP 含全部 35 个参数与 13 个短别名、--help/--version 退出 0 且 stderr 干净。
- 风险 3（PTY ESC 输入）：`ESCAPE_SEQUENCE_TIMEOUT_MS` 10ms → 50ms（xterm 惯例）；PTY 拆包的 `\x1b[A` 不再塌缩为 escape。`tui-tree-fork.sh` 改用真实上方向键导航 tree（移除 f 过滤绕行），全流程通过。
- 风险 4（全量回归）：137 个单测文件串行全量实跑（`tests/*.n` 逐个 guarded 调用，约 2 小时，16GB 机器满内存下 7 个文件编译器 OOM abort，单独重跑全部通过；1 个真实回归 `deepseek_http_stream_test.n` 已修复——fixture 需显式声明 `compat.thinking_format = 'deepseek'`（595f4de 起为运行时检测））。结论：137/137 通过（130 直接 + 7 重跑）。

## 2026-08-12 RC 稳定性门禁证据（历史 blocker：nature#302）

完整 `make e2e`（46 个脚本，offline/PTY，全部不出网）串行实跑 4 次：
第一次 46/46 绿（官方 `make e2e` 目标，总耗时 1:00.31）；第二次逐脚本计时循环
46/46 绿（总耗时 57s，单脚本最长 `tui-config.sh` 18s，其余 PTY 脚本 2–6s）；第三次
33/46 处 `tui-model-selector.sh` 失败（`current model check mark missing from the
selector`），单独复跑 3 次全绿；第四次（最终，全部改动落定后）46/46 绿（57.8s）。
逐脚本日志与本次失败的脱敏字节级证据保留在 `/tmp/adou-rc-gate/`（失败帧显示 model
行 id 渲染为同长度空格、当前模型 ✓ 缺失）。

### nature#302 → PR #303 已合并（2026-08-12 closure）

- 历史复现数据保留：Open 期间最小用例 v0.7.4 10/10 SIGABRT、weekly.2026.33 5/5；两个控制组 5/5 通过；TUI model selector 旧 runtime 72 次中 11 次内容损坏。
- 现状：`nature-lang/nature#302` 由 PR #303（`fix-concurrent-string-pool`）合并修复；上游 `20260812_00_const_string_pool` CTest 通过。
- 专用 toolchain：`/Users/liulianfuren/Code/nature-adou-toolchain`（commit `ad567d14`，nature v0.7.4 release build 2026-08-12）；`make clean && make build`（显式 NATURE/NATURE_ROOT）后 `nm build/bin/adou | grep const_str_pool_locker` 存在。
- closure 实测（2026-08-12，严格串行）：修复后的专用 runtime 下，`tui-model-selector.sh` 首轮连续 50 次 47 通过 / 3 失败，但失败已不是旧 runtime 的 model 行内容损坏；`make eval` 连续 5 次全绿，`make release-check`、`make signing-check` 全绿。
- PTY follow-up 定位：测试原先固定等待 1 秒后就发送 `Ctrl+L`；Adou 进入 raw mode 时使用 `tcsetattr(..., TCSAFLUSH, ...)`，冷启动超过 1 秒时会丢弃已排队的按键，随后是测试超时杀掉仍正常运行的 Adou，并非 Adou 自行无输出退出。人为延迟启动 2 秒时修复前稳定复现，改为等待 raw mode 之后的 `ESC[>1u` 键盘协议开启标记后同样场景通过。同类等待已覆盖 9 个会立即发键的 PTY 脚本；修复后 model selector 连续 50/50 通过，9 个定向 PTY 脚本及完整 `make e2e` 全绿。
- 当前结论：#302 内容损坏和独立 PTY 启动测试竞态均已有根因与验证闭环，不再是 RC blocker。
- 未调用真实 DeepSeek；未做真实签名/公证/发布。

- 历史 issue：https://github.com/nature-lang/nature/issues/302 ——
  `runtime: concurrent short dynamic strings corrupt const_str_pool and abort in sc_map_put_sv`
  （已由 fix PR #303 合并修复）。Nature runtime 的 coroutine 调度在多个 processor
  线程上并行执行；`string_new_with_pool` 无同步地访问进程全局 `const_str_pool`，
  并发创建 capacity <= 8 的动态字符串时 get/put/remap 竞态可损坏分配器并 SIGABRT。
- 纯 Nature 最小用例（64 coroutine × 20000 次 `fmt.sprintf('%06d', …)`，无应用代码/
  FFI/fs/网络）：v0.7.4 10/10 SIGABRT（栈顶 `sc_map_put_sv ← string_new_with_pool ←
  rt_vec_to_string_out ← utils.itos_with ← sprintf ← main.churn ← coroutine_wrapper`）；
  本地 weekly.2026.33 构建 5/5 SIGABRT。对照组均 5/5 通过：单 coroutine 同总分配量
  （WORKERS=1、ITERATIONS=1280000）；`%08d`（8 字节结果 capacity 9，绕过 pool）。
  复现期 crash report：`~/Library/Logs/DiagnosticReports/repro-2026-08-12-140606.ips`
  （v0.7.4）与 `repro-weekly-2026-08-12-141202*.ips`（weekly.2026.33），栈与 issue
  完全一致。
- Adou 侧同族静默表现（本批实测）：`tui-model-selector.sh` 的 model selector 首帧
  内容损坏——"deepseek-v4-flash [deepseek] ✓" 的 id/name 渲染为同长度空格、✓ 缺失，
  损坏帧之后 2s 内无重绘帧到达；与分配强度一致地 ~15%（11/72 次复跑）触发。该现象
  **早于 1249714 的 render_lock/quitting 修复**：1fec547（父提交）二进制同脚本 3/20
  触发，非本批回归。`render_lock` 只是串行化 render() 的防御性措施，**不修复 #302**
  （选项构建/输入处理等处的并发字符串创建不在锁内，且竞态发生在 runtime 线程之间）。
  已同步修正 `src/tui/session_view.n` 中此前"并发写竞态 runtime fs 层"的不准确注释，
  改为准确引用 #302 并明确 render_lock 不修复该 issue。
- 本批还观察到 #302 同族在 **Nature 编译器**上的崩溃：`make eval` 首次构建
  `adou-evals` 时编译器 SIGABRT（`~/Library/Logs/DiagnosticReports/nature-2026-08-12-144705.ips`，
  栈 `arm64_lower ← build ← cmd_entry`，malloc `free_list_checksum_botch` 堆损坏），
  属编译器自身 runtime 问题；按此前编译器 abort 的既有处置（单独重跑）复跑一次通过，
  共记录 1 次崩溃、1 次重试成功，不做无限重试。当日 01:16/01:44/01:51 的
  `nature-*.ips` 为先前最小用例复现期留下的同类 SIGABRT。
- 当时的处理边界：不修改 Nature 仓库、不在 Adou 内做覆盖 runtime 的伪修复、不弱化
  `tui-model-selector.sh`（其断言正确检测到真实的内容损坏）；本批完整 `make e2e`
  **未**触发 #302 的 SIGABRT 崩溃（`make eval` 编译器崩溃为本批唯一一次 #302 族
  崩溃，已按上一条记录）。后续上游 PR #303 已合并，专用 `libruntime.a`/
  编译器与 `tui-model-selector.sh` 已按上述 closure 证据复测。

### 门禁链（make e2e 之后串行执行）

- `make eval`：首次执行时 Nature 编译器构建 `adou-evals` SIGABRT（#302 同族，见上），
  单独复跑一次后 3/3 绿（basic-prompt / tool-call-read / provider-error-handling，
  exit 0）。
- `make release-check`：首次执行被上面的确定性 repo_root 缺陷挡下（见下），修复后
  build → eval 3/3 → dist → release-artifact → rpc-over-ipc → rpc-bash-stream 全绿。
- `make signing-check`：dist + macos-signing-workflow 全绿（preflight、fail-closed、
  fake-tool dry-runs、ad-hoc 副本 smoke、README 一致性；不真实签名/公证）。
- 分层检查：`make -n e2e` 展开 46 个 `tests/e2e/` 根目录脚本，**不含**
  `live/`、`release/` 任何子目录；`make -n e2e-live` 只含 live-smoke、
  live-coding-journey、live-tui-coding-journey 三个 DeepSeek 场景。`make e2e-live`
  无开关运行时 3 个脚本各自 skip（exit 0），不消耗额度、不调用真实 DeepSeek。
- 本批未调用真实 DeepSeek（live 场景全部 opt-in 关闭）。

### 本批发现的确定性测试缺陷（已修复，5/5 复跑）

`tests/e2e/release/release-artifact.sh` 与 `tests/e2e/release/macos-signing-workflow.sh`
在 1fec547 移入 `tests/e2e/release/` 子目录时未同步调整 `repo_root` 计算
（`dirname $0/../..` 只上溯两层，解析到 `tests/`），导致 `make release-check` /
`make signing-check` 在 dist 产物已生成时仍报 `release tarball not found`（确定性失败，
非竞态；Batch 1 时两脚本位于 e2e 根目录故未触发）。已改为 `../../..`（三层上溯），
修复后两脚本各 5/5 连续通过，`make release-check`、`make signing-check` 全绿。

### render_lock/quitting 回归检查（1249714）

重点脚本 `tui-bash-output.sh`、`tui-editor-wrapping.sh`、`tui-session-selector.sh`、
`tui-tree-fork.sh` 在 4 次完整 e2e 与一次定向复跑中全部通过：无死锁、/quit 退出码 0、
termios 恢复、无遗留 adou 进程、无丢帧断言失败。`tui-model-selector.sh` 的历史内容损坏来自
#302，与 render_lock 无关（父提交同概率复现）；该 runtime 缺陷和后续 PTY 测试同步缺陷现均已关闭。

## 2026-08-11 审查与实跑证据

- `make build`：退出 0；现有产物已是最新，Make 报告无需重新构建。
- 定向 Nature 单测：`chat_test.n` 11/11、`model_search_test.n` 2/2、`session_search_test.n` 7/7、`settings_persistence_test.n` 1/1、`setup_test.n` 2/2、`theme_test.n` 3/3，共 26/26 通过。
- PTY/e2e：`tui-model-selector.sh`、`tui-settings.sh`、`tui-config.sh`、`tui-setup.sh`、`auth-print.sh` 通过。
- `sh -n tests/e2e/*.sh` 通过。
- `cli-startup-boundaries.sh` 未通过：在 `/bin/sh` 下执行空 piped stdin 场景会挂起；此前 120 秒 timeout 不是通过证据，修复并自然退出前 Phase 6 保持进行中。
- 当前没有 line/branch coverage instrumentation。137 个单测文件包含 656 个 test case；156/218 个源码模块被单测直接 import（71.6% 直接模块触达率），这不是代码行覆盖率。4 个 extension 测试文件的 9 个 case 不计入生产功能覆盖结论。

## 验收与执行规则

每个阶段必须同时满足：

1. 固定 Pi 源码文件和 fixture 基线，并记录逐项行为结论。
2. Nature 单元测试覆盖正常、错误、取消、边界和顺序语义。
3. 至少一个跨模块集成或 e2e；不得只用孤立 mock 宣布完成。
4. 先运行 `make build`，再串行运行受影响的单文件 Nature 测试和 e2e。
5. 不并发运行 Nature、不使用 `make -j`、不运行 `nature fmt`；除非明确需要，不运行约两小时的完整 `make test`。

当前测试库存为 138 个 Nature 单元测试文件与 45 个 e2e 脚本；这只是覆盖资产数量，不代表每次提交后都重跑全量测试。最新可复核的模块证据维护在 `docs/pi-core-module-map.md`。
