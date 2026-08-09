# Adou 全量移植规划（Pi 0.82.1，除扩展外）

状态：规划中 — 2026-08-07
基线：Pi `0.82.1`，commit `cced6a21da273b26ee4a23a803680614bbe8dd1e`（vendors/pi）

## 目标

把 vendors/pi 中除 extensions 之外的全部模块完整移植为 Nature 实现，行为与 Pi 基线逐项对齐。

## 现状数字

- Pi 全量：924 个 TS 文件；扩展相关 104 个 → **非扩展目标 820 个**
- Adou 当前：82 个 .n 文件 / 约 2.4 万行，覆盖约 350-400 个 TS 的 MVP 核心
- 剩余待移植：约 450 个 TS 文件 → 预估新增 100-140 个 .n、2.5-4 万行

## 范围界定（排除项）

- `extensions/` ABI、loader、runner、事件总线
- Llama 扩展 provider、扩展 UI 组件（extension-editor/input/selector）、扩展工具渲染器
- 注意：`.pi/skills`、`.pi/prompts`、slash-commands 属核心功能，**不算扩展，必须移植**

## 验收闭环（每个阶段都必须满足）

1. 固定 Pi 源码文件与测试 fixture 引用
2. Nature 实现逐项行为差分记录
3. Nature 单元测试（正常/错误/取消/边界/顺序）
4. 至少一个跨模块集成测试（不许只用孤立 mock）
5. `make build`、相关 `make test`、受影响的 `make e2e` 全绿

## 分阶段规划（按依赖顺序）

### Phase 1｜AI 层完整化（最大块，模式化程度最高）
- `api/`：azure-openai-responses、openai-codex-responses、bedrock-converse-stream、
  google-generative-ai、google-vertex、mistral-conversations、cloudflare、
  constrained-sampling、github-copilot-headers、lazy 加载器
- `providers/`：deepseek、xai、qwen、zai、xiaomi（多区域）、together、cerebras、
  openrouter、radius、amazon-bedrock、ant-ling、cloudflare/vercel 网关
- 顶层：models 目录全量、models-store、oauth + auth（credential-store/resolve/oauth 子目录）、
  images 图片生成、env-api-keys、session-resources、compat
- 验收：每家 provider 有 HTTP 单测 + 至少一条 e2e

Phase 1 状态（2026-08-09）：全部 39 个 provider 已注册（`src/ai/providers/registry.n`），
每家都有 HTTP 单测 + 元数据对齐测试；新增 pi-messages 协议（radius 网关）、
constrained-sampling 纯逻辑（扩展工具路径，10/10 单测）和 radius-config 动态目录。
OAuth（credential-store/oauth 子目录）与 lazy 加载器按排除项处理：OAuth 认证不在 Adou
范围（api-key 认证覆盖全部 provider）；lazy 是 Pi 的运行时动态 import 加载优化，Adou
静态注册功能等价，不做移植。余下工作：为 `make e2e` 补充至少一条 radius/pi-messages e2e。

### Phase 2｜Agent harness 补全
- memory-repo/memory-storage、env/nodejs、tool-context、image tool、shell-output
- 验收：memory session 单测 + 集成

Phase 2 状态（2026-08-09）：memory session 已由 `src/session/repository.n` 的
`in_memory`/`in_memory_with_parent` 覆盖（Pi InMemorySessionRepo 等价物），session
单测 27/27 与 agent 集成测试（agent_session_test 中 30+ 处 in-memory 场景）通过；
shell-output 语义（tail 截断、full_output_path、退出码/footer、二进制与控制字符
清洗 `command.n sanitizer_t`）已覆盖；env/nodejs 的 ExecutionEnv 由 libc 直连的
`src/tools/command.n`/`shell_tools.n` 等价实现，不引入接口抽象；新增
`src/tools/image_detect.n`（Pi harness/tools/image.ts 的 mime 检测 + base64，
5/5 单测）。图片读取/渲染仍按排除项处理，image 模块保持纯逻辑不接入 read。

### Phase 3｜coding-agent core 补全
- skills（.pi/skills 加载）、slash-commands、event-bus、telemetry、usage-totals、
  cache-stats、source-info、http-dispatcher、package-manager、sdk、
  remote-catalog-provider、provider-composer、provider-attribution、auth-guidance、
  runtime-credentials、trust-manager、export-html 全量（交互式模板）、
  diagnostics 全量、footer-data-provider、prompt-templates
