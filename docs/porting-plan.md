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

### Phase 3｜coding-agent core 补全
- skills（.pi/skills 加载）、slash-commands、event-bus、telemetry、usage-totals、
  cache-stats、source-info、http-dispatcher、package-manager、sdk、
  remote-catalog-provider、provider-composer、provider-attribution、auth-guidance、
  runtime-credentials、trust-manager、export-html 全量（交互式模板）、
  diagnostics 全量、footer-data-provider、prompt-templates
- 验收：每项行为差分单测；skills/slash-commands 有 e2e

### Phase 4｜TUI 补全
- autocomplete、fuzzy、kill-ring、native-modifiers、terminal-image、undo-stack、
  editor-component 全量、tui/components/
- 验收：input/renderer 测试全绿 + PTY e2e

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

## 横切工作

- models 目录数据量巨大：用脚本从 Pi `models.generated.ts` 生成 Nature 数据文件
- provider 适配器模板化：先做一个参考实现（如 deepseek），其余按模板批量
- 全程遵守：串行编译、不跑 nature fmt、vendors/ 只读、延续 pi-core-module-map.md 验收规则

## 节奏

每阶段交付并更新 pi-core-module-map.md；不跨阶段并行，避免编译器高内存叠加。
