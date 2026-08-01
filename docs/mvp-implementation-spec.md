# Adou MVP 移植实现规范

状态：实施基线  
文档版本：0.6
日期：2026-08-01

## 1. 文档目的

本文档规定如何把 Pi 的核心 coding agent 能力移植为 Nature 实现，并作为 MVP 的范围、架构、行为兼容和验收依据。

本项目不是重新设计一个“类似 Pi”的简化聊天程序。凡被列入 MVP 的能力，都必须以固定版本的 Pi 源码和测试为行为来源，在 Nature 中重建同等状态机、事件顺序、错误语义和用户交互。允许改变语言、模块边界和底层依赖，不允许静默删掉边界情况。

本文中的规范词含义如下：

- `MUST`：MVP 发布前必须满足。
- `SHOULD`：无明确技术阻塞时必须满足；偏离时要记录原因和替代验证。
- `MAY`：可选实现，不影响 MVP 验收。

## 2. 固定上游基线

移植必须固定到以下源码，不跟随 `vendors/pi` 后续更新漂移：

- Pi 版本：`0.82.1`
- Pi commit：`cced6a21da273b26ee4a23a803680614bbe8dd1e`
- Nature 版本：`v0.7.4`
- Nature commit 基线：`ca3bc393c7a5d6bc65384437e83d71719add1a86`
- Pi 许可证：MIT；移植代码和文档必须保留适当的来源与许可证说明。

当前 Nature 工作区还包含尚未体现在上述 commit 中的 HTTP、JSON、TLS 改进。MVP 开发开始前，必须把这些变更形成可复现的 Nature commit 或补丁基线，至少包括：

- `http.response_t.read()` 流式响应读取、chunked body 和 trailer 支持；
- 严格、无损的动态 JSON 值及增量 `json.stream_parser_t`；
- 默认校验证书链与主机名的 TLS 连接；
- HTTP/TLS 超时、关闭和错误传播。

主要 Pi 行为来源：

- Agent 状态机：[agent-loop.ts](../vendors/pi/packages/agent/src/agent-loop.ts)
- Agent 类型和事件：[types.ts](../vendors/pi/packages/agent/src/types.ts)
- OpenAI Responses：[openai-responses.ts](../vendors/pi/packages/ai/src/api/openai-responses.ts)
- Anthropic Messages：[anthropic-messages.ts](../vendors/pi/packages/ai/src/api/anthropic-messages.ts)
- 自动压缩：[compaction.ts](../vendors/pi/packages/coding-agent/src/core/compaction/compaction.ts)
- 压缩说明：[compaction.md](../vendors/pi/packages/coding-agent/docs/compaction.md)
- 会话格式：[session-format.md](../vendors/pi/packages/coding-agent/docs/session-format.md)
- 文件读取：[read.ts](../vendors/pi/packages/coding-agent/src/core/tools/read.ts)
- 文件写入：[write.ts](../vendors/pi/packages/coding-agent/src/core/tools/write.ts)
- TUI 规范：[README.md](../vendors/pi/packages/tui/README.md)
- 终端适配：[terminal.ts](../vendors/pi/packages/tui/src/terminal.ts)
- TUI 渲染器：[tui.ts](../vendors/pi/packages/tui/src/tui.ts)

## 3. MVP 目标

MVP 必须交付一个可独立运行、运行时不依赖 Node.js、Bun 或 Pi 进程的 Nature coding agent，具备以下能力：

1. 流式模型对话，包括文本、thinking、工具调用参数、usage、结束原因和错误事件。
2. Pi 语义的多轮 agent loop，可执行全部七个内置工具（`read`、`bash`、`edit`、`write`、`grep`、`find`、`ls`）并继续调用模型。
3. 主动阈值压缩和上下文溢出恢复，压缩后完整历史仍保存在会话日志中。
4. Pi 风格的交互式 TUI，支持流式刷新、多行编辑、Unicode、粘贴、取消、窗口缩放和工具结果展示。
5. Pi 核心文件和 shell 工具：UTF-8 文本读取、完整覆写、精确编辑、shell 执行、内容搜索、文件查找和目录列举。
6. 会话的 Pi v3 JSONL 持久化、active leaf 分支与恢复，这是压缩不丢历史所需的基础能力。
7. 通过环境变量或 CLI 配置模型、端点和 API key；秘密不得写入日志或会话。

MVP 首发平台为 macOS arm64 和 Linux amd64。平台层必须隔离，不能把 Darwin 常量散落在 TUI 或 agent 代码中。

## 4. 明确范围

### 4.1 MVP 内

