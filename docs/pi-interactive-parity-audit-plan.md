# Pi Interactive Parity 审计与实施计划

状态：Batch 0（2026-08-14）、Batch 1（Autocomplete 与 SelectList 基础）、Batch 2（Model 与 Scoped Models）、Batch 3（Keybindings）、Batch 4（Editor/cursor/IME）、Batch 5（其余 Interactive 组件）与 Batch 6（Streaming、Resize 与稳定性组合回归）均已由主代理验收通过（2026-08-17）；下一批为 Batch 7
审计日期：2026-08-14
范围：Adou 交互式 TUI、编辑器、autocomplete、overlay、快捷键和终端生命周期
Nature 实现基线：Batch 0 至 Batch 6 已进入当前提交历史；本文后续记录覆盖 Batch 7 与当前全量 parity 范围修订

## 1. 结论

现有 `docs/porting-plan.md` 和 `docs/pi-core-module-map.md` 将 Phase 4/5
标为完成，但本次真机复现和源码对照证明，该结论不能继续作为 Interactive UI
的验收依据。

Adou 当前不是 Pi Interactive UI 的逐组件、逐状态机等价移植。它覆盖了多数入口和
界面名称，但多个 Pi 组件被合并进 `src/tui/session_view.n` 的通用 overlay 和手写
分支；迁移过程中丢失了组件的数据模型、状态所有权、查询生命周期、可见窗口、配置
驱动和取消/确认语义。现有测试又以直接打开单个 overlay 和静态字符串断言为主，没有
覆盖用户从编辑器进入 autocomplete、选择命令、进入 overlay、返回编辑器的组合链路。

因此，本计划撤销“Interactive UI 已收口”的前提。后续只有完成本文的组件契约、
状态转换、确定性 PTY 测试和同版本 Pi 真机对照后，才能重新宣告 parity。

**Phase 范围修订（2026-08-14）**：本计划的失败前提同时覆盖 Phase 4 的
Interactive/TUI 交互子项——IP-006（autocomplete 架构）、IP-008（app
keybindings registry）与 Batch 4（editor/cursor/IME/keybindings）都属于
Phase 4 的 "TUI 基础" 范畴，因此 Phase 4 与 Phase 5 一起重新打开
（reopened）。renderer 差分渲染、终端恢复等已验证子项保留原结论与证据，
不被笼统抹掉；重新打开的判定只针对 Interactive/TUI 交互部分。

## 2. 审计权威与基线门禁

### 2.1 当前统一的 Pi 基线

- 仓库 `vendors/pi`：Pi `0.82.1`，commit
  `cced6a21da273b26ee4a23a803680614bbe8dd1e`。
- Herdr `w7:pD` 真机 oracle：已于 2026-08-18 退出旧常驻进程，并用
  `vendors/pi/pi-test.sh` 重新启动为 Pi `0.82.1`。

当前源码和真机 oracle 使用同一版本；固定提交、终端协议和三轮离线基线证据如下：

- `vendors/pi` HEAD 与 oracle commit 均为
  `cced6a21da273b26ee4a23a803680614bbe8dd1e`；
- `./vendors/pi/pi-test.sh --version` 与 Herdr pane 启动画面均为 `0.82.1`；
- `python3 tests/e2e/lib/pi-oracle/slash-baseline.py --runs 3`：三轮语义断言
  PASS、画面一致、退出码 0。

此前 Herdr `pi-test` 0.81.0 的记录仍保留在历史章节，但不再作为当前 parity 证据。

### 2.2 权威顺序

同一版本内按以下顺序判断：

1. Pi 源码中的组件状态机和设置契约；
2. Pi 自身测试；
3. 同终端尺寸、同配置、同按键序列的 Pi 真机行为；
4. Adou 的 Nature 实现和测试。

不得以“Adou 已有同名文件/命令/测试”为完成证据。

### 2.3 明确排除项与开放项

当前唯一明确排除的是 TypeScript/QuickJS extension UI/runtime。OAuth/account 登录和
交互式图片渲染属于全量 parity 的开放项，不能标为 `EXCLUDED`；API-key 登录、
skills、prompt templates、slash commands、项目 trust 和核心 TUI 均在本轮范围内。

## 3. 冻结快照

审计时 OpenCode 已停止，未运行 Nature 编译或 e2e。当前与本轮 Interactive UI 直接
相关的 WIP 包括：

- `src/tui/session_view.n`：slash 候选窗口、动态描述、query/selection 绑定的未验收实现；
- `tests/e2e/slash-menu.sh`：未完成，最近一次执行在 Esc 关闭菜单断言失败；
- `tests/e2e/input-cursor-seq.sh`：原始 cursor 序列测试 WIP；
- `docs/herdr-real-machine-testing.md`：已记录真机稳定性问题，但 Interactive parity
  章节尚未按本文口径重写。

这些文件不回滚，也不视为已完成。OpenCode 恢复工作后必须按本文重新审查、修正和
验收。`vendors/` 是本地 oracle 工作区，可以安装依赖、构建和写入测试所需产物；当前
`vendors/pi` 内已有一个 fixture 的脏状态不影响使用。`vendors/` 下的源码变化、
`node_modules`、`dist` 和其他生成物一律不纳入 Adou 的 GitHub 提交。

## 4. 已确认问题

### IP-001｜`/model` 可进入错误 overlay（P0）

复现链路：先在 `/` 菜单导航或改变查询，再输入 `/model` 并 Enter。Adou 曾显示
`enter toggle / ctrl+a all / ctrl+x clear`，实际进入 `/scoped-models`，而 Pi 的 model
selector 应显示 `enter select`。

根因证据：Adou 的 `command_index` 未绑定生成它的 editor query；候选集变化后旧索引
仍被 `complete_command()` 使用。现有直接 `Ctrl+L` 的 model-selector e2e 绕过了这条
组合路径。

验收要求：完整匹配优先；每次 query 变化重新决定 selection；`/model`、从 `/` 菜单
选中 model、`Ctrl+L` 三条入口必须进入同一个 model 状态机。

### IP-002｜slash menu 全量铺开（P0）

同一 Herdr 尺寸下，Pi 仅显示 5 个候选和 `(1/53)`；Adou 基线显示约 50 行，覆盖聊天
和输入区域。

根因证据：Pi editor 使用 `autocompleteMaxVisible` 配置和 `SelectList` 窗口；Adou
`render_command_menu()` 原来遍历所有匹配。当前 WIP 硬编码 5 行只能恢复默认外观，
仍未实现 Pi 的 3–20 可配置契约。

### IP-003｜聚焦态输入位置出现常驻白色方框（P1，尚未关闭）

用户在聚焦的 Adou 真机观察到常驻白色块，Pi 正常输入时没有相同视觉干扰。

当前原始 PTY 证据：Pi 和 Adou 默认都隐藏 hardware cursor，并由 editor 输出单个
inverse cursor cell；Adou 没有输出 `?25h`/DECSCUSR，暂未发现“双光标叠加”。但已有
取证是在不同 pane 焦点状态下完成，不能否定用户看到的聚焦态差异。

验收要求：使用相同终端、相同主题和真正焦点状态，对空输入、ASCII、CJK、左右移动、
退格、菜单开关、resize、focus in/out 做逐帧对照。不得新增默认不生效的环境变量来
绕过默认视觉行为。

### IP-004｜动态 slash command 描述错误（P0）

大量 `/skill:*` 候选曾显示 `Quit Adou`。Adou 将动态命令降维为 name，再以静态函数
查描述；未知命令错误回退到 quit 文案。

验收要求：autocomplete item 保留 name、description、argument hint、source/source
tag 和 command kind；未知动态描述为空而非错误默认值；skills/prompts 的描述与 Pi
同源数据一致。

### IP-005｜Settings 不是 Pi 的功能面（P0）

Pi 0.82.1 `SettingsSelector` 包含 auto-compact、steering/follow-up、transport、HTTP
idle timeout、thinking、theme、hide thinking、cache notices、changelog、quiet startup、
telemetry、trust、double escape、tree filter、warnings、images、skill commands、hardware
cursor、editor/output padding、autocomplete max visible、clear-on-shrink、terminal progress
等设置及子菜单。

Adou `show_settings_overlay()` 当前只有 7 项：Thinking、Auto-compaction、Steering、
Follow-up、Hide thinking、Auto-retry、Theme。多个 Pi 设置没有配置字段、持久化 setter、
运行时 effect 或 UI；Theme 也只是 light/dark 即时切换，不是 Pi 的 theme selector。

旧文档中“settings selector 已对齐”的结论无效。

### IP-006｜Autocomplete 架构与 Pi 不等价（P0）

Pi 的 `CombinedAutocompleteProvider` 同时处理 built-ins、prompt templates、extensions
（本项目排除）和 skills，支持：

- configurable max visible；
- name/description/argument hint/source tag；
- `/model <prefix>` 与 `/login <prefix>` argument completion；
- query 改变时取消/淘汰过期异步结果；
- Tab/Enter 应用当前候选；
- Escape 取消、Backspace/删除后重算、光标移动后同步。

Adou 当前把 slash menu、`@` 附件、Tab path completion 和各 overlay 分开手写，缺少
统一 item/selection/query contract。IP-001、IP-002、IP-004 是同一架构偏差的表现，
不能仅靠三个局部分支彻底解决。

### IP-007｜Scoped Models 的空值和持久化语义错误（P0）

Pi 用 `null` 表示“全部启用”，空数组表示“全部禁用”；改动默认只作用于当前 session，
`Ctrl+S` 才写 settings，并显示 dirty/unsaved 状态。不可用但已配置的 model 也保留显示。

Adou `settings_t.enabled_model_ids` 只有数组，并以 `len() > 0` 推导 active；保存空数组时
删除 `enabledModels`。因此“全部启用”和“全部禁用”无法可靠区分，clear-all 后重载可能
恢复成 all-enabled。Adou 多个操作还立即 `save_preferences()`，不符合 session-only +
explicit save 契约。

### IP-008｜App keybindings 未实现 Pi registry 契约（P1）

Adou editor 基础键位有 registry，但 `session_view.n` 的 app/overlay 快捷键仍大量硬编码。
Pi 的 `core/keybindings.ts` 定义约 40 个 app action，支持用户映射、冲突检测、动态 hints
和 `/reload` 后更新。Adou 目前的 help/hints、实际 dispatch 和用户配置没有同一数据源，
存在“提示一种键、实现另一种键”的风险。

### IP-009｜Model catalog 刷新可能阻塞 UI（P1）

Adou 在 `ADOU_CATALOG_NETWORK` 开启时从 `show_model_overlay()` 同步调用
`models.refresh_remote_catalogs()`。这发生在输入/overlay 路径，可把网络延迟表现成
“选择 model 卡死”。Pi 在 selector 打开期间刷新并保持 UI 可响应。

Round 1 新增源码证据：即使网络刷新关闭，`show_model_overlay()`、
`available_cycle_models()` 和未修正前的 `model_argument_items()` 也会遍历约
1200 个 model，并逐 model 调用 `model_is_authenticated()`；后者再逐次执行
`auth.effective()`，即反复打开和解析同一 auth 文件。因此用户看到的“选择 model
卡死”至少存在一个完全本地、无需网络即可触发的同步 I/O 根因。Batch 1 只修
argument candidates 的热路径；selector/cycle 的同类调用必须在 Batch 2 以共享的
provider-auth snapshot 和可失效 model snapshot 消除，不能只移动 network refresh。

需要用可控慢服务器验证：打开、导航和 Escape 不得等待网络；旧刷新结果不得覆盖新
query/session；失败只更新状态，不关闭 selector。

### IP-010｜通用 overlay 丢失各组件契约（P1）

Adou 用一个 `overlay_t` 和一个 `handle_overlay_input()` 承载 model、settings、scoped
models、session、tree、auth、config 等不同组件。虽然减少了文件数量，但已经出现
selection、query、help 和 save/cancel 语义互串。

不要求 Nature 文件与 TypeScript 一一对应，但每个 overlay kind 必须有独立 state 和
transition handler；通用渲染只能复用无状态 primitive，不能共享含义不同的字段。

### IP-011｜Config/Auth 等组件只有入口近似（P1）

- Pi config selector 支持 user/project scope、search、page navigation、Tab 切 scope、
  空态和 item/header 区分；Adou `/config` 是扁平 skills/prompts 列表。
- Pi login/logout provider selector 来自运行时 auth provider 列表并支持搜索；Adou logout
  目前硬编码 `deepseek/openai/anthropic`。
- Pi trust selector 支持 j/k、当前来源和保存语义；Adou 需要重新按相同契约验收。

### IP-012｜现有测试产生了错误完成感（P0，流程问题）

现有 TUI e2e 有价值，但多数只直接打开组件：

- `tui-model-selector.sh` 由 `Ctrl+L` 进入，没覆盖 slash autocomplete → model；
- `tui-settings.sh` 只覆盖打开、thinking 子菜单和 theme 文本存在；
- `tui-scoped-models.sh` 没覆盖 null/[]、session-only、dirty、save/reload；
- session/tree 测试覆盖若干 happy path，但未对照全部键位、上下边界、page、取消恢复；
- 新 `slash-menu.sh` 尚未通过，不能作为证据；
- 静态 ANSI 中有 inverse cell 不等于用户焦点态视觉一致。

以后每个组件至少需要 unit state-machine test、direct PTY test、真实入口 integration PTY
test 和 Pi 同版本真机对照四层证据。

## 5. 功能审计矩阵

| 功能域 | Pi 权威 | Adou 当前结论 | 状态 | 优先级 |
|---|---|---|---|---|
| slash items/metadata | `core/slash-commands.ts`, `autocomplete.ts` | built-ins 大致齐；argument hint/source tag/动态 item contract 不完整 | FAIL | P0 |
| slash 可见窗口 | editor `autocompleteMaxVisible` + `SelectList` | 基线全量；WIP 硬编码 5 | FAIL | P0 |
| slash query/selection | editor autocomplete state | stale index 可选错 overlay | FAIL | P0 |
| command argument completion | model/login providers | 未形成统一 argument completion | FAIL | P0 |
| model selector | `model-selector.ts` | direct 入口部分通过；slash 链路错；慢刷新未隔离 | PARTIAL | P0 |
| scoped models | `scoped-models-selector.ts` | toggle/reorder UI 部分存在；null/[]、dirty/save 错 | FAIL | P0 |
| settings | `settings-selector.ts` | 7 项对 20+ 项，持久化/effect 大面积缺失 | FAIL | P0 |
| editor 基础编辑 | `editor.ts` | 单元测试较多，需组合与配置驱动复验 | PARTIAL | P1 |
| cursor/focus/IME | `tui.ts`, editor cursor marker | 原始序列近似；聚焦视觉报告未解释 | UNVERIFIED | P1 |
| keybindings | Pi TUI + app registry | editor 部分 registry，app/overlay 硬编码 | FAIL | P1 |
| path/@ completion | `autocomplete.ts` | 独立实现存在，缺统一生命周期测试 | PARTIAL | P1 |
| settings/config reload | interactive reload path | skills reload 有测试；keybindings/theme/settings effect 不全 | FAIL | P1 |
| config selector | `config-selector.ts` | 扁平列表，缺 scope/search/page contract | FAIL | P1 |
| login/logout API-key UI | `oauth-selector.ts`, login dialog API-key branch | 基础入口存在；provider 数据/搜索不等价 | PARTIAL | P1 |
| trust selector | `trust-selector.ts` | 入口存在，键位/来源/持久化待对照 | UNVERIFIED | P1 |
| session selector | `session-selector.ts` | search happy path存在；scope/sort/rename/delete/page 组合未闭环 | PARTIAL | P1 |
| tree/fork | `tree-selector.ts` | 主路径有 e2e；全部 filter/fold/label/copy 键位未闭环 | PARTIAL | P1 |
| streaming input queues | interactive submit/steer/follow-up | 旧真机聊天通过；需要与编辑器状态组合验证 | PARTIAL | P1 |
| tool/thinking expansion | message components + app keys | 基础实现存在；keybinding/hint/settings effect 待统一 | PARTIAL | P2 |
| resize/shrink/render | Pi TUI diff renderer | 稳定性已加强；settings-driven clear-on-shrink 未实现 | PARTIAL | P1 |
| debug/terminal lifecycle | Pi debug log + ProcessTerminal | debug 隔离/job control 已通过 | PASS（保留回归） | P1 |
| extension UI | extension components | 产品范围排除 | EXCLUDED | — |
| OAuth/account | login dialog OAuth flows | 尚未实现完整 login/refresh/logout 契约 | OPEN | P1 |
| interactive images | image selectors/render | 已有底层编码与图片 API，读取/消息/TUI 接线未完成 | OPEN | P1 |

