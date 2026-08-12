# Herdr 真机测试 SOP（macOS arm64）

本文是今后可重复执行的**真机（real machine）交互式验收流程**，面向
Herdr 终端内的真实用户操作：真实 DeepSeek、真实 TUI、真实终端渲染。
自动化的离线/live 场景由 `make e2e` / `make e2e-live` 覆盖，本文只
补充自动化无法代替的交互部分，并**不重复** `tests/e2e/live/*` 的内容。

## 0. 范围与原则

- 本 SOP 只在真实终端（Herdr pane / 用户自己的 TTY）中执行，验证
  **已安装的 `/usr/local/bin/adou`** 与开发产物 `build/bin/adou`。
- 发布验收（Gatekeeper、真实输入、真实渲染）**必须以已安装二进制为准**，
  `build/bin/adou` 只用于开发对照；两者 hash 不同是正常的，必须分别记录。
- 仓库是公开的：**任何命令、日志、文档、提交都不得包含 API key**。
  key 只允许交互式输入（`/login` 或终端粘贴），且输入后立即确认不落入
  shell 历史（不要在命令行里以参数形式粘贴 key）。
- 本文记录的是"如何做"，不是"已通过"的保证。文末有当前已知待跟踪异常，
  出现时按失败分级处理，不得写成通过标准。

## 1. 前置检查（每次执行前）

1. `echo $HERDR_ENV` 应为 `1`；否则本 SOP 的 pane/焦点约定不适用，
   先进入 Herdr 环境再继续。
2. `herdr pane list --workspace "$HERDR_WORKSPACE_ID"`：确认目标测试
   pane 存在（用返回的显式 pane id，如 `w1:pN`，不要凭侧栏顺序猜测）、
   可聚焦、没有正在运行的长任务。不要在其他 agent pane 或用户工作
   pane 中执行干扰性命令。
3. 二进制身份（分别记录，禁止混淆）：
   - `shasum -a 256 build/bin/adou`（开发产物）
   - `shasum -a 256 /usr/local/bin/adou`（已安装产物）
   - 记录两者的 mtime 与 `file` 输出的架构（Mach-O arm64）。
   - 若两份产物来自不同构建，在报告中明确以哪份为准；发布验收用
     `/usr/local/bin/adou`。
4. 隔离环境：为每次测试创建唯一临时目录（变量名避开系统 `TMPDIR`）：
   `ADOU_REAL_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/adou-real-test.XXXXXX")`
   （macOS mktemp 模板须以 `XXXXXX` 结尾），并设
   `PI_CODING_AGENT_DIR`、`PI_CODING_AGENT_SESSION_DIR` 指向其子目录；
   结束时整目录删除（或按证据留存规则保留）。
5. 确认无 `ADOU_PROVIDER`/`ADOU_MODEL` 覆盖：`env | rg '^ADOU_'`
   应为空；若存在，记录后按"覆盖生效"解读，不作为默认路径证据。

## 2. 测试 pane 的启动/退出与焦点

- 在**独立 pane** 中启动 TUI（`/usr/local/bin/adou`），不要抢用户正在
  使用的 pane 焦点；需要键入时再聚焦测试 pane，观察期结束立即释放。
- 退出：使用 `/quit`（正常退出，记录退出码）或 `Ctrl+C`（记录行为）；
  退出后确认无遗留进程：`pgrep -lf adou`（注意排除本 SOP 自身命令行）。
- 终端属性恢复：退出后 `stty -a` 对照进入前记录；异常时
  `reset`/`stty sane` 恢复并记为环境问题。

## 3. 真实凭据与默认模型

1. 交互式 `/login`（不带 provider 参数），在弹出的 provider selector 中
   选择 DeepSeek，再按提示粘贴 API key（**不得写入任何命令、日志、文档
   或提交**；不要在命令行参数中携带 key）。
2. 确认 provider：`/model` 或状态区应显示 deepseek；随后
   `ls -la "$PI_CODING_AGENT_DIR"` 确认 `auth.json` 存在（只记文件名，
   不 cat 内容、不打印 key）。
3. 默认模型确认：在**无** `ADOU_PROVIDER`/`ADOU_MODEL`、无持久默认
   （可先检查隔离目录 settings.json 是否含 defaultProvider）时，启动后
   模型应为 `deepseek/deepseek-v4-flash`，thinking 默认 `high`。
   观察 `/model` 弹层中当前模型标记与 thinking 显示。

## 4. 逐字符延迟测量（5 次）

- 在 TUI 编辑器中逐字符输入（建议输入 `hello world` 这类 ASCII 与
  一个中文串各一次），对**每次按键**记录从写入到回显的毫秒差
  （Herdr 内可用 `time` 包一层，或人工数帧；优先脚本计时）。
