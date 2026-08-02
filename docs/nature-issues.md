# Nature 问题清单

本文记录 Adou 移植过程中实际触发的 Nature 编译器、解析器、运行时和标准库问题。Adou 不依赖 `nature fmt`，格式化器专属问题不纳入本清单；Nature 源码直接遵循 `vendors/nature_cases/` 中可编译的正确格式。每项问题必须保留最小复现、实际结果、预期结果和当前绕过方式；绕过方式不视为最终修复。

- 首次记录日期：2026-07-30
- 复现版本：Nature 0.7.4
- Nature 源码：`/Users/liulianfuren/Code/nature`
- 状态约定：`待最小化`、`当前未复现`、`已提交 issue`、`已最小化`、`修复中`、`已修复待回归`、`已关闭`

## NAT-006：函数调用参数中直接使用结构体字面量会误解析逗号

- 分类：parser
- 状态：当前未复现（2026-08-01 复核）
- 现象：历史上把结构体字面量直接作为函数调用参数时，结构体字段逗号可能被误认为调用参数分隔符，出现非预期解析错误。
- 当前复核：官方案例 `vendors/nature_cases/20240519_00_struct_nest_call/main.n` 编译运行通过，未能复现解析错误。
- 预期：嵌套字面量内部的逗号只属于字面量语法。
- 当前绕过：先把结构体字面量赋给局部变量，再传入函数。
- 修复方向：检查 call arguments 与 struct literal 的 Pratt/递归下降边界，并增加嵌套字面量测试。

## NAT-007：尾随逗号在函数形参声明中产生误导性类型错误