| 能力 | MVP 要求 |
| --- | --- |
| Provider 抽象 | Pi 的统一消息、内容块、usage、stop reason 和流事件协议 |
| Provider 实现 | OpenAI Responses SSE、OpenAI Chat Completions SSE（DeepSeek）、Anthropic Messages SSE |
| Agent loop | prompt/continue、事件流、工具循环、并行与顺序执行、取消、steering、follow-up |
| 工具 | Pi 的 `read`、`bash`、`edit`、`write`、`grep`、`find`、`ls` 核心行为 |
| Compaction | 手动压缩、阈值压缩、overflow 压缩并最多自动重试一次、split-turn 压缩 |
| Session | Pi v3 JSONL 的实现子集：header、message、compaction、session info、parentId/active leaf；完整旧历史不删除 |
| TUI | 终端生命周期、差分渲染、同步输出、编辑器、Markdown、工具显示、footer、队列与取消 |
| Context | 默认 system prompt、工作目录、`AGENTS.md`/`CLAUDE.md` 发现与拼接 |
| 配置 | provider、model、base URL、context window、thinking level、compaction、timeout/retry、会话恢复/分叉、system prompt、`@file` 初始消息 |
| 启动模式 | `--print/-p` 单次纯文本输出、`--continue/-c`/`--resume/-r` 恢复、`--fork` 分叉、`--name` 会话命名、`--no-context-files`、`@file` 初始文本和 `--no-tools/--tools/--exclude-tools` |
| Headless protocol | `--mode json` 的 JSONL 事件流，以及 Pi 核心 RPC 命令（状态、模型、thinking、队列、压缩、bash、session/tree、消息和命令目录） |
| Session utilities | `--session-id`/`--session-dir` 选择记录，`--export` JSONL/HTML，项目 trust 记录和本地 share artifact |

OpenAI Responses、DeepSeek OpenAI Chat Completions 和 Anthropic Messages 都通过验收后，才能称为 MVP 完成。

### 4.2 MVP 外

以下是公开的范围裁剪，不得在交付说明中暗示已经支持：

- 现有 TypeScript extension 的加载、执行和兼容；
- Node/Bun 插件 ABI、npm Pi Packages，以及 TypeScript extension API；
- Nature 自定义扩展的动态加载实现；MVP 只保留稳定的内部接口边界；
- Pi 的远程 GitHub gist 分享、OAuth/account 登录、扩展 UI；Adou 的 `/share` 只生成本地 `.share.jsonl` artifact，`/login` 只实现 API key 路径；项目 trust 目前是本地记录和命令，不模拟 Pi 的完整启动策略；
- Google、Bedrock、Mistral、OpenRouter 专用适配等其他 provider；
- OAuth、远程模型目录、模型下载和 llama.cpp 管理；
- Pi SDK、TypeScript extension API、扩展注册和动态资源加载；JSON/RPC 已作为无扩展的核心 headless 接口纳入，但不承诺扩展 UI 请求和异步 SDK 回调；
- skills、prompt templates、themes、package manager、project trust UI；
- 图片输入、图片文件读取、图片缩放、剪贴板图片和终端 inline image；
- Windows 原生终端；
- sub-agent、MCP、plan mode 和后台 shell。

这里的“文件读取”明确指 UTF-8 文本分支。Pi `read` 工具中的图片分支属于多模态功能，不计入本 MVP。常见图片 MIME 必须返回“当前 MVP 不支持图片读取”的明确错误；其他输入按 Pi 的 UTF-8 replacement-character 语义解码，因此本工具不宣称 binary-safe。shell 工具使用 Nature `process` 协程接口，当前工作目录由受控 `cd ... && exec ...` 保证。

## 5. 不允许的替代或捷径

以下实现即使演示可运行，也不满足本规范：

- 启动 `pi`、Node.js、Bun、`curl` 或其他外部程序代理核心功能；
- 用 libcurl、cJSON、yyjson 等替代 Nature HTTP/TLS/JSON 主路径；
- 收完整个 HTTP body 后再“模拟流式输出”；
- 按网络 chunk 直接解析 JSON，而不处理 SSE framing、UTF-8 边界和跨 chunk 事件；
- 只拼接文本 delta，丢弃 thinking、tool call、usage、stop reason 或错误事件；
- 在上下文过长时直接删旧消息，而不生成 Pi 格式摘要和持久化 compaction entry；
- 把所有工具串行化，或并发完成后按完成顺序写入 tool result，改变 Pi 的顺序语义；
- 通过字节数或 Unicode 码点数近似终端列宽；
- 每次更新清屏重画，造成 scrollback 丢失或明显闪烁；
- 在异常、取消或信号退出后不恢复终端模式；
- 用 shell 命令实现 `read` 或 `write`；
- 为了容易实现而改变 Pi 的错误、截断、取消和事件顺序，却不记录为兼容差异。

## 6. 总体架构

建议的 Nature 模块布局如下；名称可在实现时按 Nature 包规则微调，但依赖方向必须保持：

```text
main.n
src/
  cli/                  参数、环境变量、启动与退出
  config/               provider/model/compaction 配置
  ai/
    types.n             Message、Content、Usage、Model、StopReason
    event_stream.n      有界事件流、终态结果、取消
    sse.n               增量 SSE framing
    provider.n          stream/stream_simple 接口
    providers/
      openai_responses.n
      anthropic_messages.n
  agent/
    types.n             AgentEvent、AgentTool、AgentContext
    loop.n              Pi agent-loop 状态机
    queues.n            steering/follow-up
    session.n           运行编排、持久化、重试、压缩触发
  compaction/
    token_estimate.n
    cut_point.n
    serialize.n
    compact.n
  session/
    entries.n
    jsonl.n
    repository.n
  tools/
    read.n
    write.n
    path.n
    truncate.n
    mutation_queue.n
  tui/
    terminal.n          包装 Nature std/term
    input_buffer.n
    keys.n
    unicode.n
    render.n
    component.n
    editor.n
    markdown.n
    chat_view.n
    tool_view.n
    footer.n
native/
  unicode_icu.c         ICU4C 的窄桥接
tests/
  fixtures/             从 Pi 测试提取的 provider/SSE/session fixture
  conformance/          Nature 与 Pi 行为差分测试
  virtual_terminal/     TUI 快照测试
```

