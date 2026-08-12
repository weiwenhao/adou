# macOS Signing（Batch 2A / 2B）

状态：Batch 2A（本地 readiness）已完成，2026-08-12；Batch 2B 未开始（阻塞
条件见下）。本批不执行任何真实 Developer ID 签名与公证。

## 背景与安全边界

- 当前两个发布二进制（adou、adou-process-group）是 linker 生成的 ad-hoc
  签名：`codesign -d --verbose=4` 显示 `Signature=adhoc`、
  `TeamIdentifier=not set`、无 `Authority=` 行；`codesign --verify
  --strict --deep` 通过。本批及此文档的一切结论都**承认这一 ad-hoc 状态**，
  不把 ad-hoc 冒充 Developer ID。
- 本批红线（全程未违反）：不执行真实 Developer ID 签名（codesign 不携带
  真实 identity）、不创建 notary profile、不执行 `xcrun notarytool
  submit`、不 `gh release`、不读取/打印 keychain 凭据内容、不发布。
- 本机当前无 Developer ID Application 或 Developer ID Installer identity
  （只有 Apple Development 身份，不用于分发签名或安装包签名）。

## Batch 2A（本批）：本地 readiness

范围：工具/identity preflight（只读）；签名/公证命令编排的离线测试
（dry-run/fake tools 验证顺序与参数）；**不真实签名、不真实上传**。

交付物：

- `make signing-preflight` → `scripts/signing-preflight.sh`：只读检查，不
  修改任何产物。检查 codesign/security/xcrun/pkgbuild/productsign/pkgutil/
  spctl、notarytool/stapler、Developer ID Application 与 Installer identity
  数量、当前 artifact 版本与签名状态。
- `make signing-smoke` → `scripts/signing-smoke.sh`：把当前 dist staging
  复制到临时目录，对副本按「先 helper、后主程序」顺序执行
  `codesign --force --sign - --options runtime --timestamp=none`，再对副本
  `codesign --verify --strict --deep`；**不修改 build/bin 与默认 dist**
  （前后哈希比对），完成后删除副本。状态行对每个二进制输出
  sign-exit/replaced/verify；任一二进制未真正替换为 hardened-runtime 签名
  或严格校验失败时，目标 fail closed。
- `make signed-dist` → `scripts/signed-dist.sh`：Developer ID 签名产物入口，
  **fail closed**（见下）；有真实 identity 时按 helper→主程序顺序签名并
  校验 authority/team/strict，产出
  `build/dist/adou-<ver>-darwin-arm64-signed.tar.gz`，不动默认 dist。
- `make signed-pkg` / `make notarize`：macOS native installer 的真实签名、
  公证和 staple 入口，详见 `docs/macos-installer.md`；均 fail closed，默认
  `release-check`/`signing-check` 不触网。
- `make signing-check` → 串行构建 tar/pkg，并运行 package/signing workflows。
- `tests/e2e/release/macos-signing-workflow.sh`：预检行为、fail-closed、fake-tools
  编排断言、副本 ad-hoc 签名校验、README 与签名状态一致性；不创建 notary
  profile、不真实提交、不打印 keychain 凭据。

### signing-preflight 确定性退出码

| 退出码 | 含义 |
|---|---|
| 0 | 就绪：工具齐备且 Application、Installer identity 都存在 |
| 20 | 缺少 Apple 签名/打包/公证工具 |
| 21 | 缺少 Developer ID Application 或 Installer identity（本机当前状态） |
| 22 | artifact 缺失、不可执行或版本不一致 |

状态行确定性格式：`signing-preflight: status=<ok|missing-tools|no-identity|artifact-error> identities=<n> developer-id-application=<m> developer-id-installer=<i> notarytool=<yes|no> stapler=<yes|no> artifact=<path> version=<v> signature=<adhoc|adhoc-linker-signed> team-identifier=<...> authority=<yes|no>`。

### 本批实测发现（2026-08-12）

1. `codesign --force --sign - --options runtime --timestamp=none` 对 cc 编译
   的 adou-process-group 副本**成功**（签名被替换并带上 hardened runtime
   flag，`--verify --strict --deep` 通过）。
2. 旧 Nature 链接器产出的 adou 主程序副本曾确定性失败：`codesign` 报
   `internal error in Code Signing subsystem`，`codesign_allocate` 报
   `function starts data out of place`。对照 Zig Mach-O linker 后定位为
   `__LINKEDIT` 布局不兼容 Apple 签名工具：function-start/data-in-code 排在
   符号与字符串表之后，dyld info 的对齐填充未计入 load-command size，且
   code signature 后仍有页尾填充。