## 6. 实施原则

1. 先修基础 contract，再修表面菜单。Autocomplete item、query/selection 和 select-list
   window 是 IP-001/002/004/006 的共同基础。
2. 不再向 `overlay_t` 增加含义复用字段。为 model、scoped models、settings、session、
   tree、config、auth 建立明确 state 类型或至少独立 handler。
3. 所有 UI 提示从 keybinding registry 生成，禁止提示字符串和 dispatch 分别硬编码。
4. Settings 每一项必须同时具备 schema/default、global/project merge、setter、运行时
   effect、UI、持久化测试；只有 UI 文本不算实现。
5. 网络和磁盘刷新不得阻塞输入循环；异步结果必须绑定 generation/query/session。
6. 不保留错误旧行为，不增加仅用于绕过 parity 的兼容环境变量。
7. `vendors/` 可自由用于安装和构建同版本 Pi oracle，但其变化不提交到 Adou；不运行
   `nature fmt`，Nature build/test 全局串行。

## 7. 分批实施计划

### Batch 0｜统一基线与测试协议

- 统一 Pi source 和 live oracle 版本。
- 固定 terminal rows/columns、theme、settings、cwd、skills fixture、model fixture。
- 建立共享 PTY driver：等待 raw/keyboard-ready marker、逐键输入、持续排水、超时、
  normalized visible screen、raw ANSI、exit code。
- 为每个 case 记录：precondition、keys、Pi screen/state、Adou screen/state、PASS/FAIL。
- 更新旧 porting 文档：Interactive Phase 状态改为 reopened，引用本文。

验收：同一 slash case 在 Pi 连续 3 次得到一致 snapshot；测试不访问真实网络或密钥。

### Batch 1｜Autocomplete 与 SelectList 基础

状态（2026-08-15）：已验收。max=3/5/20 与 Pi 0.82.1 的 parity 全部
PASS；max=20 仍保留 upstream-equivalent 的 strict UX FAIL，详见 §12.7。

- 定义完整 autocomplete item：value/label/description/argument hint/source/kind。
- query generation 与 selection 绑定；文本改变、Backspace、Delete、cursor move、Esc 后
  状态正确失效。
- 实现配置驱动的 max visible（3–20）、窗口跟随、页码和上下边界行为。
- exact/prefix/fuzzy 排序与 Pi 对齐；动态 skill/prompt 描述和 source tag 对齐。
- 实现 `/model`、`/login` argument completion。
- 统一 Tab/Enter/Esc/Up/Down/PageUp/PageDown contract。

验收：IP-001、IP-002、IP-004、IP-006 的 unit + PTY；`/model` 绝不进入 scoped-models。

### Batch 2｜Model 与 Scoped Models

状态（2026-08-15）：已验收。Model selector 与 scoped models 已拆成独立状态机，
慢 catalog refresh、session-only 变更和 explicit-empty 持久化契约均有 unit + PTY 证据，
详见 §12.8。

- Model selector 独立 state/handler；三入口共用状态机。
- 搜索、scope Tab、当前项、模型详情、空态、上下 wrap/clamp 行为按 Pi 对齐。
- catalog refresh 移出输入线程，支持取消/过期结果淘汰。
- Scoped models 引入三态：all-enabled/null、explicit list（可为空）、dirty。
- toggle/all/clear/provider/reorder 只更新 session；Ctrl+S 持久化；Escape 放弃 UI 但保留
  Pi 定义的 session 行为；不可用 model 保留。

验收：慢 catalog 仍可导航/Esc；clear-all save/reload 后仍 clear；未 Ctrl+S 不污染文件。

### Batch 3｜Settings 全量契约

- 扩展 `settings_t` 和 global/project merge，逐项对照 Pi 0.82.1 范围。
- 实现 settings list、select submenu、theme preview/cancel/apply。
- 优先核心可观察设置：autocomplete max、hardware cursor、editor/output padding、
  clear-on-shrink、quiet startup、double escape、tree filter、skill commands、transport、
  HTTP idle timeout、terminal progress、warnings。
- 图片设置在尚未完成时显示为 unavailable，不做伪实现；其完整运行时 effect 进入后续 parity 批次。
- 移除或重新定位不属于 Pi settings surface 的 Auto-retry。

验收：每项具备 default/load/save/project override/runtime effect/reopen 五类断言。

### Batch 4｜Editor、Cursor 与 App Keybindings

- App + overlay dispatch 全部接入统一 keybinding registry。
- `/hotkeys`、footer hints、overlay hints 从 registry 生成。
- `/reload` 重载 keybindings 并报告冲突。
- 焦点态 cursor/IME 对照，完成 IP-003；hardware cursor 设置真实生效且默认行为对齐。
- 覆盖 ASCII/CJK/emoji/grapheme、wrap、history、undo/kill/yank、jump、paste、resize、
  focus、autocomplete 开关前后。

验收：用户配置一个 app key 后实际行为和 hint 同时变化；无常驻残留白块。

### Batch 5｜其余 Interactive 组件

- Config：scope、search、header/item、page、toggle、Esc/Tab。
- Auth API-key：运行时 provider 列表、搜索、取消、错误恢复；OAuth 另列开放 parity 工作，不得视为 EXCLUDED。
- Trust：选择、j/k、来源、保存、取消。
- Session：scope、sort、named、path、rename、delete confirm、page、empty、cancel recovery。
- Tree/Fork：filter modes、cycle、fold/unfold、label、timestamp、copy、page、branch summary。
- Settings/selector 关闭后 editor text、cursor、autocomplete、footer 状态恢复。

验收：每个组件 direct entry 和 slash entry 均通过完整生命周期。

### Batch 6｜Streaming、Resize 与稳定性组合回归

- idle、streaming、tool call、compaction、retry、queued steer/follow-up 各状态下操作允许的
  keybindings。
- overlay 打开/关闭与 stream event、resize、Ctrl+Z/fg、debug file 同时发生。
- 保留 2026-08-13 的 render lock、terminal write、EINTR 和 event stream 回归。

验收：确定性 fixture 压测无 hang/crash/错屏；真实 provider 只做最后低次数 smoke。

### Batch 7｜同版本 Pi 真机验收与安装

- 按完整矩阵给 Pi 和 Adou 发送相同按键序列。
- 每项输出 PASS/FAIL、截图/ANSI、状态、退出码；任何 FAIL 都重新进入对应 batch。
- 连续 3 轮全矩阵无新 crash report。
- 串行 `make build`、相关 targeted Nature tests 和相关 e2e；不跑完整 `make test`。
- `git diff --check`、凭据扫描、无 vendors 改动、无 commit/push。
- 最终二进制由主代理交互式 sudo 安装，安装后 OpenCode 只读核验 hash/help/version。
- 所有批次通过后，由 OpenCode整理提交边界、提交并推送到用户指定的现有 GitHub
  remote；推送前必须再次报告 branch、remote、diff、测试和凭据扫描结果。

## 8. 最低测试矩阵

每一行都要使用 Pi/Adou 相同前置状态和按键：

| 场景 | 必测按键/状态 | 核心断言 |
|---|---|---|
| slash open | `/` | max visible、页码、描述、输入仍可见 |
| slash filter | `/m`、Backspace、Delete | query 与 selection 同步，无旧索引 |
| slash nav | Up/Down 边界、PageUp/PageDown | Pi 同样的 wrap/clamp/window |
| slash accept | Tab、Enter | 应用当前 item，进入正确 command |
| slash cancel | Esc、Ctrl+C | 菜单关闭，editor 恢复，无残留 |
| model direct | Ctrl+L | 打开、搜索、scope、取消、选择 |
| model command | `/model`、`/model <query>` | exact/selector 行为与 Pi 一致 |
| model slow refresh | 慢/失败 catalog | UI 不阻塞，旧结果不覆盖 |
| scoped models | toggle/all/clear/provider/reorder/save | session-only、dirty、null/[]、reload |
| settings | 每项 Enter/submenu/Esc | preview/cancel/apply/persist/effect |
| editor | ASCII/CJK/emoji/long/multiline | cursor、wrap、edit、history、undo |
| focus/cursor | focus in/out、菜单、resize | 默认视觉与 Pi 一致，无残留块 |
| app keys | 默认 + 自定义 + reload | dispatch/hint/conflict 同源 |
| config/auth/trust | search/nav/select/cancel | 数据源、状态恢复、持久化 |
| session/tree/fork | 全快捷键和边界 | 无误删、无错误 branch/state |
| streaming | steer/follow-up/dequeue/cancel | 队列模式与 editor 恢复 |
| terminal | resize、Ctrl+Z/fg、quit/error | 完整重绘、终端恢复、exit 0 |

## 9. 完成定义

一个功能只有同时满足以下条件才能标为 `PASS`：

1. 文档列出准确的 Pi source component 和 Adou implementation；
2. 明确 state、event、transition、render、side effect 和 cancel/confirm contract；
3. Nature unit test 覆盖正常、边界、取消、空态和错误；
4. direct PTY 测试覆盖组件本身；
5. integration PTY 从真实用户入口进入并返回 editor；
6. 同版本 Pi 真机以相同按键得到等价的可观察结果；
7. 相关测试在最终源码后串行重跑；
8. 文档保留真实失败记录，不以重试成功抹掉历史证据。

禁止以下完成口径：

- 有同名 Nature 文件；
- 有命令分支；
- overlay 能打开；
- 静态字符串存在；
- 一条 happy path e2e 通过；
- 连续几轮聊天没有 crash。

## 10. OpenCode 工作方式

OpenCode 按 Batch 0→7 顺序执行，一次只领取一个 batch。每个 batch 必须：

1. 先在本文对应章节补充精确源码映射和失败 baseline；
2. 再实施代码；
3. 串行运行最小相关测试；
4. 在 Herdr `adou-test` 和 `pi-test` 做同键对照；
5. 报告 diff、测试退出码、残余 FAIL；
6. 由主代理验收后才进入下一 batch。

OpenCode 不得自行宣布全量收口或安装。Batch 0–6 期间不提交/推送半成品；Batch 7
通过主代理最终验收后，必须创建可审查 commit 并推送到现有 GitHub remote。发现新的
独立偏差必须新编号，不能塞入现有问题后宣称已修。

## 11. Batch 0 记录（2026-08-14，主代理验收通过）

> 状态：**已由主代理验收通过（2026-08-14）**。下方记录保留返工前的错误
> 历史（§11.5），验收以返工后的协议口径（env 隔离、生命周期、语义断言、
> 三轮门禁、归一化证据）为准。

### 11.1 统一基线

- 源码权威与 live oracle 统一到 Pi `0.82.1`（commit `cced6a21da273b26ee4a23a803680614bbe8dd1e`，
  即 `vendors/pi` HEAD）。`vendors/pi` 已用 `npm ci --ignore-scripts` +
  `npm run build` 构建完成，`./pi-test.sh --version` 输出 `0.82.1`；
  运行时校验 `vendors/pi` HEAD 与证据记录 commit 一致，不一致即 FAIL。
- Herdr `pi-test` 真机 0.81.0（w7:pD）保留为历史对照，未覆盖、未修改。
- 未运行 Nature 编译/测试；未提交/推送任何内容。

### 11.2 共享 PTY 协议（返工后口径）

- `tests/e2e/lib/vt_screen.py`：VT100/ANSI 屏幕解释器（C0/ESC/CSI/OSC、
  UTF-8 与东亚宽度、滚动 margin、保存/恢复光标），输出 normalized visible
  screen + cursor；`python3 tests/e2e/lib/vt_screen.py` 自测全过。
- `tests/e2e/lib/pty_protocol.py`：`PtyCase` 驱动——固定 winsize
  （24 行 × 80 列）、keyboard-ready marker 等待、逐键输入、持续排水 +
  静默超时、normalized visible screen、exit code。
  - **env 隔离**：`start()` 用 `execvpe` 精确替换子进程环境，只携带
    `fixed_oracle_env()` 的最小 allowlist（PATH/TMPDIR 从父进程继承；
    HOME/PI_CODING_AGENT_DIR 固定为 fixture；TERM=xterm-256color 与
    LANG/LC_ALL/LC_CTYPE=en_US.UTF-8 固定）。凭据、proxy、token 按构造
    排除，不读取不打印不落盘。回归见 `tests/e2e/lib/pty_env_isolation_test.py`。
  - **生命周期**：`wait_exit` 获得任何退出状态后立即清空 `pid`，`close()`
    不再 SIGKILL 已回收 PID（无 PID reuse 误杀窗口）；运行中的异常 case
    由 `close()` 可靠 SIGKILL+reap。
  - **ready marker**：`DEFAULT_READY_MARKER = \x1b[>7u` 对应 Pi 0.82.1
    （`DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 7`）；Adou 为 `\x1b[>1u`，
    由调用方显式传入，两方 marker 在模块注释中写清。
  - **raw 边界**：`checkpoint()/raw_slice()` 提供明确 milestone 切片；
    `raw_ansi()` 只表示累计缓冲，不作为单步证据。证据内
    `normalized_raw_sha256`/`normalized_raw_bytes` 对 raw slice 先做
    **bytes 级 `<REPO>` 归一化**再哈希/计量，因此不含本机路径、跨主机
    可复现；exact raw（可能含本机路径）仅由 `--raw-dir` 本地落盘供
    诊断，不进入提交，证据 JSON 中不存在 exact raw 内容。
  - **三轮门禁**：`--runs < 3` 直接拒绝（argparse exit 2）；0/1/2 均
    不能产生 PASS（纯函数 `validate_runs` 回归覆盖）。
- `tests/e2e/lib/pi-oracle/slash_case.py`：**纯函数语义校验**（不碰 PTY），
  含 positive 与 negative self-tests（非零/None 退出、缺 milestone、
  候选数/顺序错、pager 错、wrap 选中错、Esc 候选残留（无 pager）、
  Esc pager 残留（无候选）、cursor 错、runs 0/1/2 门禁、raw 归一化、
  evidence leak 检测）。Esc 校验独立于 pager：editor 下边框之后、status
  块之前任何候选/分页样残留行都判 FAIL。
- `tests/e2e/lib/pi-oracle/slash-baseline.py`：**Pi-only** runner。原
  `--side adou` 已移除——它只替换 ready marker 却始终启动 Pi，不能诚实
  宣称支持 Adou；Adou 侧留待后续 batch 以真实 argv 映射加入。共享
  `PtyCase` 保持双方可复用。`--runs < 3` 拒绝执行（exit 2）。
- 固定项：terminal 24×80；theme dark；settings
  `{"theme":"dark","autocompleteMaxVisible":5}`；cwd =
  `tests/e2e/lib/pi-oracle/fixtures/cwd`（提交在库内的 fixture 目录）；
  skills fixture = 3 个确定性 SKILL.md（alpha-toolkit/beta-ops/gamma-report）；
  model = `deepseek/deepseek-v4-flash`；`--offline`（Pi 官方禁网开关，
  禁止 startup 网络操作）与 `--no-env`（无任何 API key）。启动日志可见
  `fd not found. Offline mode enabled, skipping download.`，证明无远程
  目录下载；全程无凭据、无真实网络。

### 11.3 slash `/` baseline 验收标准与证据（返工后口径）

验收 = **语义正确** + **三轮一致** + **退出码 0**，三者缺一即 FAIL：

1. 每个 run 的 `exit_code` 严格为 0（None/非零即 FAIL）；
2. 每个 run 的 milestone 恰好为
   startup/slash-open/slash-up-wrap/slash-down/slash-esc-closed 五个，
   顺序正确（缺失/数量错即 FAIL）；
3. 语义断言（`slash_case.py`，详见其 docstring）全部 PASS：
   - startup：Pi 0.82.1 banner、三个 fixture skills、固定 model
     （`deepseek-v4-flash • thinking off`）、fixture cwd；
   - slash-open：输入行 `/`、候选窗口严格 5 行且依次为
     settings/model/scoped-models/export/import、pager `(1/26)`、
     `→ settings` 选中、model 行含 `<provider/model>` hint 与
     `Select model (opens selector UI)` 描述、cursor (14,1)；
   - slash-up-wrap（原 slash-up-clamp 改名，Pi 实测为 wrap）：40×↑ 后
     pager `(13/26)` 且 `→ clone` 选中；
   - slash-down：8×↓ 后 pager `(21/26)` 且 `→ reload` 选中；
   - slash-esc-closed：Esc 后菜单行与 pager 全部消失、输入 `/` 与
     cursor (14,1) 保留；