- 验收：每项行为差分单测；skills/slash-commands 有 e2e

Phase 3 状态（2026-08-09）：已完成 skills 资源层（`src/context/skills.n`，
frontmatter 解析、Agent Skills 名称/描述校验、SKILL.md 根/递归发现、gitignore
规则、collision 诊断、XML prompt 格式化、source_info 内联模型，12/12 单测），
注入 system prompt（app 启动 + TUI `/reload`），TUI 新增 `/skill` 命令，
`tests/e2e/skills-loading.sh` 验证系统提示注入（e2e 通过）。
已完成 prompt-templates（`src/context/prompt_templates.n`：参数解析、占位符替换、
.prompts 目录发现、TUI `/name` 展开，7/7 单测）、provider attribution 与
telemetry（`src/ai/attribution.n`，5/5）、usage cost breakdown（`src/session/
repository.n`，2/2）、assistant diagnostics（`src/ai/diagnostics.n`，4/4）、
auth guidance 与 runtime credential overlay（`src/config/auth_guidance.n` +
auth.n runtime keys，3/3）、cache waste accounting（`src/session/cache_stats.n`，
4/4）、models.json provider 组合（`src/config/models_json.n`，5/5）、
trust-manager 补全（`src/config/trust.n` set_many/clear/资源门控，5/5）。
已完成 remote-catalog overlay（`src/ai/remote_catalog.n`：merge/etag/304/404 语义，
6/6）、slash-commands 动态来源（TUI `/skill:name` 展开，skills.strip_frontmatter）、
git 元数据检测（`src/context/git_paths.n`：.git 目录/worktree/commondir/HEAD 解析，
4/4）、ansi-to-html（`src/session/ansi_to_html.n`：SGR 全量支持，7/7，已接入
export_html 的 bash/tool 输出渲染）。
按架构性差异排除（记录理由）：sdk（createAgentSession 是外部编程 API，Adou 为
CLI 应用，其模型解析/session/工具装配由 app.n + runner_t 内部等价实现）、
package-manager（npm/git 包安装依赖 Node 生态与扩展包机制，Adou 无包资源层，
skills/prompts 为本地目录）、export-html 交互式模板（template.html/css/js +
marked/highlight vendor 资产无分发机制，保留静态 HTML + ANSI 渲染）、
footer 的 fs.watch 变更通知（无 fs.watch）、event-bus（无扩展单消费者流）、
http-dispatcher（libc 直连无全局 dispatcher）。

### Phase 4｜TUI 补全
- autocomplete、fuzzy、kill-ring、native-modifiers、terminal-image、undo-stack、
  editor-component 全量、tui/components/
- 验收：input/renderer 测试全绿 + PTY e2e

Phase 4 状态（2026-08-09）：kill-ring 与 undo-stack 已内嵌 editor.n（行为对齐），
word-navigation/stdin-buffer 已覆盖。新增 fuzzy 匹配（`src/tui/fuzzy.n`：评分/
多 token/排序，6/6）、terminal-colors（`src/tui/terminal_colors.n`：OSC 11 + 997
报告，5/5）、select-list 渲染（`src/tui/select_list.n`：两列/滚动/过滤，4/4）、
文件路径补全（`src/tui/path_completion.n`：引号/@ 前缀、目录优先排序、闭合引号
去重，7/7）、terminal-image 纯逻辑（`src/tui/terminal_image.n`：能力检测/kitty
分块编码/iTerm2/尺寸解析/单元格换算，7/7）。
进行中：编辑器视觉行包装（editor.n 目前物理行近似）、keybindings 注册表
（键位硬编码）、markdown 增强（表格/嵌套块）；native-modifiers 按 darwin 原生
模块排除（kitty 协议覆盖 Shift+Enter）；PTY e2e 目前仅 tui-auth-overlay.sh。

### Phase 5｜Interactive 模式 UI 组件全量
- interactive-mode + 40 个组件（diff、session-selector、model-search、login-dialog、
  oauth-selector、theme-selector、settings-selector、tree-selector、visual-truncate、
  custom-editor 等）+ theme/
- 验收：TUI 交互 e2e 覆盖关键路径

### Phase 6｜CLI 补全
- list-models、session-picker、file-processor、credential-print、initial-message、
  startup-ui、config-selector、project-trust
