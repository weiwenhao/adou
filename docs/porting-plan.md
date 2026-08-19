# Adou 全量移植计划（Pi 0.82.1，扩展机制暂缓）

状态：当前目标为 Pi `0.82.1` 的全量可观察行为对齐，唯一明确排除是 TypeScript/QuickJS extension runtime。2026-08-20 本批已闭合真实 OpenAI browser OAuth、真实请求和强制过期 refresh recovery，用户图片的 CLI/RPC/session/provider/SDK/HTML 全链路，Kitty/iTerm2/plain TUI 图片交互，以及 Radius 公开 OAuth discovery/web 契约和长历史/重复 live 交互。Radius 第三方账号登录页当前只提供 Email/Google，账号创建不作为 Adou 代码 parity 的完成条件。
基线：Pi `0.82.1`，commit `cced6a21da273b26ee4a23a803680614bbe8dd1e`（`vendors/pi`）
release hardening：macOS 主线进行中（Batch 1、Batch 2A、native `.pkg` installer 已完成；Batch 2B 真实签名/公证需新权限；Linux 暂缓，见 `docs/release-hardening-plan.md`、`docs/macos-signing.md` 与 `docs/macos-installer.md`）
RC 稳定性门禁：2026-08-12 已跑（完整 `make e2e`、`make eval`、`make release-check`、`make signing-check` 证据见下）；历史 runtime blocker `nature#302` 已由上游 PR #303 修复并用专用 toolchain 验证，后续 PTY 冷启动失败也已定位为测试在 raw mode 前过早发键的同步缺陷并修复

## 2026-08-20 非 Extension 差异补齐批次

- **阶段 1 已完成（提交待写入）**：对照 `vendors/pi/packages/coding-agent/src/migrations.ts`、`utils/version-check.ts`、`utils/changelog.ts` 和 `utils/tools-manager.ts`，新增 `src/config/migrations.n`、`src/config/version_check.n`、`src/config/changelog.n`、`src/tools/managed_tools.n`。
- 启动期迁移已覆盖旧 `oauth.json`、settings 中 `apiKeys`、agent 根目录旧 JSONL session、旧 `tools/{rg,fd}`；迁移范围严格限制在 `ADOU_CODING_AGENT_DIR`，不改写 `~/.pi`。
- `/changelog` 已改为解析 `CHANGELOG.md`，启动版本检查请求 `https://pi.dev/api/latest-version`，支持 `ADOU_OFFLINE` / `ADOU_SKIP_VERSION_CHECK` 守卫。
- `rg` / `fd` 已具备本机查找、`fdfind` 兼容、GitHub release 查询/下载/解包/安装路径；离线模式不联网。
- 证据：`make build` 通过；`tests/startup_migrations_test.n` 4/4 通过。工具下载 fixture/e2e 仍需在本阶段最终关闭前补齐。

## 当前进度快照

- Adou 当前有 241 个 `src/**/*.n` 文件、161 个 Nature 单元测试文件和 63 个普通离线 e2e 脚本；另有 7 个 opt-in live 脚本。
- Phase 1–3、6 已完成并有源码差分、单元测试和跨模块验收记录；Phase 4/5 的 Interactive 相关结论于 2026-08-14 重新打开（见 `docs/pi-interactive-parity-audit-plan.md`）；137 个单测文件在 2026-08-11 全量串行通过（7 个 OOM abort 单独重跑全过，deepseek fixture 回归已修复）。
- Phase 7（storage + server）已完成：storage 已完成（JSONL/memory/SQLite 三后端契约测试 + migrations + materialized 表），server supervisor/protocol/rpc_stream 已验收（Phase 7.1 于 2026-08-12 关闭）。
- 历史失败记录（cli-startup-boundaries 挂起、auth stdout 泄漏、ESC 10ms、deepseek fixture、全量 7 文件 OOM）均已由后续修复或重跑覆盖，见各批实跑证据。
- Phase 8（evals harness）已完成：`make eval` 3/3 绿（2026-08-12），见 `docs/evals-design.md`。
- 2026-08-19 当前 worktree 复验：全量 `make test`、`make e2e`、`make eval` 通过；slash/menu 三轮屏幕一致、IPC/Radius/TUI OAuth/settings/local journey 定向门禁通过。`make pkg-check`、签名/发布门禁不属于本轮功能变更的必要门禁，未重复运行。长会话 allocator 风险仍需真实 provider/长时采样闭合。
- Skills parity foundation 增量批次已关闭（2026-08-13）：`--skill`/`--no-skills`、发现优先级、trust 重解析、`/reload`、RPC `get_commands` 与 Markdown 单次分词已落地并验证（见下文 Skills parity foundation 节）。
- Pi extension 已在生产入口停用：不扫描扩展目录、不初始化 QuickJS、不注册扩展工具/命令、不派发生命周期事件；默认构建不再链接 QuickJS。相关源码暂留作未来重新设计的参考。

