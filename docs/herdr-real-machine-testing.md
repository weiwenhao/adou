# Herdr 真机测试 SOP（macOS arm64）

> **2026-08-14 更新**：Interactive UI 的 parity 结论改由
> `docs/pi-interactive-parity-audit-plan.md` 管治——真机 pane 只作补充观察，
> 不再单独作为 parity 验收依据；正式对照使用同版本 Pi 0.82.1 oracle 与共享
> PTY 协议（`tests/e2e/lib/{vt_screen,pty_protocol,pty_env_isolation_test}.py`
> + `pi-oracle/{slash_case,slash-baseline}.py`，`docs/pi-batch0-evidence/`）。
> Batch 0 已由主代理验收通过：协议含 env 隔离、语义断言（slash_case.py，
> 含 negative self-tests）、三轮一致性校验与退出码 0 硬性要求，原"只比较
> 三次一样"与 `--side adou` 等误导做法已移除。§11.9 的 UX-002/UX-004"已修复"
> 仅代表当时的真机证据，其修复实现（如硬编码 5 行窗口）未满足该计划 §9 的
> 完成定义，相关 IP-001/002/004 保持开放。Herdr `pi-test`（Pi 0.81.0，w7:pD）
> 保留为历史对照，不覆盖。

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
- `RM-TUI-005`：旧安装版在真实 `/model` 操作压力下触发 Nature runtime
  `out of memory: page allocation failed`。该异常已在 Herdr 中带 debug 文件和
  逐秒 RSS 采样复现；当前构建已连续 100 轮同等操作存活，但 Nature allocator
  在高分配压力下的次级健壮性问题仍未单独裁决。
- 流式请求在过早 Ctrl+C 后仍可能继续消费旧输出。当前实现已在事件流层丢弃
  取消后的迟到增量，并新增 `tests/e2e/tui-stream-cancel.sh` 覆盖本地 SSE
  竞态；真实 DeepSeek 流仍需专项压力复验，暂不把真机风险标成关闭。

若上述异常在后续批次被修复或根因定位，本文档对应条目更新为已解决并
注明 commit。

### 10.1 RM-TUI-005 复现证据（2026-08-18）

在 `w7:pE` 的真实 TUI 中，旧安装版 `/usr/local/bin/adou`（SHA-256 前缀
`ceebb911`，PID 36897）执行 `/model` → Enter → 上/下导航 → Esc 循环。前
10 轮完成，第 11 轮进程退出，shell 原样报告：

```text
runtime: out of memory: page allocation failed
```

逐秒采样 `/tmp/rm-tui-005-memory-20260818.log`：118 个样本，RSS 从
3,440 KiB 增至 74,576 KiB（+71,136 KiB）。同一环境的当前构建
`build/bin/adou`（SHA-256 前缀 `505856`，PID 61655）完成 100 轮后仍存活；
`/tmp/rm-tui-005-memory-built-20260818.log` 的 RSS 峰值为 41,168 KiB，末值
7,056 KiB。对应 debug 日志为 `/tmp/adou-built-rm-tui-005.log`。

代码审计和最小用例见 `tests/nature_repros/README.md`：旧路径在每个模型上
重复 `registry.find_def`，而该函数每次都会重建全部 provider definitions。
当前 commit 已将认证结果提升为 provider 级缓存，因此这条分配热点已从
`/model` 扫描中移除。结论是“Adou 旧热点触发了真实 OOM，Nature allocator
仍有高压下 abort 的待上游评估项”，不是已证实的 Nature 编译器误编译。

## 11. 2026-08-13 Pi/Adou 同指令对照：间歇性重绘损坏

本轮在 Herdr 的 `pi-test`（`w7:pD`）与 `adou-test`（`w7:pE`）pane
中，以相同 cwd、provider、model、thinking 和两轮提示做了控制变量对照。
凭据只通过进程环境传入；命令、输出和本文均不包含 key。

### 11.1 固定环境

- cwd：`/Users/liulianfuren/Code/agent-test`
- provider/model：`deepseek/deepseek-v4-flash`
- thinking：`off`
- Pi：`0.81.0`
- Adou：`main@5da8bb0144b392a01eee76eb0e2c702a3493b721`
- Adou 测试二进制：`build/bin/adou`，SHA-256
  `ea864b88368e1bea628b74cce906b04cf796d711067e3a74d5b481eae2ccb707`
