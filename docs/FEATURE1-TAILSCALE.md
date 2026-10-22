# 功能 1：只读 API 关联 Tailscale＋复用 iPhone VPN

## 最新目标与状态（2026-10-22）

实机 Screens 首次关联表单要求 Tailnet ID 和客户端密钥；此前参考图中的网页登录来自管理控制台。用户确认此前记忆有误，并明确要求按现有方案继续，打开手机关联页，由用户填写凭据做真机验证。

采用现有只读 OAuth client 方案：Tailnet ID＋Devices → Core → Read Client Secret，凭据存此 iPhone 的 App 私有 Keychain，自动同步设备；连接复用 iPhone 独立 Tailscale VPN，不创建额外节点，不要求快捷指令。API 客户端、设备同步、凭据隔离和探测逻辑已实现并安装；按钮对比度与随系统深浅色自适应已修正。真实凭据关联、设备刷新和冷启动恢复已完成真机验收；设备详情域名展示及中继设置按钮也已安装并通过真机成功／失败路径。本机原生只读发现组件与保存中继的认证组合已通过真机验证；现有 Mac mini host 临时升级后的发现／认证／在线心跳正向链路已通过，随后完整恢复原版本和配置；Wi-Fi → 蜂窝 → Wi-Fi 的前台返回、手动目录刷新与原中继认证也已通过；真实改名／地址变化仍待验。

此前网页授权探索保留为历史证据：[核查记录](TAILSCALE-WEB-AUTH-INVESTIGATION.md)。官方 OAuth App 注册拒绝设备只读 scope 的临时实验已清理；不继续将管理网页登录当作 API 授权。

[设计与验收约束](superpowers/specs/2026-10-21-tailscale-readonly-api-design.md)；[执行清单](superpowers/plans/2026-10-21-tailscale-readonly-api.md)。参考图目录 `/Users/developer/Documents/Screens参考图/`，五张图与会话附件一致。

## 原始目标核验（2026-10-22）

| 要求 | 当前证据与边界 |
| --- | --- |
| Screens 式只读关联，不依赖快捷指令 | 原生 Tailnet ID＋Client Secret 表单、菜单、设备数量与刷新均已实现；真实手机关联、刷新及冷启动恢复通过。`physical-final-refresh-v2.log`、`physical-final-relaunch-test.log`。 |
| 不创建额外 AgentInbox Tailscale 节点 | 当前工程无 TailscaleKit／libtailscale 依赖；客户端只向固定官方端点交换只读 token 和 GET devices，不调用节点创建或设备写接口。最新手机缓存来源为 API，6 个稳定 ID 与此前恢复后的集合一致。 |
| 凭据仅保存在 iPhone，原配对继续可用 | 实际签名产物主 App 有私有 OAuth 组及原共享配对组，Widget 仅有共享配对组；真机反复保留原配对，现有中继认证通过。 |
| 列表只显示域名与 IP，详情显示域名 | 真实 6 行核对、夜间截图、详情 DNS 与中继选择成功／失败路径均通过；缺失数据不拼造。 |
| 连接复用独立 iPhone VPN | 用户手动断开时提示，确认后经官方商店打开／安装；手动连接后返回不提示，原中继认证通过。普通直接唤起不支持，不能把 App Store 多一步路径写成自动直开。 |
| 发现服务与授权分开 | 本机临时调用当前原生 discovery 模块，真实 iPhone 从 API 设备行读到描述，并用原配对认证保存中继；未注册 host 正确停留“等待主机连接中转”，没有误授予权限。监听已关闭。后续经用户授权临时升级已安装 Mac mini host，真实 iPhone 的描述发现、原中继认证与注册主机在线心跳正向检查通过；原二进制、plist、配置和非排空状态已恢复，8788 已关闭。此项不代表永久启用发现。 |
| Wi-Fi／蜂窝切换 | 用户分别确认实际 Wi-Fi、关闭 Wi-Fi 后蜂窝、重新连接 Wi-Fi，且 Tailscale Connected。前台返回及手动刷新成功，6 个稳定 ID 一致、时间逐次推进，原中继认证成功；不外推后台或自动刷新时限。 |
| 构建与回归 | 最新 iOS 完整单元 118 通过／6 条件跳过，核心 UI 7 通过；当前源码 Release 设备构建通过。当前 Rust 完整回归 95 通过／2 条件忽略，arm64 Release 构建通过。 |

