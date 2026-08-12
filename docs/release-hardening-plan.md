# Release Hardening Plan

状态：unsigned tar.gz 直接分发为当前正式选择（已完成）；Developer ID/.pkg/notarization 为可选未来增强（不再阻塞发布）。
Batch 1（dist/artifact/install staging）与 Batch 2A（macOS signing readiness——
本地预检与离线编排测试）均已完成，2026-08-12（见 `docs/macos-signing.md`）；
Batch 2B（真实 Developer ID 签名与公证）未开始，需要新权限。macOS native
installer（unsigned .pkg）批次已完成（见
`docs/macos-installer.md`）；Linux 按当前优先级暂缓。当前两个发布二进制的实际签名状态为 linker 生成的 ad-hoc
签名（`Signature=adhoc`、`TeamIdentifier=not set`、无 Authority），不是
Developer ID signed，未 notarized。

## 目标

把 Adou 从源码树内可运行，推进到可交付、离开源码树可运行的 macOS arm64
原生产物：固定文档口径、审计构建产物、提供 `make dist` 打包、端到端验证
解包后的产物、提供 `make release-check` 串行门禁，并校验 `make install`
staging。

## Batch 1 范围（只验证 darwin-arm64）

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
- `tests/e2e/release/release-artifact.sh`：解包后完全离开仓库 cwd 运行
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
4. `tests/e2e/release/release-artifact.sh` 全绿（解包后运行、隔离环境、offline RPC、
   IPC 生命周期、Mach-O/动态依赖白名单、签名状态一致性）。
5. `make release-check` 全绿。
6. `make install DESTDIR=<tmp> PREFIX=/usr/local` staging 下 `--version` 正常。
7. 一个聚焦 commit，工作区干净。

## Batch 1 验收证据（2026-08-12 实跑）

- `make build`：退出 0。
- `make dist`：产出 `build/dist/adou-0.1.0-dev-darwin-arm64/`（adou、
  adou-process-group 0755、RELEASE-README 0644、SHA256SUMS）与
  `build/dist/adou-0.1.0-dev-darwin-arm64.tar.gz`——**3497293 字节**，
  SHA-256 `d0e236462a7f3e10e7e46212fc2c1b1e8cfa9c09fc06ff389fb7dcdecdbfe0c1`
  （归档含固定 mtime，重复打包字节会变化，见 reproducible tar 说明）。
  目录内 `shasum -a 256 -c SHA256SUMS` 通过；归档仅含固定 4 文件，无
  tests/sessions/auth/key 材料。
- 构建产物审计：`file` 两二进制均为 Mach-O 64-bit executable arm64；
  `otool -L` 两二进制均仅依赖 `/usr/lib/libSystem.B.dylib`（adou 的
  `current version 1356.0.0`）——动态依赖白名单通过。
- `tests/e2e/release/release-artifact.sh` 全绿：解包后离开仓库 cwd 运行
  `--version`/`--help`；隔离 `PI_CODING_AGENT_DIR`/
  `PI_CODING_AGENT_SESSION_DIR`；相邻 adou-process-group 运行时发现 +
  bash 工具真实执行；offline RPC 确定性失败响应且非挂起；RPC-over-IPC
  spawn→status→stop 生命周期与退出后无遗留进程；Mach-O/动态依赖白名单；
  RELEASE-README 签名声明与实际 codesign 状态一致（ad-hoc：
  `Signature=adhoc`、`TeamIdentifier=not set`、无 Authority）。
- `make release-check` 全绿：build → eval（3/3）→ dist →
  release-artifact.sh → rpc-over-ipc.sh → rpc-bash-stream.sh 串行门禁通过。
- `make install DESTDIR=<tmp> PREFIX=/usr/local` staging 校验：
  `<tmp>/usr/local/bin/{adou,adou-process-group}` 相邻存在且可执行、
  `<tmp>/usr/local/share/adou/docs/mvp-implementation-spec.md` 存在；
  staging 下 `adou --version` 输出 `adou 0.1.0-dev`。