- Nature：`master@311104460332ba04ef65367413b162a66318acac`
  （合并 PR #307）；系统 compiler/runtime 与 master Release 构建 hash
  一致。

两端从新会话依次接收以下完全相同的提示：

1. `What does pi-only say? Reply with only the answer.`
2. `这是 Adou 真机回归测试。必须且只能调用一次 bash，执行 printf
   'MASTER_TLS_TOOL_OK\n'；读取输出后用一句简短中文总结。最后将
   MASTER、TLS、OK 三段用下划线拼接，单独输出一行。不要调用其他工具，
   不要修改任何文件。`

两端都加载了相同项目 Skills；第二轮都只调用一次 bash，工具输出与最终
标记均为 `MASTER_TLS_TOOL_OK`。Pi 第二轮结束时上下文约 23k，Adou 约
20k，因此该对照也跨过了此前单 TLS record 的请求大小边界。

### 11.2 对照结果

| 实现 / 轮次 | 功能结果 | 终端结果 |
|---|---|---|
| Pi，新会话，两轮 | `PI_ONLY_OK`；bash 与最终标记正确 | 正常，无乱码、无系统调用错误 |
| Adou，首次两轮 | `PI_ONLY_OK`；bash 与最终标记正确 | bash 完成后的 thinking/redraw 帧短暂出现非 UTF-8/疑似内存字节，随后自愈；最终答复后显示 `Error: bad address in system call argument` |
| Adou，重新编译后的严格两轮复跑 | 与 Pi 相同，全部正确 | 正常，未复现异常；`PI_TUI_WRITE_LOG` 已启用 |

Adou 首次异常轮仍完成了 HTTPS 响应、bash toolCall/toolResult 和最终答复，
`/quit` 退出码为 0，且没有 `adou-*.ips` crash report 或遗留进程。因此它
不是 Nature #306/#307 的 TLS 回归，也不是 provider/tool 失败，而是
Adou TUI 输出/重绘路径的**间歇性 P2**。一次干净复跑不能关闭间歇性问题。

### 11.3 待修复问题与验收边界

- `RM-TUI-001`：流式回复和 bash 结束交界处，spinner/redraw 帧可能把
  非 UTF-8/非 ANSI 的疑似进程内存字节写入真实终端。Pi 对照未出现。
- `RM-TUI-002`：同一异常之后，Adou 把底层 `EFAULT` 显示为
  `Error: bad address in system call argument`。当前证据不能断言它与
  `RM-TUI-001` 是同一根因，修复前须分别保留断言。

修复不能用吞掉错误或仅删除提示来通过。验收至少要求：

1. 增加不依赖真实 provider 的 PTY/renderer 回归，覆盖 streaming partial
   tool result → tool complete → final assistant → idle 的快速连续重绘；
2. 原始 TUI 字节流必须是有效 UTF-8 与合法 ANSI/控制序列，不得含来源不明
   的二进制片段，也不得出现 `bad address` / `Render failed`；
3. 连续复跑足够次数以覆盖间歇窗口，并保持现有 `/quit`、termios 恢复、
   tool result 和最终答案断言；
4. 修复后用本节相同两轮提示重新执行 Pi/Adou 真机对照。

### 11.4 根因定位与修复状态（2026-08-13，工作区未提交）

根因（基于代码审计与离线复现，EFULT 链路为证据支持的推断）：

- 已证实：`consume_stream` 在主协程上调用 `chat.apply`（bash 输出 `+=` 追加、
  tool detail 替换、messages/active_tools 向量扩容），而 `deferred_redraw`
  在另一协程上渲染同一份 chat 状态；Nature 协程并行执行，双方无共享锁，
  渲染帧可能读到正在重分配的旧缓冲。离线 PTY 复现到同窗口的帧级失败
  （`terminal write made no progress` / `Render failed`），修复后连续多轮
  不再复现。