4. 三轮 normalized screen 逐 milestone byte-identical。

本轮实测结果（2026-08-14 返工后，Pi 0.82.1 三轮，exit 全 0，断言全
PASS，screen 全一致；哈希基于 <REPO> 归一化内容）：

| milestone | keys | screen sha256（三轮一致） | 断言要点 |
|---|---|---|---|
| startup | 无 | `3ba5c32f…` | banner/skills/model/cwd |
| slash-open | `/` | `25ea4891…` | 输入 `/`、5 候选顺序、`(1/26)`、model hint |
| slash-up-wrap | `↑`×40 | `ca70c132…` | wrap 到 `(13/26)`、`→ clone` |
| slash-down | `↓`×8 | `7dbed9f4…` | `(21/26)`、`→ reload` |
| slash-esc-closed | `Esc` | `ef5c4a87…` | 菜单/pager 消失、`/` + cursor (14,1) |
| quit | `Ctrl+C` + `/quit` + `Enter` | — | 退出码 0 |

完整记录见 `docs/pi-batch0-evidence/summary-pi.json` 与
`evidence-pi-{1,2,3}.json`（含 per-run 断言结果与一致性哈希）。

**证据可移植性**：evidence JSON 不含本机绝对路径/用户名——fixture 路径
以 `<REPO>` 归一化后写入，screen 与哈希都基于归一化内容；milestone 的
`normalized_raw_sha256`/`normalized_raw_bytes` 对 exact raw slice 先做
bytes 级 `<REPO>` 归一化再哈希/计量，不声称覆盖本机原始字节；exact raw
（可能含本机路径）仅 `--raw-dir` 本地落盘供诊断，不进入提交（默认不
写）。提交前还有运行时 `evidence_leaks` 检查：任何 evidence 记录序列化
后若含仓库根路径或用户名即 FAIL。证据字段含实际 oracle version/commit、
固定 terminal/settings/cwd/skills/model、keys、每步 normalized
screen+cursor、退出码、语义断言结果、三轮一致性结果。

协议记录的关键行为（Batch 1 的对照输入）：

1. Pi 0.82.1 的 ready marker 是 `\x1b[>7u`（`DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS
   = 7`）；Adou 是 `\x1b[>1u`。共享驱动按 side 配置 marker。
2. `--offline`/`PI_OFFLINE=1` 是 Pi 官方禁网开关（args.ts、main.ts），
   用于满足"测试不访问真实网络"；更新检查 banner 随之消失。
3. `/` 菜单候选 = 22 builtins + 3 fixture skills + 1 动态（llama）=
   26 项，全部带 name/description/argument hint。
4. Esc 只关闭菜单、保留输入 `/`；editor 清空键是 Ctrl+C（app.clear），
   Ctrl+D 是 exit（非空时删除）。
5. autocomplete 打开时 Enter 先应用当前候选（`applyCompletion`）；如果
   `suggestions.prefix` 以 `/` 开头（command-name completion），同一次
   Enter 随后落入 editor submit，提交**替换后的完整 editor 文本**；参数
   completion 则只应用、不提交。若把 `"/quit\r"` 一次性写入，Enter 可能
   在异步菜单打开前直接提交原始 `/quit`；逐键输入并等待菜单打开后再 Enter
   才能证明 command-name completion → submit 这条链路。
6. 顶部 40×↑ 后 Pi 回绕到 item 12（`(13/26)`），即 Pi SelectList 顶部是
   wrap 不是 clamp；↓ 8 次后 `(21/26)`，与列表尾无 wrap。

### 11.4 与 0.81.0 真机的冲突记录

- UX-002 曾记录"Adou 修复后 `/` 显示 5 行 + `(1/52)`"，但该修复是硬编码
  5 行（`render_command_menu`），未实现 3–20 可配置契约（IP-002 仍开放）；
  UX-002 附注"`/model` 落到 `/scoped-models` 是顺序差异非缺陷"与 IP-001
  （P0）冲突，作废。
- 0.81.0 真机画面不再作为 0.82.1 parity 的证明（§2.1 门禁）；后续对照
  一律使用本节的 0.82.1 协议基线。

### 11.5 返工前的错误记录（保留为历史证据，不抹除）

首次 Batch 0 执行记录的错误做法与失败点：

1. env 隔离缺失：`start()` 曾用 `os.environ.update()` 后 exec，父进程
   继承的凭据/proxy 变量可能进入子进程；已改为精确 allowlist + execvpe。
2. 生命周期缺陷：`wait_exit` 后 `pid` 未清空，`close()` 会对已回收 PID
   再 SIGKILL，存在 PID reuse 误杀窗口；已修复并有回归测试。
3. 无语义断言：旧版只比较"三次一样"，错误命名 `slash-up-clamp`；
   已改为语义校验 + 三轮一致 + exit 0，并改名 `slash-up-wrap`；
   Esc 校验曾依赖 pager 存在（候选残留无 pager 会假绿），已改为独立
   检测 editor 下边框之后、status 块之前的候选/分页残留行。
4. 误导接口：旧版 `--side adou` 只换 ready marker 仍启动 Pi；已移除。
5. 证据不可移植：旧版 screen/precondition 含 `/Users/...` 绝对路径，
   `raw_sha256` 还声称覆盖含本机路径的 exact raw 且可移植；已归一化为
   `<REPO>`，screen 与 `normalized_raw_sha256` 均基于归一化内容，
   exact raw 只走 `--raw-dir` 本地诊断。
6. 文档提前宣布：旧版 docs 写"Batch 0 已通过"；本修订改为"返工完成，
   待主代理复验"，验收通过与否由主代理判定。
7. 无门禁：旧版 `--runs 0/1` 也能 exit 0；已加 `--runs >= 3` 硬门禁
   （exit 2），summary 同时要求记录数 >= 3。
8. Python 缓存未忽略：`tests/e2e/lib` 运行后产生的 `__pycache__` 会
   进入 git status；已在根 `.gitignore` 加 `__pycache__/`、`*.py[cod]`
   并清理现存缓存目录。

## 12. Batch 1 主代理源码审计记录

### 12.1 Round 1（2026-08-14）

审计基线：Pi `0.82.1` commit
`cced6a21da273b26ee4a23a803680614bbe8dd1e`；OpenCode WIP 在审计期间
冻结。主代理逐段对照了 Pi 的 `autocomplete.ts`、`editor.ts`、
`select-list.ts`、`fuzzy.ts`、`interactive-mode.ts` 与 Adou 的
`autocomplete.n`、`editor.n`、`session_view.n`、`settings.n`。本轮结论是
**WIP 尚不可验收**，具体缺口如下；这些条目同时构成 OpenCode Round 1 的
封闭实现边界。

| ID | 级别 | 源码证据与当前偏差 | 修正后可观察契约 |
|---|---|---|---|
| B1-R1-01 | P0 | Pi 以 `cursorCol - suggestions.prefix.length` 计算替换起点；Adou `apply_command_completion()` 却在整个 cursor 前文本后再次拼 `/<value>`，实测得到 `/model/model `。 | `/model` 候选应用后 editor 必须是 `/model `；不得拼接旧 query。 |
| B1-R1-02 | P0 | Pi command prefix 是完整 `/mo`，argument prefix 仅是空格后的 `argumentText`。Adou 给 `/model`、`/login` 参数状态保存了整个 `before`，导致 best-match 与替换区间均错误。 | `/model deep` 只替换 `deep`；命令头、cursor 后缀和其他行不变。 |
| B1-R1-03 | P0 | Pi Enter 先更新 editor lines，再对 command prefix 提交更新后的完整文本。Adou绕过 editor，直接 `start_prompt('/' + value)`，丢失 cursor 后缀且 editor 状态与执行文本分叉。 | command Enter 走 editor submit/history 的单一事实源；argument Enter 只补全不提交；Tab 始终只补全。 |
| B1-R1-04 | P0 | Pi slash menu 只允许 `cursorLine === 0`，`applyCompletion()`复制全部 lines 后只替换当前行。Adou任意行都可开菜单，且把当前单行传给 `set_text_at()`，会清空多行缓冲区和 paste registry。 | 第二行 `/` 不开 slash menu；首行补全不删除其余行/粘贴标记，undo 仍是一个原子步骤。 |
| B1-R1-05 | P0 | Pi `setText('')` 会取消 autocomplete；Adou Ctrl+C 清 editor 后提前返回，旧菜单仍 active。Pi paste 会先取消而不会因粘贴 `/` 自动打开 slash menu；Adou相反。 | Ctrl+C 同时清 editor/menu；paste 不自动打开 slash menu；Esc 只关菜单并保留输入。 |
| B1-R1-06 | P1 | Pi PageUp/PageDown 在 autocomplete 分支中不改变 SelectList selection；Adou虽注释“leave untouched”，却在 editor 返回后无条件 `begin()`，把 selection 重置为 0。 | page keys 后候选、selection 与 pager 不变；会改变 query/cursor 的编辑键才重新查询。 |
| B1-R1-07 | P0 | item struct 虽声明 `argument_hint/source_tag/kind`，组装时 built-in 与 prompt 的 `argument_hint` 均丢失；prompt cache 类型也不携带该字段；git source tag 未实现；空描述会先生成带尾空格的 tag。 | 元数据保留 raw description + argument hint + source tag + kind，渲染时才组合 `hint — description`；project/user/npm/git tag 遵循 Pi。 |
| B1-R1-08 | P1 | Pi selected row 的 prefix、label、spacing、description 全部走 `selectedText(accent)`；Adou只给箭头 accent，选中描述仍 muted。 | raw ANSI 中选中整行使用 accent；未选中 description 才 muted。 |
| B1-R1-09 | P0 | `model_argument_items()` 每次键入都遍历约 1200 models，并对每个 model 调 `auth.effective()`；该函数每次打开/解析 auth 文件。`autocomplete_max_visible()`也每键重读 settings。 | credentials/settings/model candidates 在明确 init/reload/login/logout/scope 变化点刷新；普通键入不得触发 O(models × auth-file-read) I/O。 |
| B1-R1-10 | P1 | Pi settings 是 global+project merge；Adou autocomplete max 使用 `config_settings.load()`，忽略当前 cwd 的 project override。 | `autocompleteMaxVisible` 使用当前 cwd 合并值并 clamp 到 3–20，运行期间由缓存状态驱动。 |
| B1-R1-11 | P1 | Pi `/login` 候选按 provider **name** 排序并从运行时 provider options 去重；Adou注释声称按 name，实际按 `label=id`，且只遍历静态 `registry.defs()`。 | 当前支持范围内所有 API-key provider 候选按 name 稳定排序、按 id 去重；运行时注册项不静默丢失。 |
| B1-R1-12 | P1 | `rank_items()`排序后以 `search_text` 反查原 item；两个 item 搜索文本相同会重复第一个、丢失第二个。 | 排序过程保留 item identity 和原始稳定次序。 |
| B1-R1-13 | P0 | 现有 `tests/e2e/slash-menu.sh` 复制父进程 env、累计读取历史屏幕、仍断言顶部 clamp、批量写 `/model\r`，会假绿/假红；Batch 1 尚无 Nature unit test 或同协议 Adou/Pi oracle。 | 复用 Batch 0 `PtyCase`/VT screen/精确 env，逐键和 milestone slice；unit + Adou PTY + Pi 0.82.1 对照覆盖 replace/submit/multiline/cancel/wrap/page/metadata/max-visible/model/login。 |

Round 1 不授权修改 Batch 2 model selector、Batch 3 settings 全量表面或 Batch 4
cursor/keybinding 架构；只允许为上述 autocomplete 契约增加最小、明确的 editor
原子 API 与缓存失效钩子。旧 stability/terminal/stream 修复不在本轮改动范围，
不得回滚或顺手重写。

同轮主代理还使用 Batch 0 `PtyCase` 在 fixed env、`--offline --no-env
--no-extensions` 下对 vendored Pi 做了独立真机取证（24×100）：

- `/mod` + Tab 得到 `/model `，cursor column 7，菜单关闭、未提交；
- `/model d` + Enter 得到 `/model deepseek/deepseek-v4-flash`，cursor
  column 33，菜单关闭、未提交；
- `/model` command menu + Enter 直接进入 model selector，证明 command
  completion 与 argument completion 的 Enter 语义不同；
- `/` 后 Down×3 选中 `export`，再按 PageDown 仍为 `(4/27)`，selection
  不重置；
- `/` 后 Ctrl+C 同时清空 editor 和菜单；bracketed paste `/` 保留文本但
  不打开菜单；第二逻辑行输入 `/` 也不打开菜单；
- 该 fixture 的 Pi 总数是 27：22 built-ins + 2 prompts + 2 skills + 1
  内置 inline extension `llama`。`--no-extensions` 不移除 Pi 的 inline
  `llama`；Adou 产品范围排除 extension UI，因此双方 core 断言比较前 26
  项和 metadata，`llama` 必须明确记为 EXCLUDED，不能把 27/26 当缺陷或
  伪造相同总数。

### 12.2 Round 1 实施后的主代理 Round 2 审计（2026-08-14）

审计对象是 OpenCode 对 §12.1 的首轮实现 WIP。主代理未修改 Nature 源码；
本轮继续逐段对照 vendored Pi `0.82.1`，并使用 Batch 0 `PtyCase` 做新增的
独立 Pi 真机 oracle。结论仍是 **不得验收**。以下条目作为下一次 OpenCode
返工的单一、封闭输入；不得在处理过程中改做 Batch 2 selector 或 Batch 3
settings UI。

| ID | 级别 | 源码/实测证据与当前偏差 | 修正和验收要求 |
|---|---|---|---|
| B1-R2-01 | P0 | `handle_tab_completion()` 在菜单已关闭时先同步 `begin()`，随后同一次按键立即 `apply_autocomplete(false)`。Pi 0.82.1 独立真机实测：输入 `/mo`、Esc、Tab 后只是重新显示 model/scoped-models/import 三项，editor 仍为 `/mo`、cursor 仍在 column 3；并不直接补成 `/model `。 | Tab 在无 active menu 时只请求/打开候选；只有菜单原本 active 时才应用当前项。加入 Pi/Adou 同键 PTY 断言。 |
| B1-R2-02 | P0 | 首轮验证多次使用 `make build 2>&1 \| tail ...; echo EXIT=$?` 和同形 Nature test 管道。首次 build 明确报 `global initializer cannot assign literal to type 'any'`，unit test 也明确 panic，但两次都因 shell 返回 `tail` 状态而打印 `EXIT=0`。 | 历史失败必须保留；后续命令禁止吞状态的管道，直接记录真实 exit code。任何 panic/编译错误都不得以表面 `EXIT=0` 计通过。 |
| B1-R2-03 | P0 | `registry.find_def()` 明确规定 runtime provider 覆盖同 id builtin；`login_defs()` 却先放 builtin，发现 runtime 同 id 后丢弃 runtime，因此 `/login` 展示旧 name/metadata。Pi runtime registration 是 override。 | 按 id 合并时 runtime definition 获胜；测试 runtime provider 覆盖 builtin name 后 login 候选使用新 name，unregister 后恢复 builtin。 |
| B1-R2-04 | P0 | `/login` 候选把所有 `registry.defs()` 都当成 API-key auth option。`openai-codex` 在 Pi 只有 OAuth，当前 Adou 却会错误显示 `OpenAI Codex · API key`；同时 `provider_def_t` 没有 auth capability，无法区分 OAuth-only 与 API-key provider。 | API-key selector 只列真实支持 API-key login 的 provider，不能把 OAuth-only 伪装成 API key；完整 OAuth flow 另列开放 parity 工作。为 provider auth capability 建立可测试的数据源，不能以 `env_vars.len()` 粗略推断（Bedrock/Vertex 也是 API-key selector）。 |
| B1-R2-05 | P0 | 为消除逐 model 文件 I/O 新增了进程级 `cached_auth_root`，但 `/reload` 只重建 model items，未使 auth snapshot 失效；外部合法更新 `auth.json` 后 `/reload` 仍读取旧 map。Pi 的 AuthStorage 有显式 `reload()` 并保留最后有效 snapshot。 | 提供明确 credential reload/invalidate 点；`/reload` 后 model candidates 使用新 credential snapshot，解析失败保留最后有效 snapshot。普通键入仍不得重新读文件。 |
| B1-R2-06 | P0 | 启动层对未信任项目使用 global settings，但 `session_view.new()` 又无条件 `load_for(cwd)`，重新读取项目 `autocompleteMaxVisible`；同函数还无条件加载 project prompts。`refresh_dynamic_commands()` 的 prompt loader也不受 trust gate 约束。 | trust 决策必须贯穿 view：未信任项目不能应用 project autocomplete setting，也不能加载/广告/执行 project prompt/skill；user 资源仍可用。以 trusted/untrusted fixture 覆盖。 |
| B1-R2-07 | P1 | 动态候选的 `enabledSkills`/`enabledPrompts` 过滤仍调用 global `config_settings.load()`，忽略 trusted cwd 的 project override；`filter_enabled_skills()`、`filter_enabled_prompts()`也相同。 | 使用同一个 trust-aware、global+project merged settings snapshot；init/reload/session rebind 时刷新，普通键入不读盘。 |
| B1-R2-08 | P0 | session rebind 只调用 `refresh_dynamic_commands()`；未更新 `self.prompt_templates`、autocomplete max、credential/model candidates。结果可能是新项目 prompt 出现在 menu，但提交后仍由旧项目 `self.prompt_templates` 扩展，且新 cwd 设置不生效。 | rebind 原子刷新 prompt execution list、dynamic command list、trust-aware settings、max visible 和 model candidate snapshot；menu metadata 与实际执行必须来自同一份资源。 |
| B1-R2-09 | P1 | 手写 `git_source_tag()`只接受少数 URL；Pi `parseGitUrl()`还校验 host/path、支持 `git:` 前缀下的历史 shorthand/scp form，并拒绝不安全或不足两段的 path。当前实现对 `git:git@host:owner/repo` 解析错误，也没有任何 source-tag unit test。 | 按 Pi parser 的本轮可观察 tag contract 补齐有效/无效案例；至少覆盖 user/project/local、npm、https+ref、`git:`+scp shorthand、非法单段/父目录。 |
| B1-R2-10 | P0 | 新 unit test 只测 pure helper 和 editor range；没有调用 TUI dispatch/item assembly，声称“保留 paste registry”的 case 也没有创建真实 large-paste marker。旧 `tests/e2e/slash-menu.sh` 截至本轮审计仍复制父 env、读累计输出、断言 clamp，并批量发送 `/model\r`。 | unit 增加真实 paste marker/undo、metadata/provider merge；e2e 必须真正改为共享 `PtyCase`、exact env、VT current screen、milestone slice、逐键 input，并覆盖 command Enter、argument Enter、Esc→Tab reopen、Ctrl+C、paste、second line、wrap/page、max-visible、model/login metadata。 |
| B1-R2-11 | P1 | `autocomplete_item_t.description` 注释仍把字段称为已经组合后的 display description，而实现/计划要求 raw description；这类错误契约会再次诱发 double-tag/double-hint。 | 注释、类型契约、组装和测试统一为 raw fields，仅 render 调用 `display_description()` 组合。 |