| 阶段 | 状态 | 当前结论 |
|---|---|---|
| Phase 1：AI 层 | 已完成（extension 除外） | 39 个 provider、请求/流协议、模型兼容、用户/工具图片、重试、provider-specific OAuth bearer/refresh 和动态模型元数据已覆盖；OpenAI OAuth 请求与 refresh recovery 已 live 验收 |
| Phase 2：Agent harness | 已完成（当前基线） | agent loop、工具、memory repo、shell 捕获、取消和 tool context 已覆盖 |
| Phase 3：coding-agent core | 已完成（extension 除外） | session、compaction、配置、skills、prompts、模型目录、诊断与导出已覆盖；Pi 的非 extension 边界继续按全量目标补齐 |
| Phase 4：TUI 基础 | 已完成（extension 除外） | editor/autocomplete/keybindings/cursor、renderer、terminal recovery、路径补全、markdown、Kitty/iTerm2/plain 图片和 320-message resize 压力已验证 |
| Phase 5：Interactive UI | 已完成（extension 除外） | Batch 0–7、settings/auth/session/tree/resize/cancel/job-control、图片 UI、长历史以及真实 provider 三轮 follow-up 已通过 |
| Phase 6：CLI | 已完成 | 9 个上游模块逐项对照；空 stdin 挂起、credential 输出隔离、help/参数矩阵、启动边界均通过（help-matrix/cli-startup-boundaries/auth-print/rpc-shape-parity 等 45 个 e2e） |
| Phase 7：storage + server | 已完成（extension 除外） | SQLite/JSONL/memory、IPC/rpc_stream、实例表、旧远端 Pi 断开、machine/Pi heartbeat、3 次 404 重注册、Radius discovery/web endpoint、`session.html` Gist share 和真实 fragment viewer 已验证 |
| Phase 8：evals | 已完成 | pi-harness/smoke.eval 已移植（本地脚本化 HTTP mock），`make eval` 3/3 绿；extensions.eval 明确排除；见 `docs/evals-design.md` |

阶段完成度按行为验收判断，不用 Pi TypeScript 文件数推算百分比。本轮四个补齐批次已经闭合；最终结论仍以当前 worktree 的串行构建、定向 Nature tests、完整离线 e2e 和证据审计为准。第三方 Radius 账号是否创建属于用户外部状态，不作为 Nature 实现缺口。

## 目标与范围

目标是用 Nature 实现 Pi 的可观察 coding-agent 行为，并保持 Adou 的单一 Make/Nature 构建链。模块可以合并实现，不要求 TypeScript 文件与 Nature 文件一一对应。

当前明确排除与开放项：

- **明确排除**：Pi extension ABI、动态 TypeScript/ESM 加载、npm/git 扩展包管理、扩展工具/命令/UI/provider。
- **本批已闭合**：真实 provider OAuth/live recovery、用户图片附件与 provider 传递、跨终端交互式图片 UI、SDK/HTML/RPC 图片 API、Radius 公开 web/discovery、远程 share/viewer 以及长历史/重复交互证据。
- **平台工作**：Linux 构建、交叉编译、签名/公证属于发布工程，不改变 Pi 行为 parity 的目标。

`.pi/skills`、`.pi/prompts`、slash commands、项目上下文和信任门控属于核心功能，已经实现，不在排除范围。

2026-08-20 四个收口批次包括：

1. OAuth/account：真实 OpenAI browser OAuth、live 请求和强制过期 refresh recovery；credential union、login/refresh/logout、loopback callback 与 device/browser 选择保留既有 unit/e2e。
2. 图片与多模态：`@image`、RPC image、消息/session 序列化、全部原生 provider 输入转换、SDK、HTML 导出、BMP/resize/clipboard 以及 Kitty/iTerm2/plain TUI。
3. 分享与 server/API：Radius 真实 discovery/web endpoint、presence/recovery、SDK 图片 surface、HTML 图片导出、真实 Gist 与 fragment viewer。
4. 稳定性：320-message TUI restore/resize/exit，以及 OpenAI OAuth 同一持久化 session 三轮 follow-up。