- 分类：parser / diagnostics
- 状态：已提交 issue [#259](https://github.com/nature-lang/nature/issues/259)
- 现象：函数定义最后一个参数带尾随逗号时，报 `ident ')' is not a type`，没有指出该位置不支持尾随逗号。
- 预期：若语言支持尾随逗号则正常解析；若不支持，应给出明确的语法诊断。
- 当前绕过：函数定义形参末尾不写逗号。
- 修复方向：决定并统一函数声明、调用、构造器和字面量的尾随逗号规则。

## NAT-008：结构体字段缺省值诊断存在拼写错误

- 分类：diagnostics
- 状态：已关闭
- 现象：缺少必填字段时报 `struct filed 'conn' must be assigned default value`，其中 `filed` 应为 `field`。
- 预期：诊断文本拼写正确，并能指出结构体名和构造位置。
- 修复内容：C 编译器诊断中的 `struct filed` 已改为 `struct field`，并同步更新两个现有错误快照；NLS 诊断原本已经正确。
- 回归：Nature `20250311_00_interface` 和 `20250827_00_recycle_type` 均通过。

## NAT-009：HTTP timeout 只覆盖连接阶段，不覆盖响应流读取

- 分类：standard library / coroutine networking
- 状态：已关闭
- 现象：`http.client.new().timeout(ms)` 原先只把超时传给 TCP/TLS connect。连接成功后，响应状态行、header 或 SSE body 如果不再到达数据，读取协程可以永久等待。
- 预期：同一个请求超时配置至少作为 response header/body 的 idle read timeout；每次成功读取后重新计时，超时必须关闭底层连接并唤醒读取协程。
- 当前修复：`connable` 增加 per-connection read timeout；TCP/TLS runtime 在同一次 read wait 上启动可复用 libuv timer，超时直接唤醒原读取协程。HTTP 为响应头和每次流式 body read 统一归一化 `HTTP response read timeout`。
- 回归：独立 Nature feature `20260730_00_http_timeout.testar` 覆盖 `test_stream_read_timeout` 和 `test_response_header_timeout`；Nature 自带测试与 Adou provider timeout fixture 均通过。
- 后续评估：写请求 body 的超时和更底层 TCP/TLS deadline API 是否需要统一，避免每个上层协议重复 watchdog。

## NAT-010：跨协程关闭正在读取的 TCP 连接会破坏 waiter 并触发 libuv 断言

- 分类：runtime / coroutine networking / resource lifecycle
- 状态：已关闭
- 现象：协程 A 阻塞在 `conn.read()` 时，协程 B 调用同一个 `conn.close()`。TCP runtime 的 `inner_conn_t.co` 只有一个槽，close 会把它覆盖为协程 B；随后 read/close callback 可能唤醒错误协程，并出现重复 `uv_close`，最终触发 libuv `Assertion failed: (0), function uv_close`。
- 预期：close 可以安全取消另一协程中的 pending read；每个 pending operation 必须保存自己的 waiter，handle close 必须幂等。
- 当前修复：TCP/TLS 为 pending read 保存独立 `read_co`，read operation 持有连接引用，close 不再覆盖 waiter；close 会取消已开始的 libuv read，并让尚在异步队列中的 read 自行观察 closing 状态后唤醒。该 queued-read 引用避免 close callback 先释放连接后 `uv_async_tcp_read` 再访问的 SIGSEGV。
- 回归：Nature `test_cross_coroutine_close_pending_read` 和 Adou `abort closes a native HTTP stream with a pending read` 均通过；后者真实覆盖 `start -> pending read -> abort -> error(aborted)`。
- 后续：write/connect waiter 仍应按同一模型拆分，当前 provider 在 response 建立后取消的关键路径已关闭。

## NAT-011：runtime target 与 install 使用不同的静态库路径

- 分类：上游 build / install
- 状态：已提交 issue [#260](https://github.com/nature-lang/nature/issues/260)
- 现象：上游构建流程生成 `build/lib/<platform>/libruntime.a`，但安装步骤从源码树 `lib/<platform>/libruntime.a` 安装。若不手工同步，install 会悄悄打包旧 runtime。
- 预期：install 必须直接安装 target artifact，或 runtime target 自动更新唯一的规范输出位置。
- 当前绕过：构建后手工把 target artifact 同步到 install source，再执行 staged install。
- 修复方向：让 install 直接引用 target artifact，移除源码树与构建树双份静态库真源。

## NAT-012：buf.reader.read_until 吞掉所有底层 I/O 错误

- 分类：standard library / buffered I/O
- 状态：已关闭
- 现象：`read_until` 对 `fill()` 的任意 error 都设置 `has_error=true` 并返回已缓冲内容，因此 timeout、connection reset 等错误被当成 EOF，HTTP parser 会继续下一次 read。
- 预期：只有 EOF 可以返回 delimiter 之前的 partial bytes；其他 I/O 错误必须原样传播。
- 当前修复：`read_until` 改为 errable 返回类型，只吞 `EOF/end of file`，其余错误 `throw`。
- 回归：HTTP response-header timeout fixture 穿过 `buf.reader` 并得到 `HTTP response read timeout`，Nature 自带测试已通过。

## NAT-013：TCP server close 可先于 accepted connection close callback 释放 freelist

- 分类：runtime / TCP server lifecycle
- 状态：已关闭
- 现象：accepted connection 执行 `conn.close()` 后立即执行 `server.close()`，server 路径先释放 `inner_server_t`；稍后 connection close callback 仍会通过 `conn->server` 访问 freelist，可能触发 libuv 断言或 use-after-free。
- 预期：server close 等待/引用计数所有 active accepted connections，最后一个 connection callback 完成后再释放 server 状态。
- 当前修复：`inner_server_t` 增加 `closing`、`listener_closed` 和 active connection 引用计数；listener 与 accepted connection 全部结束后才释放 server 和 freelist。`server.close()` 不再在调用 `uv_close` 前释放 `inner_server_t`，也不再由 callback 二次释放。
- 回归：HTTP timeout fixture 已移除 `conn.close()` 与 `server.close()` 之间的延时，并通过 Nature 自带测试；Adou 七项真实 HTTP/SSE provider 测试连续通过。

## NAT-014：channel close 不唤醒已阻塞的 sender/receiver

- 分类：runtime / channel / coroutine scheduling
- 状态：已关闭
- 现象：`rt_chan_close` 原先只设置 `closed=true`，不处理 `recvq`/`sendq`。如果协程已经阻塞在 `recv()`，另一个协程 close channel 后它会永久沉睡；Adou 的 `stream.result()` 在 provider 结束前开始等待时稳定复现。
- 预期：close 唤醒全部阻塞 sender/receiver；receiver 在缓冲耗尽后得到 `recv on closed channel`，sender 得到 `send on closed channel`，select waiter 只能被选中一次。
- 当前修复：close 在 channel lock 下弹出两类 waiter，设置 `success=false` 并唤醒；send/recv 在回收 `linkco_t` 前保存 success，修复原有的回收后读取。
- 回归：Nature `20260730_01_chan_close.testar` 覆盖 blocked recv/send；Adou event stream 新增“先等待 result、后到 terminal”回归。

## NAT-015：复杂函数内直接解引用动态 JSON 子值会生成崩溃代码

- 分类：compiler / code generation / register allocation
- 状态：当前未复现（2026-08-01 复核）
- 现象：JSON Schema coercion 函数同时包含递归、嵌套 map 遍历、同名局部变量和 `ref<json.value_t>` 解引用时，编译成功，但第一轮属性处理在运行时以 SIGSEGV（exit 139）退出。单独测试 map 迭代、ref 解引用、递归以及迭代中覆盖 map value 均不崩溃，说明还需要继续缩小触发组合。
- 预期：合法 Nature 程序不得生成进程级崩溃；若别名或解引用不合法，编译器应在编译期给出诊断。
- 当前绕过：JSON Schema coercion 不直接解引用 map/array 中的动态值，改为通过 `json.value_t.stringify()` + `json.parse()` 复制后递归；该方式已通过 coercion/required/array fixture。
- 当前复核：递归、嵌套 map/array 和动态 JSON 子值直接解引用样例运行 20/20 次通过，未得到稳定崩溃。
- 修复方向：从原始 schema coercion 函数做二分最小化，重点检查嵌套作用域同名局部变量、union/struct 大值传参与 `ref` 解引用共同出现时的寄存器分配和栈槽生命周期；最小化后加入 Nature feature 回归。

## NAT-016：含原子字段的全局结构体未按字段要求对齐

- 分类：compiler / global layout / runtime mutex
- 状态：已提交 issue [#261](https://github.com/nature-lang/nature/issues/261)
- 现象：把 `co.mutex.mutex_t{}` 作为全局值后取地址并调用 `lock()`，链接后的地址可能只按 4 字节对齐。LLDB 捕获到 `rt_mutex_lock` 的 ARM64 `casal` 访问地址末位为 `0x...57c`，触发 `EXC_BAD_ACCESS (code=257)` / SIGBUS（exit 138）。相同程序是否崩溃会随其他全局符号布局变化，是典型的对齐敏感 Heisenbug。
- 预期：编译器布局每个全局值时必须满足其自然对齐；包含 `i64`/原子字段的结构体至少按 8 字节对齐，不能只连续拼接全局数据。
- 当前绕过：mutation queue 的 registry 改为惰性 `new registry_t()`，mutex 位于 GC heap 并获得正确对齐；初始化到首次可能 yield 之前完成，符合 Nature 当前单调度线程协程模型。
- 诊断证据：调用栈为 `rt_mutex_lock -> mutex_t.lock -> mutation_queue.acquire -> write.execute`，faulting 指令为 ARM64 `casal x8, x9, [x0]`。
- 修复方向：检查 Mach-O/ELF 全局区 offset 分配和 symbol alignment，按 `reflect.type_t.align`（或等价 ABI alignment）对每个 global round-up；增加前置 `u8` 后声明全局 mutex/i64 struct 并真实 lock/unlock 的 feature 回归。

## NAT-017：全局 nullable union 的 `null` 初始化没有构造 union 容器

- 分类：compiler / global initializer / union ABI
- 状态：已提交 issue [#262](https://github.com/nature-lang/nature/issues/262)
- 现象：声明 `ref<registry_t>? global_registry = null` 后执行 `if global_registry is ref<registry_t> ...`，`union_is` 收到空的 union 容器指针并从地址 `0x18` 读取类型信息，触发 SIGSEGV（exit 139）。nullable 作为结构体字段和局部变量可用，但全局初始化路径没有生成运行时 union 表示。
- 预期：全局 nullable union 的 `null` 必须生成与局部/字段相同的合法 union value；`is` 检查 null 只返回 false，不得解引用空容器。
- 当前绕过：惰性 singleton 使用全局 `anyptr = 0` 保存 registry 指针，非零后显式转回 `ref<registry_t>`。
- 诊断证据：LLDB 调用栈为 `union_is -> mutation_queue.get_registry -> mutation_queue.acquire`，fault address 为 `0x18`。
- 修复方向：检查 global initializer 对 union/null 的 data emission 与 relocation；新增全局 `int?`、`ref<T>?` 的 null 检查、赋值后检查和 GC 扫描回归。

## NAT-018：通过结构体 vector 字段指针调用 `push` 不更新原字段

- 分类：compiler / pointer semantics / vector mutation
- 状态：已提交 issue [#263](https://github.com/nature-lang/nature/issues/263)
- 现象：把 `&result.messages` 作为 `ptr<[message_t]>` 传入辅助函数，并执行 `(*messages).push(value)`，代码正常编译运行，但原结构体的 `messages` 长度仍为 0。后续 CLI 测试确认局部 vector 的地址传入 helper 后同样丢失 `push`，并非只限结构体字段。把 append 逻辑放回持有 vector 的函数内后立即恢复正常。
- 预期：对 vector 字段取得的指针解引用后执行原地 mutation，必须更新该字段；如果这种写法不受支持，编译器必须拒绝而不是静默丢失写入。
- 当前绕过：session context、CLI 诊断和项目上下文读取都由调用者直接向 vector `push`，helper 通过返回值传回单个错误，不传 vector 指针。
- 修复方向：分别最小化局部 vector 与结构体 vector 字段的 `ptr<[int]>` helper，检查 vector header copy、解引用 method receiver lowering和写回；增加 length/content 双重断言回归。

## NAT-019：`path.dir("/")` 返回空串并使祖先遍历跳回当前目录

- 分类：standard library / path
- 状态：已提交 issue [#264](https://github.com/nature-lang/nature/issues/264)
- 现象：标准库 `path.dir` 先删除末尾 `/`；输入恰好为 `/` 时执行 `slice(0, 0)` 并返回空串。继续执行 `path.dir("")` 会得到 `.`，使从绝对路径向根目录遍历的代码意外跳回进程当前工作目录。Adou 的 `AGENTS.md`/`CLAUDE.md` 发现因此重复加载了工作区文件。
- 预期：与 Go `path.Dir` 及该函数注释一致，`path.dir("/")` 应返回 `/`，根目录应为祖先遍历的不动点。
- 当前绕过：项目上下文发现到达 `/` 后直接结束，不再调用 `path.dir`。
- 修复方向：在裁剪尾斜杠前单独处理全斜杠根路径，并增加 `"/"`、`"//"`、`"/tmp"`、空串和相对路径回归。

## NAT-020：vector 字段传给返回多 vector 结构体的函数后字段访问崩溃

- 分类：compiler / code generation / aggregate return / vector lifetime
- 状态：当前未复现（2026-08-01 复核）
- 现象：方法把 `self.buffer` 作为 `[u8]` 值传给纯函数，该函数返回包含两个 vector 字段的结构体；返回后再次执行 `self.buffer.len()` 稳定 SIGSEGV（exit 139）。返回值中的另一个 vector 可正常遍历，且在调用前访问字段正常。把字段先移到局部变量、将字段清空，再调用纯函数，最后只写回返回的 remainder 可以避开崩溃。
- 预期：按值传递 vector 不应让原结构体字段变成非法 header；aggregate return 也不得破坏 receiver 或实参生命周期。
- 当前绕过：TUI input buffer 在调用 escape-sequence extractor 前先把 field header 保存到局部并清空字段，处理完成后把 remainder 作为最后一步写回，不在调用后读取旧字段。
- 当前复核：两个 vector aggregate-return 变体各运行 30/30 次通过，未复现字段访问崩溃。
- 修复方向：最小化为 `state_t { [u8] buffer }`、`result_t { [string] output; [u8] remainder }` 和返回 aggregate 的 helper，检查 hidden sret 参数、receiver 保存、vector header move/copy 与寄存器分配。

## NAT-021：同一结构体的多个默认空 vector 字段共享可变 header

- 分类：compiler / default initializer / vector aliasing
- 状态：当前未复现（2026-08-01 复核）
- 现象：结构体同时声明 `sequences: [string] = []`、`pastes: [string] = []`，另一个状态结构体也含默认 `buffer: [u8] = []`。构造后向 `buffer` 写入 7 个字节，尚未写入的 `result.sequences` 已出现相同 7 项；随后正常追加 6 个字符后长度为 13。说明多个默认空 vector 字段引用了同一可变 header，而不是各自的零值 header。
- 预期：每个结构体实例、每个 vector 字段都必须拥有独立的 length/capacity header；底层空 data 可共享，但任何一次 `push` 只能改变目标字段。
- 当前绕过：TUI input buffer 的构造、结果构造和 reset 全部用独立 `vec<T>.cap_of(...)` 显式初始化，不依赖多个 `=[]` 默认字段。
- 当前复核：跨实例、跨结构体默认空 vector 样例运行 30/30 次通过，未发现 alias。
- 修复方向：最小复现使用两个含不同元素类型和相同元素类型的空 vector 字段，分别检查实例内、实例间 alias；审计 struct default constant materialization 和 vector header copy。

## NAT-022：把可变结构体引用传给返回 vector 的 errable helper 会静默终止进程

- 分类：compiler / code generation / reference lifetime / aggregate return
- 状态：当前未复现（2026-08-01 复核）
- 现象：ANSI 换行函数把 `ref<tracker_t>` 传给一个返回 `[string]!` 的 helper；helper 调用 receiver 方法更新 tracker 并返回两行后，测试进程在调用点静默终止，既没有 panic 文本也没有非零退出码，后续测试的 `OK` 和汇总均未输出。相同输入改为把 tracker 的标量/string 字段按值传入、在 helper 内新建独立 tracker，并由调用者随后更新原 tracker 后正常完成。
- 预期：合法引用跨 errable aggregate-return 调用必须保持有效；若触发 panic，测试 runner 必须输出诊断并返回非零状态，不能把未完成测试报告为成功进程。
- 当前绕过：长单词换行 helper 只接收 tracker 快照字段，在 helper 内构造独立引用；返回后由调用者重放 token 更新外层 tracker。
- 当前复核：`ref<tracker_t>` 传入返回 `[string]!` helper 的样例运行 30/30 次通过，未复现静默终止。
- 修复方向：最小化为含 string/bool 字段的 `tracker_t`、修改 receiver 的 helper 和 `[string]!` 返回值；分别验证零/一/多元素返回、是否 errable、是否发生 GC safepoint，并检查测试 runner 对协程异常退出的状态传播。

## NAT-023：两个原生 bool 调用直接参与 `&&` 时结果错误

- 分类：compiler / code generation / native bool expression
- 状态：当前未复现（2026-08-01 复核）
- 现象：在真实 TTY 中，`term.is_tty(term.STDIN)` 和 `term.is_tty(term.STDOUT)` 分别返回 `true`，但把两个调用直接写成 `term.is_tty(term.STDIN) && term.is_tty(term.STDOUT)` 得到 `false`。问题在 `app.run` 的交互模式判断中稳定复现；拆成局部变量后再用条件语句组合可绕过。
- 最小复现：
  ```nature
  bool stdin_tty = term.is_tty(term.STDIN)
  bool stdout_tty = term.is_tty(term.STDOUT)
  println(stdin_tty)   // true
  println(stdout_tty)  // true
  bool both = term.is_tty(term.STDIN) && term.is_tty(term.STDOUT) // false
  ```
- 预期：原生函数返回的 `bool` 与普通局部 `bool` 在逻辑与表达式中具有相同语义；两个 `true` 的结果必须为 `true`。
- 当前绕过：先分别保存原生调用结果，再通过 `if !stdout_tty { interactive = false }` 组合状态，避免原生调用直接出现在 `&&` 两侧。
- 当前复核：伪 TTY 中两个 `term.is_tty` 原生调用及其直接 `&&` 结果均为 `true`，输出为 `true true true`。
- 修复方向：检查 native call 返回值在短路逻辑 lowering、临时值生命周期和 bool ABI 归一化之间的转换；增加 TTY/非 TTY 两种环境的最小 feature 回归。

## NAT-024：process.command_t.cwd 未传递给 libuv 子进程

- 分类：standard library / process
- 状态：待最小化（2026-08-01 发现）
- 现象：`process.command_t` 暴露了 `cwd` 字段，但 Darwin/Linux runtime 的 `rt_uv_process_spawn` 只设置了 file、args、env 和 stdio，没有把 `cmd.cwd` 赋给 `uv_process_options_t.cwd`。因此 `spawn()` 子进程仍在 Adou 进程当前目录运行。
- 预期：设置 `cwd` 后，子进程的工作目录应与该字段一致；空 cwd 才表示继承父目录。
- 当前绕过：Adou 的核心 shell 工具通过 argv 传递参数，并在 `/bin/sh -lc` 脚本开头执行受控的 `cd <session cwd> && exec ...`；不把用户模式参数拼入 shell 语法。
- 修复方向：Nature runtime 设置 `options.cwd = rt_string_ref(&ctx->cmd.cwd)`（空字符串转为 NULL），并在 Darwin/Linux/Windows 分别加入 pwd feature 回归。

## NAT-025：nullable union 无法对其 union 成员做类型收窄

- 分类：compiler / union type checking / narrowing
- 状态：已最小化（2026-08-01）
- 现象：给 union type alias 增加 nullable 后，`if possible is item_t value` 报 `cannot convert union type to union type`。同一类型也无法把 `item_t` 值或其具体成员构造成 `item_t?`，分别报 `type inconsistency, expect=union, actual=...item_t(union)` 和 `union type not contains 'ref<...>'`。
- 最小复现：
  ```nature
  type left_t = struct { int value }
  type right_t = struct { string value }
  type item_t = ref<left_t>|ref<right_t>

  fn main() {
      item_t? possible = null
      if possible is item_t value {
          println('found')
      }
  }
  ```
- 预期：`T?` 对 union alias `T` 应能表示 `T` 的任意成员或 `null`，并允许先收窄为 `T` 后继续按具体成员收窄；如果语言不支持 union 嵌套/展平，应在 `item_t?` 声明处给出明确诊断，不能接受类型后生成不可构造、不可收窄的值。
- 当前绕过：需要表达“零或一个 message union”时返回 `[message_t]`，以长度 0/1 表示 absent/present，避免 nullable union-of-union。
- 修复方向：统一 nullable sugar 与 union alias expansion；构造和 `is/as` 检查都应对 alias 成员做同样的 flatten，增加 nullable union alias 的 null、每个具体成员和二阶段 narrowing 回归。

## NAT-026：Darwin `syscall.getcwd()` 丢失路径最后一个字节

- 分类：standard library / syscall / Darwin
- 状态：已最小化（2026-08-01）
- 现象：在 `/Users/liulianfuren/Code/adou` 中调用 `syscall.getcwd()` 返回 `/Users/liulianfuren/Code/ado`；任意目录都会稳定丢掉最后一个字节。Adou 因此把工具 cwd、项目说明发现路径和 footer 全部指向错误目录。
- 根因：`std/syscall/syscall.darwin.n` 用 `libc.strlen(raw_path)` 取得本来就不含 NUL 的长度，随后又执行 `buf.slice(0, len - 1)`。Linux 的 getcwd syscall 返回长度包含 NUL，`-1` 只适用于该实现，不能复制到 libc `strlen` 路径。
- 预期：返回与 POSIX `getcwd()` 完全一致的 UTF-8 路径，不包含末尾 NUL，也不丢失路径字节。
- 当前绕过：Adou 的 `src/platform/cwd.n` 直接调用 `libc.getcwd`，使用 `cstr.to_string()` 复制到 Nature string；所有工作目录入口统一使用该封装。
- 修复方向：Darwin 实现改为 `buf.slice(0, len)` 或直接 `raw_path.to_string()`，加入根目录、ASCII 路径和多字节 UTF-8 路径回归，并确认 Linux/Windows 保持现有长度语义。

## NAT-027：HTTP SSE 终止读取/关闭触发 `connable` SIGBUS

- 分类：standard library / runtime / interface dispatch / coroutine networking
- 状态：待最小化（2026-08-02 发现）
- 现象：Nature HTTP 客户端读取 OpenAI-compatible SSE 响应时，响应已经发送完整的 `[DONE]` 记录，TUI 协程仍继续执行下一次 `response.read()`，或在读取异常后再次执行 `response.close()`，进程可能以 SIGBUS（exit 139）退出。LLDB 栈落在 `http.client.response_t.close`，程序计数器落入由 UTF-8 字节组成的无效地址，说明 `types.connable` 接口分发状态已被破坏。相同请求在 headless 路径的调度时序下可能不崩溃，因此需要保留 TTY/协程时序作为复现条件。
- 最小复现方向：使用 `http.client` 连接本地 HTTP/1.1 SSE 服务，依次发送一个或多个 `data:` 事件、`data: [DONE]\n\n`，客户端在收到 `[DONE]` 后继续 `response.read()`，并在 `read` error 路径调用 `response.close()`；在 TUI/并发渲染协程下重复运行观察 SIGBUS。
- 预期：`[DONE]` 作为应用层终止记录后，HTTP body reader 应安全结束；`response.close()` 必须幂等且可从任意协程调用，不能发生接口跳转损坏、use-after-free 或进程级崩溃。
- 当前绕过：Adou provider 在收到 `[DONE]` 后立即结束读取，不再访问连接尾部；成功流和已发生读取错误的失败路径均不重复调用 `response.close()`。底层连接交由 Nature 的响应生命周期回收。此绕过已用源码构建和安装后的二进制分别通过本地 SSE TUI、headless 流测试以及真实 DeepSeek key 测试。
- 修复方向：将 `response_t` 的 body 状态、底层 `connable` 引用和 close/read waiter 的所有权拆开审计；确保 EOF/`[DONE]`、跨协程 abort、close callback 只执行一次，且 interface receiver 在 response 生命周期内保持有效。增加纯 Nature 最小 HTTP SSE feature 回归，覆盖 headless、TTY 协程和 read-error 后 close 三条路径。

## 回归要求

修复任何条目时至少执行：

1. 将最小复现加入 Nature 自身 testar/测试套件。
2. 验证原始源码可编译。
3. 运行 Adou 全量 Nature 测试，防止移植层的临时绕过掩盖回归。
