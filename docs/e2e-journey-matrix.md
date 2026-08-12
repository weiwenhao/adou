# E2E 用户旅程矩阵

状态：2026-08-12。E2E 分四层，均通过 `make` 串行门禁执行（Nature 编译
/测试严格串行，见 AGENTS.md）。本文件描述**旅程**（end-to-end journey）
的构成与验证边界，不把脚本数量表述为覆盖率，不宣称任何百分比。

## 入口与分层

真机交互式验收（真实 TUI/DeepSeek/渲染，Herdr 内可重复执行）见
`docs/herdr-real-machine-testing.md`；本矩阵只覆盖自动化旅程。


| 入口 | 内容 | 模型/网络 |
| --- | --- | --- |
| `make e2e` | `tests/e2e/*.sh`（glob 天然排除子目录） | 全部 offline：本地 mock HTTP fixture 或直接 CLI/RPC/PTY |
| `make e2e-live` | `tests/e2e/live/*.sh`（显式清单，新增 live 脚本需在 Makefile 注册），脚本自身以 `ADOU_LIVE_SMOKE=1` / `ADOU_LIVE_JOURNEY=1` / `ADOU_LIVE_TUI_JOURNEY=1` 开关门控 | 真实 DeepSeek，opt-in、受控消费 |
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
| 真实在线 TUI 双轮编码旅程（`tests/e2e/live/live-tui-coding-journey.sh`） | 同一 TUI 进程内双轮（Python 标准库 PTY）+ 离线恢复 TUI | 真实 deepseek-v4-flash（`ADOU_LIVE_TUI_JOURNEY=1`） | 轮 1：PTY 向编辑器提交编码请求，模型在 TUI 内实际 read→edit→bash 并以 `ROUND1DONE` 收尾（标记为 markdown 安全字面量，避免 `_` 被强调语法消费）；轮 2：同进程 follow-up（要求基于首轮修改再次 edit+bash，`ROUND2DONE`）；`/quit` 后离线 `--session` 重开断言两轮历史渲染 | 磁盘结果（第二轮可执行验证 63）；session JSONL 为工具顺序权威（toolCall→toolResult 配对、无 isError、最终答复含完成标记、usage/cost 汇总）；`PI_TUI_WRITE_LOG` 提供 TUI 可见证据（用户请求回显、`✓ read/edit/bash` 工具行、完成标记渲染）；退出码 0、termios 恢复、无遗留进程；离线恢复不改写 session 文件 |
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

工具链驱动的双轮旅程（本地与 headless live）使用 headless `--mode json`：
脚本化 PTY 输入在 differential renderer 下脆弱，而工具链需要精确断言
request/session 顺序，因此这两层里 PTY 只承担**持久化/恢复桥接**（以
`--offline --session <file>` 重开同一会话，断言历史消息渲染后 `/quit`
干净退出）。**真实在线 TUI 双轮旅程**（`live-tui-coding-journey.sh`）
弥补了这一边界：同一 TUI 进程内、经 PTY 编辑器提交真实模型轮，证明 TUI
能在线完成工具轮、follow-up 与干净退出。该层的断言分工：session JSONL
是工具顺序的权威（不依赖 UI 字节），`PI_TUI_WRITE_LOG` 只断言稳定的
用户可见信号（请求回显、工具行、完成标记），不做脆弱字节级快照；
`/quit` 用 termios 对比与恢复转义序列验证终端还原。因成本与脆弱性，
该真实 TUI 轮为 opt-in（`ADOU_LIVE_TUI_JOURNEY=1`），普通 `make e2e`
保持全离线。

## 剩余缺口（不宣称覆盖）

- 真实签名/公证（Batch 2B）：本地做 preflight/fail-closed/ad-hoc 副本 smoke
  与 `.pkg` 双证书签名、公证、staple 的 fake-tool 编排；不使用真实 Developer
  ID、不真实上传（见 `docs/macos-signing.md` 与 `docs/macos-installer.md`）。
- OAuth/账号登录：未纳入任何 e2e（live 用测试 key 经环境变量）。
- 真实 provider eval（Batch 5）：`make eval` 只用本地脚本化 HTTP mock；
  对真实 DeepSeek 的发布级冒烟受 opt-in 开关与成本约束限制（thinking off、
  低 max tokens、最多一次受控重试）。
- 其他 provider（OpenAI/Anthropic/…）：本地 mock 有覆盖；真实端点只对
  DeepSeek 有 live 旅程。
- macOS `.pkg` 构建与离线签名/notary/staple 编排已有专门 E2E，见
  `docs/macos-installer.md`；真实 Developer ID/notary 仍需新权限。Linux
  暂缓，extension 兼容仍为独立 RFC。
- 非 opt-in 的真实 TUI 模型轮：`make e2e`/`make release-check` 保持全
  离线（成本与脆弱性考虑）；真实 TUI 工具轮由 opt-in 的 live TUI 双轮
  旅程承担，普通 PTY 恢复桥接仍不驱动真实模型轮。