最新增量证据位于忽略目录 `evidence/tailscale-api/`：`network-cellular-physical.log`、`network-wifi-return-physical.log`、`network-switch-proof.json`、`installed-host-wifi-physical-v2.log`、`installed-host-proof.json`、`installed-host-restoration.log`、`native-discovery-physical-v2.log`、`goal-api-cache-copy.log`、`goal-native-regression.log`、`goal-native-release-build.log`、`goal-ios-release-build.log`。首轮原生发现 UI 检查失败于 LabeledContent 的组合标签查询；按真实无障碍分组修正后通过，不把它误写为网络故障。用户随后确认本轮目标完成；真实改名／地址变化等未验收项继续保留在执行清单，不计为通过。

## 关联配置

1. 在 iPhone 的 Tailscale App 完成登录并连接 VPN。
2. 打开 Tailscale 管理控制台 General 页面，复制 **Tailnet ID**。
3. 在 Trust credentials 创建专用于 AgentInbox 的 OAuth 凭据，仅勾选 **Devices → Core → Read**。不需要写权限、Auth keys 或节点标签。
4. AgentInbox → 机器 → 关联 Tailscale，填入 Tailnet ID 与 `tskey-client-` 开头的 Client Secret。无需 Client ID；凭据不应发送到聊天或写入项目文件。
5. 点“关联并获取设备”。验证通过才保存本机关联；API 不可用或权限不足时保留原关联与设备。
6. 查看设备，刷新识别 AgentInbox daemon；既有应用配对不变，新服务仍需验证中转地址并使用一次性应用配对码。

关联后的 Tailscale 选项提供更换关联、管理控制台、服务状态与取消关联。取消关联删除此 iPhone 的 API 凭据和候选目录，保留原 AgentInbox 配对，不删除远端 Tailscale 设备或撤销 OAuth client。撤销凭据应在 Tailscale 控制台执行。

## 启动时 VPN 提示

App 启动或从后台回到前台时只读检查本机网络接口，给自动重连留出 1.5 秒。未检测到 Tailscale 隧道时使用系统弹窗提示；点“前往 App Store”进入 Tailscale 的 iOS 产品页（产品 ID `1470499037`），已安装时由用户点“打开”，否则安装；商店唤起失败再回退 HTTPS 页面。不会自动修改 VPN、登录或创建节点。

点“稍后”后，同一次前台访问不重复提示；从后台返回再检查。已连接时不弹窗，系统弹窗适配深浅色。检测不依赖缓存目录、中继连通性或 OAuth 凭据：仅活动 `utun` 上的 Tailscale IPv6 前缀确认连接，接口读取失败或只有共享 IPv4 网段时保留“未知”且不据此弹窗；蜂窝 CGNAT 和其他 VPN 不直接计为已接入 Tailscale。这是本机连接迹象检测，不证明特定 Tailnet、设备访问策略或中继服务健康。

本轮完整单元 118 通过／6 条件跳过，既有核心 UI 7 通过；开发签名构建、strict codesign 和最终覆盖安装通过。缺失功能与共享 IPv4 误判均保留 RED／GREEN 日志，独立复审无剩余 P1／P2。用户手动断开后，真机提示与 Tailscale 进入前台曾通过，深色提示截图已目检；但测试只断言前台状态，漏检 Tailscale 内部签名错误页，不能计为唤起流程完整通过。最初两次检查误指向缺少新功能的旧测试工程 App，已改正 xctestrun 目标及依赖为正式构建，失败日志保留。未删除用户现有 Tailscale，未将回退单元测试计为真实卸载安装验收。证据位于忽略目录 `evidence/tailscale-api/vpn-guidance-disconnected-physical-v3.log`、`vpn-guidance-physical-proof.json` 及 `vpn-guidance-screenshots/`。