新增 Pi oracle（24×100、Batch 1 fixed env、`--offline --no-env
--no-extensions`）：`/mo` 逐键输入后 menu 为 model/scoped-models/import；Esc
关闭后 editor/cursor 保持 `/mo`/column 3；Tab 后同一三项 menu 重新出现，
editor/cursor 仍保持不变；随后按协议退出，exit code 0。这一证据关闭了
B1-R2-01 的语义不确定性。

Round 1 的真实失败历史：首次 `make build` 失败于 `src/config/auth.n` 的非法
全局 `any = null`；首次 targeted autocomplete test 在第 2/18 项因错误 cursor
期望（36，正确为 33）panic。两次终端都因 `| tail` 打印了伪 `EXIT=0`。
后续成功重跑不能删除这两条记录。

### 12.3 Round 2 实施中的主代理 Round 3 审计（2026-08-14）

审计对象是 OpenCode 对 §12.2 B1-R2-01..11 的第二轮实现，包括新加入的
trust-aware resource snapshot、provider auth capability、auth reload 与 RPC/session
rebind 代码。主代理继续以 vendored Pi `0.82.1` 为源码权威，并检查了实际
调用链，而不把 helper unit test 当成生产路径已经接通的证明。本轮结论仍为
**不得验收**；下列条目是下一次 OpenCode 实现的封闭边界。

| ID | 级别 | 源码/实测证据与当前偏差 | 修正和验收要求 |
|---|---|---|---|
| B1-R3-01 | P0 | `session_view.apply_path_completion()` 仍调用 `editor.set_text_at()`。该 API 会重建整个 editor、清空 `pastes/paste_counter`，而调用方传入的又只是当前单行；因此 Tab 文件补全或 `@` 补全仍会删除其他逻辑行和 large-paste registry。slash 补全虽已改用 range API，但同一 Pi `CombinedAutocompleteProvider.applyCompletion()` 的 path/attachment 分支没有接上。 | 扩展/复用保留全部 lines、paste registry、kill/history 状态的原子 range completion API；文件和 `@` 补全不得再走 `set_text_at()`。用真实 `handle_paste(>1000 chars)` marker + 多行 + suffix + 单步 undo 覆盖生产所用 API。 |
| B1-R3-02 | P0 | TUI `rebind_project_context()` 在刷新 snapshot 后直接以 CLI `system_prompt_override` 和 `append_system_prompts` 重建 prompt；当 CLI 未显式提供时，没有像 startup 和 `/reload` 那样发现目标 cwd 的 `.pi/SYSTEM.md` / `.pi/APPEND_SYSTEM.md`。切换 session 后菜单来自新项目，system prompt 却缺少新项目文件。 | rebind 与 startup/reload 使用同一 trust-gated system/append resolution；untrusted 不发现项目文件，trusted 目标 cwd 发现并应用，CLI override 继续优先。 |
| B1-R3-03 | P0 | RPC `rebind_rpc_context()` 虽新增 trust gate，却没有重新加载/过滤 skills，也没有把 `format_skills_for_prompt()` 注入重建后的 system prompt；startup runner 原有 skills block 会在 `switch_session` 后消失。 | RPC rebind 使用目标 cwd 的 trust-aware merged settings 和同一 filtered skills snapshot；仅在 `read` tool 存在时注入 skills，规则与 fresh/spawned/TUI 完全相同。 |
| B1-R3-04 | P0 | `runner.replace_repository()` 在外层知道目标 cwd trust 之前无条件调用 `settings.load_for(next.cwd)`，项目的 queue/compaction/retry settings 已先写入 runner；随后 TUI/RPC resource rebind 的 trust gate无法撤销这次泄漏。 | session replacement 的 preference 应用必须接收/使用目标 cwd 的 trust-aware snapshot，不能在 core 内无条件读 project settings。更新 TUI、RPC、clone/fork 和对应 tests，保证 untrusted 只用 global、trusted 才 merge project。 |
| B1-R3-05 | P0 | 新 `refresh_resource_snapshot()` 会读取目标 cwd settings，但 `model_scope_patterns`、`scoped_model_ids/active` 仍保持启动项目的值；`refresh_model_argument_cache()` 因而只是用旧 scope 重新扫描。B1-R2-08 所要求的 rebind model candidate snapshot 尚未实现。 | 明确保存 CLI `--models` 是否显式：显式 scope 跨 rebind 保持；否则 init/reload/rebind 从 trust-aware `enabledModels` 原子更新 scope/selector backing state，再重建候选。 |
| B1-R3-06 | P1 | `auth.read()` 使用 last-valid snapshot，但 `read_credential()` 每次直接读盘，`list_credentials()`又先以文件存在性短路；同一个 CredentialStore 在外部 corrupt/delete、尚未 successful reload 时会返回互相矛盾的状态。Pi `AuthStorage.read/list` 都读同一内存 `data`，只有 `modify` 在锁内读取当前存储。 | `read/read_credential/list_credentials` 统一读取同一 last-valid snapshot；外部 delete 在显式 reload 前仍返回旧 snapshot，reload 后为空。write/modify 仍以当前磁盘对象做 read-modify-write，并在成功后同步/失效 snapshot。 |
| B1-R3-07 | P1 | `git_source_tag()` 仍是局部手写 parser：把 `#` 当主要 ref，却不实现 Pi `splitRef()` 的 path `@ref`；`git:git@host:owner/repo`、`git:host/owner/repo`、host/path 验证、`.git` normalization 与 traversal/encoded traversal 拒绝均不完整，且没有 production assembly test。 | 提取可测试的 source-tag parser 并由 `command_items()` 实际调用；至少覆盖 local user/project/temporary、npm、https/ssh `@ref`、`git:`+scp/host shorthand、`.git`，以及单段 path、无 host、absolute/backslash/NUL/`..`/encoded traversal 拒绝。 |
| B1-R3-08 | P0 | `rpc_commands()`现在复用了 filtered resource list，但映射 JSON 时仍只输出 `name/description/source`，漏掉 Pi `RpcSlashCommand.sourceInfo`；其注释声称“source metadata”已对齐，实际 wire contract 没有。Adou `source_info_t` 本身也缺 Pi 的 resource `path` 字段。 | source info model 补齐 resource path，并在 prompt/skill loader 填充；RPC `get_commands` 输出完整 `sourceInfo {path,source,scope,origin,baseDir?}`，以 JSON contract test 覆盖 trusted/untrusted 和 enabled filters。argument hint 不属于 Pi RPC contract，不得伪加。 |
| B1-R3-09 | P1 | provider capability 已修正 OAuth-only 排除，但 vendored Pi provider 名是 `Google Vertex AI`，Adou仍为 `Google Vertex`；`/login` 的排序、description 和 search text 因此可观察不等价，现有 test 还固化了错误名称。 | provider canonical name 与同版本 Pi 对齐为 `Google Vertex AI`，更新 login metadata/sort test 与 PTY 断言。 |
| B1-R3-10 | P0 | B1-R2-10 仍未关闭：`tests/autocomplete_test.n` 的“keeps paste registry”没有调用 `handle_paste()`，没有创建 marker；Adou PTY 也尚未覆盖 `autocompleteMaxVisible` 3/20、`/login` capability/metadata、prompt hint/source tag、选中整行 raw ANSI accent。 | unit 必须创建真实 large paste；PTY 复用 exact-env `PtyCase`、current VT screen、milestone raw slice，补齐上述分支并连续三轮。辅助函数通过不能替代 dispatch/item assembly/raw render 断言。 |

本轮还对一个容易误判的 Tab 边界做了反例核验：阅读 Pi
`runAutocompleteRequest()` 时，`force && explicitTab && items.length === 1` 会直接
应用 completion；但 slash 的 `handleSlashCommandCompletion()` 传入 `force=false`。
主代理随后用同一 Pi 0.82.1 PTY 对 `/sett`、Esc、Tab 以及 `/settings`、Esc、
Tab 实测：即使过滤后严格只有 `settings` 一项，Tab 仍只重开菜单，editor 与
cursor 不变。故 B1-R2-01 当前“inactive slash Tab 只重开”实现正确，未把源码
条件误读成新 bug。

Round 2 实施期间还保留一条真实工具链失败历史：auth snapshot 首版使用
`(map, bool)` 返回后，Nature targeted auth test 在 `auth.save -> auth.read` 路径
无输出挂起；缩小复现后改为 bool-only helper 才通过 2/2。该 hang 不能因最终
重跑成功而从记录中删除。另一次 OpenCode 生成在 RPC rebind edit 画面超过
25 分钟无文件变化、且无 Nature 进程，主代理中断并恢复同一 session；这是
agent 执行停滞，不计为产品测试结果。

### 12.4 Round 3 实施中的主代理 Round 4 审计（2026-08-14）

审计对象是 OpenCode 对 §12.3 的实现 WIP。主代理继续直接检查生产调用链，
并补做 vendored Pi `0.82.1` 的精确环境 PTY oracle。本轮确认 Batch 1 尚未收口：
slash command 的主要 range completion 已开始统一，但 path/`@` 仍保留另一套
generic overlay 和错误的 Tab fallback。下列条目构成下一轮 OpenCode 的封闭输入；
不得扩展到 model selector/settings UI，也不得用 helper-only test 宣称产品路径通过。

| ID | 级别 | 源码/实测证据与当前偏差 | 修正和验收要求 |
|---|---|---|---|
| B1-R4-01 | P0 | `cli_args_t`/args parser 已开始保存 `scoped_models_explicit`，但 `config.resolve()` 返回 `config_t` 时仍可能丢失该位；rebind/reload 也只刷新部分 scope state，旧 `model_scope_patterns_cache` 可继续驱动 selector；显式 CLI scope 分支又会跳过 settings-backed `scoped_model_ids` 初始化。 | 从 args 到 resolved config 完整传递 explicit 位；显式 `--models` 跨项目保持，未显式时从 trust-aware settings snapshot 更新；reload/rebind 同步 active scope、legacy selector cache 和 settings-backed selector ids，并覆盖 explicit/implicit 两条生产路径。 |
| B1-R4-02 | P0 | path/`@` 多候选仍走 `OVERLAY_PATH_COMPLETION` generic overlay，而 Pi 与 slash/argument 共用 editor 下方 SelectList。Adou 该 overlay 是全屏布局，Up/Down clamp，忽略 Tab、普通输入和 Backspace，也不按查询重算；description、统一 max-visible、关闭/重开生命周期均与 Pi 分叉。 | path/`@` 接入同一个 autocomplete state/SelectList dispatch；方向键 wrap、active Tab 应用、编辑键重算、Esc 关闭、max-visible/description/render 生命周期与 slash 一致。移除或停止从生产路径进入 generic path overlay。 |
| B1-R4-03 | P0 | `handle_tab_completion()` 在空 prefix 或无候选时插入四个空格。Pi 0.82.1 新 PTY oracle：fixture 只有 `.pi/` 候选时，空 editor + Tab 直接得到 `.pi/`、cursor column 4；输入 `zzzz-no-such-entry` + Tab 后文本/cursor 完全不变。 | explicit Tab 对唯一 path 候选直接应用；无候选不修改 editor，不把补全失败伪装成缩进。为 one/no candidate 加生产 dispatch unit 和双方 PTY milestone。 |
| B1-R4-04 | P0 | `session_view.at_prefix_for()`自行向左扫描 `@`，未实现 Pi 的 token-boundary 规则，且绕过已有 `path_completion.extract_at_prefix()`；普通输入出现唯一 `@` 候选时 Adou还会立即应用，而 Pi 的非 explicit request 即使只有一项也打开 SelectList。 | 使用一份可测试的 boundary parser；`me@domain` 保持普通文本且不显示 completion；自然输入的 one candidate 打开列表，只有 `force && explicitTab && one item` 才直接应用。 |
| B1-R4-05 | P1 | `get_fuzzy_file_suggestions()`递归收集时把 absolute `full_path` 同时当 display/completion path。Pi 的 `fd --base-directory` 普通结果相对 baseDir，只有明确 scoped/absolute 输入保留相应前缀。 | 普通 path/`@` 候选和插入文本使用 baseDir-relative path；显式 `./`、`../`、absolute/scoped prefix 按 Pi 规则处理。以临时 fixture 断言 label 与最终 editor 文本均不泄漏绝对 cwd。 |
| B1-R4-06 | P1 | auth read/list 已统一 last-valid snapshot，但 `remove()` 在 auth 文件被外部删除、损坏或 key 不在当前磁盘对象时直接返回，可能把待删除 provider 留在旧 snapshot；logout 后仍表现为 configured。 | mutation 成功或确认目标已不存在后，同步/失效内存 snapshot；外部 delete/corrupt + remove/logout 的行为必须确定且一致，测试 read/list/effective 不再返回已删除 credential，同时保留 reload parse-failure 的 last-valid 契约。 |
| B1-R4-07 | P0 | `runner.replace_repository()` 已移除无条件 project settings read，但旧 `tests/agent_session_test.n` 仍断言仅调用 replace 就加载目标项目 preferences，继续固化已禁止的 trust bypass。 | 重写为 caller 传入 trust-aware `apply_preferences_snapshot()`：trusted 使用 merged project snapshot，untrusted 只用 global；core replace 本身不得读目标项目 settings。 |
| B1-R4-08 | P0 | §12.3 要求的生产证据仍不完整：autocomplete unit 尚未证明真实 `handle_paste(>1000)` marker 经 path/`@` completion 保留；PTY 尚缺 email literal、one/multiple/no candidate、active Tab、typing/Backspace requery、wrap、relative insertion 和 selected raw ANSI。 | unit 调用真实 paste API并经过生产 completion dispatch；Adou PTY 复用 exact-env `PtyCase` 与 current VT/raw milestone，覆盖全部上述分支并连续三轮，再与同键 Pi oracle逐项比较。 |
| B1-R4-09 | P1 | 修复 `scoped_models_explicit` 时曾整体改写 `cli_args_t` 片段，最终虽恢复了误删的 `file_args/errors`，却又把只属于 resolved `config_t` 的 `steering_mode/follow_up_mode/hide_thinking` 复制进 CLI struct；三字段无 parser/consumer，是本轮意外死状态。 | `cli_args_t` 相对原契约只增加 `scoped_models_explicit`，移除三项误加字段；以 HEAD schema 对照和 config targeted test 防止再次误删/搬移相邻字段。 |
| B1-R4-10 | P0 | RPC rebind 会加载 filtered skills 注入 system prompt，但 `get_commands` 随后调用 `rpc_commands()`重新读取 settings/prompts/skills。文件在未 `/reload` 时变化即可让 RPC 菜单与当前 system prompt/可执行资源分叉；Pi 返回 `session.promptTemplates/resourceLoader` 已加载的同一 snapshot。 | RPC runtime 持有 init/reload/switch-session 原子刷新的 trust-aware resource snapshot；system prompt 注入、prompt execution 与 `get_commands` 共用它。无 reload 的磁盘变化不可单独改变 wire commands；switch 后三者一起切换。 |
| B1-R4-11 | P1 | 新 `git_source` parser 只做最小 `%XX` 解码：畸形 percent/非法 UTF-8 不像 Pi `decodeURIComponent` 那样拒绝；协议 URL 又把 port 留在 host、未完整复现 `URL.hostname/pathname`。这会产生与 Pi 不同甚至不稳定的 source tag。 | 对照 Pi `parseGitUrl` 补 malformed percent、encoded UTF-8、userinfo+port、query/fragment、大小写协议测试；host/path/ref 输出必须与 Pi 一致，无法可靠解析时返回空 tag。 |
| B1-R4-12 | P0 | Pi `applyCompletion()` 对 `@file`（非目录）在 item 后追加一个空格，对 `@dir/` 不追加；Adou `apply_path_completion()`只替换 `item.value`，两者都不加，且现有测试未断言该分支。 | unified range apply 明确区分 attachment/file-path：`@file` 后一个空格且 cursor 在其后，`@dir/` 无空格；quoted item、cursor suffix、多行、paste marker 和单步 undo 同时保持。 |

