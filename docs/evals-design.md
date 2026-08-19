# Adou Phase 8：evals harness 设计

状态：Phase 8 已完成（2026-08-12）。上游基线 `vendors/pi` `packages/evals`（Pi 0.82.1，commit `cced6a21da273b26ee4a23a803680614bbe8dd1e`）。

## 上游文件清单与映射

| 上游文件（vendors/pi/packages/evals） | 作用 | Adou 对应实现 |
|---|---|---|
| `src/pi-harness.ts` | 单 case 运行器：装配 session（provider/tools/session）、跑 prompt、抽取 response/transcript/usage，非 `stop` 结束即抛错 | `src/evals/harness.n`：`make_runner`/`drive_prompt`（装配 session、运行 prompt、按最后 assistant 的 stop_reason 判定 run 失败） |
| `src/smoke.eval.ts` | smoke 集合：`describeEval("Pi Coding Agent smoke", ...)`，case 名 "runs a basic prompt end to end"（断言 output 为 Paris、errors 为空、usage 元数据） | `tests/evals/smoke_evals.n`：case 定义（name + prompt + 期望），`basic-prompt` 沿用“回答 Paris”语义与 case 命名风格 |
| `src/extensions.eval.ts` | 扩展创建/reload/工具调用 eval | **明确排除**：Pi extension 已在生产入口停用，扩展相关 eval 不移植（记录于 porting-plan 排除项） |
| `scripts/run-evals.mjs` | CLI 包装：校验 ADOU_PROVIDER/ADOU_MODEL 后跑 vitest | `Makefile` 的 `eval` target：经 `scripts/nature-build-safe.sh` guarded 串行构建 `tests/evals/smoke_evals.n` 并运行二进制 |

上游 harness 依赖真实模型 API（`ADOU_PROVIDER`/`ADOU_MODEL` + ModelRuntime），本实现按任务要求改为**本地脚本化 HTTP mock**（参照 `tests/anthropic_http_stream_test.n` / `deepseek_http_stream_test.n` 的 fixture server 模式）：每个 case 一个 `http.server()`，按请求序号返回预置的 Anthropic-messages SSE 体，全程离线、确定、零成本。真实 provider eval 未做（记录为剩余差异）。

## Harness 结构（src/evals/harness.n）

- `mock_t`：本地 mock provider 状态——端口、请求计数、按轮次的 SSE 响应体、捕获的请求体、可选 HTTP 错误状态。
- `case_t`：case 定义——名称、端口、SSE 脚本、注册的内置工具名、prompt、断言项（期望 assistant 文本子串、期望工具结果子串、期望回传 provider 的请求体子串、期望 run 失败 + 错误片段）。
- `drive_prompt`：装配 session（in-memory repository、内置工具、`anthropic_provider.stream` 指向 `http://127.0.0.1:<port>/v1`），跑一次 prompt，消费 session stream；最后 assistant 的 stop_reason 非 `stop` 即把 run 标记为失败（对应上游 `promptAgent` 对非 `stop` 结束抛错）。
- `run_case`：逐项断言，产出 `result_t{name, passed, detail}`。
- `print_report`：每 case 一行（`PASS <name>: <detail>` / `FAIL <name>: <detail>`）+ 汇总行 `eval summary: N passed, M failed, N total`；返回失败数，入口据此 `syscall.exit(1)`。
- `text_response` / `tool_use_response`：构造确定性 SSE 体（tool_use 的 arguments 在嵌入前做 JSON 转义）。

## Smoke case 列表（tests/evals/smoke_evals.n，入口 `make eval`）

1. `basic-prompt`（端口 19210）：mock 返回固定文本 `Paris`；断言最终 assistant 文本包含 `Paris`。对应上游 smoke.eval 的 "runs a basic prompt end to end"。
2. `tool-call-read`（端口 19211）：turn 1 mock 返回 `read` 工具调用（读 fixture.txt），真实执行内置 read 工具；turn 2 返回 `Read the file.`。断言：assistant 最终文本、工具结果文本包含文件内容、且第二轮 provider 请求体包含工具结果（证明工具结果进入上下文并回传 provider）。
3. `provider-error-handling`（端口 19212）：mock 返回 HTTP 500；断言 harness 把该 run 标记为失败（错误信息含 `Anthropic API error: HTTP 500`）且进程不崩溃、后续报告正常输出。

`make eval` 全绿退出 0；任一 case 断言失败输出 FAIL 行并以退出码 1 失败（make 报 Error 1）。

## 与既有测试的关系

- `tests/evals/*.n` 不在 `make test` 的 `tests/*.n` glob 内（避免被当作单元测试重复串行跑）；`tests/evals/` 非 `.sh`，也不被 `make e2e` 的 `tests/e2e/*.sh` glob 误抓。
- `src/evals/harness.n` 随 `NATURE_SOURCES` 进入主构建（与其余 src 模块一致）。
- 与单元测试一样，所有 Nature 编译器调用都经 `scripts/nature-build-safe.sh` 串行守卫。