## 全量对齐阶段

以下是当前执行用的全量 parity 分阶段方案。旧的 Phase 1–8 保留为实现历史和已验收
证据；本表是后续工作的交付顺序。所有阶段都只对齐 Pi 可观察行为，TypeScript/QuickJS
extension runtime 在全程明确排除。

| 阶段 | 范围 | 完成门槛 | 当前状态 |
|---|---|---|---|
| Stage 0：基线冻结 | 固定 Pi 0.82.1 source/oracle、终端尺寸、设置、cwd、fixture、按键协议和证据格式 | Pi source 与真机 oracle 版本一致；同一 case 连续 3 轮稳定；禁止用旧版本画面证明当前 parity | **已完成（2026-08-18）**：`vendors/pi` 与 Herdr `w7:pD` 均为 `0.82.1` / `cced6a21...`；Batch 0 slash 基线三轮 PASS |
| Stage 1：核心 agent 基线 | AI provider、agent loop、工具、session、compaction、CLI、RPC/IPC、skills/context | 相关 Nature 单测、离线 e2e、eval 和已有跨模块证据在当前 HEAD 复验通过 | **已完成（2026-08-19）**：153 个定向 Nature 用例、58/58 离线 e2e、eval 3/3 通过；见 `docs/stage1-core-baseline-evidence.md` |
| Stage 2：Interactive/TUI | autocomplete、selector、settings、editor、keybindings、stream/resize、session/tree/fork、terminal lifecycle | 每个组件具备 state/transition/render/effect/cancel 契约；direct + slash/integration PTY；同版本 Pi 对照；Batch 7 长会话通过 | **已完成**：离线组合门禁、Kitty/iTerm2/plain 图片和 320-message resize 压力通过 |
| Stage 3：认证与 provider lifecycle | OAuth/account、credential union、login/refresh/logout、过期刷新、bearer token、Radius OAuth、API-key 与 OAuth 混合模型选择 | provider capability、存储、CLI/TUI/RPC、刷新失败恢复和模型认证过滤全部有 unit + integration + live smoke | **已完成**：OpenAI browser OAuth、live request、隔离强制过期 refresh recovery 通过；Radius discovery/web endpoint live 通过 |
| Stage 4：图片与多模态 | `read` imageProcessor、图片消息/session 序列化、provider 输入转换、剪贴板粘图、Kitty/iTerm2 TUI 图片组件、图片 settings effect | PNG/JPEG/GIF/WebP/BMP 边界、真实消息往返、无图片终端 fallback、settings 持久化/恢复和 PTY 证据通过 | **已完成**：CLI/RPC/session/provider/SDK/HTML 链路与 Kitty/iTerm2/plain PTY 通过 |
| Stage 5：server/share 与剩余非 extension 表面 | `/share` 远程 artifact/viewer、Radius presence、实例表持久化、SDK/API surface、交互式导出模板、全局 HTTP 行为 | 与 Pi server/coding-agent 契约逐项对照；多实例重启/恢复、远程分享和导出结果可验证 | **已完成**：Radius presence/discovery/web endpoint、SDK/HTML 图片、真实 Gist 与 `pi.dev` viewer 通过 |
| Stage 6：runtime 稳定性 | 长会话/重复 `/model`、取消/resize/job-control 压力 | 长会话采样稳定；取消、resize、job-control 压力矩阵通过 | **已完成**：320-message restore/resize 和 OpenAI 持久化三轮 follow-up 通过 |
| Stage 7：全量收口验收 | 完整功能矩阵、Pi 0.82.1 真机 3 轮、真实 provider smoke、离线回归、凭据/产物审计 | 所有非 extension 项为 PASS；未完成项为零；最终报告明确 extension 的唯一 EXCLUDED 差异 | **已完成（2026-08-20）**：四个增量批次、受影响的 12 个 Nature test 文件、63/63 普通离线 e2e、OpenAI OAuth/request/refresh/三轮 journey 和 Radius live web contract 通过 |

Linux、交叉编译、Developer ID 签名和公证继续走独立 release track。它们可以与
Stage 2–6 并行推进，但不改变功能 parity 的 PASS/FAIL 判定。

## 已完成阶段

### Phase 1｜AI 层