依赖方向：

```text
CLI/TUI -> Agent Session -> Agent Loop -> Provider + Tools
                         -> Compaction -> Provider
                         -> Session JSONL
TUI -> Nature std/term + ICU Unicode adapter
Provider -> Nature HTTP/TLS + Nature JSON + SSE parser
Tools -> Nature fs/os/path
```

`ai`、`agent`、`compaction` 和 `session` 不得依赖具体 TUI 组件。TUI 只能订阅事件，不得成为 agent 状态的唯一存储。

## 7. 依赖决策

### 7.1 网络、TLS 和 JSON

MUST 使用 Nature 原生标准库：

- TCP、DNS、协程调度、HTTP body streaming；
- TLS 证书链和 hostname 校验；
- JSON 编解码、无损数字和值模型；
- 增量 JSON framing。

若 provider 实现暴露标准库缺口，必须优先在 `/Users/liulianfuren/Code/nature` 中补齐通用能力并添加 Nature 测试，不能在 Adou 中复制一套私有 HTTP/JSON 实现。

Adou 自己实现 SSE，因为 SSE 是应用层协议，不需要放入 C。SSE parser 必须支持：

- LF 和 CRLF；
- comment、空行、`event:`、多行 `data:`；
- BOM 和空字段；
- 任意网络 chunk 边界；
- UTF-8 多字节字符跨 chunk；
- `[DONE]` 和 provider 自身终止事件；
- body EOF 前的最后完整事件；
- 大小上限、超时、取消和 backpressure。

### 7.2 POSIX C API

MVP 需要 POSIX C API，但只通过 Nature 标准库中的窄桥接使用。原因是 `termios`、`winsize`、`ioctl`、`sigaction` 的结构体布局和常量具有平台差异，直接在 Adou 的 Nature 文件中复制 C ABI 容易出错。实现位置应是 Nature 的 `runtime/nutils` 加 `std/term`，Adou 只消费稳定的 Nature API。

桥接层只暴露值语义接口：

- 保存并启用 stdin raw mode；
- 恢复原 terminal state；
- 读取终端行列数；
- 注册或转发 `SIGWINCH`、`SIGINT`、`SIGTERM`、`SIGHUP`；
- 判断 stdin/stdout 是否为 TTY；
- 在所有退出路径执行幂等恢复。

终端输入读取本身必须接入 Nature 协程友好的 I/O，不能在调度线程上做无限期阻塞 `read(2)`。

### 7.3 ICU4C

MVP 使用 ICU4C 的 C API，通过 `native/unicode_icu.c` 暴露最小接口。原因是 Pi TUI 使用 `Intl.Segmenter` 做 grapheme/word segmentation，并结合 East Asian Width 与 emoji 规则计算终端列宽。仅调用 libc `wcwidth()` 无法正确处理 ZWJ emoji、regional indicator、variation selector、combining marks 和多码点字素。

分工如下：

- ICU4C：UAX #29 grapheme/word 边界、Unicode 属性查询；
- Nature：ANSI escape 解析、Pi 的 grapheme width 规则、wrap/truncate/slice、编辑器游标逻辑；
- fixture：从 Pi 的 Unicode/TUI 测试复制输入输出，而不是假设 ICU 与 Node 的默认行为永远一致。

首发构建固定 ICU major version，并记录 Unicode data version。若平台 ICU 版本不一致导致 fixture 差异，优先静态链接固定版本。ICU4C 不进入网络、JSON 或 agent 逻辑。

### 7.4 其他 C 依赖

MVP 不引入其他强制 C 依赖。Markdown、SSE、ANSI、key parsing、截断和 session JSONL 均使用 Nature 实现。

## 8. 核心数据模型与流协议

Nature 类型必须表达 Pi 的语义，而不是把所有数据降级为 `{string:any}`：

- `text_content_t`
- `thinking_content_t`
- `tool_call_t`
- `user_message_t`
- `assistant_message_t`
- `tool_result_message_t`
- `usage_t`
- `model_t`
- `agent_event_t`
- `assistant_message_event_t`

`stop_reason_t` 至少包含：

- `pending`
- `stop`
- `length`
- `tool_use`
- `error`
- `aborted`

Provider 流事件必须保持以下协议：

1. `start`
2. 零个或多个 `text_start/text_delta/text_end`
3. 零个或多个 `thinking_start/thinking_delta/thinking_end`
4. 零个或多个 `toolcall_start/toolcall_delta/toolcall_end`
5. 唯一终态 `done` 或 `error`

每个增量事件携带当前 partial assistant message 快照。错误不得以协程未处理异常结束流；必须归一化成 `error` 事件和 `stop_reason=error|aborted` 的最终消息。

事件流使用有界 channel 和独立终态 future：

- 慢 TUI 消费者必须形成 backpressure 或合并纯渲染通知，不能让网络流无限增长内存；
- 终态只能设置一次；
- 取消必须关闭 HTTP response，并最终产生 `aborted`；
- consumer 提前退出时必须释放 response、parser 和 channel。

## 9. Provider 移植规范

### 9.1 OpenAI Responses

实现必须从 Pi 的 `openai-responses.ts` 与 `openai-responses-shared.ts` 搬运以下行为：