本轮新增 Pi oracle 使用与 Batch 1 相同的 24×100 fixed env 和 fixture，协议退出
均为 exit code 0：输入 `me@domain` 时无 completion UI、文本保持原样；输入
`zzzz-no-such-entry` 后按 Tab，文本和 cursor 不变；空 editor 按 Tab，在唯一
`.pi/` 候选条件下直接补为 `.pi/`。这三项分别关闭了 email boundary、no-match
fallback 和 explicit-Tab single-item 语义的不确定性。

Round 3 实施的串行验证历史（失败不抹除）：首次 `make build` 因
`cli_args_t.scoped_models_explicit` 缺失失败；补字段时一度误删相邻
`file_args/errors`，在下一次构建前恢复。`git_source_test` 先因协议 URL slice
上界使用错误 panic，修复后又以 NUL/percent validation 暴露第二个失败，最终
6/6；临时 `git://` probe 还纠正了“该形式应被 Pi 接受”的错误预期。
`slash_commands_test` 曾因 `any == string` 编译失败，`autocomplete_test` 曾因
`apply_completion_at` 少传 cursor 参数失败，`agent_session_test` 曾因 settings
alias 错误失败，均修复后重跑通过。最终串行结果：`make build` exit 0；
git source 6/6、slash commands 7/7、autocomplete 19/19、agent session 31/31、
auth 2/2、auth store 4/4、settings 5/5、prompt templates 8/8、registry 8/8、
config context 25/25、path completion 7/7、editor 25/25、skills 22/22、
config resolve 5/5。Round 3 的 source/unit 收口不等于 Batch 1 验收；
§12.4 和三轮 Adou PTY 仍是硬门禁。

### 12.5 Round 4 实施后的 Round 5 baseline（2026-08-14）

主代理已复审 Round 4 结果：严格 max20 证据可信；Pi 0.82.1 与 Adou 在
24×80 + autocompleteMaxVisible=20 都会把 editor 挤出屏幕，该契约冲突由
主代理另行裁决。以下为 OpenCode Round 5（间歇性 child mid-run exit 的
RCA）baseline，只记录已证实事实，禁止无证据归因。

| ID | 级别 | 已证实事实 | 未证实/待查 |
|---|---|---|---|
| B1-R5-01 | P1 | 在 batch1-max20 fixture 的完整 slash-menu 里程碑序列中，约 1/10 概率（观察到的次数：Round 4 的 runner 两次 run-2 早退 + 一次最小 harness run-1 早退）出现 Adou 子进程中途干净退出：PTY 写侧观察到 EIO（子进程已退出），raw 尾部含终端 restore 序列（`?2026l`/`<u`/`?2004l`/`?25h`），说明清理路径已执行；无 crash report 文件产生。退出发生前 screen/cursor 已渲染 startup。尚未复现于 default/max3 fixture；未在 Pi 0.82.1 上观察。 | 退出分类（正常 exit code / 负 signal / timeout / EIO 时序）、最小按键重现、是否与 max20 布局、特定 milestone、settle timing、runner 生命周期或 Adou 产品退出相关、根因是否涉及 Nature heap/renderer/product——均未证实。 |

Round 5 不接受"未复现即修复"的宣称；20 轮内未复现时必须报告置信边界与
下一诊断点，不得修改 max20 可见性验收定义或把 summary 改为 PASS。

Round 5 实测补充（2026-08-14，§12.6 有口径纠错）：新窗口 29 次未复现
（20 轮完整 max20 repro + 9 轮直接 slash-menu max20 runner）；点估计 0/29，
独立同分布假设下 rule-of-three 95% 上界约 10%（假设未证实），不得写成
"复发率低于 3%"。历史三次保留，B1-R5-01 仍 OPEN。

Round 6 跟进重跑（2026-08-14，identity 返工通过后）：按现有协议对
batch1-max20 完整里程碑序列串行重跑 30 轮（/tmp harness，逐轮分类
clean-quit / EIO+waitpid / drain-timeout / ready-timeout / quit-*），全部
clean-quit，0 异常；同窗口内 strict slash-menu max20 runner 3 轮亦无
EIO（仅冻结的严格 UX FAIL verdict）。累计未复现窗口扩大为 0/59（点估计
0；rule-of-three 上界随窗口缩小，但 iid 假设仍未证实）。退出分类
（正常 exit code / 负 signal / timeout / EIO 时序）与根因仍未证实；
B1-R5-01 仍 OPEN，不得误写为已修复。下一诊断点不变：term.n
EINTR-retry 预算耗尽的 debug 日志埋点 + 受控内存压力复现（历史三次均
出现在高负载窗口，该假设尚未验证）。

### 12.6 Round 5 记录纠错与 Round 6 主代理裁决（2026-08-14）

#### §12.5 纠错（2026-08-14）

Round 5 的复现统计与退出码口径需按以下事实纠正（原 §12.5 文字已修订
保留历史）：

- 新窗口统计：**0/29** —— 20 轮完整 max20 repro harness + 9 轮直接
  slash-menu max20 runner，均未复现历史早退。点估计为 0；在"独立同分布"
  假设下 rule-of-three 95% 置信上界约为 10%，**但该假设未证实**，不得写
  成"复发率低于 3%"。
- 退出码口径：直接运行 strict max20 runner 时，UX 断言失败使 runner
  返回非零（实测 exit 1），此前表格中"runner exit=0"是指子进程 adou 的
  exit code（runner 打印的 per-run 字段），不是 runner 自身退出码；两类
  必须分列。
- B1-R5-01 仍 OPEN：根因未证实（候选：term.n EINTR-retry 预算耗尽 →
  EOF 清理路径；受控内存压力假设未验证），下一诊断点为 EINTR 耗尽 debug
  日志 + 受控压力复现。

#### Round 6 主代理裁决（2026-08-14）

依据 docs §2.2（Pi 0.82.1 源码、Pi 测试、同版本同键真机行为优先于 Adou
与旧计划断言）：

- Pi 0.82.1 与 Adou 在 24×80 + autocompleteMaxVisible=20 均把 editor
  挤出屏幕（Round 4 oracle 证据）。因此该场景：
  - **parity：PASS**（双方行为等价）；
  - **输入可见性 UX：KNOWN UPSTREAM LIMITATION / strict UX FAIL**（旧
    §8 矩阵"slash 输入仍可见"仅适用于 normal/default 与 max3；max20 为
    fixture-qualified upstream-equivalent UX limitation）。
- parity verdict 与 strict UX verdict 必须分字段、分证据；禁止把 UX FAIL
  改写为普通 PASS。现有 strict `summary-adou-batch1-max20.json` 与 Pi
  max20 FAIL 证据保留不动。

#### Pi 0.82.1 精确 source mapping（max-visible 契约）

- 设置进入点：`interactive-mode.ts:471/4165` `settingsManager.getAutocompleteMaxVisible()`
  → `new Editor({ autocompleteMaxVisible })`；设置变更时
  `interactive-mode.ts:1723-1728` `setAutocompleteMaxVisible(...)` 热更新。
- Editor 钳制：`editor.ts:352/382` `Math.max(3, Math.min(20, Math.floor(v)))`，
  非法值回退 5。
- SelectList 接线：`editor.ts:2132 createAutocompleteList` →
  `new SelectList(items, this.autocompleteMaxVisible, ...)`；slash 菜单使用
  `SLASH_COMMAND_SELECT_LIST_LAYOUT`（min/max primary 12/32）。
- 窗口数学：`select-list.ts render` `startIndex = max(0, min(selectedIndex -
  floor(maxVisible/2), length - maxVisible))`，`endIndex = min(startIndex +
  maxVisible, length)`；越界时追加 pager `(n/N)`。
- 24×80 裁剪 editor 的原因：SelectList 渲染 `maxVisible` 行且不与终端高度
  做预算交互（无 effective-count 钳制），editor 区域 + 20 行候选 + pager +
  status 超出 24 行，diff renderer 将 editor 滚出视口；Esc 关闭后恢复。
  Adou 行为等价（无产品改动，裁决冻结）。

#### Round 6 首版比较器复审失败及返工记录（2026-08-14，历史保留）

首版 `max-visible-parity.py` 经主代理复审发现以下假绿路径（均已返工，
缺陷记录保留）：

1. `load_side/compare` 未提取/验证 terminal rows/cols 与 configured
   autocompleteMaxVisible，双方同样跑错尺寸/配置仍 PASS。
2. `parse_screen` 在 startup 空候选处可能返回 candidate_count=None /
   candidate_names=None，`compare_side` 对双方 None==None 不报错，违背
   "candidate_count=None 永不等价"。
3. summary 声称 leak-checked 但代码无 leak 检查。
4. 未验证 run ID 恰为 {1,2,3}、case/side/fixture、Pi oracle
   version/commit 与 evidence precondition；重复或错 fixture 可混入。
5. aggregate 从磁盘已有 per-max 文件拼接，未要求 3/5/20 全齐、未保证同
   一新鲜执行；Python `all([])` 或部分集合可能假 PASS；CLI 无参数时
   exit 2，不能一条命令重建并验证完整 aggregate。
6. source commit 是硬编码常量，未与 evidence 记录或 vendored HEAD 交叉
   验证。

返工后契约（`max-visible-parity.py` v2，self-test 逐项覆盖）：

- parser：正常空候选窗口 → count=0/names=[]；非空不可解析 candidate
  area → 显式 parse_error；slash-open 任何 None/parse_error（即使双方
  相同）→ parity FAIL。startup 无 candidate area（editor 后为
  cwd/status 块），其候选字段仅记录不比较。
- 每侧 3 record 校验：run IDs 精确 {1,2,3} 无重复；case/side/fixture；
  terminal 每轮 24x80；configured max 每轮一致且等于当前 3/5/20；
  exit=0；required milestones 每轮恰一个；归一化 screen 三轮一致。
- Pi oracle version/commit 从 evidence 读取并与 vendored `vendors/pi`
  HEAD 交叉核对；Adou evidence 增加 `adou_head` 字段并与工作树 HEAD
  核对（slash-menu.sh schema 已扩展并重新生成三轮证据）。
- 输入 evidence 与输出 summary 均做 repo root/username/HOME leak 检查，
  `leak_checked` 仅在真实检查通过后为 true。
- CLI：无 `--max` 时同进程加载并验证 exactly {3,5,20}，全部成功后原子
  写 aggregate（tmp + rename）；部分 `--max` 仅诊断，不写 aggregate。
- 自测新增负例：双方 count/name 均 None、双方同错 terminal、双方同错
  configured max、duplicate/missing run、错 side/fixture/case、缺/重
  milestone、错/缺 Pi commit、Adou stale HEAD、evidence leak、缺一个
  max、陈旧 per-max 文件不影响 in-memory aggregate；保留既有
  editor/order/pager/status/exit/consistency/llama 负例。

返工后实测（2026-08-14）：self-test 全过；完整 aggregate 单进程重建
max3/max5/max20 → parity PASS ×3，strict UX max20 FAIL（冻结裁决不
动）；独立 JSON contract 检查通过（exactly {3,5,20}、commit 交叉、无
leak、max20 双方 editor 不可见 + 20 候选 + pager (1,26) + status 可见、
max5 双方 editor 可见 + input "/"）。

#### Round 6 第二次主代理复审失败及 identity 返工记录（2026-08-14，历史保留）

第二次复审 findings（均已返工）：

- F0（self-test 破坏真实证据）：首版 self-test 为测试 stale per-max 直接
  覆盖 `docs/pi-batch1-evidence/max-visible-parity-summary-20.json`，文件
  原本存在时未恢复。返工：self-test 完全隔离，aggregate 构造抽为纯函数
  `build_aggregate`（内存对象测试），fingerprint 测试用
  `tempfile.TemporaryDirectory`；self-test 前后对真实 evidence 目录做
  bytes 级哈希断言，任何改动即 FAIL。
- F1（Pi 缺 side 字段）：`max-visible-oracle.py` 每个 Pi record 增加
  `side:"pi"`；comparator 强制 Pi side 精确等于 "pi"（缺失/错误均 FAIL）。
- F2（Adou 只有 HEAD，dirty worktree 下 HEAD 不变）：`slash-menu.sh` 每
  record 增加 `binary_sha256`（ADOU_BIN 实际 bytes）与 `source_fingerprint`
  （Makefile build 输入：main.n、package.toml、src/**/*.n 含 untracked、
  native/*.c、scripts/nature-build-safe.sh；repo-relative 排序，path+content
  入 hash）。comparator 重算并逐轮校验；binary 变化、tracked 源码变化、
  untracked src/*.n 变化均 FAIL（纯/tempdir 负例）。
- F3（vendors/pi worktree dirty）：`oracle_runtime_fingerprint` 覆盖
  pi-test.sh 启动链输入（launcher、tsconfig、packages/*/package.json、
  packages/*/src/**/*.ts）；record 同时写 `vendor_dirty_paths`。comparator
  classify：dirty 路径在 fingerprint 输入集内 → parity FAIL；无关路径
  （当前 `packages/coding-agent/test/fixtures/before-compaction.jsonl`）→
  known limitation 显式记录，不静默。vendors dirty fixture 未修改未回滚。
- F4（aggregate 元数据缺失）：aggregate 增加 `max_values:[3,5,20]`、
  `validated_contract`（terminal 24x80、runs 3、Pi version/commit/runtime
  fingerprint、Adou head/binary/source fingerprint、required milestones、
  leak check）；per-max summary 增加 `schema_version:"2"`。

返工后实测：self-test 全过（含 evidence 目录前后 bytes 不变）；Pi
oracle 3/5/20 与 Adou batch1/max3/max20 三轮 evidence 全部重生成（max20
双方仍为严格的 upstream-equivalent UX FAIL）；完整 aggregate 单进程
重建 → parity PASS ×3、strict UX max20 FAIL；独立 JSON contract 检查
通过（side/commit/fingerprints 交叉核对、vendor dirty 分类、无 leak）。

### B1-R5-01 terminal I/O 诊断埋点契约（2026-08-14 实施）

默认关闭、可显式启用，不改默认交互行为，不写交互 PTY 输出、不改变
JSON/RPC stdout（复用 src/debug.n 的文件日志纪律）：

