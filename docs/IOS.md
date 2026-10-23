# iOS App 与 Widget

## 当前方案与迁移状态（2026-10-22）

“内置 Tailscale 与机器发现”已废弃。2026-10-21 最新方案按 Screens 官方方式使用 Tailnet ID＋仅 Devices/Core Read 的 OAuth Client Secret 关联，只读 API 自动更新设备；iPhone 上的独立 Tailscale App 提供 VPN。不创建额外节点，不再要求快捷指令。旧 AppIntent／JSON 导入保留为兼容入口，关联 API 时不可混用。见 [FEATURE1-TAILSCALE.md](FEATURE1-TAILSCALE.md)。

App／测试与 Widget 源码基线为 iOS 17，构建无需 Go 或 TailscaleKit。API 凭据仅 App 私有 Keychain，使用 `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`，不会共享给 Widget；原共享设备配对 Keychain 组继续独立使用。当前已用现有开发身份和 profiles 完成 API 新版签名构建并覆盖安装、启动；最新完整单元 118 通过／6 条件跳过、核心 UI 7 通过；真实只读关联、目录刷新、冷启动恢复、手动断开提示、连回后不提示及原中继认证均已通过。当前 Release 设备构建与本机原生只读发现组件真机探测也通过；已安装 Mac mini host 经授权临时升级后的发现／认证／在线心跳正向验收通过，并恢复原二进制、plist、配置及非排空状态，关闭 8788；用户确认实际网络状态的 Wi-Fi → 蜂窝 → Wi-Fi 前台返回、手动目录刷新和原中继认证均通过，6 个稳定 ID 一致且更新时间逐次推进；真实改名／地址变化仍待验。此前快捷指令版真机预览／取消验证保留原边界，不能充当 API 授权证据。

独立工程：`ios/AgentInbox.xcodeproj`；源配置：`ios/project.yml`。SwiftUI、WidgetKit、AppIntent。App／测试及 Widget 当前源码部署基线为 iOS 17。早期使用 Xcode 27.0（27A266a）、iPhone 17 Pro / iOS 26.4 模拟器；2026-10-21 实际使用 Xcode 27.1、iOS 26.5 模拟器。最初目标 iPhone 17 Pro / iOS 26；最新用户确认当前用于安装的是 Mac mini USB 上 Example iPhone / iOS26.6.1；已批准独立 App/Widget/App Group/Push/Keychain 登记、使用现有证书签名与真机安装。最新 fresh CoreDevice 已确认 physical/wired/connected/paired，现有证书手动 Debug 构建与真机安装成功；真实App已自动正式配对、Keychain、私网认证取题与Sandbox APNs注册；手机系统UNPushNotificationTrigger确认真实送达。用户手机Beta提交已被同一原Codex session/turn/call采用；真机中号Widget随后也已按扩展Intent/无App激活/唯一原生采用三方证据单独通过，见[本轮记录](IPHONE-LIVE-20261015.md)。

App bundle ID：`dev.matianyi.agentinbox`；Widget：`dev.matianyi.agentinbox.widget`；team：`YOUR_TEAM_ID`。实际 Widget 测试使用切换前的临时 bundle IDs，所有回调结束、测试 Keychain 清理后才切换为这些独立正式标识。最终标识已做实际主屏幕 Widget → 独立 fixture 回归，共享认证和唯一提交通过；此模拟器证据独立于真机；最新真机 profiles、签名和安装已完成，见设备报告。

## 构建和测试

```sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/AgentInbox.xcodeproj -scheme AgentInbox \
  -destination 'platform=iOS Simulator,id=example-id-afc22b8e39c7' \
  -derivedDataPath /private/tmp/AgentInboxFinalSimulator CODE_SIGNING_ALLOWED=NO build
```

纯协议与 UI 模拟测试可使用 `CODE_SIGNING_ALLOWED=NO`。真实模拟器 Keychain/App Group 测试需要本地 ad-hoc entitlement 签名；未签名构建删除 Keychain 返回 `-34018`，不能把无签名结果当作共享支持证据：

