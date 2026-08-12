# Release Hardening Plan

状态：Batch 1（darwin-arm64）进行中，2026-08-12。本批只验证 macOS arm64 原生产物；
其他平台与发布事项见"已知排除项"与"后续批次占位"。

## 目标

把 Adou 从源码树内可运行，推进到可交付、离开源码树可运行的 macOS arm64
原生产物：固定文档口径、审计构建产物、提供 `make dist` 打包、端到端验证
解包后的产物、提供 `make release-check` 串行门禁，并校验 `make install`
staging。

## 本批范围（只验证 darwin-arm64）

- 文档统一：本文件与 `docs/porting-plan.md`、`docs/pi-core-module-map.md`、
  `docs/phase7-storage-design.md` 的顶部状态互相一致（Phase 1–8 完成，
  release hardening 进行中）。
- 构建产物审计：`file`（Mach-O arm64）、`otool -L`（仅
  `/usr/lib/libSystem.B.dylib`）、`ls -la build/bin/`（adou +
  adou-process-group）。
- 版本一致性：`src/app.n` 的 `pub const VERSION` 为准，`package.toml` 的
  version 必须与之相等（当前均为 `0.1.0-dev`）；`make dist` 内做一致性校验，
  不一致即失败。
- `make dist`：产出 `build/dist/adou-<version>-darwin-arm64/`（adou、
  adou-process-group 0755、RELEASE-README 0644、SHA-256 manifest）与
  `build/dist/adou-<version>-darwin-arm64.tar.gz`。不打包 tests、sessions、
  auth 文件、porting-plan 及任何含 DeepSeek key 的文档。
- `tests/e2e/release-artifact.sh`：解包后完全离开仓库 cwd 运行
  `--version`/`--help`；隔离 `PI_CODING_AGENT_DIR`/
  `PI_CODING_AGENT_SESSION_DIR`；验证相邻 adou-process-group 存在且可执行
  且运行时按环境变量或相邻路径发现；offline RPC 冒烟（确定性响应、非挂起）；
  RPC-over-IPC 生命周期（spawn→status→stop、spawn_result 形状、退出后无遗留
  进程）；Mach-O arm64 与动态依赖白名单；不访问公网、不打印/打包密钥。
- `make release-check`：build → eval → dist → release-artifact.sh →
  rpc-over-ipc.sh → rpc-bash-stream.sh（bash 执行 e2e）串行门禁，不跑全量
  `make test` / 全量 `make e2e`。
- `make install` staging 校验（DESTDIR）：bin/adou 与 bin/adou-process-group
  相邻存在，从 staging 目录运行 `--version`。

## 完成标准（Batch 1）

1. 文档顶部状态互相一致，无"验收中/下一批"残留（历史批次段落保留）。
2. `otool -L build/bin/adou` 仅 `/usr/lib/libSystem.B.dylib`；
   `file build/bin/adou` 为 Mach-O arm64。
3. `make dist` 产出目录与 tar.gz，SHA-256 manifest 校验通过。
4. `tests/e2e/release-artifact.sh` 全绿（解包后运行、隔离环境、offline RPC、
   IPC 生命周期、Mach-O/动态依赖白名单）。
5. `make release-check` 全绿。
6. `make install DESTDIR=<tmp> PREFIX=/usr/local` staging 下 `--version` 正常。
7. 一个聚焦 commit，工作区干净。

## 已知排除项（本批明确不做）

- codesign / notarization：本批不签名、不公证；产物为未签名 Mach-O，首次
  运行需用户绕过 Gatekeeper 或手动 `codesign -s -` 临时签名。
- Linux 交叉构建：`package.toml` 已声明 linux_amd64/linux_arm64 链接对象，
  但本批不构建、不验证 Linux 产物。
- 系统安装器（pkg/dmg/brew formula）：本批只提供 `make install`
  DESTDIR staging 校验，不产出安装器。
- 真实 provider eval：`make eval` 只跑本地脚本化 HTTP mock；不对真实
  DeepSeek/OpenAI/Anthropic 端点做发布级冒烟（live smoke 需显式开启且限制
  消费，见 porting-plan）。
- Pi extension compatibility：只作为未来独立 RFC 提及，本批不实现任何
  扩展运行时/ABI 兼容。
- reproducible tar：本批保证文件清单与权限稳定，不保证字节级可复现——
  macOS bsdtar 与 gzip 会把时间戳写入归档与压缩头，同一版本两次构建的
  tar.gz 字节可能不同（见下）。

## 关于 reproducible tar 的准确说明

本批的 `make dist` 采用固定 tar 命令
（`tar -C build/dist -czf <name>.tar.gz <name>`）与固定文件列表/权限，
因此同一版本产物的**文件清单与权限**是稳定的；但**不声明字节级可复现**：
(1) macOS 的 bsdtar 在无 `--options` 定制时记录文件 mtime，gzip 头部也写
mtime；(2) 本次构建的 Nature 二进制本身由编译器生成，编译器输出未做字节级
复现保证。若后续批次需要 bit-for-bit 可复现（如 CI 哈希比对），需引入固定
mtime（`--mtime`/`SOURCE_DATE_EPOCH`）、gzip `-n` 与排序固定，作为独立工作项。

## 后续批次占位

- Batch 2：codesign + notarization（Developer ID、`codesign` 验证、
  `spctl`/notarytool 流程）与 Gatekeeper 运行验证。
- Batch 3：Linux（amd64/arm64）交叉构建与对应 artifact e2e。
- Batch 4：系统安装器（pkg/dmg 或 brew formula）与升级路径。
- Batch 5：发布候选上的真实 provider eval（有限消费、失败快速）与
  远端 catalog 刷新冒烟。
- 独立 RFC（不并入上述批次）：Pi extension compatibility。
