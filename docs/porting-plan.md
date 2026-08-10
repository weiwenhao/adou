# Adou 全量移植计划（Pi 0.82.1，扩展机制暂缓）

状态：Phase 5 进行中 — 2026-08-10
基线：Pi `0.82.1`，commit `cced6a21da273b26ee4a23a803680614bbe8dd1e`（`vendors/pi`）

## 当前进度快照

- Adou 当前有 215 个 `src/**/*.n` 文件、约 4.0 万行 Nature 源码、132 个 Nature 单元测试文件和 33 个 e2e 脚本。
- Phase 1–4 已完成并有源码差分、单元测试和跨模块验收记录；当前主线进入 Phase 5（Interactive UI）。
- Phase 5 已覆盖主要会话交互，但尚未完成逐组件对照；Phase 6 已覆盖主要 CLI 路径，但尚未完成逐文件验收。
- Phase 7（独立 storage/server）和 Phase 8（evals harness）尚未开始，且不阻塞当前本地 CLI agent 主业务。
- Pi extension 已在生产入口停用：不扫描扩展目录、不初始化 QuickJS、不注册扩展工具/命令、不派发生命周期事件；默认构建不再链接 QuickJS。相关源码暂留作未来重新设计的参考。

| 阶段 | 状态 | 当前结论 |
|---|---|---|
| Phase 1：AI 层 | 已完成 | 39 个 provider、请求/流协议、模型兼容、图片 API、重试与认证主链已覆盖 |
| Phase 2：Agent harness | 已完成 | agent loop、工具、memory repo、shell 捕获、取消和 tool context 已覆盖 |
| Phase 3：coding-agent core | 已完成（排除扩展） | session、compaction、配置、skills、prompts、模型目录、诊断与导出已覆盖 |
| Phase 4：TUI 基础 | 已完成 | renderer、editor、autocomplete、fuzzy、路径补全、markdown、terminal image 逻辑已覆盖 |
| Phase 5：Interactive UI | 进行中 | 核心 overlay/消息渲染已具备，待逐组件差分和 PTY 验收 |
| Phase 6：CLI | 部分完成 | 主参数和启动路径已具备，待逐文件差分和边界 e2e |
| Phase 7：storage + server | 未开始 | 当前使用 JSONL repository 与进程内 RPC；尚无 SQLite/IPC server |
| Phase 8：evals | 未开始 | 尚未移植 pi-harness/smoke.eval |

阶段完成度应按行为验收判断，不再用 Pi TypeScript 文件数推算百分比。当前可以确认 4/8 阶段关闭；Phase 5–6 的现有实现不能在逐项对照前提前计为完成。

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

接下来按以下顺序收口：

1. 建立 `modes/interactive` 逐文件矩阵，将每个上游组件标为“等价实现 / 合并实现 / 排除 / 缺失”，避免用 `session_view.n` 文件大小代替行为验收。
2. 补齐非排除组件的行为差异，优先处理 theme/config selector、model search、session selector 搜索与删除、消息/工具 diff 展示、visual truncate、首次启动和倒计时状态。
3. 对合并在 `session_view.n`、`chat.n`、`components.n` 的组件补单元测试，覆盖空状态、错误、取消、过滤、选择、删除确认和窄终端布局。
4. 增加串行 PTY e2e：session resume/search/delete、model/scoped-model、settings 持久化、API-key login/logout、tree/fork/branch summary。

Phase 5 完成标准：所有非排除 interactive 文件在矩阵中有结论；相关单测通过；至少覆盖上述五类 PTY 场景；终端在成功、失败和取消后均恢复。

### Phase 6｜CLI 补全

当前已有：参数解析与校验、`--list-models`、`@file`、piped stdin、initial messages、text/json/rpc/print 模式、session/continue/resume/fork、export、project trust 和启动时 session picker。

接下来：

1. 对照 `src/cli` 的 9 个上游文件，确认 list-models、file processor、initial message、session picker、startup UI、config selector、credential print 和 project trust 的全部输入/错误语义。
2. 补齐 credential/config selector 的非 OAuth 分支，以及参数组合、无 TTY、缺失文件、空 stdin、损坏 session、未认证 provider 等启动边界。
3. 为每类 CLI 行为增加针对性 e2e，并保持 JSON/RPC stdout 不受诊断日志污染。

Phase 6 完成标准：9 个上游 CLI 文件逐项有结论；帮助文本与参数行为一致；相关 CLI/RPC e2e 全绿。

### Phase 7｜storage + server

- 移植 SQLite storage 的 repo、migration、session/branch entry、sequence 和 materialized view。
- 在不替换现有 JSONL 默认存储前，先定义 repository 适配边界和双后端一致性测试。
- 移植 server 的 IPC protocol、rpc process、supervisor、handler、serve 和 radius；不得破坏现有进程内 RPC 协议。

Phase 7 完成标准：SQLite migration/storage 单测、JSONL/SQLite 行为一致性测试和 RPC-over-IPC e2e 通过。

### Phase 8｜evals 基建

- 移植 `pi-harness` 和 `smoke.eval`；`extensions.eval` 继续排除。
- 将现有 provider/tool/session/TUI e2e 接入统一验收入口，但仍通过 Make 串行调度 Nature。

Phase 8 完成标准：harness 可重复运行 smoke 集合，并输出稳定的通过/失败报告。

## 验收与执行规则

每个阶段必须同时满足：

1. 固定 Pi 源码文件和 fixture 基线，并记录逐项行为结论。
2. Nature 单元测试覆盖正常、错误、取消、边界和顺序语义。
3. 至少一个跨模块集成或 e2e；不得只用孤立 mock 宣布完成。
4. 先运行 `make build`，再串行运行受影响的单文件 Nature 测试和 e2e。
5. 不并发运行 Nature、不使用 `make -j`、不运行 `nature fmt`；除非明确需要，不运行约两小时的完整 `make test`。

当前测试库存为 132 个 Nature 单元测试文件和 33 个 e2e 脚本；这只是覆盖资产数量，不代表本次快照已重跑全量测试。最新可复核的模块证据维护在 `docs/pi-core-module-map.md`。