- 已注册全部 39 个 provider，并覆盖 OpenAI Responses/Completions、Anthropic Messages、Google、Mistral、Bedrock、Codex WebSocket、pi-messages 等协议分支。
- 已补齐 model compat、thinking 配置、constrained sampling、deferred tools、temperature/tool choice、provider retry、错误体截断、remote catalog、models.json overlay 和运行时认证解析。
- provider 使用 HTTP/协议单测验证；radius/pi-messages 有 e2e。
- OAuth 已覆盖 provider-owned login/refresh/logout、OAuth credential、浏览器/device flow 和真实 OpenAI recovery。Nature 继续使用静态 provider registry；可观察行为等价，不复制 TypeScript lazy import 机制。

### Phase 2｜Agent harness

- agent loop、并发/顺序工具、队列、取消、schema 校验、tool stream repair 和 session stream 生命周期已对齐。
- 内置 read/write/edit/bash/grep/find/ls、mutation queue、截断、输出清洗、流式 shell 捕获、完整输出落盘和临时文件能力已覆盖。
- memory repo 已覆盖 create/open/list/delete/fork、游标查询、active tools change 和 `position: "at"`。
- 图片已覆盖读取/processor、BMP 转换与 resize、消息/session/provider/SDK/RPC/HTML 传递、clipboard 和 Kitty/iTerm2/plain TUI 渲染。

### Phase 3｜coding-agent core

- Pi v3 JSONL session、恢复/导入/导出、fork/clone/tree、自动压缩、branch summary、retained tail 与 usage/cost 统计已覆盖。
- settings/auth/trust/model resolution、remote catalog、project context、skills、prompt templates、slash commands、system prompt 和 git metadata 已接线。
- diagnostics、timings、output guard、静态 HTML/Markdown export 与 ANSI 转 HTML 已覆盖。
- 扩展 package manager 随 extension runtime 明确排除；SDK/API surface、交互式 HTML 模板和全局 HTTP 行为需要按可观察契约继续审计，不能仅以旧架构边界判为完成。
- 早期 QuickJS 扩展实验已由 `98eef79` 停用：生产主链与默认构建不再依赖扩展运行时；`tests/e2e/rpc-extension-loading.sh` 现验证扩展 fixture 保持惰性。

### Phase 4｜TUI 基础

> **2026-08-14 状态更新：Interactive/TUI 交互子项重新打开（reopened）。**
> 下方历史记录保留为事实。按 `docs/pi-interactive-parity-audit-plan.md`，
> IP-006（autocomplete 架构）、IP-008（app keybindings registry）与 Batch 4
> （editor/cursor/IME/keybindings）归属本阶段的交互部分，随 Phase 5 一并
> 重新验收；renderer 差分渲染、终端恢复、fuzzy、路径补全、markdown 等
> 已验证子项保留原结论与证据。

- differential renderer、终端恢复、输入序列、Unicode/grapheme、视觉行折行与跨行移动已覆盖。
- keybinding registry、kill ring、undo/history 快照、word navigation、Shift+Space 与滚动指示器已覆盖。
- Tab 路径补全、`@` 附件搜索、fd 式递归模糊匹配、命令/skill/prompt completion 已接入。
- Markdown 表格/引用/inline 样式和 terminal image 能力检测/协议编码/尺寸计算已覆盖。
- 已有 editor wrapping 与 auth overlay 两条 PTY e2e；extension UI 明确排除，IME 原生集成继续按 TUI 全量 parity 验收。

## 下一阶段实施计划

### Phase 5｜Interactive UI 组件全量

> **2026-08-14 状态更新：本阶段已重新打开（reopened）。** 下方 2026-08-10/11 的
> "已收口/已关闭" 记录保留为历史事实，但不再作为 Interactive UI 的验收依据。
> 2026-08-14 真机复现与源码对照（`docs/pi-interactive-parity-audit-plan.md`，
> IP-001..012）证明：多个组件被合并进通用 overlay 后丢失了数据模型、状态所有权、
> 查询生命周期、可见窗口、配置驱动和取消/确认语义；现有测试以直接打开单个
> overlay 和静态字符串断言为主。后续按审计计划 Batch 0→7 逐组件重新对照与验收；
> Batch 0 至 Batch 6 均已由主代理验收通过；协议与证据见
> `docs/pi-interactive-parity-audit-plan.md` 及 `docs/pi-batch*-evidence/`；下一批为
> Batch 7，并继续承接 OAuth、图片等新打开的全量 parity 项。

