# 真机签名与安装


## 2026-10-21 新方案安装

用户在本机创建 Apple Development 证书后，系统识别 1 个有效签名身份，团队与项目一致。使用该现有证书、现有 App／Widget 标识和已登记 iPhone，经 Xcode `-allowProvisioningUpdates` 获取两个开发 profiles；未创建或导出私钥，未撤销证书。

```sh
xcodebuild -project ios/AgentInbox.xcodeproj -scheme AgentInbox \
  -configuration Debug -destination "id=$DEVICE_UDID" \
  -derivedDataPath /private/tmp/AgentInboxPhysicalShortcuts \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_IDENTITY="Apple Development" AGENTINBOX_APP_SIGN_STYLE=Automatic build
```

Automatic 模式需使用 `Apple Development` 类型；具体 SHA1 身份会与自动签名冲突。初次 SHA1 尝试被 Xcode 拒绝，改用类型后构建成功，实际产物仍由用户现有证书签名。

App 和 Widget 的 embedded profiles 经检查器验证：精确 App ID、team、目标物理 UDID、现有证书、有效期、开发调试、App Group、共享 Keychain 与 `aps-environment=development` 全部通过。两者 strict codesign 验证通过。CoreDevice 确认目标为有线连接、已配对、Developer Mode 已开启的 iPhone 16 Pro / iOS 26.6.1。

devicectl 覆盖安装成功并启动新版，未卸载应用。专用真机 XCTest 的无效 JSON、有效预览、取消、重启后无测试设备残留与配对标签状态保留检查通过；此结果不代替快捷指令 AppIntent、daemon、VPN 恢复或新 APNs／Widget 验收。

证据在不提交 Git 的 `evidence/physical-shortcuts/`：`signing-build.log`、`profile-validation.json`、App／Widget entitlements、`install.json`、`launch.json` 与真机测试日志／附件。完整现场链路结果见 [功能 1](FEATURE1-TAILSCALE.md)。

## 2026-10-21 只读 API 版覆盖安装

Screens 式 API 版使用同一有效开发身份与 profiles 签名；App 增加自己的私有 Keychain access group，原 App／Widget 共享配对组不变。签名 entitlement 确认 OAuth 私有组存在于 App 且不在 Widget，二者 development APNs 与 shared pairing group 保留；strict codesign 和 profile 检查通过。Debug 签名构建及 Release 无 SDK 构建成功，API 新版已由 devicectl 覆盖安装并启动。

证据为 `evidence/tailscale-api/` 中的 `signed-final-build.log`、`profiles.json`、`artifact-validation.json`、`install.json` 和 `launch.json`。此安装不等于用户真实 OAuth 凭据已关联；真实设备目录与 VPN 恢复仍须分别记录。

## 早期手动流程与历史结果

用户确认目标为 Mac mini USB 上的 Example iPhone / iOS26.6.1，手机已在 Developer 后台登记。实际 UDID 与 CoreDevice 标识仅存本机 `evidence/local-dev/ios-physical-target.json`，不使用模拟器标识。最新 fresh CoreDevice 已确认 physical/wired/connected/paired；用户已正常完成信任。

以下早期手动流程只使用现有有效 Apple Development 身份，不启用 `-allowProvisioningUpdates`、不生成证书或私钥。2026-10-21 用户明确授权继续配置 profiles 与安装，采用下述自动获取 profiles 的流程。两个独立开发 profiles：App `dev.matianyi.agentinbox`（App Group、Push development、共享 Keychain）和 Widget `dev.matianyi.agentinbox.widget`（同 App Group、共享 Keychain；本轮Widget专用推送还必须aps development，旧无aps profile不适用）。都必须包含确认的物理 UDID、现有证书与 team `YOUR_TEAM_ID`。

主负责人在 Portal 下载后可保存在 `~/Downloads/AgentInbox_Development.mobileprovision` 和 `~/Downloads/AgentInbox_Widget_Development.mobileprovision`，实际路径可不同。先运行只读检查器（Python 只用于 Mac 开发工具，不是产品执行端运行依赖）：

```sh
python3 ios/Tools/inspect-device-profiles.py /实际路径/App.mobileprovision /实际路径/Widget.mobileprovision --team "$APPLE_TEAM_ID" --udid "$DEVICE_UDID" --identity "$EXISTING_CERT_SHA1"
```

只有所有 checks 为 true，才把两文件按检查器输出 UUID 安装到 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.mobileprovision`。不要替换无关 profiles。Xcode27读取此目录；旧 `MobileDevice/Provisioning Profiles` 目录无需批量迁移。

从项目根使用单独 derived data，分别传入两个 UUID，避免全局 `PROVISIONING_PROFILE_SPECIFIER` 把同一profile错用于extension：

```sh
xcodebuild -project ios/AgentInbox.xcodeproj -scheme AgentInbox \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/AgentInboxPhysicalDevice \
  AGENTINBOX_APP_SIGN_STYLE=Manual DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_IDENTITY="Apple Development" \
  AGENTINBOX_APP_PROFILE="$APP_PROFILE_UUID" \
  AGENTINBOX_WIDGET_PROFILE="$WIDGET_PROFILE_UUID" build
```

generic iOS 签名构建不依赖手机已配对。构建成功后检查 App/extension 代码签名有效、签名 entitlement 中 `application-identifier` 与各 bundle 匹配、同共享 Keychain group/App Group、App和Widget `aps-environment=development`；各 embedded profile UUID 与预期一致。不得把 BUILD SUCCEEDED 当作安装或 APNs 验收。

物理 CoreDevice 显示正常 paired/connected 后，才执行：

```sh
xcrun devicectl device install app --device "$PHYSICAL_COREDEVICE_ID" \
  /private/tmp/AgentInboxPhysicalDevice/Build/Products/Debug-iphoneos/AgentInbox.app
```

只安装此新独立 App，不修改旧 App。launch/配对/推送注册与主负责人协调；目前不假称真机 Keychain、Widget、APNs 已通过。

本轮真机结果：两个 profiles 全检查通过，手动 Debug BUILD SUCCEEDED；App 和 Widget strict codesign、现有证书 SHA1、嵌入 profile UUID、App ID、App Group 与带 team prefix 的共享 Keychain 全部匹配，App aps development / sandbox。devicectl 实际安装成功，并只读按精确 bundleID 查询已装 App。尚未 launch、relay 配对、APNs 注册或真机 Widget 操作。证据：`evidence/ios-device-profile-validation.json`、`ios-physical-signed-build.log`、`ios-physical-signature-verification.json`、`ios-physical-install-proof.json`。

执行记录：首次只读公钥证书提取的 optional 参数错误，strict 签名检查已运行而后续获准安装仍执行；修正为 `--extract-certificates=prefix` 后全部证书/entitlement 检查通过。实际顺序已保存在签名证据，未重复安装。构建有一项 iPad 全方向支持警告，不影响本次 iPhone 构建与安装；iPad 尚未验收。

2026-10-15 Widget自动刷新修复：Portal独立Widget ID Push已从关闭启用，旧Widget profile因该能力变更需重建；不更换App profile、证书或APNs key。新profile/签名/安装的实际结果记录另见 WIDGET-PUSH-DEPLOY.md，不将本文早期安装记录当作新推送已通过。目标级AGENTINBOX_APP_SIGN_STYLE避免把测试Runner强制改Manual；不对自动签名测试target传证书SHA。