```sh
xcodebuild -project ios/AgentInbox.xcodeproj -scheme AgentInbox \
  -destination 'platform=iOS Simulator,id=example-id-afc22b8e39c7' \
  -derivedDataPath /private/tmp/AgentInboxSignedSimulator \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

这只对本项目本地模拟器产物签名，不创建 Apple 证书或 APNs 私钥。实际 relay、原 Agent、配对、Widget 主屏幕测试有显式测试环境开关，缺少开关时跳过，避免普通测试自动回答真实任务或创建凭据。对已采用题不能再次执行采用测试，应创建明确获准的独立测试原题与新完整 native binding。API fixture 必须独立于真实引擎。

模拟器 ID 由 `xcrun simctl list devices available` 核对。Xcode 测试可能使用克隆模拟器；安装与截图前确认指定设备已启动。旧 happyword 未修改。

## 使用

1. 设置服务地址。模拟器本地默认 `http://127.0.0.1:8787`；真 iPhone 的 loopback 是手机自身。真机需要批准并配置 Tailscale 私网服务监听或 HTTPS。
2. 在中转服务生成 10 分钟有效、单次使用的配对码；设置输入地址和码，选择“配对此 iPhone”。设备密钥自动写 Keychain，不需要在聊天粘贴私钥。
3. 待决列表展示机器、项目目录名、短会话 ID；详情显示完整项目路径与显式会话名或短 ID。`launchSurface=unknown` 明确显示“原生请求；终端来源未确认”，不从 pane、focus 或易变来源 metadata 猜测 tmux/Herdr/Desktop。
4. 添加“Agent 待决”主屏幕 Widget。完整可读且适合当前尺寸的简短单选直接通过 AppIntent 回答；文字、多选、长题、多题或缺少真实操作摘要的审批打开 `agentinbox://request/{requestId}` 准确页。自动切题后先点右上角“回答此题”再选答案；待办数、等待时长、最近同步和发送状态的行为及最新验收范围见 [主屏体验](WIDGET-INBOX-EXPERIENCE.md)。
5. 多请求时，详情可“显示在小组件”，只显示所选 requestId，失效或已采用不会退回另一个待决题。设置“显示最新待决请求”可取消固定。
6. 历史显示原任务采用、已在本机处理、过期、失效与结果未知；机器页显示主机在线状态。
7. 用户点“启用推送通知”才请求系统通知权限并注册 APNs。Debug 使用 sandbox，Release 使用 production；注册成功不等于送达验收。

## 回复可靠性

- 每个回答包含准确 product requestId、revision、稳定 responseId、选项 ID；relay/host 再核对完整机器与 native tuple。
- 原生单题虽保留 `questions:[一题]` 提供题面，仍使用顶层 `optionIds/text`、空 `answers`；`kind=questions` 多题仅使用 nested answers、空顶层。
- 选择与文字即时互斥。共享验证在写 journal 前检查 canonical、选项合法性/重复、文本资格/UTF-8 长度、互斥和非空，非法新草稿不会锁死后续更正。
- App 与 Widget 共享 App Group 缓存和不可改写 journal；`flock` 保护跨进程保存。同 request/revision 不可换 responseId 或内容。
- 网络失败保存原答案。显式恢复先 GET 原 request；只有服务器仍 pending、revision 一致才用同 responseId/内容重试 relay HTTP。unknown/submitting/终态只刷新，不自动或盲目重派原引擎。
- Widget 提交前获取最新请求、检查有效期/revision/选项；按钮的可访问标识携带准确 requestId/revision/optionId，旧 Widget 不投下一题。
- HTTP 200、按钮点击或提交中均不冒称采用。只有 relay 的原引擎采用回执显示“原任务已采用”。
- Widget 通常请求 5 分钟后新时间线，但系统可延迟；App 前台每 8 秒刷新。推送和App收件箱独立；组件新增只读刷新按钮，真机刷新及单选Beta免开App路径已单独通过，未实现iOS26 Widget推送增强。
- HTTP 仅接受 loopback 或 Tailscale 地址；其他地址必须 HTTPS。私网也需要设备认证。

