> **已废弃方案归档（2026-10-21）**：用户已废弃“内置 Tailscale 与机器发现”，改用“复用独立 Tailscale App＋快捷指令导入设备”。本文仅保留旧 SDK 实现、构建和测试的历史记录，其中的操作步骤与待验清单不再作为当前实施要求。当前方案与迁移状态见 [FEATURE1-TAILSCALE.md](FEATURE1-TAILSCALE.md)。旧 SDK 代码尚待迁移，历史测试不计入新方案验收。

# 功能 1：iPhone 内置 Tailscale 与机器发现

依据 `NEXT-REQUIREMENTS.md` 第 1 项。实现范围：前台内置节点、网页登录、身份可见机器列表、daemon 识别、一次性配对、稳定身份与网络恢复；后台通知和 Widget 中转生命周期属于功能 7。

## 当前方案与提交状态（2026-10-21）

本次提交保存内置 Tailscale SDK 实现。复用 iPhone 已安装 Tailscale App、通过快捷指令导入设备列表的替代方案已讨论，尚未实现；不能将本次提交视为已切换连接方案。

此前用户已在真机完成内置浏览器登录，Mac 侧观察到新增内置 iPhone 节点在线；完整发现、应用授权、网络切换，以及未安装独立 Tailscale App 的条件仍未完成现场验收。Debug 诊断中的 `loginBrowserRequested` 只表示请求打开登录页，不表示页面已实际展示。

提交前重新执行 `cargo test --offline`：95 通过、2 忽略、0 失败；iOS 单元测试执行 88 项：83 通过、5 条件跳过、0 失败，其中发现与重连测试 18 项。另通过差异空白检查与 SDK 构建脚本语法检查。本轮没有重新运行真机验收。

## 设计

- 官方 `tailscale/libtailscale` 固定到 `d1dc45d039edb7759ecbee6ba2aea0c4bca884b8`，本地编译 TailscaleKit XCFramework，仅 App 链接，SDK 要求 App / 单元测试最低 iOS 18.1。Widget 保持 iOS 17，不链接 Go / TailscaleKit。
- App 私有 Application Support 存储持久节点状态，禁止备份，启用文件保护；不记录控制面登录 URL、密钥或代理凭据。用户明确点击登录才创建身份。前台恢复已有节点，不在测试或演示启动时登录真实网络。
- 从 SDK 的 statusJSON 解码 LocalAPI 状态；机器以 StableNodeID 去重，主机名、地址、在线状态为可变属性。不以 IP、显示名或轮换公钥建立机器身份。机器列表不持久缓存其他账号的机器。
- 原生 Rust daemon 可选开启只读发现监听，默认不启动监听。只发布产品标识、协议版本、hostId、操作系统、主机名、产品版本和供用户确认的 relay 地址。仅允许 loopback 或 Tailscale 私网绑定；不提供任务正文、凭据或管理接口。通过已有 Tailscale Serve 暴露时由操作者配置，不自动部署。
- iOS 仅对控制面返回的 Tailscale 地址探测固定发现端口 8788。探测不带设备密钥、不跟随重定向。发现只提供候选地址，用户输入一次性码后通过现有 PairingService 认证；绝不将现有设备凭据发送到发现返回的新地址。已配对身份不会被自动替换。
- 区分机器离线、连接受限或服务不可用、HTTP 明确拒绝、协议不匹配、待配对和已配对。网络超时不能证明 ACL 拒绝，必须明确为不确定。
- 前台轮询及网络路径恢复重建 SDK 节点 / 代理会话，复用持久状态。已配对的 relay 地址不因未经认证的发现响应而自动改写。

## 实施与验证

- [x] Rust 只读发现协议、监听地址限制、host 启动参数与隔离 HTTP 测试。
- [x] SDK 固定版本构建脚本、App 专属框架依赖和源工程同步。
- [x] Swift 状态解码、稳定身份去重、发现响应验证、状态区分的单元测试。
- [x] 内置节点登录、私网 URLSession 路由、机器页、配对和前台重连代码实现。
- [x] Rust 回归、iOS 单元测试、模拟器 / 真机架构构建。
- [ ] 真机无独立 Tailscale App 登录、可见机器、授权连接、改名 / 地址变化、断网恢复现场验收。

真机验收需用户交互完成身份提供商登录；没有现场证据的条目保持未验收。SDK 构建工具只用于开发机，目标 daemon 仍为 Rust 原生二进制，不依赖 Go / Node / Python 运行时。

## 构建与使用

开发机安装 Go >= 1.27.1、Xcode 和 XcodeGen 后运行：

```sh
scripts/build-tailscalekit.sh
xcodegen generate --spec ios/project.yml
```

脚本核对官方源码固定提交并构建 iPhone / arm64 与 x86_64 模拟器 XCFramework 到 `ios/.build/TailscaleKit.xcframework`。可用 `TAILSCALE_SOURCE` 指定已有的未修改固定提交源码，或用 `GOPROXY` 选择模块下载代理；Go 始终依据固定 go.sum 校验。只在首次或升级 SDK 时重建。

主机默认不开放发现接口。操作者在自己的 Tailscale IPv4 上显式启用：

```sh
agentinbox host /absolute/private/host.local.json \
  --discovery-listen 100.100.1.2:8788 \
  --discovery-relay-url https://relay.example.ts.net:8443
```