- 推断（未在真机直接取证）：真机 `bad address in system call argument`
  是 libuv 对失效用户缓冲写 tty 的 EFAULT 报错，与上述"渲染读到已释放缓冲"
  可能一致（写命中已释放缓冲即可触发该错误），但尚未直接证明该链路必然
  导致该 EFAULT；此外 `fs.file_t.write` 复用同一 libuv fs_context
  （req/buf/data_len），帧写与 restore/reenter 控制序列写并发时会互相踩踏，
  且 `terminal.restore()` 在写完序列后才置 `restored/active`，标志位守卫
  无法关闭窗口。

修复（`src/tui/session_view.n`、`src/tui/term.n`、`native/term.c`、
`src/app.n`，工作区未提交）：

1. `chat.apply`/`chat.load_messages`/`chat.clear` 全部在 `render_lock` 内
   执行，与渲染互斥（apply 错误 unlock 后原样传播，保留 app 错误路径）；
   `restore_terminal`/`reenter_terminal`/OSC-52 剪贴板写入与退出路径
   （`restore_terminal_sync`，正常路径可抛、异常路径 catch-ignore，与旧
   语义一致）同样纳入 `render_lock`，帧写与生命周期切换串行化，无嵌套
   加锁；所有加锁路径 catch 内先 unlock 再 throw，避免死锁；
   `reenter_terminal` 持锁时无条件 `renderer.invalidate()`，保证挂起/
   外部编辑器后首帧为清屏全量重绘。
2. `native/term.c` 新增单次非阻塞 `write(2)` bridge（`adou_term_write`）：
   调用期间临时加 O_NONBLOCK（返回前恢复原 flags，恢复失败报错，外部
   editor 子进程不会继承 nonblock），C 内只重试 EINTR；成功返回正 count，
   EAGAIN/EWOULDBLOCK 返回 0，永久错误返回 `-errno`。`term.write` 按
   written offset slice/ref 循环推进（partial UTF-8 按字节安全前进），
   count==0 时 `co.sleep(4)` 有界重试（400 次上限）后抛错，count<0 直接
   抛错保留诊断；`terminal_t.output` 字段移除，完全绕开共享 libuv
   fs_context。
3. `write_terminal` 保留 `quitting`/`restored` 守卫（冗余防御，注释明确
   restored 在序列之后设置，窗口由 render_lock 关闭），跳过帧时同样
   invalidate；`deferred_redraw` 的 render 失败 catch 改用
   `renderer.invalidate()`（清屏全量重绘，含失败帧残留行清理），失败
   重试限速（16ms）且有界（连续 50 次后清 dirty 让出，避免热转）。

回归（2026-08-13 最终离线结果，全部串行、真实退出码 0）：

- `tests/term_test.n` 9/9：含 write 走 fd bridge 写文件、`output_fd=-1`
  永久错误必须抛出的用例，以及固定数值 EINTR/EAGAIN 状态码与重试预算
  用例。
- `tests/renderer_test.n` 13/13：含 `invalidate()` 后相同帧必须
  STRATEGY_FULL 且含清屏序列、随后 force 位复位为 STRATEGY_NONE 的用例。
- `tests/tui_redraw_test.n` 3/3：tool complete→final assistant→idle 全帧
  严格 UTF-8/NUL/失败标记校验；UTF-8 边界按 first byte E0/ED/F0/F4 与
  second byte 判定，含 overlong/surrogate/out-of-range/截断样例；双协程
  加锁压测。
- `tests/e2e/tui-redraw-storm.sh` 连续 5 轮：本地 fixture 快速流式 text→
  bash tool→final answer，校验原始 PTY 字节严格 UTF-8、sync 序列配平、
  无 `bad address`/`Render failed`、bash 工具真实执行。
- `make build` 退出 0。

尚未验收：11.1 Herdr 真机两轮提示对照待主代理在提交后复跑；真机 EFAULT
链路仍属推断，真机复跑通过后才能把 RM-TUI-002 标记为已解决。文档记录到
此为离线证据，不代表真机已验收。

残余风险：命令路径上的 `chat.status/error_message` 单字段写未全部纳入锁
（非流式热路径、常量赋值、torn 读概率极低）。

### 11.5 RM-TUI-003：Ctrl+Z + fg 后 Adou 立即退出（2026-08-13，已修复，工作区未提交）

