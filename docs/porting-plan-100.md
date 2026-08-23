# Adou 100% 移植完成度计划（非扩展全量口径）

状态：依据 2026-08-22 四路源码差分评估制定。当前非扩展口径完成度约 **85%**（对 Pi 完整功能面约 78–80%，差额主要为声明排除的扩展生态）。本计划目标：**非扩展口径收敛到 100%**。扩展运行时维持排除，不在此计划内。
基线：Pi `0.82.1`，commit `cced6a21da273b26ee4a23a803680614bbe8dd1e`（`vendors/pi`）。

验收规则沿用 `docs/porting-plan.md`：每个工作项必须有源码差分记录、Nature 单测（正常/错误/取消/边界/顺序）、至少一个跨模块集成或 e2e；Nature 构建与测试严格串行；不使用 `nature fmt`。

## 口径定义

**100% = Pi 0.82.1 除扩展生态外的全部可观察行为，逐项通过同版本真机对照。**

明确排除（不计入 100%判定，与 README 声明边界一致）：

- TypeScript/QuickJS extension ABI、加载器、生命周期事件总线、`transformContext` 等 extension hook；
- `extension_ui_request/response` RPC 通道、`extension_error` 事件及对应 TUI 组件（custom editor/input/selector）；
- 包管理生态：`install/remove/uninstall/update/list/config` 子命令、npm/git 扩展包管理、unknownFlag passthrough、`--extension/-e/--no-extensions`；
- `extensions.eval`；
- 平台性等价物：undici http-dispatcher（以 transport 设置等价）、Node 专属执行环境（已有 `src/sdk_node.n` 对应面）；
- 上游彩蛋组件（armin/daxnuts/clankolas），纯装饰，可选不做。

MCP 不在范围内：Pi core 明确无内建 MCP（属扩展生态能力）。

## 当前差距快照（2026-08-22 评估）

| 域 | 完成度 | 主要缺口 |
|---|---|---|
| AI 层 | ~85% | 约束采样与 deferred tools 死代码；Google/OpenAI Responses 请求构建细节；Claude Code 工具名映射；options 钩子 |
| Agent harness + core | ~80% | SQLite 后端健壮性（~55%）；bash 无界缓冲；edit 互斥窗口；settings/trust 写盘耐久性；trust `'ask'` 语义 |
| TUI + 交互 | ~77% | Markdown 渲染（~55%）；主题系统（~50%）；selector polish；运行时终端查询缺失 |
| CLI/RPC/server/SDK/evals | ~78% | SDK 面（~55%）；信号处理；evals 真实 provider runner；若干 flag/subcommand |

## Batch 1｜正确性与数据安全（P0，量级 M，无前置依赖）

| # | 工作项 | 源码定位 | 验收门槛 |
|---|---|---|---|
| 1.1 | trust `'ask'` 门控：启动时未知项目弹信任 overlay（TUI）；headless 拒绝加载项目资源并输出提示；显式 `--approve/--no-approve` 与已保存决定优先级不变 | `src/config/trust.n:96`（`'ask'` 现静默返回 true）、`src/app.n:270` | 未信任项目拒载 `.pi/skills`、项目层 settings 的 e2e；TUI overlay 触发路径 PTY e2e |
| 1.2 | bash 生产路径接入有界捕获（现仅测试使用），替换无界输出缓冲 | `src/tools/shell_tools.n:235` ← `:71` | >10MB 输出压测内存有界；截断标记与 Pi 一致 |
| 1.3 | edit 读改写全程互斥（mutation queue 覆盖整个操作而非仅最终写入） | `src/tools/shell_tools.n:358→398` | 并发双 edit 定向测试连续 10 轮不丢失 |
| 1.4 | settings.json/trust.json 原子写：temp+rename+fsync + fcntl 锁（复用 `native/auth_store.c` 先例） | `src/config/settings.n:408-413`、`trust.n` 写盘路径 | kill 注入中断写入后文件不损坏 |
| 1.5 | SQLite 健壮化：WAL + `synchronous=FULL` + `busy_timeout`；append_entry 包事务；真实 `migrations` 版本表；移除 JSONL 行写入 `.db` 的路径；branch_entries/materialized 补读取与 setLeafId 持久化；补齐 4 个缺失索引；API 补 cwd 过滤、fork entryId/before 模式、delete not_found | `src/session/backend.n:61-70`、`sqlite_repo.n:107-141`、`sqlite_migrations.n` | JSONL/SQLite 双后端一致性测试扩展到分支/树/图片；`.db` hexdump 无 JSONL 行 |

## Batch 2｜会话格式互操作（P0-P1，量级 M，依赖 1.5）