- 开关：`ADOU_TUI_IO_DIAG=1`；日志目标：`ADOU_DEBUG_FILE=<file>`；未设
  开关或未设文件目标时静默丢弃。payload 为固定事件类别 + errno
  分类/计数，无本地路径、无凭据。
- 事件集（`src/tui/term.n` `TUI_IO_*`）：
  - `eintr-retry`：首次被重试的中断读；
  - `eintr-exhausted`：EINTR 重试预算（INPUT_EINTR_RETRY_LIMIT=100）耗尽
    后仍为 EINTR——这是"clean restore 退出"的最可疑来源（read 失败 →
    read_terminal 转 EOF channel → run loop 正常退出 → restore）；
  - `eof`：read 返回 0（真 EOF，如 PTY master 关闭）；
  - `read-failure`：非 EINTR 读失败 / 负 count；
  - `write-failure`：terminal write 停滞后超限或永久错误；
  - `restore`：terminal restore 序列已发出（suspend 与 shutdown 都会触发）；
  - `quit`：run loop 正常退出（session_view.view_t.run 末尾）。
- 分类判定：`quit`+`restore` = 正常退出；`eof`（或
  `eintr-exhausted`/`read-failure`）后跟 `quit`+`restore` = EOF/故障诱导的
  干净退出；`restore` 无 `quit` = suspend（Ctrl+Z）。下一轮 max20 复现时
  以该日志区分三种路径。
- 纯逻辑覆盖（tests/term_test.n）：默认关闭/开启门控、行格式、固定数值
  EINTR/EAGAIN 状态码、EINTR 预算边界（eintr_retry_allowed）、事件类别固定
  且互异。

#### B1-R5-01 诊断窗口复现与机制确认（2026-08-15）

启用 ADOU_TUI_IO_DIAG 埋点后，用现有 PtyCase 协议对 batch1-max20 完整
里程碑序列串行重跑：第 11 轮复现（前 10 轮 clean-quit）。复现轮精确
分类：

- child 干净退出，waitpid = ('exit', 0)，非信号、非 PTY 写超时；EIO
  只是检测到子进程已退出的时机点（failing key：slash-prompt-filter-2 的
  '/'，last_success=at-clear-6，run 内第 18.5s）。
- 诊断日志事件序（保留证据：/tmp/r5-diag-11.log）：仅 `quit` →
  `restore`；无 `eof`/`eintr-exhausted`/`read-failure`/`write-failure`——
  排除输入侧（EOF/EINTR 耗尽）与输出侧机制。
- 定向实验（现有 binary，同一 24×80/fixed env/同一日志契约）：`/` 后
  300ms 间隔连按两次 ctrl+c → 子进程 exit 0，事件序同为 `quit` →
  `restore`（无任何输入侧事件）。与复现轮日志字节级同构。
- 结论：B1-R5-01 的间歇性 child mid-run exit 机制为 session_view
  ctrl+c 双击退出路径（session_view.n:515：500ms 窗口内第二次 ctrl+c
  即 quitting）。max20 重渲染使输入处理滞后、PTY 队列中来自不同
  milestone 的 ctrl+c 在应用侧被 <500ms 处理，触发该路径；与历史三次
  出现于高负载窗口一致。历史 0/59 之后的累计 clean 窗口为 0/69（本轮
  前 10 轮），第 11 轮复现。
- 状态：B1-R5-01 机制已定位（双击退出在输入突发下被误触发），产品侧
  是否属缺陷（vs 协议时序假象）由主代理裁决；本轮未改产品代码，埋点
  后续可对 515/2207 路径补行为中立的 quit-reason 事件以在野确认。

#### B1-R5-01 测试协议屏障修正（2026-08-15，非产品修复）

只读对照确认 Adou 与 Pi 0.82.1 的 Ctrl+C 双击退出语义一致（500ms、处理
时墙钟、首清次退；真机 300ms 双按均 exit 0）。复现机制为 e2e 协议时序：
plain drain 的 quiet 可在滞后子进程处理新输入前满足，不同 milestone 的
Ctrl+C 在应用队列中被 <500ms 突发处理，触发双击退出。修复的是测试协议，
不是产品：

- `tests/e2e/lib/pty_protocol.py`：新增 `mark_input()` 与
  `drain_after_input(quiet, timeout, no_output_hold)`——输入批处理屏障：
  仅当 mark 之后出现输出并满足 quiet（或对真正的 no-op 批——如单行
  editor 上的 PageDown 帧为 STRATEGY_NONE 无输出——在 hold 窗口后且确认
  子进程存活）才放行；子进程在 hold 内退出即判失败，不被吞掉。
- `tests/e2e/slash-menu.sh`：每个 milestone 的 checkpoint 移到按键前
  （barrier 排空的输出仍属本 milestone 的 raw slice），按键后调用
  barrier；`--barrier-quiet`（默认 0.6s）与 `--barrier-hold`（默认 0.5s）
  可配置。Ctrl+C 携带的 milestone 在协议中必然改变画面 → 走输出路径，
  合并窗口被关闭；no-op milestone 走 hold。
- 纯 Python 回归（pty_env_isolation_test.py，8 项全过）：延迟输出不被
  pre-input quiet 提前放行；stale pre-mark 输出不能即时放行；no-op hold
  仅对存活子进程放行；子进程在 hold 内退出必须报错。
- 串行验证：batch1 与 batch1-max3 各 3 轮 PASS（exit 0）；batch1-max20
  3 轮 runner exit 1 = 冻结的 strict UX FAIL verdict，**三个子进程
  exit_code 均为 0、零 child died / no post-input output 异常**（child
  exit 与 runner verdict 分列）。
- 结论：**B1-R5-01 不得写成产品已修复**。机制为 upstream-equivalent
  双击语义 + 测试协议时序修正；产品行为未改。后续若再复现 child 干净
  退出，ADOU_TUI_IO_DIAG 埋点（quit/restore 事件）可继续分类。

### 12.7 Batch 1 最终验收（2026-08-15）

主代理在接管剩余工作后重新审计并关闭 B1-R4-01 至 B1-R4-12。最终补齐的
关键缺口是 B1-R4-10：RPC 不再从磁盘临时拼接一套与运行 session 分离的
commands/resources，而是让 init、session switch/rebind 发布同一个
trust-aware resource snapshot。`get_commands`、system prompt、`prompt`、
`steer`、`follow_up` 均从该 snapshot 读取或展开；未 refresh/switch 时，
磁盘上的 prompt/skill 新增或修改不会单独改变 wire commands 或实际执行，
session switch 时 resources、context 与 trust-aware preferences 在同一 runner
锁内一起发布。CLI 已显式覆盖的运行选项在初始发布时不被 settings 反向覆盖。

验收覆盖不只检查纯 JSON：`resource_snapshot_test.n` 验证 prompt/skill
展开、磁盘漂移隔离、refresh 生效和 untrusted 排除；
`agent_session_test.n` 验证真实 `prompt_rpc` 展开及 resources/context/preferences
原子发布；`rpc-queue-update.sh` 验证 provider 收到展开后的 prompt，且排队中的
steer/follow-up 使用同一 snapshot；`rpc-new-session.sh` 验证受信项目 prompt
只在切换到目标 session 后同时出现在 commands 与偏好中。e2e 的 HOME 均隔离，
不再把开发机真实 `~/.agents/skills` 混入证据。

最终串行验证结果：

- `make build` exit 0；完整 `make e2e` exit 0。
- 资源、session、autocomplete、slash、prompt、skills、config、editor、path、
  renderer、settings、auth、registry、git source、term 等受影响 Nature 单文件
  测试全部通过；遵守仓库门禁，未运行约两小时的完整 `make test`。
- `slash-menu.sh --self-test` 与 `max-visible-parity.py --self-test` 均 exit 0；
  PTY environment/barrier 的 8 个 Python 回归用例全部通过。
- Adou batch1 max=3/5/20 均重新生成三轮证据。max=3、max=5 三轮 strict UX
  PASS；max=20 三个 child 均 exit 0，runner exit 1 仅表示冻结的 strict UX
  FAIL。聚合比较器 exit 0，三档 parity 均 PASS。

B1-R5-01 最终分类保持 §12.6 的裁决：它是 Pi/Adou 一致的双 Ctrl+C 退出语义
被旧 PTY 时序误触发，修正的是 e2e 输入屏障，不宣称产品 bug 已修复。Batch 1
据此验收关闭；下一项工作从 Batch 2 的 model selector/scoped models 独立状态机开始。

### 12.8 Batch 2 最终验收（2026-08-15）

Batch 2 已关闭 model selector 与 scoped models 的状态所有权缺口。
`src/tui/model_selector.n` 维护 all/scoped 精确列表、查询过滤、当前项和选择索引；
scope 切换保留配置顺序，当前模型在 all 列表中优先，带初始 query 的
`/model` 仍从 scoped 列表开始。`src/tui/scoped_models.n` 明确区分
all-enabled/null、explicit ordered list（包括空列表）与 dirty；支持 toggle/all/clear/
provider/reorder，不可用或未知 model ID 不会被丢弃。

session view 只在 `Ctrl+S` 时把 scoped 变更写回 settings；`Escape` 关闭 UI
但保留本 session 的变更，不污染磁盘。显式空列表会写成 `enabledModels: []`，
重启后仍为 clear-all；切回 all-enabled 并保存时移除该 key。Catalog refresh
已移出输入线程，以 generation 标记丢弃已关闭或过期的结果；本地 8 秒
延迟 catalog fixture 还在等待响应时，缓存 selector 仍可导航和退出。

最终串行验证结果：

- `make build` exit 0；使用可持续读取的 PTY 终端会话完整运行 `make e2e`，
  保留尾部输出并确认最终 exit 0。
- `model_selector_test.n` 4/4、`scoped_models_test.n` 4/4、`settings_test.n`
  7/7、`config_context_test.n` 25/25、`model_search_test.n` 2/2 与
  `models_test.n` 8/8 通过；model/scoped 新 PTY 用例及 model-selection/project-config
  相关 e2e 通过。
- `slash-menu.sh --self-test` 与 `max-visible-parity.py --self-test` 均 exit 0。
  Batch 1 的 max=3/5/20 证据已按 Batch 2 源码重新生成，三档 Adou
  source fingerprint 统一为
  `62804516732fd30f712d36fc03200bbbe829f75e721441481ccc2ef23bfca446`。
  max=3 与 max=5 的 runner 均 exit 0；max=20 的三个 child 均 exit 0，
  runner exit 1 仅代表冻结的 strict UX FAIL。比较器 exit 0，结论为
  max=3/5/20 parity 全部 PASS，strict UX 分别为 PASS/PASS/FAIL。
- 遵守仓库门禁，未运行约两小时的完整 `make test`；本轮未触发
  429/503 或其他外部 catalog API 错误，验收全部使用本地确定性 fixture。

Batch 2 据此验收关闭；下一项工作从 Batch 3 的 Settings 全量契约开始。

## 13. Batch 3 记录（Settings 全量契约，2026-08-16 开工）

### 13.1 源码映射与失败 baseline（实施前）

Pi 0.82.1 权威源（vendors/pi，commit cced6a21）：

- `packages/coding-agent/src/core/settings-manager.ts`（Settings 接口、deepMergeSettings、
  migrateSettings、persistScopedSettings、全部 getter/setter、env fallback）