2026-10-22 用户截图确认 `tailscale://` 触发“Could not sign device / Unable to verify deeplink”。[官方问题记录](https://github.com/tailscale/tailscale/issues/14679)也说明裸链接会打开带错误的 App，普通启动入口未解决。已移除该链接、`canOpenURL` 和查询 scheme 声明；界面改为如实提示经 App Store 打开／安装，多一步用户点击，不再宣称直接自动唤起已实现。回归先 RED（旧代码仍调用签名 scheme）后 GREEN，完整单元 118 通过／6 条件跳过，签名构建、strict codesign 和实际安装通过，独立复审无剩余 P1／P2。最终正式版真机 1 项通过完整路径“未连接提示 → 官方 Tailscale 产品页 → 商店点打开 → Tailscale 进入前台且无签名错误页”，最终深色提示截图已目检；连接返回首次检查在 XCTest 初始化阶段超时，测试体未执行；重试时存在提示。随后只读核对 Tailscale 显示 Not Connected、无签名错误页，本机接口也无 Tailnet 地址，当前提示与实际状态一致；随后用户确认 iPhone 真正显示 Connected，正式 App 返回不再提示的真机检查通过；原 `relay-host` 中继的已配对 `/v1/hosts` 认证另 1 项通过，结束停在收件箱。此前自动断开一说后由用户澄清可能只是打开 App 未手动连接，未确定独立掉线故障。证据在忽略目录 `evidence/tailscale-api/vpn-deeplink-fix-*.log` 和 `vpn-guidance-connected-physical*.log`、`vpn-store-physical.log`、`vpn-store-screenshots/`、`vpn-guidance-connected-physical-v3.log` 和 `vpn-connected-relay-physical.log`。

## 从设备详情设置中继

设备详情显示 Tailscale 域名。点“设置为中继服务器”后，使用该域名并沿用当前中继协议和端口，显示候选地址，再以现有应用配对身份请求 `/v1/hosts`。只有收到兼容且认证成功的响应才保存；失败、取消或配置变化保留原地址。无应用配对时先提示配对，不把只读 Tailscale 关联当作应用授权。

此操作不依赖 8788 主机发现接口，也不会在目标设备上安装或启动中继。详情中的“连接受限或服务不可达”是主机发现探测结果，可能来自未启用发现监听、端口不可达或访问策略，不能直接据此判断中继或 VPN 不可用。中继切换后清理原待办和 Widget 缓存，并拒绝原连接的迟到响应及旧组件操作。

## 主机发现监听

设备 API 只提供候选主机。要在设备详情中识别 AgentInbox daemon，主机的本产品 host 进程还需显式启用只读发现接口；默认不监听 8788：

```sh
agentinbox host /absolute/private/host.local.json \
  --discovery-listen 100.100.1.2:8788 \
  --discovery-relay-url https://relay.example.ts.net:8443
```

IP 与 relay 是公开示例，必须替换为该主机现有 Tailnet IP 和已配置中转地址。监听随 host 进程退出；只返回产品、协议、主机身份、系统、版本和 relay 地址，不含任务或凭据。本文命令不会由 App 自动执行，不修改 ACL、Tailscale Serve 或 VPN。已有中转中的已授权主机列表独立展示，API 关联不更换其应用配对。

## 接口与边界

[Edovia 官方说明](https://help.edovia.com/en/screens-5/connecting-anywhere/tailscale)明确 Screens 使用 Tailnet ID＋OAuth Client Secret、Devices/Core Read；截图中的网页登录不足以证明有面向第三方 App 的通用 SSO。Tailscale OAuth clients 使用 client credentials 换取短期 bearer token；App 请求 scope 固定为 `devices:core:read`，访问令牌仅内存缓存、过期前换取。参见 [OAuth clients](https://tailscale.com/docs/features/oauth-clients) 与[官方 API](https://tailscale.com/api)。

- 凭据存一个 App 私有 Keychain 项，ThisDeviceOnly、不同步 iCloud、不共享给 Widget；原应用配对继续使用独立共享 Keychain 项。API Secret／token 不进入设备缓存、日志、URL、daemon 或 relay。
- token POST 和设备 GET 的主机固定为 `https://api.tailscale.com`，不使用 cookies、缓存或跟随重定向；有超时、响应大小与设备数量限制。错误文本脱敏，不回显服务端可能含凭据的响应。
- 设备身份优先 nodeId，兼容 legacy id；Tailnet＋ID 共同建立身份。API 获取 hostname、MagicDNS、Tailnet 地址、系统、Tailscale 版本与控制面连接字段；AgentInbox 产品版本来自 daemon。
- 设备列表每行仅显示 API 提供的 Tailscale 域名和 IPv4／IPv6；长地址可换行，域名使用主文字颜色、IP 使用系统次要文字颜色，适配深浅色。其他机器信息在详情中查看。缺失域名／IP 明确显示未提供，不推测或拼接。域名从已有快照传递到展示模型，刷新与缓存恢复使用同一来源。
- 控制面连接不等于主机服务可达，API 拉取成功不等于手机 VPN 已连接。未知字段明确未知；不从 lastSeen 猜在线状态。API 不授予 AgentInbox 任务访问权。
- 前台首次／恢复、网络路径变化和手动刷新更新目录，再分批轮转探测固定 Tailnet IP 上的 8788 只读 daemon。自动发现探测无产品或 OAuth 凭据、不跟随重定向。正常应用请求使用已保存中转；用户明确点击“设置为中继服务器”时，另向所显示的候选域名发送现有应用配对凭据验证，禁止重定向，成功后才保存该地址。Tailscale API Secret／token 从不参与此验证。
- 换账号整体更新目录，取消或更换关联令旧在途结果失效。认证／限流／网络失败保留旧列表和上次更新时间；不清配对、不修改远端节点、ACL、VPN 或主机服务。
- SDK 已从工程、源码、资源和构建脚本移除；App／测试与 Widget 维持 iOS 17 基线。ATS 明文例外只覆盖 Tailscale IPv4 `100.64.0.0/10` 和 IPv6 `fd7a:115c:a1e0::/48` 的 daemon 发现，API 始终 HTTPS。

## 验证记录与剩余门槛

本地证据位于忽略目录 `evidence/tailscale-api/`：官方 OpenAPI、RED/GREEN 测试日志、签名构建及后续真机记录。最终新构建目录完整单元执行 107 项：101 通过、6 项专用环境未启用而跳过；核心 UI 7 项通过。覆盖 token 续期、撤销、取消时的在途交换、切换 Tailnet 时丢弃旧 API 响应、稳定 ID 改名／换地址、超过 16 台的轮转探测、关联失败回滚等。两项审查 P2 均先复现为失败测试再修复，复审无剩余 P1／P2。Debug 签名与 Release 设备架构构建通过；App 私有 OAuth Keychain 组不在 Widget entitlement 中，原共享配对组与 development APNs 保留，strict codesign 和 profiles 全项通过。API 新版已覆盖安装并启动 iPhone。

最终完整运行日志为 `audit-unit.log`（全新 DerivedData）和 `final-regression.log`（UI 7 通过）。此前一次增量单元运行未加载新增测试且 Widget bundle 无法加载；该失败保留在 `final-unit.log`，不改写为通过。已导出并目检关联表单和兼容入口截图。对官方 token 端点用公开无效 fixture 的真实 HTTPS 请求返回 401，只证明错误路径，不能代替真实授权。

本轮真机关联与恢复：用户最初误填 Client ID，实际错误为设备接口 404；正确 Tailnet ID 下真实关联成功。正式版补充字段来源说明及专用 404 提示；API／存储回归 16 项通过，签名构建与 strict codesign 通过，正式源码构建版已实际安装。手动刷新、App 冷启动后刷新各 1 项真机检查通过，原应用配对状态保留；API 缓存为同一组 6 个稳定 ID，重启后更新时间推进。首次目录曾为 7 台，后续少的是旧 `agentinbox-iphone`，远端变化原因未定；没有据此新增或删除远端节点。脱敏证明见忽略目录 `evidence/tailscale-api/physical-proof.json`。

本轮中继设置回归：完整单元 117 项中 111 通过、6 项专用环境跳过，核心 UI 7 项通过；签名构建、strict codesign 与实际覆盖安装通过。iPhone 真机 1 项检查覆盖详情域名、不可达候选失败保留原地址、`relay-host` 域名中继认证成功、设置页地址一致及原配对保留，深色成功／失败截图已目检。成功路径复核的是当前已配对的 `https://relay.example.ts.net:8443`；从另一原地址提交新域名的行为由单元测试验证，未声称两套独立中继间的真机迁移。独立复审发现的 Widget 迟到缓存问题已补回归并修复，复审无剩余 P1／P2。证据为 `relay-selection-full-unit-v2.log`、`relay-selection-ui-regression-v2.log`、`relay-selection-physical-v2.log` 与 `relay-selection-screenshots/`，均位于忽略的证据目录。

VPN 手动断开提示及连回后中继认证已通过；已安装 Mac mini host 的发现＋认证＋在线心跳端到端及完整恢复也已通过；用户确认网络状态的 Wi-Fi → 蜂窝 → Wi-Fi 三阶段已通过前台返回、手动目录刷新与原中继认证，6 个稳定 ID 一致且更新时间逐次推进；蜂窝及切回 Wi-Fi 各 1 项真机检查通过，无误报未连接提示。此项不等于后台无人操作恢复或自动路径变化刷新时限验收。真实改名／地址变化未验。第 7 项挂起／终止／锁屏时 APNs 与 Widget 回传完整矩阵单独验收；APNs 到达不证明私网 API 或答案回传可用。

[旧快捷指令入口](TAILSCALE-SHORTCUT-IMPORT.md)仅用于兼容；[旧内置方案归档](FEATURE1-TAILSCALE-EMBEDDED-ARCHIVED.md)保留原历史。旧 SDK 登录、旧 App 或旧导入结果不累计为本方案验收。