真机复现（Herdr adou-test 真 pane，两次复现）：空闲 TUI 按 Ctrl+Z 能正确
恢复 shell（进程状态 T）；执行 `fg` 后 Adou 立即 exit 0。开启 debug 的
确定性证据：`tui: terminal input failed: interrupted system call`，随后
`tui: run loop end`。

根因（已证实）：SIGTSTP/SIGCONT 落在阻塞中的 fs 输入 read 上时，runtime
把 EINTR 抛为 "interrupted system call"；`read_terminal` 把任何 read 错误
都当作输入通道失效 → 发送 EOF、关闭 channel → `run_loop` 的
`input_events.recv()` 抛错 → `quitting=true` → run loop 结束 → app 正常
退出路径（restore + exit 0）。与 RM-TUI-001/002 的区分：001/002 是渲染帧
字节与终端写路径的问题；003 是输入读取生命周期问题，独立于渲染，空闲
TUI 即可复现。

修复（`src/tui/term.n`，工作区未提交）：`terminal_t.read` 使用 native
非阻塞单次 read bridge；EAGAIN 以 `co.sleep(4)` 让出调度，固定数值状态码
区分 EINTR 并以 `INPUT_EINTR_RETRY_LIMIT=100` 有界重试，永久错误直接传播，
不再依赖本地化的 `strerror(EINTR)` 文本。

回归：`tests/e2e/tui-job-control.sh`——PTY 内交互 bash 作为 session
leader，Adou 作为其前台子进程（非孤儿进程组，与真机 job-control 语义
一致），验证 Ctrl+Z → shell prompt（"Stopped" + 新 prompt）→ fg → 清屏
全量重绘（`\x1b[2J` 出现在新字节中）→ /quit 可交互 → shell prompt 返回
且 `$?` 为 0；所有 marker 等待只扫描本步新增字节，避免 stale prompt
假绿。有效性已双向验证：把重试上限临时置 0 重建后该 e2e 在 fg 重绘步
确定性失败（reader 死于 EINTR），恢复修复后通过。`tests/term_test.n`
新增分类单测（命中/不命中样例）。串行验证：`make build` 退出 0；
`term_test.n` 9/9；`renderer_test.n` 13/13；`tui_redraw_test.n` 3/3；
`tui-redraw-storm.sh` 5 轮、`tui-job-control.sh` 均通过。

尚未验收：真机 Herdr pane 复跑 Ctrl+Z → fg → /quit 流程；真机复跑通过后
才能把 RM-TUI-003 标记为已解决。

### 11.6 RM-TUI-004：工具调用后的第二段 HTTP 流触发 SIGBUS（2026-08-13，待修复）

真机发现（Herdr `adou-test` 真 pane，修复 RM-TUI-001/002/003 后的二进制
SHA-256 `2314f6ade61495efae2776a1bf1f28142cb867b9faa3427dde0344584f36278a`）：
先输入与 Pi 对照实验完全相同的 `pi-only` 指令，Adou 正确返回
`PI_ONLY_OK`；随后输入要求仅调用一次 bash 的原始回归指令。bash 已真实
执行并返回 `MASTER_TLS_TOOL_OK`，但 Adou 在发起工具结果后的第二个
OpenAI-compatible HTTP 流、收到 200 且进入首个 `response.read()` 后，
被 macOS 以 `Bus error: 10` 终止，未生成最终回答。

确定性证据：

- shell 报告 PID 81880 `bus error`；debug 日志为
  `build/real-machine/adou-final-20260813.log`，末尾依次出现第二次请求
  accepted 200、response 200、`message_start`、`read begin`，之后无
  `read bytes`，也没有 Adou 的正常退出日志。
- macOS crash report：
  `~/Library/Logs/DiagnosticReports/adou-2026-08-13-182737.ips`。异常为
  `EXC_BAD_ACCESS / SIGBUS / EXC_ARM_DA_ALIGN`，fault address
  `0x5f6567617373656d`；faulting thread 栈顶的第一个可符号化 Nature 帧是
  `client.chunked_reader_t.fill_staging`，上层为 `chunked_reader_t.read` →
  `buf.reader.read` → `client.response_t.read` →
  `openai_completions_provider.run_inner`。
- fault address 按小端字节可见为 `message_` 的一部分，crash report 同时
  标注 possible pointer authentication failure；这支持“失效/被覆盖的函数
  或对象指针”方向，但目前还不能仅凭地址断言具体写坏位置。
