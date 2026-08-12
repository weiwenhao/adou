# macOS Signing（Batch 2A / 2B）

状态：Batch 2A（本地 readiness）进行中，2026-08-12；Batch 2B 未开始（阻塞
条件见下）。本批不执行任何真实签名与公证。

## 背景与安全边界

- 当前两个发布二进制（adou、adou-process-group）是 linker 生成的 ad-hoc
  签名：`codesign -d --verbose=4` 显示 `Signature=adhoc`、
  `TeamIdentifier=not set`、无 `Authority=` 行；`codesign --verify
  --strict --deep` 通过。本批及此文档的一切结论都**承认这一 ad-hoc 状态**，
  不把 ad-hoc 冒充 Developer ID。
- 本批红线（全程未违反）：不执行真实 Developer ID 签名（codesign 不携带
  真实 identity）、不创建 notary profile、不执行 `xcrun notarytool
  submit`、不 `gh release`、不读取/打印 keychain 凭据内容、不发布。
- 本机当前 `security find-identity -v -p codesigning` 无 Developer ID
  Application identity（只有 Apple Development 身份，不用于分发签名）。

## Batch 2A（本批）：本地 readiness

范围：工具/identity preflight（只读）；签名/公证命令编排的离线测试
（dry-run/fake tools 验证顺序与参数）；**不真实签名、不真实上传**。

交付物：

- `make signing-preflight` → `scripts/signing-preflight.sh`：只读检查，不
  修改任何产物。检查 `codesign`/`security`/`xcrun`（含 `xcrun --find
  notarytool`）、Developer ID Application identity 数量、当前 artifact
  版本与签名状态（`codesign -d --verbose=4` 解析：adhoc/linker-signed
  判定、TeamIdentifier、Authority）。
- `make signing-smoke` → `scripts/signing-smoke.sh`：把当前 dist staging
  复制到临时目录，对副本按「先 helper、后主程序」顺序执行
  `codesign --force --sign - --options runtime --timestamp=none`，再对副本
  `codesign --verify --strict --deep`；**不修改 build/bin 与默认 dist**
  （前后哈希比对），完成后删除副本。状态行对每个二进制输出
  sign-exit/replaced/verify，不把"未能替换"冒充为"已替换"。
- `make signed-dist` → `scripts/signed-dist.sh`：Developer ID 签名产物入口，
  **fail closed**（见下）；有真实 identity 时按 helper→主程序顺序签名并
  校验 authority/team/strict，产出
  `build/dist/adou-<ver>-darwin-arm64-signed.tar.gz`，不动默认 dist。
- `make notarize` → `scripts/notarize.sh`：公证入口，**fail closed**；必须是
  单独显式目标，默认 `release-check`/`signing-smoke` 不调用 notarytool、
  不触网。
- `make signing-check` → 串行 `dist` + `tests/e2e/release/macos-signing-workflow.sh`。
- `tests/e2e/release/macos-signing-workflow.sh`：预检行为、fail-closed、fake-tools
  编排断言、副本 ad-hoc 签名校验、README 与签名状态一致性；不创建 notary
  profile、不真实提交、不打印 keychain 凭据。

### signing-preflight 确定性退出码

| 退出码 | 含义 |
|---|---|
| 0 | 就绪：工具齐备且 ≥1 个 Developer ID Application identity |
| 20 | 缺少工具（codesign/security/xcrun） |
| 21 | 无 Developer ID Application identity（本机当前状态） |
| 22 | artifact 缺失、不可执行或版本不一致 |

状态行确定性格式：`signing-preflight: status=<ok|missing-tools|no-identity|artifact-error> identities=<n> developer-id-application=<m> notarytool=<yes|no> artifact=<path> version=<v> signature=<adhoc|adhoc-linker-signed> team-identifier=<...> authority=<yes|no>`。

### 本批实测发现（2026-08-12）

1. `codesign --force --sign - --options runtime --timestamp=none` 对 cc 编译
   的 adou-process-group 副本**成功**（签名被替换并带上 hardened runtime
   flag，`--verify --strict --deep` 通过）。