当前已有：assistant/user/tool/bash/summary/status/footer 渲染，model/scoped-model/settings/login/logout/session/tree/fork/name/branch-summary/help/hotkeys/path-completion overlay，resume picker，以及外部编辑器入口。

逐组件 parity 审计（2026-08-11 更新，历史结论见上方当前状态）：对照 `modes/interactive` 下 39 个组件，全部非 extension 实现项已经收口。等价或合并实现包括 user/assistant/tool/bash、footer/status/keybinding-hints、login、session/model/scoped-model/settings selector、editor、theme/diff、first-time setup、tree、branch/compaction/custom message。OAuth、交互式图片和长会话已由 2026-08-20 的增量批次补齐。

已实现批次（2026-08-10）：bash 完成态输出管理——render_bash_lines 接入 tool_output_expanded 折叠（视觉行末 20 行 + "N more lines, press Ctrl+O to expand"）、bash.truncated/full_output_path 渲染 "Output truncated. Full output: <path>"、退出码短格式 "(exit N)"（错误色）、活动 bash 视觉行截断 + 跳过计数、chat status 行不再重复 echo 退出码。新增 text_utils.truncate_visual_lines（Pi visual-truncate 语义）与 PTY e2e tui-bash-output.sh。

已实现批次（2026-08-10）：session selector/resume 主路径——session_search.n（Pi session-selector-search 对齐：搜索文本覆盖 id/名称/全部消息文本/cwd、re: 正则、引号短语、fuzzy token、relevance 排序 + recent 模式保序 + named 过滤）；OVERLAY_SESSION 搜索/排序接入（ctrl+s 循环 recent→alpha→relevance）；session_actions.delete_session_file（trash CLI 优先、unlink 回退、按实际方法报告状态，对齐 Pi deleteSessionFile）；单测 session_search 4/4、session_actions 2/2；PTY e2e tui-session-selector.sh（启动 picker 列出 fixture 会话、消息文本搜索过滤、空结果空态、escape 取消、终端恢复退出）。

补齐批次（2026-08-10）：完整对齐——Tab 作用域切换（Current Folder / All，options 合并集按 scope 过滤）；ctrl+s 四档排序（recent→alpha→relevance→threaded，threaded 按 parentSessionPath 树形排序 + │/├─/└─ 前缀渲染）；会话行元数据（消息数 + 相对时间 now/5m/3h/2d/w/mo/y + 路径视图 cwd，对齐 Pi formatSessionDate）；四种分场景空态文案（named/all/current 变体）；re: 查询走 native POSIX regex 桥（libc regcomp/regexec，REG_EXTENDED|ICASE，native/regex.o 接入 Makefile 与 package.toml [links]），替换子串近似；删除确认闭环的 PTY e2e 完整跑通（确认→取消→再确认→enter 删除→列表刷新→状态消息；此前失败为 e2e 自身 query 污染，非渲染竞态）。单测 session_search 6/6（含 threaded 树序与正则语义）、session_actions 2/2；PTY e2e 连跑 3 次稳定。

已收口：session-selector（含 PTY e2e）、bash-execution、visual-truncate、login API key 分支、tree 主体、footer/status。

已收口：model-selector / scoped-models-selector（当前模型 ✓、Tab All/Scoped、id/provider/名称搜索、详情行、空态、目录刷新反馈和默认模型保存）；settings/config selector（thinking/theme 子菜单、skills/prompts 资源启停和持久化）；theme、diff、countdown、first-time setup、tree 搜索/过滤/折叠均有对应实现和单测或 PTY 证据。

Phase 5 验收结果（2026-08-11 关闭，**2026-08-14 撤销**）：`tui-tree-fork.sh` PTY 闭环覆盖 `/tree` 打开/搜索过滤/取消/重开、非 leaf 导航进入 branch summary（`No summary` 完成）、`/fork` 选择与 `Forked to new session`、`/quit` 终端恢复退出码 0；39 个组件矩阵全部有结论。历史“剩余验收项”已由该闭环覆盖。该关闭结论仅代表当时的 happy-path 证据，不满足 `docs/pi-interactive-parity-audit-plan.md` §9 完成定义（state/event/transition/render/effect/cancel 契约、direct+integration PTY、同版本 Pi 真机对照）。

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

Phase 7.1（server 协议 2026-08-12 首次关闭；2026-08-16 完成真实多进程隔离）：