- `packages/coding-agent/src/modes/interactive/components/settings-selector.ts`
  （settings list 30 个 item、WarningSettingsSubmenu、SelectSubmenu、ThemeSubmenu
  preview/cancel/apply、HTTP_IDLE_TIMEOUT_CHOICES、DEFAULT_PROJECT_TRUST_LABELS）
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts`
  （showSettingsSelector：SettingsConfig 组装与每个 callback 的 runtime effect）
- `packages/coding-agent/src/core/http-dispatcher.ts`
  （DEFAULT_HTTP_IDLE_TIMEOUT_MS=300000，choices 30s/1m/2m/5m/disabled）

Adou 现状源：

- `src/config/settings.n`：settings_t 13 个字段（defaultProvider/Model、thinking、
  autoCompaction、steering/followUp、hideThinkingBlock、retry 扁平三键、
  compaction 两子键、enabledModels、theme、enabledSkills/Prompts、
  autocompleteMaxVisible）；load_for/load_trusted_for/save 已具备
  global+project 合并与 unknown-key 保留。
- `src/tui/session_view.n`：OVERLAY_SETTINGS 固定 7 行列表（Thinking/Auto-compaction/
  Steering/Follow-up/Hide thinking/Auto-retry/Theme），enter 直接翻转或进 thinking 子菜单，
  无 preview/cancel/apply。
- `src/config/resolve.n:219-229`：preferences 注入 runtime config 的唯一组装点。
- `src/config/trust.n resolve_trust`：无默认信任回退参数，无决策时恒 true。
- `src/tui/session_view.n:515-527`：ESC ESC 固定打开 tree overlay。
- `src/tui/session_view.n:3195`：tree_filter 在 overlay 内 0..4 循环，无 settings 种子。
- `src/context/slash_commands.n:84`：compose_resource_commands 无条件注册
  /skill:name 命令。
- `src/ai/types.n` stream_options_t.transport（仅 Codex 用）、timeout_ms=120000；
  `src/ai/providers/*` 经 http.client 的 `.timeout(state.options.timeout_ms)`。
- `src/tui/theme.n`：仅 light/dark 单值变体；`src/tui/chat.n render_padded_text`
  固定 1 空格 output padding；`src/tui/editor.n` 无 paddingX；
  `src/tui/renderer.n` 无 clearOnShrink；`native/term.c`/`src/tui/term.n` 无
  cursor 显隐与 OSC 9;4。

字段级 gap 表（Pi 设置键 → Adou 动作）：

| Pi 键（默认值/规则） | Pi scope | Adou 现状 | Batch 3 动作 |
|---|---|---|---|
| defaultProvider/defaultModel/defaultThinkingLevel | g+p | 已有 | 保持 |
| transport（auto；sse/websocket/websocket-cached/auto） | g+p | 无 | 新增；UI 四选；resolve.n 注入 stream_options.transport |
| httpIdleTimeoutMs（300000；30s/1m/2m/5m/disabled；"disabled"/数字解析） | g+p | 无 | 新增；作为 --timeout 未显式给出时的默认值；0=禁用 |
| steeringMode/followUpMode（one-at-a-time） | g+p | 已有 | 保持 |
| theme（dark/light/自定义/"light/dark" 自动对） | g+p | 仅 light/dark 单值 | 扩展存储形状接受 "a/b"；UI 子菜单 Automatic+preview/apply |
| compaction.enabled/reserveTokens/keepRecentTokens | g+p | enabled 以扁平 autoCompaction 落盘，子键已嵌套 | autoCompaction 磁盘形状迁移为 compaction.enabled |
| retry.{enabled,maxRetries,baseDelayMs,provider}（3/2000） | g+p | 扁平 retryEnabled/retryMaxAttempts/retryBaseDelayMs | 磁盘形状迁移为嵌套 retry；不进 UI |
| hideThinkingBlock | g+p | 已有 | 保持 |
| showCacheMissNotices（false） | g+p | 无 | 新增；gate cache miss 提示 |
| collapseChangelog（false） | g+p | 无 | 新增；Adou 无 changelog 横幅，runtime NOP 记录 |
| quietStartup（false；隐藏 version header/context info/scope line） | g+p | 无 | 新增；gate 启动状态行 |
| enableInstallTelemetry（true） | g+p | 无 | 新增；Adou 无 update ping，runtime NOP 记录 |
| defaultProjectTrust（ask/always/never；仅 global） | g | 无 | 新增；resolve_trust 回退参数 |
| enableSkillCommands（true） | g+p | 无 | 新增；gate compose_resource_commands 的 /skill:name |
| doubleEscapeAction（tree；tree/fork/none） | g+p | 无（ESC ESC 固定 tree） | 新增；分支到 tree/fork/none |
| treeFilterMode（default；5 档） | g+p | 无（overlay 内循环） | 新增；/tree 打开时种子 overlay.tree_filter |
| showHardwareCursor（false；PI_HARDWARE_CURSOR env） | g+p | 无 | 新增；term cursor 显隐 |
| editorPaddingX（0；0-3 clamp） | g+p | 无 | 新增；editor 左侧 padding |
| outputPad（1；0/1） | g+p | 无（固定 1 空格） | 新增；chat 输出 padding |
| autocompleteMaxVisible（5；3-20 clamp；UI 值 3/5/7/10/15/20） | g+p | load/clamp 已有，UI 无 | UI 六选接入 |
| terminal.clearOnShrink（false；PI_CLEAR_ON_SHRINK env） | g+p | 无 | 新增；renderer 收缩清理 |
| terminal.showTerminalProgress（false） | g+p | 无 | 新增；OSC 9;4 |
| warnings.anthropicExtraUsage（true） | g+p | 无 | 新增；子菜单；Adou 无 Anthropic 订阅鉴权路径，runtime NOP 记录 |
| terminal.showImages/imageWidthCells、images.autoResize/blockImages | g+p | 无 | OPEN：当前 UI 只显示 unavailable，不伪实现；完整落盘与运行时 effect 待补 |

失败 baseline（Batch 3 开工时的事实）：

1. /settings 仅 7 行，Pi 为 26 个可见 item（含当前尚未接线的 4 项图像设置）；
2. 无任何 submenu 组件（除 thinking 7 选）、无 theme preview/cancel/apply；
3. retry 落盘形状与 Pi 不同（扁平 vs 嵌套 retry 对象）；
4. autoCompaction 落盘形状与 Pi 不同（顶层 vs compaction.enabled）；
5. 15 个 Pi 设置键在 Adou 无法 load/save，全部新键 default/load/save/project
   override 五类断言缺失；
6. transport/httpIdleTimeoutMs/showHardwareCursor/editorPaddingX/outputPad/
   clearOnShrink/terminalProgress/doubleEscapeAction/treeFilterMode/
   enableSkillCommands/quietStartup/defaultProjectTrust 无 runtime effect；
7. theme 无法表达 Pi 的 "light/dark" 自动模式值（load 时被丢弃）。

### 13.2 实施记录

- `src/config/settings.n`：settings_t 全量扩展（transport/httpIdleTimeoutMs/
  showCacheMissNotices/collapseChangelog/quietStartup/enableInstallTelemetry/
  defaultProjectTrust/enableSkillCommands/doubleEscapeAction/treeFilterMode/
  showHardwareCursor/editorPaddingX/outputPad/terminal.clearOnShrink/
  terminal.showTerminalProgress/warnings.anthropicExtraUsage）；磁盘形状迁移
  （autoCompaction→compaction.enabled、retry 扁平键→retry.{enabled,maxRetries,
  baseDelayMs}，旧键读取兼容并在保存时删除）；Pi env fallback
  （PI_CLEAR_ON_SHRINK/PI_HARDWARE_CURSOR）；defaultProjectTrust 仅 global
  （项目文件不可覆盖）；theme 接受 "light/dark" 自动对；逐项 clamp 对齐 Pi
  （padding 0-3、outputPad 0|1、autocomplete 3-20、httpIdleTimeoutMs
  "disabled"/数字解析）。
- `src/config/trust.n`：resolve_trust 增加 default_project_trust 回退参数
  （always/never 生效；ask 保持现状，交互式信任提示为 Batch 5 范围）。
- `src/config/resolve.n` + `src/config/types.n`：preferences 注入 runtime
  config（transport→stream_options.transport；httpIdleTimeoutMs 作为
  --timeout-ms 未显式给出时的默认请求超时，0 流经 std 客户端无超时值）；
  新 config_t/skills_options_t 字段。
- `src/context/slash_commands.n` + `src/context/resource_snapshot.n`：
  compose_resource_commands 增加 enable_skill_commands 门控。
- `src/agent/session.n`：apply_preferences_snapshot/publish_rpc_resources
  应用 transport 与 timeout；新增带锁 runtime setter。
- `src/tui/chat.n`：outputPad 贯穿 user/assistant/thinking 渲染
  （pad_sides 0|1）；cache-miss 通知（EVENT_MESSAGE_END 检测、Pi 阈值
  missedTokens>=20000 或 missedCost>=0.1、模型切换/空闲标签、warning 色）。
- `src/tui/renderer.n`：clearOnShrink 默认 off（Pi 默认）；开启时才清理
  收缩行。
- `src/tui/term.n`：set_hardware_cursor（?25h/l）与 OSC 9;4 set_progress。
- `src/tui/session_view.n`：Settings UI 重写为 Pi 顺序 27 行（Enter 循环
  value 行、unavailable 图像四行、Warnings/Thinking/Theme 子菜单）；Theme
  子菜单 single/automatic 双模式 + live preview/apply/cancel（Esc 恢复
  原值）；ESC ESC 按 doubleEscapeAction 分支 tree/fork/none；/tree 打开
  时以 treeFilterMode 种子 overlay.tree_filter；raw 进入时按
  showHardwareCursor 决定隐藏光标；stream 起止按 terminalProgress 发
  OSC 9;4；render_editor 应用 editorPaddingX；quietStartup 门控启动状态
  行；save_preferences 改为从 trust-aware snapshot 全量持久化。
- 测试：settings_test 12/12（新增 B3 默认值/嵌套形状加载/保存形状/
  项目合并+global-only trust/重开五类断言）；config_resolve_test 7/7
  （transport/timeout/trust runtime effect）；trust_test 8/8（回退矩阵）；
  chat_test 13/13（outputPad/cache-miss）；renderer_test 14/14（默认 off
  + 开启清理）；agent_session_test 33/33（snapshot transport/timeout）；
  slash_commands_test 7/7（门控签名）。e2e：tui-settings.sh（Pi 顺序、
  unavailable 行、transport 循环、thinking 子菜单、settings.json 持久化）
  与 tui-config.sh（theme 子菜单应用 + 重启恢复）通过。

### 13.3 验收记录

本地确定性验收（2026-08-16）：

- `make build` 干净重建 exit 0；`git diff --check` 干净；凭据扫描仅命中
  fixture 假 key。
- 串行针对性单测：settings_test 12/12、config_resolve_test 7/7、
  trust_test 8/8、chat_test 13/13、renderer_test 14/14、
  agent_session_test 33/33、slash_commands_test 7/7、
  settings_persistence_test 1/1、config_context_test 25/25、
  skills_test 22/22、editor_test 25/25、model_selector_test 4/4、
  scoped_models_test 4/4、term_test 9/9。
- e2e：tui-settings.sh 与 tui-config.sh 均 exit 0。
- Pi oracle 同键对照：`tests/e2e/lib/pi-oracle/settings-parity.py`（本地 PTY
  版，--self-test 通过）与 `herdr-settings-parity.py`（Herdr 真实终端版）
  已实现。本地 PTY 版被环境阻塞：vendored Pi 0.82.1 TUI 在本地 PTY 下
  渲染首帧后丢弃全部输入（含 Batch 1 的 slash-open 按键流；历史证据
  同样无法本地复跑）。经用户启用 Herdr 后，在真实终端 pane 中确认 Pi
  0.82.1 输入完全正常（/settings 立即打开 27 项列表），本地阻塞确认为
  PTY 环境问题，与 Adou 无关。Herdr 版驱动按同一契约跑 3 轮，
  证据落盘 docs/pi-batch3-evidence/herdr-*/。
- Herdr 对照发现的真实 parity 偏差（均已修复）：(1) Pi 的主题子菜单
  预选中当前主题（SelectSubmenu setSelectedIndex），Adou 原先固定从
  Automatic 开始——show_theme_overlay 现按当前 single 主题预选
  （dark→index 1）；(2) Pi 设置行标签为 'Thinking level'，Adou 原为
  'Thinking:'——设置列表行已改为 'Thinking level:'（Pi oracle 3 轮
  labels 顺序对照暴露，e2e 同步更新）。
- Herdr 调试中排查的"屏幕冻结"结论（非 bug）：esc 关闭 selector 后屏幕
  仍显示旧行，是 Pi 默认 clearOnShrink=false 的既定行为（收缩时保留旧
  行，Pi 同款默认）；本地 46×50 PTY 复现，开启 terminal.clearOnShrink
  后旧行即被清除。输入侧全程正常（esc 后 /quit 正常退出、settings.json
  正确落盘）。据此 Herdr 驱动改用输入真相/文件真相断言，屏幕残留不再
  作为 FAIL 判据。
- B3-EXT-01（间歇性假成功删除，已修复）：早前两次运行
  repository_contract_test.n 第 1 例在 delete 后仍列出被删会话。根因在
  `src/session/backend.n delete_session_file`：spawn `/bin/sh trash` 抛错时
  `catch` 填入空 `command.result_t{}`，其 exit_code 默认 0，函数即返回
  `(true, 'Session moved to trash')` 而未真正删除，也不走 os.remove 回退。
  修复：spawn 失败按失败处理（exit_code 置 -1），且 trash 成功只以
  “exit 0 且文件确实消失”为准，否则一律落到 os.remove。回归测试：
  `tests/backend_list_session_paths_test.n` 新增两例（PATH 清空使 trash
  查找失败→回退 unlink 且文件确实消失；缺失文件视为已删除）。验证：
  repository_contract_test.n 连跑 3 次均 5/5。

- Herdr 真实终端同键对照（`herdr-settings-parity.py`，3 轮 × 2 侧）：
  **PASS，0 failures**。每轮双方 labels 顺序 23/23 一致（含 Thinking
  level）、transport auto→sse、theme 落盘 light、/quit 干净退出；泄漏
  检查通过。证据：docs/pi-batch3-evidence/herdr-*-round{1,2,3}.json +
  herdr-settings-parity-summary.json。本地 PTY 版 settings-parity.py
  因 vendored Pi 在本地 PTY 丢弃输入而无法执行（环境阻塞，与 Adou
  无关），Herdr 版为正式对照证据。

残余 FAIL：无。按协议不提交/推送半成品，等主代理裁决。

## 14. Batch 4 记录（Editor、Cursor 与 App Keybindings，2026-08-16 开工）

### 14.1 源码映射与失败 baseline（实施前）

Pi 0.82.1 权威源：

- `packages/tui/src/keybindings.ts`：KeybindingsManager（definitions/defaultKeys/
  description、userBindings 覆盖、normalizeKeys 去重、冲突检测 = 多个 action
  认领同一 key、matches/getKeys/getConflicts/setUserBindings/getResolvedBindings、
  global setKeybindings/getKeybindings）；TUI_KEYBINDINGS 30 个
  tui.editor.*/tui.input.*/tui.select.* 定义。
- `packages/coding-agent/src/core/keybindings.ts`：KEYBINDINGS = TUI_KEYBINDINGS
  + 40 个 app.* action（defaultKeys + description）；KEYBINDING_NAME_MIGRATIONS
  （旧名→新名）、toKeybindingsConfig（string/数组）、migrateKeybindingsConfig、
  orderKeybindingsConfig；KeybindingsManager.create(agentDir) 从
  `keybindings.json` 加载；reload() 重读文件。
- `packages/coding-agent/src/modes/interactive/components/keybinding-hints.ts`：
  keyText/keyDisplayText/keyHint/rawKeyHint——hint 一律从 registry 的 resolved
  keys 格式化（darwin 下 alt 显示为 option）。
- `interactive-mode.ts`：`keybindings.matches(key, "app.*")` 驱动全部 app 分发；
  /reload → `keybindings.reload()`（冲突经 getConflicts 暴露）。

Adou 现状：

- `src/tui/keybindings.n`：仅 editor 级扁平 registry（key→action→description
  三元组，default_keybindings() 一次性缓存，无用户覆盖、无冲突检测、无
  resolved-keys 查询）。
- `src/tui/session_view.n`：app/overlay 分发 92 处硬编码 `key == '...'`：
  handle_idle_input（escape 双击 tree/fork、ctrl+c、ctrl+d、ctrl+z、ctrl+g、
  shift+tab、ctrl+p/shift+ctrl+p、ctrl+l、ctrl+o、ctrl+t、ctrl+x、alt+enter）、
  handle_stream_input（escape/ctrl+c abort、ctrl+z、ctrl+o、ctrl+t、alt+up
  dequeue、alt+enter follow-up）、handle_overlay_input（tree：f/[ ]/shift+l；
  session：tab/ctrl+p/ctrl+s/ctrl+n/ctrl+r/ctrl+d/ctrl+backspace/pgup/pgdn；
  scoped models：ctrl+a/ctrl+x/ctrl+p/alt+↑↓/ctrl+s；settings/theme 子菜单
  up/down/enter/escape；通用 overlay up/down/enter/escape/backspace）。
- `/hotkeys`（show_hotkeys_overlay）为 20 行硬编码列表；footer
  （chat.render_footer）只有 cwd/tokens/model，无任何 key hints；overlay
  help 行（render_overlay 尾部）为硬编码字符串。
- `/reload`（run_command）：只刷 resource snapshot/context/system prompt，
  不重载 keybindings、不报告冲突。
- `keybindings.json`：不存在任何加载路径。

app action ↔ Adou 映射（Pi 40 个 action）：

| Pi action（默认键） | Adou 现状 |
|---|---|
| app.interrupt（escape） | handle_idle_input 双击树逻辑 + handle_stream_input abort 硬编码 |
| app.clear（ctrl+c） | handle_idle_input 双击退出硬编码 |
| app.exit（ctrl+d） | 硬编码 |
| app.suspend（ctrl+z） | 硬编码（两处） |
| app.thinking.cycle（shift+tab） | 硬编码 |
| app.model.cycleForward/Backward（ctrl+p / shift+ctrl+p） | 硬编码 |
| app.model.select（ctrl+l） | 硬编码 |
| app.tools.expand（ctrl+o） | 硬编码（两处） |
| app.thinking.toggle（ctrl+t） | 硬编码（两处） |
| app.session.toggleNamedFilter（ctrl+n） | session overlay 硬编码 |
| app.editor.external（ctrl+g） | 硬编码 |
| app.message.copy（ctrl+x） | 硬编码 |
| app.message.followUp（alt+enter） | 硬编码（idle+stream 两处语义不同：idle 直接发、stream 入队） |
| app.message.dequeue（alt+up） | 硬编码 |
| app.clipboard.pasteImage（ctrl+v darwin） | OPEN（当前 UI 无此项，待接入图片 parity 批次） |
| app.session.new/tree/fork/resume | 无键（slash commands 已覆盖） |
| app.tree.foldOrUp（alt+left）、unfoldOrDown（alt+right）、editLabel（shift+l）、toggleLabelTimestamp（shift+t） | tree overlay 硬编码 f/[/]/L，shift+t 缺失 |
| app.session.togglePath（ctrl+p）、toggleSort（ctrl+s）、rename（ctrl+r）、delete（ctrl+d）、deleteNoninvasive（ctrl+backspace） | session overlay 硬编码 |
| app.models.save（ctrl+s）、enableAll（ctrl+a）、clearAll（ctrl+x）、toggleProvider（ctrl+p）、reorderUp/Down（alt+↑/↓） | scoped-models overlay 硬编码 |
| app.tree.filter.{default,noTools,userOnly,labeledOnly,all,cycleForward,cycleBackward} | tree overlay `f` 单键循环 5 档，无单项直接键 |
| tui.editor.*（30 个） | editor.n registry 已有（键名与 Pi 基本一致，但无用户覆盖/冲突） |
| tui.select.up/down/pageUp/pageDown/confirm/cancel | 各 overlay 硬编码 |

失败 baseline（Batch 4 开工时事实）：

1. keybindings.json 用户映射不存在（写一个 app 键不生效）；
2. 无冲突检测；/reload 不重载 keybindings、不报告冲突；
3. /hotkeys、overlay help 行、实际 dispatch 三处各写各的（改 dispatch 不改
   hint 的漂移风险真实存在）；
4. tree filter 只有单键循环，Pi 有 5 个单项键 + 前后循环共 7 个 action；
5. footer 没有任何 key hints；
6. tree shift+t（label timestamp）、scoped-models ctrl+backspace 等个别键
   缺失或键名不同；
7. showHardwareCursor 已由 Batch 3 落地，但 IP-003 的焦点态逐帧对照证据
   尚未产出。

### 14.2 实施记录

- `src/tui/keybindings.n` 全量重写为 Pi 契约：70 个 action 的
  definitions（defaultKeys + description，TUI 30 + app 40）、用户覆盖、
  去重、冲突检测（仅用户认领计为冲突，共享默认键如 ctrl+p/c 为上下文
  语义）、matches/get_keys/describe/get_conflicts/set_user_bindings/reload、
  `keybindings.json` 加载 + 旧名迁移表、format_key_text（alt→option）、
  进程级 current registry（Pi setKeybindings/getKeybindings）。
- `src/tui/editor.n`：ACTION_* 常量改为 Pi action id；handle_key/jump
  经 keybindings.current() 解析（删除本地静态缓存）。