## 各批次排除项（Batch 1 未覆盖风险，标注归属批次）

- codesign / notarization：Batch 1 不签名、不公证，产物为 linker 生成的
  ad-hoc 签名（`Signature=adhoc`、`TeamIdentifier=not set`），首次运行需
  用户绕过 Gatekeeper 或手动临时签名。Batch 2A（已完成）只做本地
  readiness：工具/identity 预检、签名/公证命令编排的离线测试（dry-run/
  fake tools），不真实签名上传；真实签名/公证属 Batch 2B（未来，需用户
  提供 Developer ID Application、Developer ID Installer identities 与显式
  notarytool profile 后执行）——见
  `docs/macos-signing.md`。
- Linux 交叉构建：按当前产品优先级显式暂缓，不属于接下来的 release
  hardening 主线。
- 系统安装器：flat `.pkg` 构建、内容 E2E、Application+Installer 双证书签名
  入口及 submit/staple/validate/Gatekeeper 编排已完成；真实签名/公证仍受
  Batch 2B 权限阻塞，见 `docs/macos-installer.md`。
- 真实 provider eval：`make eval` 只跑本地脚本化 HTTP mock；不对真实
  DeepSeek/OpenAI/Anthropic 端点做发布级冒烟（live smoke 需显式开启且限制
  消费，见 porting-plan）；归属 Batch 5。
- Pi extension compatibility：只作为未来独立 RFC 提及，未实现任何扩展
  运行时/ABI 兼容。
- reproducible tar：保证文件清单与权限稳定，不保证字节级可复现——
  macOS bsdtar 与 gzip 会把时间戳写入归档与压缩头，同一版本两次构建的
  tar.gz 字节可能不同（见下）。属独立工作项。

## 关于 reproducible tar 的准确说明

Batch 1 的 `make dist` 采用固定 tar 命令
（`tar -C build/dist -czf <name>.tar.gz <name>`）与固定文件列表/权限，
因此同一版本产物的**文件清单与权限**是稳定的；但**不声明字节级可复现**：
(1) macOS 的 bsdtar 在无 `--options` 定制时记录文件 mtime，gzip 头部也写
mtime；(2) 本次构建的 Nature 二进制本身由编译器生成，编译器输出未做字节级
复现保证。若后续批次需要 bit-for-bit 可复现（如 CI 哈希比对），需引入固定
mtime（`--mtime`/`SOURCE_DATE_EPOCH`）、gzip `-n` 与排序固定，作为独立工作项。

## 后续批次占位

- Batch 2A（已完成，2026-08-12）：macOS signing readiness——`signing-preflight`/
  `signing-smoke`/`signed-dist`/`notarize`/`signing-check` 的本地预检与离线
  编排测试；Nature `__LINKEDIT` 重签阻塞已修复并提交上游
  [nature-lang/nature#304](https://github.com/nature-lang/nature/pull/304)，目标、
  退出码、实测证据与 2B 阻塞条件见 `docs/macos-signing.md`。
- Batch 2B（未来，需新权限）：真实 Developer ID 签名 + notarization
  （用户提供 Developer ID Application、Developer ID Installer identity
  与显式 notarytool profile 后才允许执行；主程序签名槽扩容、双层签名、
  公证和 staple 技术路径已经离线验证）。
- macOS native installer（已完成，2026-08-12）：`make pkg`/`pkg-check`/
  `signed-pkg` 与 `.pkg` notarize/staple/Gatekeeper 路径，见
  `docs/macos-installer.md`。
- Linux：按用户当前优先级暂缓，不作为下一批。
- Batch 5：发布候选上的真实 provider eval（有限消费、失败快速）与
  远端 catalog 刷新冒烟。
- 独立 RFC（不并入上述批次）：Pi extension compatibility。