- storage 段落关闭；server 段按上游 `packages/server/src/ipc/protocol.ts` 重写：
  `src/server/protocol.n`（响应形状）、`src/server/rpc_process.n`（子进程 JSONL
  transport/pending/lifecycle）、`src/server/supervisor.n`（多实例表）、
  `src/server/ipc_server.n`（连接级逐行 TCP serve）、`src/app.n` run_serve/serve_command。
- 响应形状：spawn_result/list_result/status_result/stop_result/rpc_result/rpc_ready/error
  （ok/instance/instances/response 字段），不再使用旧 response/success 包装。
- 多实例：每 spawn 一个独立 `adou --mode rpc` 子进程和持久化 session，id 为 uuid；
  stop=SIGTERM（有界 SIGKILL fallback）；list/status 按实例表路由；未知 instanceId 返回
  `error{ok:false,error:"Unknown instance: <id>"}`；stop A 不影响 B。
- rpc_stream：同一连接 rpc_ready → 持续多命令 → 逐行 RpcResponse/AgentSessionEvent；
  连接断开即解除订阅；`extension_ui_response` 确定性返回
  `error{ok:false,error:"extensions disabled"}`。
- 旧 stdin blocker 已由 nature-lang/nature issue #308 / PR #309 解除：runtime
  现在消费自定义 `cmd.stdin` 并建立真实 pipe。Nature PR #310 也已让 runtime
  消费 `command_t.cwd`；Adou 在 spawn 前直接设置 child cwd，测试读取 session
  header 验证该目录。
- 多进程验收（2026-08-16 串行实跑）：`make build` 退出 0；
  `tests/rpc_process_test.n` 2/2；`tests/ipc_protocol_test.n`
  7/7、`tests/backend_list_session_paths_test.n` 2/2、
  `tests/repository_contract_test.n` 5/5、`tests/setup_test.n` 2/2；
  e2e `rpc-over-ipc.sh`（两个真实 child PID、并发 pending 路由、目标 cwd、
  rpc_stream、stop 单实例隔离、父退出无 orphan）、
  `rpc-shape-parity.sh`、`rpc-empty-messages.sh`、`rpc-new-session.sh`、
  `rpc-tree-corrupt.sh` 全绿；完整 `make e2e` 54 个脚本串行 exit 0。

### Phase 8｜evals 基建

- 已移植 `pi-harness` 和 `smoke.eval`（`src/evals/harness.n` + `tests/evals/smoke_evals.n`）；`extensions.eval` 继续排除（Pi extension 已停用）。
- 统一验收入口 `make eval`：guarded 串行构建 smoke eval 入口并运行，每 case 一行 PASS/FAIL + 汇总；不改变 build/test/e2e 行为。
- smoke 集合：`basic-prompt`（mock 固定文本 Paris）、`tool-call-read`（mock 触发内置 read 工具并断言结果进入上下文、回传 provider）、`provider-error-handling`（HTTP 500 被标记为 run 失败且不崩溃）。
- 本地脚本化 HTTP mock provider（参照 anthropic/deepseek HTTP fixture server 模式），离线确定性，不用真实 API；结构设计与上游映射见 `docs/evals-design.md`。

Phase 8 验收结果（2026-08-12 关闭）：`make build` 退出 0；`make eval` 连续多次全绿（3 passed, 0 failed, exit 0；人为注入断言失败时输出 FAIL 行并 exit 1）；e2e 抽查 `rpc-shape-parity.sh`、`help-matrix.sh` 通过。

## Skills parity foundation 批次（2026-08-13 关闭）

上游对照点：`cli/args.ts` 的 `--skill` 可重复与 `--no-skills`/`-ns`；`core/package-manager.ts` 的 skill 路径合并、`resourcePrecedenceRank` 与 `.agents` 祖先发现；`core/skills.ts` 的 discovery mode、collision 与 `includeDefaults` 语义。

已落地：