- 同一轮第一个 HTTPS 请求和 bash 工具均成功，故这不是 master TLS 修复
  失效；崩溃点也不在 TUI write/read bridge，暂不并入 RM-TUI-001/002/003。

### 11.7 RM-TUI-004 收口（2026-08-13，工作区未提交）

复现与判别实验（全部本地 fixture、串行、无真实模型）：

- 本地同类崩溃（独立证据 1）：`~/Library/Logs/DiagnosticReports/adou-2026-08-13-205638.ips`
  ——本地 chunked TUI 压测中 SIGSEGV，faulting 线程为同一 provider 协程
  （`openai_completions_provider.run_inner → assistant_stream_t.push →
  chan.send → rt_chan_send`，KERN_INVALID_ADDRESS 0x8f）：与真机 SIGBUS
  同属"provider 协程触到损坏运行时状态"，但仅一次、非按需复现。
- 本地可重复的输入路径症状（独立证据 2，已排除 harness 自伤）：TUI
  （PTY）+ 同进程两轮 prompt（4 个 chunked 响应）之后，stdin 的 uv fs
  read 线程永久阻塞在 `read(2)`、主协程停在 `input_events.recv()`，
  /quit 无法处理（sample 证据）。已排除：stderr 重定向文件、PTY 持续
  排水、TCSANOW 恢复、debug 隔离；仍复现。**疑似 Nature stdin/fs
  runtime 缺陷**（同进程 ≥2 个 chunked 响应后 stdin 阻塞读完成不再
  触发）；无独立最小复现（无 TUI/无 stdin 读）时不作定论。
- 判别对照（证据 3，干净）：同 fixture 单 prompt（2 流）TUI 10/10；
  headless 单进程两 prompt（RPC，4 流、无 TUI stdin 读）干净；非 chunked
  （EOF 终止）fixture 多次干净。

Adou 范围内加固（已提交到 worktree，未验证可消除 SIGBUS）：

- `src/ai/event_stream.n`：`done` 通道改为只在 `end()`（provider 协程的
  最后一个 stream 操作）关闭，不再在 terminal 事件推送时关闭——消费方
  （agent 循环）必须等到 provider 完成全部 teardown 才能继续/释放
  stream，消除"agent 在 provider 收尾期间释放 assistant_stream"的生命
  周期竞态窗口。本地样本量不足以证明消除，作为生命周期硬化保留。

真机验收（修复版二进制，Herdr `adou-test` pane，真实 DeepSeek，4 个 fresh
session + job-control）：

- Round 1/2/3（SHA-256
  `7058324f25fb7d759e72b4d1b3792415ac8b98653571f20802e966f329196776`）
  各自完整：pi-only（read tool → final `PI_ONLY_OK`）与
  bash 回归（bash tool → `MASTER_TLS_TOOL_OK`，最终行以 JSONL 为权威
  断言同为 `MASTER_TLS_TOOL_OK`）；每轮 debug 计数 4×
  `request accepted`/`received [DONE]`/`stream end`、2×
  `agent_settled`/`session_end`，无 `terminal input failed`/`bad address`/
  `Render failed`；`/quit` 每轮 `$?`=0。
- Round 4（最终二进制 SHA-256
  `c104be3f916e86aa935856ddf076c480f36ea8771383bc57de7f4c78e90ac08f`，
  含 debug 终端隔离改动）：同一两轮指令完整通过（计数同前），且真机
  pane 的 TUI 字节流不再出现 `[adou debug]` 阶梯错列（627 行 lifecycle
  日志全部落入 `ADOU_DEBUG_FILE`）；`/quit` exit 0。
- job-control（SHA-256 `7058324f…`）：Ctrl+Z → shell prompt → fg → TUI
  全屏重绘 → `/help` 渲染 → `/quit` exit 0，debug 无输入失败。
- 4 轮 + job-control 期间无新的 adou `*.ips` crash report。

结论：RM-TUI-004 状态为"经生命周期硬化与真机 4+1 轮复验后未再复现"，
保留根因证据（真机 SIGBUS + 本地 SIGSEGV + 本地输入路径疑似缺陷）与
残余风险（Nature runtime 层缺陷未修，见下）；不声明为已修复。