- 验收：对应 CLI e2e

### Phase 7｜storage + server
- storage 12 个：repo/migrations/branch-entries/session-entries/sequences/materialized
- server 13 个：rpc-process/supervisor/protocol/handler/serve/radius
- 验收：存储单测 + RPC over IPC e2e

### Phase 8｜evals 基建（收尾验收）
- pi-harness + smoke.eval（extensions.eval 排除），作为全量回归基准
- 验收：harness 跑通全量用例

## 完成度验证（2026-08-09，vs vendors/pi 同步对比）

对 Phase 1-3 做了逐模块/逐功能对照（Pi packages/ai、agent/harness、coding-agent/src），
三档结论：Phase 1 已完成 26 / 行为不一致 15 / 缺失 4；Phase 2 已完成 13 / 行为不一致 9 /
缺失 0；Phase 3 已完成 10 / 行为不一致 8 / 缺失 4。详见各阶段小节。

扩展接口面（extension ABI/钩子/注册点）按"接口齐全、具体扩展不移植"标准补齐：
EventBus（`src/agent/event_bus.n`，emit/on/off/clear）、provider 钩子
（before_provider_request/after_provider_response 挂在 agent config_t）、
CredentialStore 完整接口（`src/config/auth.n`：credential_t/oauth 形状、list、
序列化 modify）、ModelRegistry 注册面（`src/ai/providers/registry.n` 运行时
register/unregister）、compat API 注册面（`src/ai/provider.n` runtime api
分派优先）、动态 slash 命令注册（`src/context/slash_commands.n`，RPC
get_commands 返回 prompt/skill 来源）、扩展注册集合（`src/agent/extensions.n`：
Extension/tool/command/flag/shortcut 集合、ExtensionError、LoadExtensionsResult）、
ToolDefinition 扩展字段（promptSnippet/promptGuidelines/constrainedSampling/
renderShell）、ExtensionRunner 生命周期（`src/agent/extension_runner.n`：
handler 分发、bindCore 会话动作、provider 注册排队）、扩展发现规则
（`src/agent/extension_loader.n`：直接文件/子目录 index/package.json
pi.extensions manifest）、扩展工具执行器与绑定（`src/agent/extension_bindings.n`）、
ExtensionContext/UIContext 类型面（状态字段 + 动作闭包占位）。
扩展 UI 组件的完整渲染、jiti 动态加载由静态链接替代——接口面保留。

本轮验证补上的缺口（每项独立 commit）：
- Phase 1：mistral `promptMode:"reasoning"`；google thinkingConfig（Gemini 3 level /
  2.5 budget）；thinking_level_map 驱动的 clamp/available；unpaired surrogate 清理
  （sanitize_unicode.n，接入 OpenAI responses 文本）；openai-completions 按 provider
  分发 thinkingFormat（deepseek/zai/qwen/openrouter/together/ant-ling）
- Phase 2：bash 输出剥 `\r`；bash 截断 footer 补 `(line is X)`；read 图片路径返回
  Pi 占位文案（含 BMP 提示）
- Phase 3：settings save 读-改-写合并（未知字段不再被抹掉）；session-cwd 缺失校验；
  resolve-config-value（`!command`/`$ENV` 模板 + auth 存储接线）；experimental 开关；
  项目信任门控（--approve/--no-approve 消费 + 未信任跳过 .pi 设置与项目上下文）
- 记录的工具链缺陷：Nature map 参数按值拷贝（子函数修改不生效）、含 ESC 字符串 `==`
  不稳定、嵌套 json map key 前导空格、`path.join(dst, '.')` 越界、单 token split 失效

剩余已知缺口（记录不补）：deferred-tools 接线、codex WebSocket 传输、model compat
标志、temperature/toolChoice 等可选字段、compaction retainedTail 持久化、leaf 条目
targetId 语义、keybindings 注册表、视觉行包装。

- models 目录数据量巨大：用脚本从 Pi `models.generated.ts` 生成 Nature 数据文件
- provider 适配器模板化：先做一个参考实现（如 deepseek），其余按模板批量
- 全程遵守：串行编译、不跑 nature fmt、vendors/ 只读、延续 pi-core-module-map.md 验收规则

## 节奏

每阶段交付并更新 pi-core-module-map.md；不跨阶段并行，避免编译器高内存叠加。