- CLI：`--skill` 可重复收集并在启动 cwd 立即解析为绝对路径，后续 `--session`/`--resume`/session rebind 不漂移；`--no-skills` 只关 default discovery（显式路径仍加载），HELP 文本同步说明；HELP/`help-matrix.sh` 同步 `--skill`、`--no-skills`、`-ns`。
- 发现顺序（name collision 先加载者胜）：可信项目优先于用户：`<cwd>/.pi/skills` → `<cwd>` 至 git root 的各层 `.agents/skills`（近层优先）→ `<agent_dir>/skills` → `~/.agents/skills`。
  - `.pi/skills` 与 agent_dir 使用 pi mode（允许根部 `*.md`），`.agents/skills` 与 `~/.agents/skills` 使用 agents mode（只识别子目录 `SKILL.md`）。
  - git root 只按 `.git` marker 存在性封顶（不要求 HEAD）；`~/.agents/skills` 只作为 user 层，不作为 project 层重复（cwd 在 HOME 下同样适用）。
- trust：共享 `trust.resolve_trust`（显式 `--approve`/`--no-approve` 最高优先级）；启动打开最终 repository 后按 repository cwd 重解析，serve spawn cwd、TUI `/open`/`/import`/session rebind、RPC `get_commands` 均按各自项目 cwd 重解析。
- system prompt：仅 read 工具可用时注入 `<available_skills>`；`/reload`、session rebind、serve 实例重建、RPC `get_commands` 复用同一技能集合与 `enabledSkills` 过滤。
- Markdown：含下划线的行只做一次 ICU word segmentation，长标识符输入不再退化为 O(n²) ICU 扫描。

复核发现收口（2026-08-13 全部修复并验证）：

- `run_rpc` 的 skills options 改用 `resolve.skills_options_for`（携带 trust override），直接 RPC `get_commands` 不再丢失显式 `--no-approve`。
- TUI `view_t` 保存 trust override 字段并新增 `trusted_for(cwd)`；`/open`、`/import`、session rebind 跨项目时按新 cwd 重解析 trust。
- `config_context_test.n` 改为断言相对 skill 路径在 resolve 时固化为启动 cwd 绝对路径、绝对路径原样保留。
- `skills_test.n` collision case 改为 project-first（`.pi/skills` 胜 user），并补齐同名 winner 断言；新增项目胜用户、pi mode/agents mode、above-repo 不加载、HOME 下 `.agents` 单层加载等 case（22/22 绿）。
- `skills-loading.sh`/`skills-reload.sh` 隔离 HOME/agent/session（HOME 隔离防止未信任分支误载入真实 `~/.agents/skills`），改用随机空闲端口；`skills-reload.sh` 增加 child chdir project、completion 输入校验与 fixture 多请求计数校验。

验证结果（2026-08-13，全部串行、不调用真实模型）：

- `make build` 退出 0。
- `skills_test.n` 22/22、`config_context_test.n` 24/24、`components_markdown_test.n` 9/9（含长下划线单次分词回归）、`trust_test.n` 7/7（含 `resolve_trust` 按 cwd 重解析与显式覆盖）全绿。
- e2e：`help-matrix.sh`、`skills-loading.sh`（5 场景：信任默认、`--no-tools` 门控、`--no-skills`、显式路径穿透、未信任项目）、`skills-reload.sh`（无技能启动 → 创建 SKILL.md → `/reload` → 完成项/列表/注入/展开 → `--no-skills` 禁用）、`rpc-extension-loading.sh` 全部通过。

### MCP 结论（本批文档化，非缺陷）

- Pi core 明确不内建 MCP：coding-agent README 的 Philosophy 标注 “No MCP”，并说明用户可自行构建 extension 来添加 MCP support；其扩展能力列表也包含 MCP server integration。
- 因此 MCP 属于 extension/package 生态，不是 core parity 缺陷；Adou 本批不实现 MCP，不引入 Node/JS/QuickJS。
- Adou extension 机制保持停用（QuickJS 不链接、扩展目录不扫描、扩展工具/命令/UI/provider 不注册、生命周期事件不派发）；未来重新设计扩展机制后再评估 MCP。

## 测试模型、密钥与成本约束

- 常规模型统一使用 `deepseek-v4-flash`；需要 provider-qualified reference 时使用 `deepseek/deepseek-v4-flash`。
- public 仓库不保存 DeepSeek API key；live 测试从
  `DEEPSEEK_TEST_API_KEY` 或 `DEEPSEEK_API_KEY` 环境变量读取。
- 离线 credential-selection 测试使用非秘密 sentinel，不能把它用于公网请求；
  live 开关只有在显式提供真实环境变量时才会启用 provider 调用。
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