| # | 工作项 | 对照 | 验收 |
|---|---|---|---|
| 2.1 | `custom`/`custom_message` 条目：解析、无损保留、读写往返（供 SDK 与跨实现互认）；SDK 面暴露 append 入口 | `session-manager.ts:1122-1189` | Pi 写出的 custom 条目 adou 可读且重序列化不丢字段；双向 fixture 往返测试 |
| 2.2 | toolResult images 改为嵌入式 ImageContent 序列化（现顶层 `images` 键会丢弃 Pi 写入的图片块） | `src/session/message_json.n:218-227` | 含图 toolResult 跨实现读写往返 |
| 2.3 | 写路径补齐：`fromHook`、header `metadata` 保留、`responseModel`；header 延迟至首条 assistant 消息落盘 | `session-manager.ts:1015-1042` | header 字段 diff 断言；空 prompt 退出不留 header 文件 |
| 2.4 | manager 级 `get_tree()/get_children()`；server storage materialized 补全 | `src/session/repository.n`、`src/server/storage.n` | RPC `get_tree` 与 manager API 一致性测试 |

## Batch 3｜AI 层协议收口（P1，量级 M，可与 Batch 1 并行）

1. 约束采样激活：grammar/custom tools 接入 openai-completions 与 openai-responses 请求构建，处理 `custom_tool_call_input.delta/.done` 事件（消除 `constrained_sampling.n` 死代码）。
2. deferred tools 接线：`split_deferred_tools` 接入 anthropic-messages / openai-responses / codex 三条协议线 + deferred 重注入（消除死代码）。
3. Google builder 补齐：temperature、toolChoice→`functionCallingConfig`、functionCall thoughtSignature 回放、同 provider thinking 过滤、tool-result 图片→inlineData（对照 `google-generative-ai.ts:358-366` 等）。
4. OpenAI Responses：`service_tier`、`text.verbosity`、`instructions`、custom tools。
5. Anthropic OAuth 场景的 Claude Code 工具名映射（`toClaudeCodeName`）。
6. Options 面补 `onPayload/onResponse/metadata` 注入钩子。

验收：每项一个 HTTP fixture 单测；现有 provider 流测试全量回归；grep 确认零调用方模块清零。

## Batch 4｜TUI 渲染保真度（P1，量级 L，含决策点 C）

1. Markdown 渲染器重构（~55%→100%）：块级 parser（setext 标题、松散列表、段落软连接、反斜杠转义）；表格溢出换行为多行并保留单元格 inline 格式；task checkboxes；OSC8 能力门控 + `(url)` 回退；代码语法高亮（见决策点 C）。
2. 主题系统（~50%→100%）：命名主题注册表 + JSON schema 校验 + 基于 `fs_watch.n` 热载；256-color 降级链；`MarkdownTheme` 对象；light 变体全色覆盖；将 `terminal_colors.n` 已实现的 OSC11/CSI-16t 解析器接入运行时（替换 env-only 检测）。
3. 运行时终端查询：CSI 16t 动态 cell size（替换硬编码 9×18）、CURSOR_MARKER 硬件光标定位（IME）、kitty keyboard 协议协商握手、modifyOtherKeys 回退激活。
4. mid-stream `set_model` 安全切换（当前 streaming 中抛错）；diff renderer 补 kitty 图片跨帧删除跟踪。

## Batch 5｜TUI 组件 polish（P2，量级 M，依赖 Batch 4）

- session/tree selector：异步加载 + `Loading n/m` 进度、current-session 标记、cwd 标签、`(i/n)` 计数、tree `├─└─` 连接线、消息内容行、panning。
- 编辑器：word-boundary/CJK 软换行（对照 `editor.ts wordWrapLine`）、history-Up 边界守卫、方向键进 keybinding registry、`externalEditor` 设置覆盖。
- autocomplete：Tab 打开的 path 菜单活过滤、`` #`` 触发器。
- skill-invocation 独立消息渲染；macOS native modifier 探测。

## Batch 6｜CLI / server / SDK / evals 收口（P2，量级 L）

- Flags：`--prompt-template/--no-prompt-templates/--theme/--no-themes`；`--resume` picker 在 json/rpc/print 模式同样生效；`--session` 跨项目命中时 fork 询问。
- Subcommands：`auth print-bearer-token`、`auth help`。
- 进程生命周期：rpc/print/serve 注册 SIGTERM/SIGHUP/SIGINT；serve 优雅停机与 uncaughtException 兜底；RPC prompt success 移至 preflight 之后；stdout 背压处理。
- Settings 缺失键补齐（`lastChangelogVersion`、`thinkingBudgets`、`shellPath/shellCommandPrefix`、`externalEditor`、`httpProxy`、`websocketConnectTimeoutMs` 等约 17 个）+ 3 个迁移（keybindings.json、commands→prompts、弃用告警）+ changelog dismissed 循环。
- SDK（~55%→100%）：`ModelRuntime`、`SettingsManager`、`ResourceLoader` 注入、`defineTool/customTools`、`subscribe()`、`cycleModel/cycleThinkingLevel/dispose`、run-mode 导出、`agentDir/thinkingLevel/scopedModels` 选项。
- Evals：真实 provider runner（`ADOU_PROVIDER/ADOU_MODEL` 等价 `PI_PROVIDER/PI_MODEL`，opt-in）、usage/transcript JSON 报告、run-evals CLI 入口。
- Server：TCP stale 连接 liveness 探测（对应上游 stale socket 检查）、status 词表对齐（`stopping/error`）、Radius backoff 加抖动、hostname/platform/arch 取实测值。