- system/developer、user、assistant、tool result 消息转换；
- `stream=true`、`store=false`、`max_output_tokens` 最小值；
- text、reasoning、function call 的增量组装；
- tool arguments 跨事件拼接并在结束时严格解析；
- response id、content index、usage 和 cache usage；
- stop/toolUse/length/error/aborted 映射；
- HTTP 状态、provider error body、超时、Retry-After 和取消；
- session id/cache key 语义中适用于官方 OpenAI endpoint 的部分；
- 请求和响应日志脱敏。

MVP 不实现 OpenRouter、GitHub Copilot、xAI 等 URL/provider compat 分支；这些分支不得混入官方 OpenAI adapter。

### 9.2 OpenAI Chat Completions（DeepSeek）

实现必须从 Pi 的 `openai-completions.ts` 搬运 DeepSeek provider 实际使用的行为：

- `deepseek/deepseek-v4-flash` 固定模型目录项、context window 和 max tokens；
- system、user、assistant、tool result 消息转换，以及 `reasoning_content` assistant replay；
- `stream=true`、`stream_options.include_usage`、`max_tokens`；
- `thinking.type` 和 `reasoning_effort`；
- text、reasoning、function call 的增量组装和严格 tool argument 解析；
- response id、usage、cache usage、stop/toolUse/length/error/aborted 映射；
- DeepSeek API key 认证、HTTP 状态、重试、超时和取消。

不得把 DeepSeek 的兼容字段混入 OpenAI Responses 请求构造器。

### 9.3 Anthropic Messages

实现必须搬运：

- text、thinking、redacted thinking、tool use 的流式内容块；
- tool result 转换；
- cache read/write usage 和 reasoning usage；
- stop reason 映射；
- Anthropic SSE event 顺序、ping/error 事件；
- max token、thinking level/budget；
- 超时、重试、取消和错误归一化。

### 9.4 Provider fixture

禁止在 CI 中依赖付费 API。每个 provider 必须提供录制或手工整理的 HTTP/SSE fixture，覆盖：

- 正常文本；
- UTF-8 与 JSON 跨 chunk；
- thinking + text；
- 单个和多个 tool call；
- tool arguments 被拆成多个 delta；
- usage；
- length stop；
- HTTP 4xx/5xx；
- 流中 error；
- EOF 不完整；
- timeout 和 abort。

真实 API smoke test 在具备密钥时手工执行，但不是普通 CI 的前置条件。

## 10. Agent loop 移植规范

Agent loop 必须保留 Pi 的事件和状态顺序。

普通 prompt：

```text
agent_start
turn_start
message_start(user)
message_end(user)
message_start(assistant)
message_update*
message_end(assistant)
turn_end
agent_end
```

带工具调用时：

```text
assistant message_end
tool_execution_start
tool_execution_update*
tool_execution_end
message_start(toolResult)
message_end(toolResult)
turn_end
turn_start
next assistant...
```

必须实现的细节：

- `continue()` 只能从 user 或 toolResult 上下文继续，不能从 assistant 继续；
- assistant partial message 在流式期间存在于 state 中，结束时原位替换成 final message；
- assistant `error` 或 `aborted` 结束当前 run，不执行工具；
- `length` stop 中出现的所有工具调用都不得执行，因为参数可能被截断；
- 工具参数必须先做 schema 校验；工具不存在、参数错误和执行异常都转成 `isError=true` 的 toolResult；
- 默认工具批次可并行，preflight 按源顺序；完成事件按真实完成顺序；持久化 toolResult 和后续上下文仍按 assistant 中的调用顺序；
- 任一工具声明 sequential 时，整个批次顺序执行；
- 同一文件的 mutation 必须串行，不同文件可并行；
- tool update 只在该次 execute 未结束时有效；
- 只有批次中每个 tool result 都设置 `terminate=true` 时才停止自动 follow-up；
- `before_tool_call`、`after_tool_call`、`prepare_next_turn`、`should_stop_after_turn` 以 Nature callback 接口保留，供未来 Nature 扩展使用；MVP 不动态加载 callback；
- steering 在当前 assistant 与其工具全部结束后注入；follow-up 只在 agent 本来要结束时注入；
- `one-at-a-time` 与 `all` 两种队列模式都要支持；
- `agent_end` 是最后一个 loop event；持久化订阅完成后 run 才算 settled。

## 11. `read` 与 `write` 工具规范

### 11.1 `read`

参数：

```text
path: string, required
offset: number, optional, 1-based
limit: number, optional
```

行为：

- 相对路径基于 session cwd；支持绝对路径、`~` 和输入前导 `@`；
- macOS 路径兼容 NFD、curly quote 和截图文件名中的 narrow no-break space；
- 检查存在性和可读性；
- UTF-8 解码规则必须固定并测试非法字节；
- `offset` 超过文件末尾时返回 Pi 等价错误；
- 用户 `limit` 先应用，再应用全局截断；
- 默认最多 2000 行或 50 KiB，先命中者生效；
- 字节限制按 UTF-8 字节计算，只返回完整行；
- 返回下一次 `offset` 的 continuation notice；
- 第一行单独超过 50 KiB 时返回明确的 `firstLineExceedsLimit` 错误信息，并提示使用 `bash` 的 `sed/head` 读取有界片段；
- 取消产生 `Operation aborted`；
- 结果保留 truncation details，供 TUI 和 compaction 使用。