## 真实测试证据

历史27个唯一XCTest方法至少一次通过；本轮新增AutomaticPairingTests 11项全部通过，Release构建通过且DEBUG自动入口已移除。真机UI Runner系统初始化超时、0测试体执行，不计成功。历史重复原任务采用场景不重复计数。测试类别：协议兼容 9、共享提交/故障 6、中文常规 UI 4、本地 relay fixture 与原 CLI 2、临时配对/Keychain/清理 3、实际 Widget 3。部分测试仅在显式授权 fixture 环境下运行，不是一次通用 `test` 会无条件执行全部。

| 范围 | 实际结果 | 证据 |
| --- | --- | --- |
| 协议、状态、canonical、fault、中文文字/多选/设置 | 17 项通过，mixed 回复先红后绿 | `ios-ui-test.log`、`ios-mixed-red.log` |
| 可选来源、项目、会话兼容 | 2 项通过 | `ios-source-test.log`、`ios-identity-test.log` |
| 真实 HTTP fixture API | 认证 GET、提交、幂等与内容冲突通过 | `ios-api-test.log` |
| iOS 正式 ReplyDraft/ReplySubmission → Codex 原 CLI | native9 Beta adopted；native11 手机先 Beta adopted | `ios-codex-test.log`、`ios-codex-adoption.json`、`ios-codex-phone-first-test.log`、`ios-codex-phone-first-proof.json` |
| 临时配对与模拟器 Keychain | 配对、单次码重放拒绝、写读删、撤销即401通过 | `ios-pairing-test.log`、`ios-pairing-proof.json`、`ios-keychain-signed-test.log` |
| 实际主屏幕 Widget → fixture API | 中号 Widget 真实共享 Keychain/App Group 认证；点乙后 App不前台、唯一 response 持久化为 submitting | `ios-widget-surface-test.log`、`ios-widget-direct-test.log`、`ios-widget-shared-proof.json` |
| 最终 IDs/group 的实际 Widget → fixture | 最终 `group.dev.matianyi.agentinbox` 下 Provider 共享 Keychain 认证，准确 fixture 按钮乙唯一提交，App非前台；清理通过 | `ios-final-widget-direct-test.log`、`ios-final-widget-shared-proof.json`、`ios-final-cleanup-test.log` |
| 实际主屏幕 Widget → Codex 原 CLI | 精确 pin request27afd422/rev1/native12，点击 Beta，App始终非前台，原任务 adopted | `ios-widget-native-test.log`、`ios-widget-native-proof.json`、`adapters-live/widget-native-adoption-proof.json` |
| 临时 Keychain 与 pin 清理 | 严格只删除本轮 fixture key，恢复空 Keychain、默认8787、空缓存和无 pin | `ios-cleanup-test.log`、`ios-simulator-cleanup-proof.json` |

实际原 CLI Widget responseId 为 `example-id-df9609c0858a`；原 session/turn/native12/item 的通用 `function_call_output` 恰好一次包含 Beta，marker 关闭，不依赖预设 echo。主屏幕截图见 `evidence/ios-widget-native.png`。这证明真实模拟器 Widget 直答到原 CLI，不能替代真 iPhone、真实 APNs、Herdr、Ubuntu 或 Desktop 入口验收。

此前自动审批曾拒绝实际 Beta 与配对；用户后来明确批准这些隔离测试，本轮已据此完成，不再把这两项列为待授权。

## 真机剩余事项

Apple 账户中的独立 App 登记由主负责人推进。用户已明确批准这些独立标识/权限与现有证书签名安装；主负责人已完成独立 App、Widget、App Group 登记关联；App Store Connect 记录由主负责人继续处理。只使用现有 Apple Development 身份，不自动生成新证书/私钥。最新目标手机与已有后台 UDID 已由用户确认；CoreDevice 已确认 physical/wired/connected/paired；两个新开发 profiles 验证通过，手动 Debug 签名与真实 iPhone 安装完成（尚未启动/配对/APNs），具体准备见 `docs/IOS-device-signing.md`。手机需要 USB 连接、解锁并信任 Mac；若 Developer Mode 尚未开启，需要用户手动完成。最终 `AGENTINBOX_APP_GROUP=group.dev.matianyi.agentinbox`，`AGENTINBOX_KEYCHAIN_GROUP=$(AppIdentifierPrefix)dev.matianyi.agentinbox.shared`；真机需匹配已注册权限与 provision。