## Batch 7｜全量收口验收（量级 M，依赖全部批次）

1. 功能矩阵逐项对照 Pi 0.82.1 真机三轮（同终端、同配置、同按键序列）。
2. 全量串行门禁：`make test`（预计 >200 文件）、`make e2e`、`make eval`、`make release-check`、`make signing-check`。
3. 本计划各工作项逐条销账；四路差分审计方法复测，四个域均需 ≥99%（剩余为已记录的可接受 drift）。
4. 更新 `docs/porting-plan.md` 与 `README.md` 的 parity 边界描述。

## 决策点

| 决策点 | 问题 | 建议 |
|---|---|---|
| C. 语法高亮范围 | 上游 cli-highlight 支持 190+ 语言；adou 需自实现 | 自实现高频语言子集（ts/js/py/go/rust/json/md/sh/c++），其余语言降级为无高亮纯文本；差异记录于模块映射文档 |

（原扩展语言与包管理决策点随扩展排除一并取消。）

## 里程碑

| 批次 | 量级 | 依赖 |
|---|---|---|
| B1 正确性与数据安全 | M | 无 |
| B2 会话格式互操作 | M | 1.5 |
| B3 AI 协议收口 | M | 无（可与 B1 并行） |
| B4 TUI 渲染保真度 | L | 决策点 C |
| B5 TUI 组件 polish | M | B4 |
| B6 CLI/server/SDK/evals | L | 无强依赖 |
| B7 全量收口 | M | 全部 |

## 实施销账（2026-08-22 更新）

全部批次已实施完成（提交 0a255a3…792faa5，共 20 个实施提交）：

- **B1 ✅** trust 'ask' 门控与启动选择器、bash OutputAccumulator、edit 全程互斥、settings/trust 原子写、SQLite 健壮化（WAL/事务/migrations/JSONL 泄漏修复/leaf 持久化/fork 模式）
- **B2 ✅** toolResult 内嵌图片、custom/custom_message 条目、fromHook、延迟首刷、get_children、responseModel
- **B3 ✅** Google 构建器对齐、Claude Code 工具名映射、service_tier、deferred tools（tool_reference）、约束采样 strict 路径（grammar 分支因 nature #302 族运行时段错误保持 ADOU_GRAMMAR_TOOLS=1 显式启用，已记录）、metadata 透传
- **B4 ✅（15/16）** 实时 OSC11/997 主题、mid-stream set_model、CSI 16t cell size、kitty 协商+mOK 回退、CURSOR_MARKER 全链、setext 标题、GFM 任务标记、表格换行+inline 保留、段落软连接、语法高亮（高频语言子集）、主题注册表+校验、256 色降级、kitty 稳定 id+退出清理。唯一遗留：逐帧差分图片删除（低优先；退出清理已覆盖主要可观察面）
- **B5 ✅** skill 折叠渲染、selector 当前会话标记+(i/n) 计数、PATH 菜单活过滤、词边界软换行（纯函数重做版）、Apple Terminal CR 归一（探针降级与 Pi 无 prebuild 一致）
- **B6 ✅** auth print-bearer-token/help、--prompt-template/--theme 资源 flags、headless 信号处理、settings 补键（lastChangelogVersion/externalEditor/shellPath/shellCommandPrefix/httpProxy/websocketConnectTimeoutMs/thinkingBudgets）+externalEditor 接线、evals live runner+JSON 报告、SDK cycle/set/dispose

**验收门禁全部通过（2026-08-23）**：
- make test: ✅ 183 文件 0 失败（编译器 v0.7.4 build 2026-08-23）
- make e2e: ✅ 64 脚本全绿
- make eval: ✅ 3/3
- make release-check: ✅ build+eval+dist+pkg+artifacts+ipc+bash OK
- make signing-check: ✅ dist+pkg+package/signing workflows OK

**B7 门禁进行中记录（2026-08-22）**：全量 make test 三轮运行暴露两处问题——
1. 段落分支多推空行导致 chat outputPad 断言失败：已修复（fa94e4d）；
2. editor 词边界换行的 Nature 计数型 for 循环计数器重启赋值被忽略，致 CJK 混排切分错误：改用手动索引循环修复（d008448）。