### 11.2 `write`

参数：

```text
path: string, required
content: string, required
```

行为：

- 相对路径基于 session cwd；支持绝对路径和 `~`；
- 自动递归创建父目录；
- 文件不存在则创建，存在则完整覆写；
- 内容按 UTF-8 写入；
- 成功文本与 Pi 对齐：`Successfully wrote N bytes to PATH`，其中兼容阶段必须测试 Pi 的计数语义；
- 已存在文件以 realpath 作为 mutation queue key，不存在文件以规范化绝对路径为 key；
- 同一路径并发写入严格串行，不同路径允许并发；
- abort 不得提前释放 mutation lock；底层写操作结束后再返回 abort；
- 错误通过工具异常进入标准 toolResult，不返回伪成功内容。

### 11.3 `edit`

参数为 `path` 和 `edits[]`，每项包含 `oldText`、`newText`。所有匹配都针对原始文件计算，`oldText` 必须唯一，编辑之间不得重叠；CRLF 和 UTF-8 BOM 在写回时保留。旧版 Pi 客户端发送的顶层 `oldText/newText` 也接受并转换成单项编辑。

### 11.4 `bash`

参数为 `command` 和可选 `timeout`（秒）。stdout/stderr 合并后按 Pi 的 2000 行/50 KiB 上限截断；非零退出码、信号终止和超时都进入标准工具错误。交互式 `!command` 复用同一执行器，结果写入 Pi `bashExecution` session 消息并进入下一轮模型上下文；`!!command` 保留在 session 和 TUI 中，但按 Pi 语义排除出模型上下文。

### 11.5 `grep`、`find`、`ls`

`grep` 优先使用系统 `rg`（支持 `--hidden`、glob、大小写和 literal/context/limit），不可用时回退到 POSIX grep；`find` 使用系统 find 并排除 `.git`、`node_modules`；`ls` 使用排序的 `ls -A1p`，保留隐藏文件和目录 `/` 后缀。路径参数统一相对 session cwd 解析，命令参数不通过 shell 拼接，避免模式和路径注入。

MVP 保持 Pi 的默认安全模型：`read`/`write` 没有内建权限弹窗，也不偷偷限制在 cwd。系统 prompt 和文档必须明确工具可访问用户进程有权限的路径。

## 12. Session 与持久化

压缩是上下文变换，不是历史删除。因此 MVP 必须有 append-only JSONL session。

MVP 使用 Pi v3 格式的兼容子集：

- header；
- user/assistant/toolResult message entry；
- compaction entry；
- `id`、`parentId`、timestamp；
- compaction usage/details。

MVP 写入 Pi v3 的 parent 链，并维护当前 active leaf；reader 不得因遇到未知 entry type 而破坏原文件。未实现的 entry 必须保留或明确拒绝继续写入，不能静默丢弃。`/tree`、`/fork`、`/clone`、`/resume`、`/import`、`/export` 和 `/name` 通过同一条 JSONL 记录链工作，不能另建一套内存历史。

要求：

- 每个 `message_end` 后追加并 flush；
- session 文件权限默认仅当前用户可读写；
- 写入必须保证单条 JSONL 不被并发交错；
- 尾部半条记录按 crash recovery 处理并报告；
- compaction 后重建 LLM context 为 `compactionSummary + firstKeptEntryId 之后的消息`；
- 原始消息仍保留在 JSONL；
- API key、Authorization header、完整请求 header 不得写入 session；
- 默认目录为 `~/.adou/sessions/`，不直接修改 `~/.pi/agent/sessions/`。

MVP 提供最近 session 恢复、树状 active path 选择以及从当前 leaf fork/clone 的能力；远程分享仍不在范围内。

## 13. 自动压缩规范

默认设置必须与 Pi 对齐：

```text
enabled = true
reserveTokens = 16384
keepRecentTokens = 20000
```

阈值条件必须是严格大于：

```text
contextTokens > contextWindow - reserveTokens
```

### 13.1 Token 计算

- 优先使用最近一个非 aborted、非 error、非全零 assistant usage；
- context tokens 优先使用 `usage.totalTokens`，否则为 input/output/cacheRead/cacheWrite 之和；
- 最近 usage 之后的消息用 Pi 的 `chars / 4` 启发式估算；
- 图片估算在 MVP 中不适用，但数据模型保留相应扩展位置；
- stale pre-compaction usage 不能在压缩后立即再次触发压缩。

### 13.2 Cut point

- 从最新消息向前累计，保留约 `keepRecentTokens`；
- 正常优先在 turn 边界切分；
- user、assistant 和实现的 custom/summary message 可作为 cut point；
- 绝不在 toolResult 处切分；tool result 必须跟随对应 tool call；
- 单个 turn 超过预算时允许从 assistant 处切分，并产生独立 turn-prefix summary；
- 重复压缩从前一 compaction 的 `firstKeptEntryId` 开始更新，而不是只总结新 compaction entry 后的内容。

### 13.3 摘要

摘要使用当前 provider/model 发起独立请求：