- 共 5 次独立测量，记录每次数值；阈值：单次 < 1.5s 视为通过，
  平均 < 0.5s 为良好；任何一次 >= 1.5s 记为性能问题（见失败分级）。
- 测量时保持 pane 无其他负载；若 Herdr 自身开销影响测量，记录环境
  噪声并复测。

## 5. Unicode 显示与字节连续性

输入并逐项确认渲染（`PI_TUI_WRITE_LOG` 开启，日志路径设在临时目录）：

1. 中文：`你好`
2. 组合字符：`a\u0301`（a + 组合重音）
3. ZWJ emoji：`👨\u200d💻`
4. 国旗：`🇨🇳`

检查：
- 显示无乱码、无替换符 `�`；
- 原始字节流连续性：`PI_TUI_WRITE_LOG` 中
  `e4 bd a0 e5 a5 bd`（你好）必须连续出现，不得出现 `e5 <ANSI> a5`
  这类 ANSI 插入 code point 的模式；ZWJ/国旗字节序列同样必须连续。
- 光标在中文/emoji 上时，光标样式必须包住整个 grapheme，不得截半。

## 6. 真实 DeepSeek 完整编码流程

1. 在隔离临时目录创建 fixture（如 `compute.py`，带 TODO）。
2. TUI 中提交明确编码请求：要求模型依次 read、edit、bash 验证并输出
   完成标记；**限定模型只能操作该临时目录**（提示中写明禁止访问仓库、
   禁止安装依赖、禁止删除外部文件、禁止额外网络）。
3. 等待完成（总超时如 300s；不用固定 sleep 当成功条件），确认：
   - 文件被真实修改（`cat`/`diff` 验证）；
   - bash 验证输出出现完成标记；
   - session JSONL 中 user/assistant/toolCall/toolResult 顺序完整、
     无工具错误（工具顺序以 JSONL 为权威断言）。
4. 同一 TUI 进程内提交第二轮 follow-up（基于首轮修改继续 edit+bash），
   确认上下文带入。
5. 自动化替代：`ADOU_LIVE_SMOKE=1 ADOU_LIVE_JOURNEY=1 ADOU_LIVE_TUI_JOURNEY=1
   make e2e-live` 提供等价的自动旅程；真机 SOP 与自动旅程互补，自动旅程
   通过**不能**替代本文第 6 节的真实交互验收。

## 7. 退出重启与 /resume 恢复

1. `/quit` 正常退出（记录退出码，应为 0）。
2. 重新启动（同隔离 session 目录），用 `/resume` 或 `--resume` 选择
   刚才的会话；确认两轮历史、完成标记与工具结果渲染完整。
3. 恢复后不修改会话文件（记录 `shasum` 前后一致）。

## 8. 证据留存

每次执行保留到报告目录（可归档、可复现）：
- 两份二进制的 `shasum -a 256` 与 mtime；
- `PI_TUI_WRITE_LOG`（去 ANSI 后可作为渲染证据；含 key 的行禁止留存）；
- session JSONL 的条目顺序摘要（只记类型/顺序，不复制消息正文）；
- 5 次延迟测量原始记录；
- 模型/thinking 确认截图或文本；
- 结束时的进程列表与临时目录清理记录。
- 报告尾部列出本次会话的 commit 与二进制 hash，供回溯。

## 9. 失败分级与清理

| 级别 | 定义 | 处理 |
|---|---|---|
| P0 | 输入丢失/崩溃/进程无法退出/密钥泄露风险 | 立即停止，保留现场（日志/crash report），按 blocker 上报；不做后续测试 |
| P1 | 功能错误（文件未改、工具链错乱、恢复失败） | 记录复现步骤与日志，修复后复测同一场景 |
| P2 | 渲染/性能（乱码、延迟超阈值、ANSI 破坏） | 记录证据；属于本文档待跟踪异常类型的先归档 |
| 环境 | pane/网络/终端属性问题 | 记录，重置后重试 |

清理：退出所有 TUI 与遗留进程（`pgrep -lf adou` 逐条确认），删除隔离
临时目录；**不得用宽泛 pkill**（会误杀其他 agent/用户进程）。

## 10. 待跟踪异常（当前已知，不代表通过）

真机观察到的偶发自恢复现象，**未定位根因、不构成通过标准**，出现时
按 P2 记录证据并继续：

- `Error: bad address in system call argument`（偶发于输入/重绘期间，
  单次出现后 TUI 继续工作）
- `Render failed`（渲染帧失败，随后帧自愈）

若上述异常在后续批次被修复或根因定位，本文档对应条目更新为已解决并
注明 commit。