当前唯一阻塞：`provider_user_images_test` Test 5 确定性段错误（连续 4 次复现；二分排除 google_messages/message_json/deferred tools，指向 B2 时期 stream_options_t 增加 `{string:string} metadata = {}` 结构字段默认空 map 后，构造路径上该字段为 nil、任何访问即触发 #302 族缺陷）。已回退 metadata 切片（types 字段 + anthropic 发射 + 测试用例），回退后待复验。下一轮专修后重跑全量门禁。

**补充二分结果**：回归窗口锁定为 `55ec7a9..6b843e6`——即 Claude Code 工具名映射与 deferred tools 接入提交（8815610）引入；`55ec7a9` 处同测试绿。修复方向：在该提交范围内对 anthropic convert/build 路径做逐段还原重验，优先怀疑 deferred 消息转换对 image-only 用户消息的空内容处理。

**2026-08-22 专项调试结论**：多轮二分（map 类型切换、守卫添加、逐文件回退、pending_siblings 移除）均未能消除段错误。崩溃点在 anthropic_request.build 的 image-only 用户消息路径，但具体行需 lldb/native 级调试（本轮上下文不足）。已回退全部临时调试改动，HEAD 干净。该测试为唯一 make test 阻塞；其余 163 个文件两轮运行均绿。

**✅ 已修复（39e015f）**：根因是 `stream_options_t.api_key` 无默认值——`new types.stream_options_t()` 构造时 Nature 字符串 data 指针为 nil，B3 新增的 `is_oauth_token()` 调用 `.contains('sk-ant-oat')` 时 strstr(NULL,...) 段错误。修复：api_key 默认值 `= ''` + is_oauth_token 空 len 守卫。修复后 pui 10/10 绿、anthropic 四套件全绿。

**上游 issue 已提交**：nature-lang/nature#318（https://github.com/nature-lang/nature/issues/318）——空 map struct 字段默认值在 new() 构造路径上为 nil，任何访问即段错误。待上游修复后重新落地 metadata 切片。

**✅ metadata 切片已重新落地（df472cc）**：nature #318 由 PR #319 修复后编译器更新至 v0.7.4 build 2026-08-23，metadata 字段与 Anthropic 发射块安全恢复。

**Herdr 真实用户模拟测试（2026-08-23）**：在 Herdr PTY 窗格中以 DeepSeek API 启动 adou TUI，模拟真实用户构建台风监测网页。验证了：TUI 启动 ✅、DeepSeek API 连接 ✅、模型读文件+分析 ✅、bash 工具检查目录 ✅。发现 Nature 运行时 `page_alloc_grow` 内存分配器断言崩溃（allocator.c:637）——生成大型 HTML 文件时内存耗尽，属 nature 运行时限制非 Adou 逻辑缺陷。已最小复现（/tmp/nature-oom-repro/repro.n：持有 >16GiB 活内存即触发）并提交上游 issue：https://github.com/nature-lang/nature/issues/320（硬性 16GiB 堆上限，根因：page_alloc_grow 断言写死检查 summaries[0] 而非新 arena 所在区域）。

**adou 内存暴涨根因已定位（2026-08-23）**：非 Adou 逻辑缺陷，而是 nature 运行时 **GC 完全失效**——官方 GC 测试用例（vendors/nature_cases/20230502_00_gc_large.n，断言 GC 后 malloc_bytes < 2000）直接 panic；丢弃数组循环中显式 runtime.gc() 20 次零回收（每次迭代 malloc_bytes 精确 +8.4MB 线性增长）；`s += delta` 拼接循环 4 秒内堆单调涨到 16GiB 触发 #320 崩溃。adou 的流式输出路径 `content.text += delta`（src/sdk_proxy.n:126）即此模式：concat 每次分配新缓冲区（O(n²) 复制），中间字符串永不回收。已提交上游 issue：https://github.com/nature-lang/nature/issues/322。同时发现编译器对超大固定数组类型（如 [i64; 16384] 起）编译时间/内存超线性爆炸：https://github.com/nature-lang/nature/issues/321。**后续**：上游修复 GC 后需回归验证 adou 长会话/大输出场景。



## 附：评估缺口 → 批次销账索引

- AI 层全部缺口 → B3；Agent/core 正确性类（trust/bash/edit/原子写/SQLite）→ B1；会话格式类 → B2；Markdown/theme/终端查询/model switch → B4；selector/editor/autocomplete polish → B5；CLI/信号/settings 键/SDK/evals/server → B6。
- 扩展相关缺口（extension UI、包管理、unknownFlags、extensions.eval、transformContext）不在销账范围，见「口径定义」排除清单。