Nature 层修复建议（未改动 vendors/`nature` repo，需 Nature 侧评估）：
在 nature-lang runtime 检查 libuv fs read（stdin 阻塞读）的完成回调与
tcp/tls 连接拆卸之间的共享状态——复现配方：单进程内两次以上
`Transfer-Encoding: chunked` HTTP 响应（std http client chunked_reader
路径）后，同一进程的 stdin `uv_fs_read` 完成不再触发。候选点：runtime
`rt_uv_fs_read` 的 req 复用/完成投递、以及 tls/tcp 关闭时对全局 loop
状态的影响。

Pi debug 行为对照（同批完成）：Pi 的 CLI `args.ts` 无 `--debug` 开关；
TUI 中仅 `/debug` 命令把调试转储写入 `<agentDir>/pi-debug.log` 文件并在
TUI 内显示 "✓ Debug log written"，终端不被 lifecycle 日志污染。Adou 原
`--debug` 把 `[adou debug]` 行写入 stderr——在 TUI 中 stderr 就是同一
终端，与原地重绘交错成阶梯错列。已按 Pi 行为修复：解析 CLI 后先按
stdin/stdout 和 mode 预设 `debug.set_terminal_output`，并在交互路径（正式
`interactive` 判定后、startup 日志之前）再次确认；`log()` 只写
`ADOU_DEBUG_FILE`，未显式指定时默认落到 `<agentDir>/adou-debug.log`，
stderr 保持干净；headless/RPC/JSON/serve 模式保持原 stderr 行为。每行
保留 `[adou debug] component:` 兼容前缀并追加 `ts`/`pid`，便于按进程和
时间重建事件顺序。覆盖：新增确定性 e2e
`tests/e2e/debug-isolation.sh`（真实代码路径）——Part A 以 PTY 启动 TUI
并断言原始字节流不含 `[adou debug]` 且 `ADOU_DEBUG_FILE` 含 startup/run
loop 行、`/quit` exit 0；Part B 以 `--offline -p` 断言 headless 模式
stderr 仍含 debug 行且文件同样写入。复现夹具
`chunked-sse-fixture.py`/`chunked-tls-fixture.py` 保留用于 Nature 缺陷
复现；曾用于诊断的 PTY 压测脚本因该疑似 Nature 缺陷无法全绿已从仓库
移除，复现配方见上文。

Nature 编译器附带证据（同批，独立于运行时缺陷）：两次 `make build`
首次运行 `Abort trap: 6`，crash report `nature-2026-08-13-205358.ips`（
`free_list_checksum_botch` ← `slice_push` ← `arm64_peephole_pre`）与
`nature-2026-08-13-215318.ips`（`free_list_checksum_botch` ←
`sc_map_put_s64` ← `ssa_rename`），均为编译器构建期堆损坏，第二次
`make build` 成功；不作为 Adou 缺陷。

验证：`make build` 退出 0；`agent_loop_test.n` 17/17、
`agent_session_test.n` 31/31、`chat_test.n` 11/11、`term_test.n` 9/9、
`renderer_test.n` 13/13、`tui_redraw_test.n` 3/3、
`config_context_test.n` 24/24 全部通过；`debug-isolation.sh`、
`tui-redraw-storm.sh`、`tui-job-control.sh`、`skills-reload.sh`、
`help-matrix.sh` 通过。

### 11.8 系统安装与最终验收（2026-08-13 22:45）

- 安装（主代理执行，交互式 sudo，凭据未进入任何命令/文件/日志）：
  `sudo cp build/bin/adou /usr/local/bin/adou` 与
  `sudo cp build/bin/adou-process-group /usr/local/bin/adou-process-group`。
- 安装后核对（本批次验收）：
  - `/usr/local/bin/adou` SHA-256
    `c104be3f916e86aa935856ddf076c480f36ea8771383bc57de7f4c78e90ac08f`
    与 `build/bin/adou` 完全一致；权限 `-rwxr-xr-x root:wheel`。
  - `/usr/local/bin/adou-process-group` SHA-256
    `d2d45a8e2bf8bc5d471f26b23d010891f7ad9fb5ff153442f13489a63675e285`
    与 `build/bin/adou-process-group` 完全一致；权限
    `-rwxr-xr-x root:wheel`。