- 独立 session/routing id；
- 禁用不可复用的 prompt-cache write；
- 最大摘要输出为 `min(0.8 * reserveTokens, model.maxTokens)`；
- split-turn prefix 最大输出为 `min(0.5 * reserveTokens, model.maxTokens)`；
- 对话先序列化为 `[User]`、`[Assistant thinking]`、`[Assistant]`、`[Assistant tool calls]`、`[Tool result]` 文本；
- tool result 在摘要输入中截断到 2000 字符；
- 使用 Pi 的结构化 Goal/Constraints/Progress/Decisions/Next Steps/Critical Context prompt；
- 重复压缩把 previous summary 放入 `<previous-summary>` 并执行 update prompt；
- 累计 readFiles/modifiedFiles，并写入 summary 和 details；
- 摘要调用的 usage 计入 session totals。

### 13.4 触发与恢复

- threshold：当前 run 正常结束后压缩，不自动继续调用模型；如队列中已有消息则继续交付；
- overflow error：错误消息保留在 session 历史，但从 retry context 移除；压缩后自动重试；
- successful response 的 usage 已超过窗口：压缩但不重试，因为答案已完成；
- 同一个用户 prompt 最多执行一次 compact-and-retry；再次 overflow 必须停止并显示 Pi 等价错误；
- aborted assistant 默认不触发自动压缩；
- compaction 自身可取消，取消后不写 compaction entry；
- 摘要请求遵循 provider retry policy，但 deterministic error 和 abort 不重试。

MVP 同时提供 `/compact [instructions]`，复用同一套 preparation 和 summary 逻辑，不能维护第二套手动压缩实现。

## 14. TUI 移植规范

### 14.1 终端生命周期

启动时：

- 检查 TTY；
- 保存原 termios；
- 进入 raw mode；
- 启用 bracketed paste；
- 隐藏硬件 cursor；
- 查询 Kitty keyboard protocol，必要时使用 modifyOtherKeys fallback；
- 注册 resize 和退出信号。

停止、异常、abort、SIGINT、SIGTERM、SIGHUP 时：

- 停止 provider 和工具协程；
- 关闭 bracketed paste 和 keyboard protocol；
- 显示 cursor；
- 恢复原 termios；
- flush session；
- terminal restore 必须幂等。

### 14.2 输入

- stdin byte stream 必须先经过 input buffer，处理拆分/合并的 CSI、OSC、DCS、APC、SS3、Kitty CSI-u 和 bracketed paste；
- Escape 单键与不完整 escape sequence 使用有限超时区分；
- UTF-8 输入跨 read 边界时不得产生乱码；
- 大于 10 行的 paste 使用 Pi 风格 marker 存放，提交时恢复原内容；
- editor 支持多行、grapheme-safe 左右移动和删除、word navigation、Home/End、undo、kill ring；
- `Enter` 提交，换行快捷键与 Pi 保持兼容；
- streaming 时 `Enter` 入 steering queue，`Alt+Enter` 入 follow-up queue；
- `Escape` abort，并把尚未交付的队列消息恢复到 editor；
- `Ctrl+C` 清空 editor，空 editor 上连续退出行为与 Pi 对齐。

### 14.3 渲染

必须移植 Pi 的三种策略：

1. 首次渲染：直接追加，不清除 scrollback；
2. 宽度变化或 viewport 上方变化：全屏重绘；
3. 普通更新：定位到首个变化行，清除尾部，仅输出变化内容。

每次更新使用 synchronized output：

```text
CSI ? 2026 h
...render operations...
CSI ? 2026 l
```

要求：

- assistant text/thinking/tool-call delta 到达时增量刷新；
- 高频 delta 合并为短 render tick，但不能改变 agent event 序列；
- 每个 component 的可见宽度不得超过 terminal width；
- ANSI SGR 和 OSC 8 不计入可见宽度，跨行时正确重置/恢复；
- CJK、combining mark、emoji、ZWJ、flag、variation selector 按 grapheme 处理；
- resize 后重新 wrap，cursor/viewport 不漂移；
- tool call/result 默认折叠，支持展开；
- Markdown 至少覆盖 Pi 聊天视图实际使用的 heading、list、blockquote、inline code、fenced code、bold、italic、link；
- footer 显示 cwd、model、thinking、上下文使用率和 streaming/compacting 状态。
- footer 的统计顺序与 Pi 对齐：累计 input/output/cache read/cache write/cost、最近一次 cache hit（`CHx.x%`）、上下文百分比；上下文超过 70%/90% 使用 warning/error 色。多 provider 时显示 `(provider)`，已命名 session 追加在 cwd 后。
- working、compacting、branch summary 和交互式 bash 使用 Pi Loader 的 `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` 帧序列；普通 TUI 更新只改变差分行，不重复清屏。

### 14.4 MVP 组件

MUST 实现：

- `Terminal`
- `TUI/Container`
- `Text/TruncatedText/Spacer/Box`
- `Editor`
- `Markdown`
- `Loader/CancellableLoader`
- chat message、assistant message、tool execution、compaction summary、footer 组件

完整的 Pi SelectList/SettingsList 组件和 image component 不属于 MVP；当前实现提供等价的紧凑认证、模型、设置和帮助 overlay，扩展加载仍不属于 MVP。模型选择器支持空参数、精确 provider/model、初始搜索词、循环选择和未认证模型过滤；切换模型前必须已有对应 provider 凭据。

## 15. 配置与 CLI

最小 CLI：

```text
adou [--provider deepseek|openai|anthropic]
     [--model MODEL]
     [--base-url URL]
     [--thinking LEVEL]
     [--session PATH]
     [--continue]
     [--no-session]
```