- `src/tui/session_view.n`：view 持有 registry（init 时 create(agent_dir)
  + set_current）；handle_idle_input/handle_stream_input 全部 app 键改经
  matches() 分发；session/tree/scoped-models overlay 键改经 registry
  （tree filter 7 个 action、fold/unfold、shift+t label timestamp 键已
  注册待 UI 行为补齐、session 五个 action、scoped-models 六个 action）；
  /hotkeys 由 registry 生成（Navigation/Editing/Other 三组）；
  render_overlay 的 help 行按 overlay 类型从 registry 派生；启动 header
  hint 行 = Pi compact instructions（registry 派生、quietStartup 静默、
  按终端宽度折行——修复了窄终端 79>60 的宽度守卫崩溃）；/reload
  重载 keybindings.json 并以 'Keybinding conflicts: key -> actions'
  报告冲突。
- 修复：header 行未按宽度折行导致 24×60 终端首帧 'rendered line
  exceeds terminal width: 79 > 60' 崩溃（tui-bash-output.sh 暴露）。
- 测试：keybindings_test 7 例全量重写（默认解析/共享键上下文语义/
  覆盖/冲突/迁移/重载/格式化）；editor_test 2 处常量断言更新；
  tui-keybindings.sh 新增验收 e2e（重映射后 ctrl+p 失效 + shift+ctrl+m
  生效 + /hotkeys 显示新键 + /reload 冲突报告，三个断言同时成立）；
  slash-menu.sh 的 chat 区断言过滤 registry header 行、fixture
  settings.json 增 terminal.clearOnShrink=true（严格跑者的精确屏幕
  断言需要无残留行）；rpc-settings.sh 的 retry 断言更新为嵌套形状
  （Batch 3 落下的既有脚本）；新增
  tests/e2e/lib/pi-oracle/herdr-keybindings-parity.py（Herdr 同键驱动）。

### 14.3 验收记录

- 单测：keybindings 7/7、editor 25/25、settings 12/12、resolve 7/7、
  trust 8/8、chat 13/13、renderer 14/14、agent_session 33/33、slash 7/7、
  config_context 25/25、skills 22/22、models 8/8、model_selector 4/4、
  scoped_models 4/4、term 9/9、path_completion 11/11、autocomplete 20/20。
- e2e：tui-keybindings（新增验收契约）、tui-settings、tui-config、
  tui-tree-fork、tui-session-selector、tui-model-selector、
  tui-scoped-models、tui-bash-output、tui-unicode-input、slash-menu（3 轮
  PASS）、rpc-settings 全部通过。
- Herdr 同键对照（`herdr-keybindings-parity.py`，3 轮 × 2 侧）：验收
  契约 = ① 双方启动 header hint（interrupt/clear/exit//commands/!bash）
  存在；② 输入矩阵 'hello 你好 😀' 双方编辑器渲染；③ 共享
  keybindings.json（Pi 格式 app.model.cycleForward→shift+ctrl+m）后
  双方 /hotkeys 的 cycle 行显示新键且不再含裸 ctrl+p；④ 光标证据
  （IP-003）：双方编辑帧恰一个反显光标格（Pi/Adou 均 7m...0m 归一），
  无常驻白块；⑤ /quit 干净退出。（结果见
  docs/pi-batch3-evidence/herdr-keybindings-parity-summary.json。）
- shift+t（APP_TREE_TOGGLE_LABEL_TIMESTAMP）已补齐 UI 行为：tree 行
  以相对时间（'2m ago'）后缀渲染，开关保持选中/折叠/过滤状态，help
  行含该键。
- 残留：IP-003 的真·焦点切换（focus in/out）逐帧对照依赖 Herdr 焦点
  控制，本轮证据为同终端同主题聚焦帧的单光标格对照（双方均恰一个
  反显光标格，无常驻白块），真实焦点切换留待用户交互验收。

残余 FAIL：无。HerDr 3 轮同键对照 PASS（0 failures），见
docs/pi-batch3-evidence/herdr-keybindings-parity-summary.json。

## 15. Batch 5 记录（其余 Interactive 组件，2026-08-17）

### 15.1 实施记录

- Config：`/config` 现在提供全局/项目 scope、来源标记、可搜索的
  header/item 列表、j/k 与方向键、PageUp/PageDown、Space/Enter toggle、
  Tab scope 切换，以及 Esc 先清 query、再关闭的生命周期。显式空
  `enabledSkills`/`enabledPrompts` 会保留为“全部禁用”，资源仍留在列表中
  可重新启用；项目写入 `.pi/settings.json`，全局写入用户 settings。
- Auth API-key：provider 选择来自运行时 registry，带名称和搜索；logout
  只显示已保存的 API-key provider，并在无凭据时给出状态。空 key 提交会
  留在 overlay 展示错误，Esc 后可重新打开；OAuth 流程本批未实现，现作为
  全量 parity 的开放工作继续实施。
- Trust：`/trust` 无参数进入选择器，显示当前 cwd、最近保存决策来源、
  Trust/Trust parent/Do not trust 与 session-only 选项；j/k、方向键、Enter
  保存、Esc 取消均可用。持久化选择走 `set_many`，session-only 只存在于
  当前 view，切换项目时清除，并在保存后立即刷新 trust-aware 资源快照。
- Session：resume selector 补齐 current-folder/all scope、recent/relevance/
  threaded sort、named/path toggle、rename、delete confirmation、分页、
  empty state 和 query-first Esc recovery；排序状态与显示 header 使用同一
  三态模型。
- Tree/Fork：过滤五档与前后 cycle、折叠/展开、label、相对 timestamp、
  OSC-52 copy、分页和 branch summary 生命周期已接通；折叠保留父行并
  按祖先隐藏后代。overlay 关闭/取消后恢复编辑器文本、光标、autocomplete
  与 footer 状态，不重启进程。

### 15.2 验收记录

- `make build` 串行成功；未运行耗时且不必要的完整 `make test`。
- 定向 Nature 测试：settings_persistence 2/2、settings 12/12、
  slash_commands 7/7、resource_snapshot 2/2、trust 8/8、
  session_search 7/7、registry_runtime 8/8、session_actions 2/2，
  共 48/48 通过。
- PTY e2e：tui-config、tui-auth-overlay、tui-session-selector、
  tui-tree-fork、tui-setup 全部 exit 0；覆盖 direct slash entry、overlay
  key actions、取消恢复和干净 terminal restore。
- `git diff --check` 干净；本批没有 vendors 改动，也没有提交凭据。

本批已定义范围内残余 FAIL：无。OAuth 仍未在本批实现，但现归入开放 parity
工作；项目资源 scope 使用 Adou 现有 named allow-list 模型，Pi package manager
中属于 extension 的部分保持排除，其他可观察差异继续审计。

## 16. Batch 6 记录（Streaming、Resize 与稳定性组合回归，2026-08-17）

### 16.1 实施记录

- `assistant_stream.result()` 的测试 fixture 现在在终端事件后显式执行
  `stream.end()`，与 provider teardown 生命周期一致，避免测试等待永久挂起。
- 编辑器在高频多行输入下对过期 byte cursor 做边界归一；可视光标宽度、
  autocomplete 查询和路径菜单锚点在读取编辑器快照时也限制在当前行长度内。
  ICU grapheme 边界进入 `string.slice` 前统一校验，非法 native offset 不再使
  TUI 直接 panic。
- 新增 `tests/e2e/tui-stream-resize.sh`：本地 SSE provider 交错输出 tool/final
  事件，PTY 连续 resize、Ctrl+O 展开、`/settings` overlay、Esc 取消和 `/quit`
  全链路验证 UTF-8、同步输出边界、终端恢复与请求数量。
- `tui-editor-wrapping.sh` 改为等待本次输入产生的新帧，并处理 PTY close 的
  EIO；`tui-config.sh` 与 `tui-session-selector.sh` 增加 overlay close 输入屏障，
  消除脚本自身的时序抢跑。

### 16.2 验收记录

- `make build` 串行成功。
- 定向 Nature 测试：agent_loop 17/17、agent_session 33/33、compaction
  15/15、retained-tail 1/1、provider-retry 5/5、event-stream 5/5、
  tui-redraw 3/3、term 9/9、shell-capture 3/3、debug 2/2、editor 26/26、
  tui-unicode 3/3、tui-text-utils 5/5，合计 127 个用例通过。
- `rpc-queue-update.sh` 单项压力重复 30/30 通过；其余 Batch 6 相关 RPC、
  redraw、latency、job-control 与本地 coding journey 均通过。
- 完整 `make e2e` exit 0，串行执行当前 57 个离线 e2e 脚本；包含新增
  `tui-stream-resize.sh`，以及 3 轮 slash-menu 语义/屏幕一致性验证。
- 按项目约束未运行耗时的完整 `make test`，未修改 `vendors/`，未提交任何凭据。

残余 FAIL：无。下一批为 Batch 7（安装产物、真实 provider smoke 与 Herdr 长会话
组合验收）；OAuth、扩展运行时和完整 `make test` 仍按计划范围处理。

## 17. Batch 7 中间记录（安装、真机 provider 与日志诊断，2026-08-18）

### 17.1 日志模块补强

- `--debug`/`ADOU_DEBUG=1` 在未显式设置 `ADOU_DEBUG_FILE` 时，默认把文件日志
  写入当前 Adou agent 目录的 `adou-debug.log`；显式目标仍优先，TUI stderr
  保持干净，headless/RPC stderr 契约不变。
- `[adou debug] component:` 原前缀保持不变，每行追加 `ts` 与 `pid`。启动、
  config resolve、模型缓存/远程 catalog（跳过、尝试、成功、失败、耗时）、
  session、资源快照、runner、slash command、`/model` 候选计数和 stream cancel
  都有阶段日志，且不记录 API key、请求 URL、请求正文或完整 prompt。
- `tests/debug_test.n` 3/3、`tests/e2e/debug-isolation.sh`、
  `tests/e2e/rpc-debug-stderr.sh` 均通过。真实 `adou-test` 使用显式 debug
  文件观察到 `/model` 的 `begin -> candidates -> ready` 链路约 18ms（端到端
  pane 测量约 134ms），provider 往返和 `ctrl+c` 取消均能在日志中闭合到
  `session_end`。

### 17.2 安装与真实 pane

- `DESTDIR` 安装检查、`make pkg-check` 通过；sudo 安装后
  `/usr/local/bin/adou` 与 `build/bin/adou` SHA-256 均为
  `ceebb911ad4346257797dcb26abadf4d5ab3f32c7a61117504166ce6d361cc21`，
  `--version` exit 0。
- Herdr `adou-test`（`w7:pE`）重启后真实 DeepSeek 往返、跨轮记忆、项目
  skill 命中、只读 `pwd` 工具、长输出完成与后续对话均通过；`/settings`、
  `/hotkeys`、`/help`、`/session`、`/reload` 和 `/model` 均可操作。
- Herdr `pi-test`（`w7:pD`）此前已退出到 shell，本轮重新启动 Pi 0.81.0
  后，用相同的无副作用提示完成精确回复、跨轮记忆与只读工具对照；Pi 的
  model selector 也能打开。
- 2026-08-18 Stage 0 刷新后，`w7:pD` 已改用仓库
  `vendors/pi/pi-test.sh` 启动 Pi 0.82.1；live DeepSeek 无工具提示精确返回
  `PI_B7_STAGE2_OK`。`w7:pE` 的当前构建（SHA-256
  `2ce02803da1d064ad8ef0c2fb4d4cd16017c6f4979a91cd921b00e0d715c41c4`）
  对等返回 `ADOU_B7_STAGE2_OK`。这关闭低次数 provider smoke，不代替长会话
  或连续三轮全矩阵验收；`/usr/local/bin/adou` 仍是旧 hash，不作为当前构建证据。

### 17.3 未关闭的真机风险

- 旧的 `adou-test` 进程在一次 `/model` 操作前出现
  `runtime: out of memory: page allocation failed` 并退出；使用隔离的新
  session、持久 session 和显式 debug 日志重启后未复现，不能据此宣称已修复。
  暂记为 RM-TUI-005，后续必须在 debug 文件和进程内存采样可用的环境下重复
  验证。此次 pane 后续把 `/model` 延迟和 provider/cancel 链路记录完整。
- 一次过早发送的 Ctrl+C 显示 `Request aborted` 后仍继续长输出；在 provider
  已进入活动流的复现实验中，第二次测试正常记录 `stream cancel requested`
  及 `Request aborted -> session_end`。取消时序仍需下一轮针对性压力验证。

本中间记录不改变 Batch 7 的最终验收状态；未运行完整 `make test`，未修改
`vendors/`，尚未提交或推送。

## 18. 当前 worktree 复验记录（2026-08-18）

### 18.1 模型候选与内存热点加固

- `/model`、`/scoped-models` 和 `/model` 参数补全现在共享 view 生命周期内的
  provider 认证快照。认证结果只在初始化、`/reload`、`/login`、`/logout` 或
  scope 变化时刷新；普通输入不再对每个模型重复调用 `auth.effective()`。
- 该修复对应 B1-R1-09 的实际遗漏：此前代码只缓存 provider 数量，候选扫描仍
  逐模型重新解析认证状态。修改位于 `src/tui/session_view.n`，不改变候选顺序或
  scope 语义。
- `tests/model_selector_test.n` 4/4、`tests/autocomplete_test.n` 20/20、
  `tests/settings_test.n` 12/12、`tests/settings_persistence_test.n` 2/2、
  `tests/agent_session_test.n` 33/33、`tests/chat_test.n` 16/16、
  `tests/debug_test.n` 3/3 通过；完整 `make build` 通过。

### 18.2 取消、离线回归与发布门禁

- `rpc-abort.sh`、`rpc-abort-retry.sh`、`rpc-abort-bash.sh`、
  `rpc-compaction-abort.sh`、`tui-stream-resize.sh` 和新增的
  `tui-stream-cancel.sh` 均通过；取消链路在离线 fixture 中能按
  `cancel requested → agent_settled → session_end` 收束，并丢弃取消之后迟到的
  provider 增量。
- 当前完整 `make e2e` 串行 58/58 通过；`make eval` 3/3 通过。
- `make pkg-check`、`make signing-check`、`make release-check` 全部通过，产出
  `build/dist/adou-0.1.0-dev-darwin-arm64.tar.gz`、校验文件和 unsigned `.pkg`。
- `tests/e2e/rpc-over-ipc.sh` 将输入的二进制路径先做 `realpath`，修复
  `make release-check` 传相对路径时 macOS `ps` 显示绝对路径、导致子进程被误报为
  0 个的验收脚本缺陷。

### 18.3 尚未关闭的真机事项

- RM-TUI-005 已在 Herdr 真实 TUI 中带逐秒进程内存采样复现：旧安装版
  `/usr/local/bin/adou`（SHA-256 前缀 `ceebb911`）前 10 轮 `/model` 操作完成，
  第 11 轮以 `runtime: out of memory: page allocation failed` 退出。118 个样本
  中 RSS 从 3,440 KiB 增至 74,576 KiB；原始数据保存在
  `/tmp/rm-tui-005-memory-20260818.log`。
- 同一 pane、session 和操作协议下，当前 `build/bin/adou`（SHA-256 前缀
  `505856`）完成 100 轮后仍存活。141 个样本的 RSS 峰值为 41,168 KiB，
  末值为 7,056 KiB；原始数据与 debug 日志分别保存在
  `/tmp/rm-tui-005-memory-built-20260818.log` 和
  `/tmp/adou-built-rm-tui-005.log`。
- `tests/nature_repros/rm_tui_registry.n` 将热点缩到无 TUI 的 Nature 入口：
  每轮 1,200 次 `registry.find_def` 会反复构造全部 provider definitions，能
  产生大幅瞬时分配压力。纯短生命周期 vector + GC/scheduler 对照保持平稳。
  该最小用例尚未独立触发 allocator abort，因此当前裁决是 Adou 旧热点已由
  provider 级认证缓存消除；Nature runtime 在高压下直接 abort 的次级问题需
  上游继续评估，不能写成已证实的编译器误编译。
- 取消实现现在在 `src/ai/event_stream.n` 对取消后的迟到增量和正常 DONE 做了
  原子化收口，离线 PTY 已覆盖“Ctrl+C 后 provider 继续发送”的竞态；真实
  DeepSeek 流仍需一轮针对性 Herdr 验证，才能关闭真机风险记录。
- 按项目约束仍未运行约两小时的完整 `make test`；没有修改 `vendors/`，本轮
  改动已形成当前 commit。