手机密钥用 `AfterFirstUnlockThisDeviceOnly`；APNs 私钥只配置到 relay 文件，不能发普通聊天。独立日本服务器/Tailscale 监听、部署、持久服务和 APNs 凭据仍有各自授权边界。未创建 Apple/APNs 私钥或新证书，未安装到真 iPhone。

初轮设备只读证据：`evidence/ios-device-preflight.json`。devicectl 的 connected iPhone17Pro 实为 reality=simulated/sameMachine，已排除；xctrace 非模拟器列表无手机。现有有效代码签名身份1个（Apple Development），不打印姓名/私钥。

初轮现有证书签名准备：已固定本地现有 Apple Development 身份、manual 方式尝试一次（不启用 automatic provisioning updates），本地3个profiles均不匹配新 App/Widget，明确缺两个含正确 capabilities 的开发 profiles；`ios-device-signing-build.log`（证书姓名已脱敏）、`ios-signing-preflight.json`。可通过 `AGENTINBOX_APP_PROFILE` 与 `AGENTINBOX_WIDGET_PROFILE` 分别指定现有证书对应的新开发 profile UUID/名称。最新两个下载 profiles 已验证并安装匹配 UUID，手动真机签名构建和 App 安装完成；未创建新证书/私钥。

最终命名空间 Widget 回归截图：`evidence/ios-final-widget-before.png` 与 `ios-final-widget-after.png`。request `fixture-widget-final-group`，response `example-id-16a726a954f7`，rev1/乙/唯一回复，engine fixture、state submitting；不声称原生采用。新的共享组和 Keychain 跨 App/extension 已实际验证。临时密钥匹配后删除、缓存/pin 清空、地址恢复8787，见 `ios-simulator-cleanup-proof.json`。本轮没有访问8787或操作已采用原任务。

自有几何图标位于 `ios/App/Assets.xcassets/AppIcon.appiconset`，源 `ios/Tools/AppIcon.svg`、构建生成脚本 `ios/Tools/generate-icon.swift`；在项目根运行 `swift ios/Tools/generate-icon.swift` 可重生成。深绿收件箱/箭头、暖浅色背景，无旧App素材；`ios-final-icon-build.log` 记录最终构建。

## 开发用一次性真机配对

DEBUG 支持 `--consume-pairing-file --write-diagnostics`，固定读取本App私有Documents/agentinbox-pairing.json；需同UID、regular、0600、无symlink、≤4096B、32位hex码、剩余有效期≤600秒，真机只允许源码中的示例 HTTPS 目的地（本地调试前需设置为自己的地址）。删除成功才联网，已有Keychain或deviceId拒绝覆盖；未知网络/成功响应解码失败停止、不自动重试。与设置页共用PairingService。凭据只由App正常保存至Keychain，结果/诊断文件仅不透明ID及状态。不能把正式码放到argv/environment/日志或仓库。Release无此入口，见[11项与Release验证](../evidence/ios-auto-pairing-regression-verification.json)。

签名build-for-testing时App/Widget使用 `AGENTINBOX_APP_SIGN_STYLE=Manual`、各自profile；测试目标保留Automatic，使用本机已有wildcard与 `CODE_SIGN_IDENTITY='Apple Development'`。不要全局传Manual加Xcode-managed wildcard或具体SHA给Automatic测试目标；不加allowProvisioningUpdates。详见[签名证据](../evidence/ios-physical-auto-pair-signature.json)。

真机Widget前两次App回复与第三次实际Widget免开App通过分别留证，见[现场记录](WIDGET-PHYSICAL-DEBUG.md)。小号、大号、文字/审批/多选及物理同时键盘竞答仍须真实手机单独验收。