- 最小可执行性检查（不发起网络请求）：`/usr/local/bin/adou --help`
  输出完整帮助且退出 0；`--version` 输出 `adou 0.1.0-dev` 且退出 0。
- 收口状态：`git diff --check` 无空白错误；`git status --short` 无
  凭据、无 `vendors/` 改动；未 commit/push（worktree 留待审查）。

### 11.9 真实交互巡检批次（2026-08-14，UX-001..004）

上一轮（11.8）仅覆盖预设 happy path（真机 pi-only + bash 回归 + job-control），
对 slash 菜单、model selector、输入区视觉与动态命令元数据覆盖不足；本批次
按"系统交互矩阵 + Pi 逐项对照 + PTY 原始序列"重做。真机 pane：Adou
`w7:pE`（独立重启，fresh session，凭据由 Adou 自身读取 auth，命令不含
key）、Pi `w7:pD`（idle 会话，权威对照）。测试控制纪律：每次 pane
操作前确认前台进程；活动 TUI 上不用 `pane run`；每 case 后恢复状态。
曾有一次在活动 TUI 上误发命令文本（被模型当作聊天输入）的无效样本已
排除，不计入任何证据。

#### UX-001 /model（及 slash 菜单选 model）卡死 — 未复现，保持开放（P1）

基线复现尝试（修复版二进制 SHA-256 `a3b686e7…`，真机）：
1. 新会话 `/model` + Enter 打开 overlay，↑↓ 导航（Model Name 行随动），
   Esc 取消，进程存活；
2. 打开后键入搜索词 `deep` 筛选出 deepseek 模型，Enter 选择成功（状态行
   `Model: deepseek/deepseek-v4-flash`），overlay 关闭，进程存活；
3. slash 菜单路径：`/` 打开菜单 → 菜单 Enter 完成命令 → overlay 打开/关闭
   正常；`/model` 经模糊匹配落到 `/scoped-models`（顺序差异见 UX-002 附注），
   该 overlay 渲染与取消正常；
4. 同会话先完成 2 轮真实 DeepSeek 往返（4 个 chunked 流，PI_ONLY_OK +
   MASTER_TLS_TOOL_OK×2）后再执行 `/model`：菜单打开/导航/Esc 全部响应，
   输入路径存活。

结论：`/model` 各生命周期（打开/搜索/导航/选择/取消）在 4 个场景均未卡死。
用户报告的卡死最可能属于 RM-TUI-004 证据链中的"疑似 Nature stdin/fs
runtime 输入死亡"（间歇性，按需不可复现）；本项保持开放，不做 Adou 侧
修改，待 Nature 侧修复或确定性复现后关闭。附 PTY 超时断言（见 11.9 测试节）。

#### UX-002 slash 菜单候选可见行/分页 — 已确认并修复（P2）（2026-08-14 撤销为开放，见文首更新）

基线（同 pane 尺寸，52 行×约 200 列）：Adou 输入 `/` 后渲染全部候选
（实测 50 行，含 27 个 `/skill:*`），无分页/滚动指示；Pi 只显示 5 行
（settings/model/scoped-models/export/import）+ 暗淡 `(1/53)` 分页指示，
支持筛选、↑↓、Esc、Enter。

修复（`src/tui/session_view.n` `render_command_menu`）：可见窗口固定 5 行
（跟随选中项滚动），窗口非边缘时渲染暗淡 `...` 行，末尾暗淡
`(selected+1/total)` 分页指示（Pi 同款 `(1/N)`）。真机复验：`/` →
5 行 + `...` + `(1/52)`；导航至中部显示 `(7/52)`，顶部 `(1/52)`；筛选
`m` → 12 项 + `(12/12)`；Esc 关闭、Enter 完成，均正常。

附注（顺序差异，非缺陷）：Adou 的 fuzzy 匹配对 `/model` 的排序会把
`/scoped-models` 排在前（菜单 Enter 落到 scoped-models）；直接键入完整
`/model`+Enter（无菜单）打开 model selector。与 Pi 的 fuzzy 排序未逐字
对齐，记录不改（formatter 级差异不列为 blocker）。