默认模型为 `deepseek/deepseek-v4-flash`，密钥按已保存的 `~/.adou/auth.json`、环境变量 `DEEPSEEK_API_KEY`/`OPENAI_API_KEY`/`ANTHROPIC_API_KEY` 解析。`--api-key` MAY 支持，但帮助文本必须提示命令行参数可能进入 shell history。

配置必须包含模型 `contextWindow` 和 `maxTokens`。未知 context window 时不得凭空触发 threshold compaction；overflow error recovery 仍可依据 provider error pattern 执行。

MVP 内置 TUI 命令：

- `/model [provider/model]`
- `/scoped-models`
- `/login [provider] [api-key]`
- `/logout [provider]`
- `/compact [instructions]`
- `/new`
- `/session`
- `/settings`
- `/copy`
- `/hotkeys`
- `/resume`、`/reload`（恢复保存 session / 重载项目说明）
- `/help`
- `/quit`

输入以 `!` 开头时在当前 cwd 执行交互式 bash；`!` 的结果写入 `bashExecution` 并加入模型上下文，`!!` 的结果保留在 session/TUI 但排除出模型上下文。

`!` bash 复用模型 bash 的同一个 Nature process 执行器：stdout/stderr 按 chunk 增量显示，运行中显示可取消 Loader，结束时保留截断详情、退出码、超时和 full-output 路径。`/model` 的非精确参数打开带搜索词的选择器；`Ctrl+P`/`Ctrl+Shift+P` 只在已认证模型之间循环。

`/share` 在没有远程凭据时生成与当前 Pi v3 记录对应的本地 `.share.jsonl` artifact，并明确提示远程 GitHub gist 尚未配置；`/trust` 写入 `$HOME/.adou/trust.json`，不把 trust 误当成已完成的完整策略执行。其余 session 管理命令直接操作 Pi v3 JSONL：`/resume`、`/import` 打开已有记录，`/export` 输出 JSONL/HTML，`/name` 写入 session info，`/tree` 选择 active leaf，`/fork` 从历史 user message 分支，`/clone` 创建带 `parentSession` 的新记录。

无扩展 RPC 的响应结构遵循 Pi `rpc-types.ts`：模型和统计使用嵌套对象，`get_entries` 支持 `since` 游标，`get_tree` 返回递归节点，`get_fork_messages` 返回可分叉的 user message；stdin 为管道时必须保留 JSONL 命令，不得先被普通 prompt 读取。prompt、compact 和 bash 在后台协程中运行，主循环可继续接收 `steer`、`follow_up`、`abort`、`abort_retry`、`abort_bash` 与状态查询；响应和事件通过单一输出锁保持 JSONL 行完整。由于 Nature 运行时没有 Pi 的扩展事件总线，文档只承诺无扩展核心命令，不承诺扩展 UI 请求或 SDK 回调。

## 16. Nature 标准库扩展边界

属于通用语言能力的缺口必须放回 Nature：

- HTTP streaming、chunked、trailers、timeout、verified TLS；
- lossless/streaming JSON；
- coroutine-friendly terminal input；
- POSIX terminal mode/window size 的跨平台 std API；
- 必要的 signal 生命周期封装。

只服务 Adou 的逻辑留在本仓库：

- provider payload 和 SSE 事件；
- Pi message/event 类型；
- agent loop；
- compaction prompt 和 session schema；
- TUI component 与 Pi 兼容规则；
- ICU 到 Pi segmentation/width 语义的适配。

Nature 标准库扩展必须有独立 testar/CTest；Adou 不得依赖未测试的私有 runtime symbol。

## 17. 移植方法

每个模块按以下顺序完成：

1. 固定对应 Pi 源文件和测试文件。
2. 提取输入、事件序列、输出、错误和 side effect fixture。
3. 先建立 Nature test，确认在未实现时失败。
4. 用 Nature 实现状态机或算法。
5. 同一 fixture 同时运行 Pi oracle 和 Nature 实现，做结构化 diff。
6. 记录有意的范围差异；未经记录的差异视为 bug。
7. 完成端到端切片后再进入下一里程碑。

允许在开发测试中运行 vendor Pi 作为 oracle，但生产二进制和运行时路径不得依赖 vendor Pi。

## 18. 里程碑

### M0：可复现基线

- 固定 Pi/Nature commit；
- 固化 Nature HTTP/JSON/TLS 补丁；
- 建立 Make + Nature 构建入口；
- 建立单测、fixture 和差分测试框架。

退出条件：干净环境能构建 Nature runtime、Adou 测试和空 CLI。

### M1：AI 流协议

- 核心消息/事件类型；
- event stream、abort、backpressure；
- SSE parser；
- OpenAI Responses 和 DeepSeek OpenAI Chat Completions fixture adapter。

退出条件：所有 OpenAI fixture 在任意 chunk 切分下产生相同的 Pi 事件序列。

### M2：Agent loop 与工具

- agent loop；
- read/bash/edit/write/grep/find/ls；
- schema validation；
- 并行/顺序工具执行；
- steering/follow-up；
- session message 持久化。

退出条件：faux provider 能完成 `read -> write -> final answer`，事件和 JSONL 与 oracle 对齐。

### M3：自动压缩

