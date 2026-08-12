# macOS Native Installer

状态：macOS flat installer 批次已完成，2026-08-12。Linux 发布工作按当前优先级
暂缓，不是本批依赖。未签名 `.pkg` 的构建与离线验收已实跑；真实 Developer ID
签名、公证和 stapling 入口已实现并 fail closed，但本机缺少分发证书与 notary
profile，因此真实提交仍未执行。

## 产物与安装布局

`make pkg` 生成：

`build/dist/adou-<version>-darwin-arm64.pkg`

这是 identifier 为 `dev.adou.cli`、install-location 为 `/` 的 flat installer，
payload 与 `make install PREFIX=/usr/local` 一致且只有：

- `/usr/local/bin/adou`（0755）
- `/usr/local/bin/adou-process-group`（0755）
- `/usr/local/share/adou/docs/mvp-implementation-spec.md`（0644）

构建使用系统 `pkgbuild`。默认 `.pkg` 明确是 unsigned，只用于本地内容验收；不把
它作为可对外分发的 Gatekeeper 就绪产物。

## 离线安装包门禁

`make pkg-check` 串行执行两个 E2E：

1. `tests/e2e/release/macos-pkg.sh`
   - 展开 flat package，校验 identifier/version/install-location；
   - 对逻辑安装路径做严格白名单检查；
   - 识别 pkgbuild 用于扩展属性的 AppleDouble metadata，并要求每个 sidecar
     都有对应真实路径；
   - 解出 payload，检查权限并从临时目录运行 `adou --version`；
   - 确认默认包没有 Installer 签名；
   - 构造更高版本 package，确认 identifier 与 install-location 稳定、version
     前进，以锁定 Installer receipt/upgrade 边界；
   - 不调用 `installer`，不写 `/usr/local`，不修改 receipt database。
2. `tests/e2e/release/macos-pkg-signing.sh`
   - 缺少/错误 Application 或 Installer identity 时确定性拒绝；
   - 缺少 notary profile、输入包未签名时确定性拒绝；
   - fake tools 验证 payload helper→main→outer pkg 的签名顺序；
   - fake tools 验证 `notarytool submit --wait` → `stapler staple` →
     `stapler validate` → `spctl --type install` 的完整顺序；
   - 不读取私钥、不联网、不创建 profile、不安装 package。

## 真实签名入口

`make signed-pkg` 要求：

- `ADOU_CODESIGN_IDENTITY`：keychain 中的 Developer ID Application identity；
- `ADOU_INSTALLER_IDENTITY`：keychain 中的 Developer ID Installer identity。

脚本先在临时 root 中复制 payload，再按以下顺序执行：

1. helper：`codesign --options runtime --timestamp`
2. main：`codesign --options runtime --timestamp`
3. 分别验证 Developer ID Application authority、TeamIdentifier、hardened
   runtime、secure timestamp 和 strict/deep signature；
4. `pkgbuild` 生成临时 unsigned flat package；
5. `productsign --timestamp` 用 Developer ID Installer 对外层包签名；
6. `pkgutil --check-signature` 验证 Installer certificate；
7. 原子移动到
   `build/dist/adou-<version>-darwin-arm64-signed.pkg`。

缺少 identity 时在创建临时产物之前失败，不修改 `build/bin` 或默认 unsigned
package。确定性退出码：64（identity 缺失/placeholder）、65（Application
identity 类型错误）、67（Installer identity 类型错误）、66（输入缺失）、69
（Apple 工具缺失）。

## 公证、staple 与 Gatekeeper

`make notarize` 只接受 Developer ID Installer 签名的 `.pkg`，并要求显式
`ADOU_NOTARY_PROFILE`。流程是：

1. `xcrun notarytool submit <signed.pkg> --keychain-profile <profile> --wait`
2. `xcrun stapler staple <signed.pkg>`
3. `xcrun stapler validate <signed.pkg>`
4. `spctl --assess --verbose=4 --type install <signed.pkg>`

缺少 profile 时 exit 64；包不存在时 exit 66；没有 Developer ID Installer
签名时 exit 67。该目标是唯一会联系 Apple notary service 的路径，不属于默认
`make release-check` 或 `make signing-check`。

Apple 要求分发到 Mac App Store 之外的软件使用合适的 Developer ID 证书、
hardened runtime 和 secure timestamp；flat installer package 可以提交公证并
staple ticket。参考 Apple 的
[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、
[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
和 [Developer ID support](https://developer.apple.com/support/developer-id/)。

## 当前真实权限边界

本机只有 Apple Development identity，没有 Developer ID Application、Developer
ID Installer，也没有经用户提供的 notarytool profile。因此本批没有执行真实
payload 签名、Installer 签名、notary 上传或 stapling。拿到两类证书和 profile
后，先运行 `make signing-preflight`，再由用户显式授权执行 `make signed-pkg`
与 `make notarize`。