这里的 IP / DNS 是示例，替换为该主机现有 Tailnet 地址和已配置的认证中转。监听随 host 进程一起结束。也可仅监听 `127.0.0.1:8788`，由操作者将 Tailnet TCP 8788 转发到该 loopback；本次实现不会修改现有 Tailscale Serve 或 ACL。

手机打开“机器”→“登录 Tailscale 并发现机器”，在内置浏览器完成登录；如需管理员批准，界面保留该状态。机器列表含当前身份可见的所有节点，最多 16 台在线节点分批探测，后续前台刷新轮转覆盖其余节点；收件箱刷新独立进行。进入发现的 daemon，确认其展示的中转地址，再输入该中转的一次性配对码。已有同一中转配对身份直接认证关联，不重复生成或覆盖身份。

网络路径变化或从后台返回时重建节点 / loopback 代理会话，复用受保护且不参与备份的本机节点状态。机器名或 Tailscale IP 变化不改变 StableNodeID。离线节点仍显示在当前控制面返回的列表中；控制面移除的节点立即移除。未登录或切换身份期间清空上一次机器列表。

此功能只为 App 安装内置连接会话。Widget 不加载 SDK；尚不能据此宣称“没有独立 Tailscale App 时，私网 Widget 仍能回传”或“App 挂起后内置节点常驻”，这两项属于功能 7 的中转与生命周期验收。

## 2026-10-16 验证结果

基础代码为远端 `docs/next-requirements` 的 `5260551`。初轮代码验证在独立工作区构建和测试，未修改正在运行的主机配置、Tailnet ACL 或服务器。后续真机自动化准备及结果见下文。

| 检查 | 结果 | 本地证据（不提交 Git） |
| --- | --- | --- |
| `cargo test --offline` | 95 通过、0 失败、2 条件忽略 | `evidence/feature1/rust-tests.log` |
| iOS 单元测试 | 执行 87；82 通过、5 条件跳过、0 失败，含 17 项新增发现 / 重连测试 | `evidence/feature1/ios-unit-tests.log` |
| iOS 常规 UI 回归 | 5 通过、0 失败；机器入口截图已目检 | `evidence/feature1/ios-ui-tests.log`、`machines-demo.png` |
| 固定 SDK 构建 | iPhone arm64、模拟器 arm64 / x86_64 XCFramework 构建成功 | `ios/.build/TailscaleKit.xcframework` |
| Release 真机架构构建 | `generic/platform=iOS`、`CODE_SIGNING_ALLOWED=NO` 成功 | `evidence/feature1/ios-release-device-build.log` |
| 产物依赖检查 | App 最低 18.1 且链接 TailscaleKit；Widget 最低 17.0 且不链接 SDK | `otool -L` / 产物 Info.plist |
| 静态复审 | 已修复认证关联、错误分类、探测阻塞及两类断开竞态；限定复审无剩余 P1/P2 | 对应测试及实现 |

单元测试以隔离传输 fixture 检验旧凭据不会发往新发现地址、已配对用户无需重复配对、401 与缺心跳区分、重连期间私网请求失败关闭，以及断开覆盖正在启动 / 停止的旧刷新。协议解析测试覆盖改名、换地址、轮换公钥、同名机器、身份缺失、控制面移除和未登录列表清空。fixture 不替代真实 SDK 登录或真实网络切换证据。

### 真机现场验收步骤（尚未执行）

1. 在未安装独立 Tailscale App 的真机上，用现有合法签名安装本轮 App，完成机器页网页登录；按需由 Tailnet 管理员批准节点。
2. 在一台测试主机启用上述发现监听，确认系统、主机名和产品版本；先验证无配对不能取题，再用该中转一次性码完成应用授权。
3. 改主机显示名、轮换其地址后刷新，确认 StableNodeID 不变且列表不重复；验证离线、服务停止、明确 401/403 和访问超时的不同提示。
4. 切换 Wi-Fi / 蜂窝、断网后恢复、将 App 放入后台再返回，检查复用节点身份并重连，不覆盖应用配对身份。
5. 分别记录实际结果；后台挂起、进程终止、锁屏的通知与 Widget 回传仍留给功能 7，不能从前台结果外推。

### 真机自动化准备与首轮阻塞（2026-10-16）

用户连接手机并明确要求自动化验证后，已确认 USB 上真实 iPhone 16 Pro / iOS 26.6.1，开发者模式开启。使用本机现有证书、App profile 和更新的带 Push Widget profile 完成 `build-for-testing`；strict codesign 校验通过，新版正式 App 已安装，保留原数据与设备配对身份。

首轮专用 XCUITest Runner 已启动，但 iOS 弹出“为 XCTest 输入 iPhone 密码 / Enable UI Automation”。等待系统确认超时，测试体未执行，不能算登录、发现或重连通过。该确认必须由用户在手机上操作；未读取或输入手机密码。已准备后续真实 SDK 登录、隔离 native daemon 发现与前后台恢复用例。

手机当前已安装独立 Tailscale；本次没有卸载它。因此即使后续内置节点链路通过，也须单独记录“未安装独立 Tailscale App”的验收条件。隔离测试 host / relay 不绑定真实 Agent，Mac 侧发现协议已验证，等待手机确认期间已停止测试服务；未提交任何真实任务答案。

本地记录：`evidence/feature1/physical-preflight.json`、`physical-login-attempt1.log`。后续必须在系统确认完成后再启动 UI 自动化，避免重复无效重试。