- 风险 1（无凭据快速失败 + 网络挂死）：完全无凭据（`ADOU_CODING_AGENT_DIR` 隔离 + env 清空）时 piped prompt 0.03s 内 `Error: No API key found for deepseek.` 退出——preflight 已存在。真正的挂死根因是 Nature TLS runtime：TCP 连接成功后停止超时 timer，mbedtls 握手阶段无超时（坏代理下永久挂）。应用层 watchdog（headless print/json，超时后 stderr 报错并 exit 1）作为兜底已实现；**根因已修复并发布**：issue `nature-lang/nature#300` → PR #301 `fix(runtime): time out stalled TLS handshakes` 已合并，系统 `libruntime.a` 已更新（2026-08-11 15:55）。验证：黑洞代理 + `--timeout-ms 8000` 默认构建 8s 有限退出；`api.deepseek.com` 正常握手 ~330-450ms；baidu 200。RPC 模式（watchdog 不覆盖）在黑洞下 46s 有限退出（DNS 解析亦慢），此前永久挂；watchdog 现为纯兜底。
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
- PTY follow-up 定位：测试原先固定等待 1 秒后就发送 `Ctrl+L`；Adou 进入 raw mode 时曾使用 `tcsetattr(..., TCSAFLUSH, ...)`，冷启动超过 1 秒时会丢弃已排队的按键，随后是测试超时杀掉仍正常运行的 Adou，并非 Adou 自行无输出退出。当前 raw-mode 边界使用 `TCSANOW` 配合显式 `TCIFLUSH`，并改为等待 raw mode 之后的 `ESC[>1u` 键盘协议开启标记后交互。同类等待已覆盖 9 个会立即发键的 PTY 脚本；修复后 model selector 连续 50/50 通过，9 个定向 PTY 脚本及完整 `make e2e` 全绿。
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

## 2026-08-13 大请求 TLS EOF 与退出时 double-free 闭环

- 复现场景：项目同时发现 `.pi/skills` / `.agents/skills` 后，完整 system prompt 与
  用户消息形成约 19 KiB 的 DeepSeek HTTPS 请求；服务端尚未返回事件时客户端报
  `TLS read failed: end of file`。随后 TUI redraw 触发 `malloc: double free` 并
  SIGABRT。
- TLS EOF 根因位于 Nature，而非 Adou provider/Skills：`rt_uv_tls_write` 只调用一次
  `mbedtls_ssl_write`，但 mbedTLS 每次最多接受一个 TLS record（通常约 16 KiB）；
  `http.client` 又忽略正数 short write。捕获证据为请求头 `Content-Length: 19010`、
  服务端实收 `16094`、JSON 不完整。Nature issue
  [#306](https://github.com/nature-lang/nature/issues/306) 与修复 PR
  [#307](https://github.com/nature-lang/nature/pull/307) 已建立：runtime 循环写完 TLS
  buffer，HTTP client 同时处理任意 connable 的正数 short write，并补 runtime
  多 record、no-progress、错误返回的确定性 C 回归。
- 修复后同类本地 HTTPS 捕获为 `19016/19016` 且 JSON 可解析；真实
  `deepseek-v4-flash` headless 与 Herdr TUI 均返回 `PI_ONLY_OK`，未再出现 TLS EOF。
- double-free 是同次失败中的第二个、独立根因：崩溃栈为
  `sc_map_put_sv <- string_new_with_pool <- normalize_terminal_output <- render`，旧
  Adou 二进制仍链接未包含 PR #303 的 runtime。全量重建后同时验证
  `const_str_pool_locker`、TLS write-all 与 HTTP write-all 符号/字符串存在，TUI
  重绘未再崩溃。
- 本机 `/usr/local/nature` 已更新为包含 PR #303 与 #307 本地修复的
  `weekly.2026.33` toolchain；`/usr/local/bin/adou` 与 `build/bin/adou` 已同步。默认
  `make build`（不设置 `NATURE`/`NATURE_ROOT`）重建后仍包含三项修复，避免后续回退。
- 串行验证：Nature `test_tls_write_all`、`20260811_00_tls_handshake_timeout` 2/2；
  Adou `deepseek_http_stream_test.n` 2/2、
  `skills_test.n` 22/22、`skills-loading.sh`、`skills-reload.sh`。第一次以相对
  `ADOU_BIN=./build/bin/adou` 运行 `skills-reload.sh` 时，脚本在 chdir 到临时 project
  后无法解析二进制路径并报告 TUI 未就绪；脚本现于 chdir 前固化绝对路径，相对与
  绝对调用均通过，非产品回归。

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