3. Nature 修复提交 `1bfb8bf7`（上游
   [nature-lang/nature#304](https://github.com/nature-lang/nature/pull/304)）按 Zig
   语义重排 `__LINKEDIT`、把 dyld padding 计入 size，并只页对齐 vmsize。
   使用该编译器重建 Adou 后，`codesign_allocate -a arm64 200000` 成功扩容
   签名槽；主程序 `codesign --force --sign - --options runtime
   --timestamp=none` 成功，产生 `adhoc,runtime` 签名，strict/deep 校验与
   `adou --version` 均通过；`--remove-signature` 也成功。
4. `signing-smoke` 现要求 helper 与主程序都满足 `sign-exit=0 replaced=yes
   verify=ok`，不再接受“旧签名仍可验证”作为成功。默认/发布 Nature 工具链
   必须包含上述修复；该要求会由 `make signing-check` 自动验证。

## Batch 2B（未来，需新权限）：真实签名与公证

阻塞条件（**全部**满足后才允许执行真实签名/上传；任何一条不满足即保持
当前 fail-closed 状态）：

1. 用户提供 Developer ID Application identity（`security find-identity -v
   -p codesigning` 中出现的 Developer ID Application 条目），且用户授权
   执行真实签名——属新权限动作；
2. 用户提供 Developer ID Installer identity，用于对外层 flat `.pkg` 签名；
3. 用户显式提供 notarytool keychain profile（由用户执行
   `xcrun notarytool store-credentials` 创建，或等价显式凭证）；本批及
   Batch 2A 任何测试都**不得创建** profile；
4. 用户显式授权执行真实签名和 `xcrun notarytool submit`（属新权限动作）。

2B 入口与校验：

- `make signed-dist`：`ADOU_CODESIGN_IDENTITY` 必填且不得为 `-`（空值或
  `-` 一律拒绝并报错退出，exit 64）；identity 必须是 keychain 中的
  Developer ID Application（否则 exit 65）。先签 helper 后签主程序，校验
  `codesign --verify --strict --deep`、`Authority=Developer ID
  Application`、TeamIdentifier 存在、hardened runtime flag。注意：notarization
  通常要求安全时间戳，2B 可能需把 `--timestamp=none` 改为 `--timestamp`
  （本批无法实跑验证，届时以实际公证为准）。
- `make signed-pkg`：payload 使用 Developer ID Application、hardened runtime
  和 secure timestamp，外层使用 Developer ID Installer + timestamp。
- `make notarize`：只接受已用 Developer ID Installer 签名的 `.pkg`，执行
  `notarytool submit --wait`、staple/validate 和 Gatekeeper install assessment。

### notarization / stapling 边界（准确）

- tar.gz / zip 可以提交公证但不能直接 staple；flat `.pkg` 可以提交并 staple。
- Adou 的最终 macOS 交付路径已统一到 signed `.pkg`。tar.gz 仍是便携归档，
  但不再是 `make notarize` 的输入。

## 测试与验证（2026-08-12 实跑，Nature 串行规则同 AGENTS.md）

- `sh -n` 全部新/改脚本通过；
- `make pkg-check`、`make signing-check`、`make release-check` 全绿；
- 0 Application/Installer identity 下 `signing-preflight` 输出
  `status=no-identity` 并 exit 21
  （确定性）；
- signed-pkg 对缺失/错误 Application、Installer identity 分别 fail closed；
  notarize 对缺 profile 或 unsigned pkg fail closed；
- fake tools 断言 helper→main→Installer 签名顺序，以及 submit --wait→staple→
  validate→spctl 顺序；另用 no-op 主程序 signer 验证
  `sign-exit=0` 但 `replaced=no` 时仍 fail closed；
- `codesign_allocate -a arm64 200000` 可扩容 Nature 产出的主程序签名槽；
  helper 与主程序副本均完成 hardened-runtime ad-hoc 重签，输出
  `sign-exit=0 replaced=yes verify=ok`，且 `codesign --verify --strict --deep`
  通过；build/bin 与默认 dist 哈希签名前/后不变；
- RELEASE-README 声明与 `codesign -d` 实际状态一致（ad-hoc；
  TeamIdentifier 出现真实值或出现 Authority 即失败并标记"非 Developer ID"）。