> **2026-08-14 撤销附注**：该附注与 IP-001（P0，"`/model` 可进入错误
> overlay"）冲突，作废；硬编码 5 行修复未实现 Pi 的 3–20 可配置契约
> （IP-002）。两者按审计计划 Batch 1 重新验收。

#### UX-003 输入区常驻白色块/白色输入框 — 静态结构未复现差异，保持开放（P2）

Pi 源码对照（vendors/pi `packages/tui`）：editor 假光标渲染
`\x1b[7m<grapheme>\x1b[0m`（字符上）与 `\x1b[7m \x1b[0m`（EOL），与
Adou `theme.cursor` 完全同构；硬件光标默认隐藏（`\x1b[?25l`，
`PI_HARDWARE_CURSOR=1` 才显示）；Pi 焦点态在假光标前发射零宽 IME 标记
`\x1b_pi:c\x07` 并据此定位（隐藏的）硬件光标，退出前用普通空格覆盖
假光标格。

Adou 真机/PTY 取证（8 个状态：空输入、1 个 ASCII、多 ASCII、中文、
左右移、退格、长文本换行、菜单开关前后）：每帧恰 1 个反色格（光标
所在格），无残留反色块；原始 PTY 序列：启动 `?25l`×1，全程无
`?25h`、无 DECSCUSR、无 IME 标记；光标于字符上/EOL 的渲染与 Pi 一致。

结论：静态 ANSI 结构与原始 PTY 序列（启动 `?25l`×1、全程无 `?25h`、
无 DECSCUSR）均未复现"常驻白色输入框"；Pi 与 Adou 默认都隐藏硬件光标并
绘制 inverse 单元格，无双块叠加。与 Pi 的结构性差异记录在案：Pi 焦点态
发射零宽 IME 标记 `\x1b_pi:c\x07` 并定位（隐藏的）硬件光标，退出前用
普通空格覆盖假光标格；Adou 均无。**焦点态视觉差异待确认**：用户聚焦
pane 的观感差异需要在同一焦点几何下做逐帧对照后才能定性；本项不改
默认行为（不引入旁路开关），保持开放。

#### UX-004 /skill:* 菜单描述全部显示 "Quit Adou" — 已确认并修复（P2）（2026-08-14 重审：修复方向保留，契约按 Batch 1 复核）

基线：`/` 菜单中 27 个 `/skill:*` 候选描述全为 "Quit Adou"。
根因：`command_names()` 只提取动态命令名字，`command_description()`
是静态映射且默认返回 "Quit Adou"，未查询
`dynamic_commands_cache`（其中 skill/prompt 描述齐全）。

修复（`src/tui/session_view.n` `command_description`）：先按名字在
`dynamic_commands_cache` 中解析描述，命中即返回；静态命令回退到原映射；
未命中返回空（不再输出误导性 "Quit Adou"）。真机复验：
`/skill:pi-only  exists only in the pi layer`、`/skill:lark-approval
 飞书审批 API：…` 等真实描述正常显示。

> **2026-08-14 复核**：该修复仍以静态映射 + 缓存查询实现，未建立 Pi 的
> autocomplete item 契约（name/description/argument hint/source tag/kind，
> IP-004）；未知动态命令返回空而非错误默认值的结论保留，契约完整性按
> 审计计划 Batch 1 验收。

#### 本批新增确定性回归

- `tests/e2e/slash-menu.sh`：PTY 启动 TUI → `/` 菜单断言可见候选行数
  ≤5（含选中行）、存在 `(1/N)` 分页行、`/skill:` 项描述非 "Quit Adou"、
  ↑↓ 边界（顶部/底部不越界、分页跟随）、Esc 关闭、Enter 完成、菜单
  关闭后编辑器恢复输入；全部断言作用于逐步新增字节。
- selector 不挂死断言并入该 e2e：`/model` 打开 → 2s 内渲染出模型列表 →
  ↑↓ → Esc，全程进程存活（waitpid 检查），超时即 FAIL。
- 输入区原始序列断言（并入 `tests/e2e/debug-isolation.sh` 同款 harness，
  新脚本 `tests/e2e/input-cursor-seq.sh`）：启动/输入/光标移动期间原始
  PTY 字节中 `?25h` 计数为 0、`?25l` 仅启动一次、无 DECSCUSR、每帧
  反色格 ≤1。
