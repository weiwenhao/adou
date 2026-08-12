# E2E 用户旅程矩阵

状态：2026-08-12。E2E 分四层，均通过 `make` 串行门禁执行（Nature 编译
/测试严格串行，见 AGENTS.md）。本文件描述**旅程**（end-to-end journey）
的构成与验证边界，不把脚本数量表述为覆盖率，不宣称任何百分比。

## 入口与分层

| 入口 | 内容 | 模型/网络 |
| --- | --- | --- |
| `make e2e` | `tests/e2e/*.sh`（glob 天然排除子目录） | 全部 offline：本地 mock HTTP fixture 或直接 CLI/RPC/PTY |
| `make e2e-live` | `tests/e2e/live/*.sh`，脚本自身以 `ADOU_LIVE_SMOKE=1` / `ADOU_LIVE_JOURNEY=1` 开关门控 | 真实 DeepSeek，opt-in、受控消费 |
| `make release-check` | build → eval → dist → `tests/e2e/release/release-artifact.sh` → rpc-over-ipc → rpc-bash-stream | 全部 offline |
| `make signing-check` | dist → `tests/e2e/release/macos-signing-workflow.sh` | 全部 offline（preflight/fail-closed/fake-tools/ad-hoc 副本） |

`make e2e` 在 `make clean` 后只依赖 `make build`；不包含 release/signing
（`tests/e2e/release/`）与 live（`tests/e2e/live/`）场景，不调用真实模型、
不消耗额度。`make -n e2e` 可复核分层（输出片段见下）。

## 用户旅程

| 旅程 | 载体 | 模型 | 流程 | 断言 |
| --- | --- | --- | --- | --- |
| 本地确定性编码旅程（`tests/e2e/local-coding-journey.sh`） | headless `--mode json` 双轮 + 最小 PTY 恢复桥接 | 内嵌 python mock（OpenAI-completions SSE，无外部网络） | 轮 1：read → edit → bash → 最终答复；PTY 离线重开同 session 断言历史渲染；轮 2：`--session <file>` 续跑 follow-up | 磁盘文件真实被 edit 修改；mock 第二次请求正文含首轮工具结果与文件内容（`history-check`）；session JSONL 的 user/assistant/toolCall/toolResult 顺序 |
| 真实 DeepSeek 编码旅程（`tests/e2e/live/live-coding-journey.sh`） | headless `--mode json` 双轮 + 最小 PTY 恢复桥接 | 真实 deepseek-v4-flash（`ADOU_LIVE_JOURNEY=1`） | 轮 1：隔离工作区 seeded fib.py，模型实际调用 read/edit/bash 后答复；PTY 离线重开同 session；轮 2：`--session <file>`"改为递归"，模型基于首轮修改作答 | 文件结果（TODO 消除、第二轮递归实现）；session JSONL 工具链顺序（toolCall→toolResult 配对、无 isError、末条为最终答复文本）；usage/cost 从 session 汇总打印（不打印密钥） |
| 单请求 live smoke（`tests/e2e/live/live-smoke.sh`） | headless `--print` | 真实 deepseek-v4-flash（`ADOU_LIVE_SMOKE=1`） | 单请求、thinking off、64 max tokens、0 retries | 回复含 "ok"；日志只输出 key 配置状态 |
| TUI/PTY（`tests/e2e/tui-*.sh`） | PTY 交互 | offline（--offline 或本地 fixture） | 会话选择/模型选择/设置/树/fork 等 UI 流程 | 渲染、导航、退出码 0 |
| RPC/组件（`tests/e2e/rpc-*.sh`） | headless stdin 协议 / python 客户端 | offline | 会话生命周期、重试、compaction、工具结果形状等 | 响应形状与 Pi JSON 序列化对齐 |
| release/signing（`tests/e2e/release/*.sh`） | headless | offline | 解包后 artifact 运行、Mach-O/依赖白名单、signing 预检/fail-closed | 见 `docs/release-hardening-plan.md` / `docs/macos-signing.md` |

## 分层证据（2026-08-12）

`make -n e2e` 的 glob 展开仅包含 `tests/e2e/` 根目录脚本：包含
`tests/e2e/local-coding-journey.sh`，不包含任何 `tests/e2e/release/`、
`tests/e2e/live/` 路径（`tests/e2e/*.sh` 只匹配顶层）。live 集合只由
`make e2e-live` 串行展开。

## PTY 边界

工具链驱动的双轮旅程（本地与 live）使用 headless `--mode json`：脚本化
PTY 输入在 differential renderer 下脆弱（现有 tui-* 用例只能做有限
键盘/粘贴交互），而工具链需要精确断言 request/session 顺序。PTY 在本层
只承担**持久化/恢复桥接**：以 `--offline --session <file>` 重开同一会话，
断言历史消息（工具结果与最终答复）渲染，再 `/quit` 干净退出（退出码 0）。
TUI 内部状态的深度交互断言仍由 `tests/e2e/tui-*.sh` 承担。

## 剩余缺口（不宣称覆盖）

- 真实签名/公证（Batch 2B）：本地只做 preflight/fail-closed/ad-hoc 副本
  smoke，不真实签名上传、不 notarytool（见 `docs/macos-signing.md`）。
- OAuth/账号登录：未纳入任何 e2e（live 用测试 key 经环境变量）。
- 真实 provider eval（Batch 5）：`make eval` 只用本地脚本化 HTTP mock；
  对真实 DeepSeek 的发布级冒烟受 opt-in 开关与成本约束限制（thinking off、
  低 max tokens、最多一次受控重试）。
- 其他 provider（OpenAI/Anthropic/…）：本地 mock 有覆盖；真实端点只对
  DeepSeek 有 live 旅程。
- Linux 构建、安装器、stapler、extension 兼容：见
  `docs/release-hardening-plan.md` 后续批次。
- PTY 桥接仅验证渲染与干净退出，不驱动真实模型轮（成本与脆弱性考虑）。