- token usage/estimate；
- cut point 与 split turn；
- summary/update/turn-prefix prompt；
- threshold/overflow/manual 流程；
- compaction entry 与 context reload。

退出条件：重复压缩、split turn 和一次 overflow retry 全部通过差分测试，旧历史仍在 JSONL。

### M4：终端与 TUI

- POSIX terminal bridge；
- ICU bridge；
- input buffer/key parser/editor；
- component/render engine；
- chat/tool/compaction/footer UI。

退出条件：virtual terminal 快照、Unicode、resize、paste、abort/restore 测试全部通过。

### M5：Anthropic 与集成加固

- Anthropic Messages adapter；
- DeepSeek OpenAI Chat Completions adapter；
- retry/timeout/error normalization；
- OpenAI、DeepSeek 与 Anthropic 端到端 smoke；
- crash recovery、资源释放和性能测试。

退出条件：满足第 19 节全部验收门槛。

## 19. 验收门槛

### 19.1 自动化测试

MUST 全部通过：

- Nature 编译和单元测试；
- HTTP/TLS/JSON 标准库回归测试；
- SSE 任意切分 property test；
- provider fixture conformance；
- agent event-order golden test；
- tool validation/error/abort/concurrency test；
- read offset/limit/50 KiB/2000 行/Unicode/path test；
- write mkdir/overwrite/concurrent same-file/abort test；
- compaction threshold、repeated、split-turn、overflow、stale usage test；
- session crash-tail 和 secret-redaction test；
- TUI ANSI/CJK/emoji/combining/resize/paste/differential-render snapshot test；
- terminal restore 的正常退出、异常、SIGINT、SIGTERM test。

### 19.2 端到端场景

1. 用户提问，assistant 的文本逐 delta 显示而不是请求结束后一次显示。
2. 模型请求读取文件，TUI 展示调用和截断信息，toolResult 回传后模型继续作答。
3. 模型请求写入新目录中的文件，父目录创建，内容正确，session 记录完整。
4. 模型一次返回多个 read/write 调用，执行和结果顺序符合 Pi。
5. 用户在执行期间提交 steering 和 follow-up，交付时点正确。
6. 用户按 Escape，HTTP/tool 协程停止，队列恢复，终端仍可继续使用。
7. 上下文跨 threshold，自动压缩后下一次对话携带 summary 与近期消息。
8. provider 返回 overflow，系统压缩并只自动重试一次。
9. 长中文、combining mark、ZWJ emoji 和 flag 流式输出期间无列宽漂移。
10. 进程被信号终止后 shell echo、cursor 和 raw mode 均恢复。

### 19.3 性能与资源

- 流式响应不能按完整 body 大小线性缓存；只保留 parser 状态、当前消息和 session 所需内容；
- render 更新可合并，但首个可见 delta 不应等待完整响应；
- 连续运行 100 个 fixture session 后无未关闭 fd、response、channel 或 coroutine；
- 50 MiB 工具目标文件仍受 50 KiB read 输出上限约束，不把整个文件复制多份进入 agent context；
- session JSONL 追加期间崩溃最多损坏最后一条未完成记录。

## 20. 风险与处理

| 风险 | 处理 |
| --- | --- |
| Nature HTTP/JSON API 仍有边界缺口 | 在 Nature std 修复并先加回归测试，不在 Adou 绕过 |
| ICU 与 Node Intl 的版本差异 | 固定 ICU/Unicode 版本，以 Pi fixture 作为兼容标准 |
| TUI escape sequence 分片复杂 | 搬运 StdinBuffer 状态机和 Pi 回归 fixture |
| tool-call JSON 被截断后误执行 | `length` stop 的工具一律失败，不执行 |
| repeated compaction 丢上下文 | 保留 previous summary 和 firstKeptEntryId 差分测试 |
| overflow 无限重试 | 每个用户 prompt 最多一次 compact-and-retry |
| 并发写同一文件竞态 | canonical path mutation queue |
| 信号退出破坏 shell | POSIX terminal guard + 幂等 restore + 子进程测试 |
| API 密钥泄漏 | header/body 日志脱敏，session schema 禁止 secret 字段 |
| MVP 范围逐渐包含整个 Pi | 以第 4 节为边界，新增能力必须更新本文档 |

## 21. Definition of Done

只有同时满足以下条件才可宣布 MVP 完成：

- OpenAI Responses、DeepSeek OpenAI Chat Completions 与 Anthropic Messages 三个真实流式协议可用；
- Agent loop 行为不是单轮 demo，工具后续轮、队列、取消均可用；
- read/write 不是 shell wrapper，edit 的唯一替换和 bash 的超时/截断行为通过测试，grep/find/ls 可在 cwd 下稳定运行；
- threshold、overflow、manual、repeated、split-turn 五类压缩均通过；
- 压缩不会删除 session 原始历史；
- TUI 在中文和 emoji 输入/输出下正确，异常退出后恢复 terminal；
- 生产二进制运行时不需要 Node、Bun、Pi、curl、libcurl 或第三方 JSON 库；
- 所有未移植的 Pi 能力与第 4.2 节一致，没有额外未披露差异；session tree、fork/clone、导入导出不得被误列为未实现；
- 构建、测试、配置和已知限制在 `docs/` 中可复现。

达到上述门槛后，下一阶段再设计 Nature 原生 extension ABI；不得为了未来 extension 提前引入 TypeScript 兼容层。