2. 对 Nature 编译器产出的 adou 主程序副本：codesign 在本机 macOS 上**无法
   原地替换 ld64 生成的 linker-signed 签名**——确定性报错 "internal error
   in Code Signing subsystem"（exit 1），文件保持原 linker 签名且
   `codesign --verify --strict --deep` 仍通过；`--remove-signature` 同样
   失败。已在多个变体（含/不含 `--options`/`--timestamp`、去签名后重签）下
   复现，结论稳定。
3. 含义：真实签名前必须解决主程序签名替换问题（候选路径：Nature 工具链
   链接时关闭 ld64 adhoc codesign、改用可工作的去签名工具、或在不同
   codesign/macOS 版本上验证），这是 Batch 2B 的阻塞条件之一（见下）。
   signing-smoke 的状态行如实报告 `replaced=no reason=codesign-internal-error`。

## Batch 2B（未来，需新权限）：真实签名与公证

阻塞条件（**全部**满足后才允许执行真实签名/上传；任何一条不满足即保持
当前 fail-closed 状态）：

1. 用户提供 Developer ID Application identity（`security find-identity -v
   -p codesigning` 中出现的 Developer ID Application 条目），且用户授权
   执行真实签名——属新权限动作；
2. 用户显式提供 notarytool keychain profile（由用户执行
   `xcrun notarytool store-credentials` 创建，或等价显式凭证）；本批及
   Batch 2A 任何测试都**不得创建** profile；
3. 解决 2A 发现的主程序签名替换问题（见上）；
4. 用户显式授权执行 `xcrun notarytool submit`（属新权限动作）。

2B 入口与校验：

- `make signed-dist`：`ADOU_CODESIGN_IDENTITY` 必填且不得为 `-`（空值或
  `-` 一律拒绝并报错退出，exit 64）；identity 必须是 keychain 中的
  Developer ID Application（否则 exit 65）。先签 helper 后签主程序，校验
  `codesign --verify --strict --deep`、`Authority=Developer ID
  Application`、TeamIdentifier 存在、hardened runtime flag。注意：notarization
  通常要求安全时间戳，2B 可能需把 `--timestamp=none` 改为 `--timestamp`
  （本批无法实跑验证，届时以实际公证为准）。
- `make notarize`：`ADOU_NOTARY_PROFILE` 必填且不得为 `-`；只提交
  `xcrun notarytool submit <tarball> --keychain-profile <profile>`，
  不 stapler（见下）。

### notarization / stapling 边界（准确）

- tar.gz / zip 可以提交给 notarytool 公证（获得 ticket），但**不可
  stapler**——stapling（把 ticket 嵌进产物）只适用于 dmg/pkg 等容器。
- 因此：本批及 `make notarize` 的当前实现**不声称** tar.gz 可 staple，也
  不执行 stapler；如需无对话框体验（Gatekeeper 不再警告），必须先做
  dmg/pkg 打包（Batch 4 候选），届时 stapler 在 dmg/pkg 上使用。

## 测试与验证（2026-08-12 实跑，Nature 串行规则同 AGENTS.md）

- `sh -n` 全部新/改脚本通过；
- `make build` → `make dist` → `tests/e2e/release/release-artifact.sh` →
  `tests/e2e/release/macos-signing-workflow.sh` → `make signing-check` →
  `make release-check` 全绿；
- 0 identity 下 `signing-preflight` 输出 `status=no-identity` 并 exit 21
  （确定性）；
- identity/profile 缺失时 `signed-dist`/`notarize` exit 64、非 Developer ID
  identity exit 65，且 build/bin 与默认 dist 哈希不变（fail closed）；
- fake codesign 日志断言：先 helper 后主程序、每次 `--force --sign - --
  options runtime --timestamp=none`；fake xcrun 只记录
  `notarytool submit <tarball> --keychain-profile <profile>`，不执行真实
  提交；signing-smoke 从不调用 xcrun；
- 副本 ad-hoc 签名后 `codesign --verify --strict --deep` 通过，build/bin
  与默认 dist 哈希签名前/后不变；
- RELEASE-README 声明与 `codesign -d` 实际状态一致（ad-hoc；
  TeamIdentifier 出现真实值或出现 Authority 即失败并标记"非 Developer ID"）。
