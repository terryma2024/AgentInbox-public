# Tailscale 快捷指令设备导入实施计划

> 使用 executing-plans 在本机会话逐项实施；沿用用户指定的当前目录及分支。

**Goal:** 核实独立 Tailscale 的设备导出能力，完成快捷指令导入，移除内置 SDK。

**Architecture:** Tailscale 的 Find Devices 与 Get Status 产生设备属性及账号；快捷指令构造版本化 JSON，交给 AgentInbox 的 AppIntent。App 展示预览，由用户确认后原子替换当前账号快照，不改已有 Keychain 配对。设备探测和 App／Widget API 均经系统 VPN 路径。

**Tech Stack:** SwiftUI、AppIntents、Foundation URLSession、原有 Rust 只读发现。

**Spec:** ../../FEATURE1-TAILSCALE.md

## Global Constraints

- 目标机器不增加 Node／Python／Go 运行时。
- 不以名称或 IP 建立设备身份；以快捷指令 ID 加账号区分。
- 快照不代表实时连接；超时不能证明 VPN 断开或 ACL 拒绝。
- 导入不代替应用授权，不覆盖现有配对、不向新发现地址发送现有凭据。
- 新方案真机结果与旧 SDK 测试隔离记录。

## Task 1: 核实来源与导入模型

Files: 新建 ios/App/TailnetImport.swift、ios/Tests/TailnetImportTests.swift；调整 ios/App/TailnetDiscovery.swift。

- [x] 官方文档确认 Find Devices；本机 1.104.1 元数据确认 ID、Name、IPv4／IPv6、MagicDNS、Is Online，Status 确认 Account Name 与 Connected。未将 Mac 元数据算作 iPhone 执行证据。
- [x] 先写快照与存储测试；首次构建被当前源码缺失的旧 SDK 阻塞，记录该限制，不将依赖错误算作导入功能 RED。在线字段缺失测试后续已取得明确 RED→GREEN。
- [x] 实现 schemaVersion=1、account、connected、devices 数组；每项 id、name、可选 isOnline／ipv4Address／ipv6Address／magicDNSAddress。IP 必须为 Tailscale 网段；字段限长、总量 256 KiB／512 设备。空数组用于清空快照，不清配对。
- [x] 保存经过校验的模型及本地导入时间，不持久化未知输入字段；私有目录、原子写入、禁止备份。运行模型及存储测试。

## Task 2: 导入入口与系统 VPN 连接

Files: 新建 ios/App/TailnetStore.swift、TailnetImportView.swift、ImportTailnetDevicesIntent.swift；修改 AgentInboxApp.swift、TailnetMachineView.swift、InboxNetwork.swift；替换 TailnetDiscoveryTests.swift。

- [x] 先覆盖错误导入不改状态、存储失败不改状态、刷新期间替换／清空丢弃旧结果、已配对只认证已保存 relay、401 与缺心跳区分的测试。
- [x] AppIntent 接收 JSON 字符串并前台打开导入预览；机器页也支持粘贴和 JSON 文件。确认替换后刷新，取消不落盘。
- [x] 替换 EmbeddedTailnetDriver：仅通过系统 URLSession 探测，前台与网络变化重新探测，不尝试控制独立 VPN。保留分批探测及应用层认证。
- [x] 更新 UI 测试，验证导入预览、确认、取消和错误反馈；回归已有回复与 Widget 测试。

## Task 3: SDK 移除、构建与交付

Files: 删除 EmbeddedTailnet.swift、TailnetPhysicalVerification.swift、PhysicalTailnetTests.swift、旧 SDK 构建脚本和许可证资源；同步 project.yml、project.pbxproj、Makefile 及当前文档。

- [x] 移除链接、嵌入、代理、登录入口和旧 SDK 专用测试，将 App／测试基线恢复为 17.0（不宣称 iOS 17 真机通过）。
- [x] 提供快捷指令字段映射、可使用的 JSON 示例和导入操作步骤；注明实机版本与执行证据的边界。
- [x] Rust 全套、iOS 单元／UI、Release 设备架构构建；检查 App／Widget 无 SDK 依赖与 SDK 资源。
- [x] 检查 diff、源码残留、配对保存路径未改及文档状态；记录真实执行结果，保留真机目标与验收待办。

## 执行记录

- 基线 cargo test --offline 因本机 p256 缓存缺失未执行测试，已启动锁定依赖联网回归。
- 本机 Xcode 27.1、iOS 26.5／27.0 模拟器已确认，iPhone 16 Pro 在 devicectl 列表为 available (paired)；尚未执行新方案真机测试。

- 2026-10-21：Rust 基线联网依赖就绪后 95 通过／2 忽略；首轮 iOS 单元 82 通过／5 跳过，导入 UI 6 通过；Release 设备架构构建通过，无 SDK 框架及资源。
- 初次构建明确失败于缺失旧 SDK；移除后发现并修正旧浏览器 sheet 残留。在线字段缺失测试随后先失败于契约必填，改为可选并显示未知，后续完整回归已通过。
- 用户补充强调独立 App 指 iPhone 上的 App；说明与实现始终以同机快捷指令导入为目标。Mac 验证只作辅助证据。
- iPhone 安装 Tailscale 1.104.1 已核实；本机有效开发签名身份 0、profile 0，新版真机安装及链路尚未执行。已异步询问用户可用现有签名配置；不创建新证书或越过签名约束。

- 阶段检查：Rust 95 通过／2 忽略；当时 iOS 单元 85 通过／5 跳过，UI 6 通过；Release 无 SDK。后续新增真实 ATS 测试，最终结果见下文。
- 独立审查：无 actionable P1／P2；待补现场证据是 iPhone Shortcuts→AppIntent 冷启动、系统 Files picker 入口和真实 VPN 恢复。测试中的 intent 直接调用与粘贴 JSON UI 不代替这些现场证据。

- 真实网络补充：最终 UI 日志暴露 ATS 阻断，并发现 demo 确认后误触发真实探测。已写真实 URLSession→本机只读 Tailnet fixture 测试，明确 RED 为 -1022 与配对候选缺失；增加仅 Tailnet IPv4／IPv6 CIDR 的 ATS 例外，保留全局 HTTPS 策略，demo／hosted test 不触发确认后的真实探测。修复后的全套最终回归已通过。
- 测试工具状态：第二轮 UI 的 6 个测试体通过后 Xcode 协调进程清理卡住，只中断了本轮已重新核对的协调 PID；不将其算作第二轮完整成功。此前独立完整 UI 6 通过记录保留，修复后将重新执行完整 UI。

- 最终串行验证完整退出成功：iOS 单元 93 执行、88 通过／5 条件跳过，UI 6 通过；真实 URLSession 只读 Tailnet 发现通过；Release 设备架构构建通过。合成服务已停止，无生产 Agent 或服务变更。
- 用户确认会在本机配置现有签名；真机导出、冷启动导入、配对与 VPN 恢复待签名就绪后继续，不标记完整现场验收完成。

- 最终 UI 预览与导入设备列表截图已导出并目检，中文与确认按钮可读，无关键内容溢出。签名待用户配置，本地保留当前分支检查点，不合并或推送。


### 2026-10-21 真机签名与阶段验证

- 用户已在本机创建 Apple Development 证书并授权配置 profiles／安装。系统有效身份 1 个；Xcode 自动获取 App／Widget 开发 profiles，均匹配现有证书、目标 UDID、App ID、App Group、共享 Keychain 和 development APNs。strict codesign 通过，签名 Debug 构建及覆盖安装／启动成功，未卸载 App。
- iPhone 16 Pro / iOS 26.6.1，wired／paired／Developer Mode Enabled。专用真机 XCTest 验证无效 JSON、有效预览、取消、重启后无 fixture 残留以及配对标签状态保留通过；截图已目检。未确认替换现场设备快照。
- 快捷指令首次自动启动失败，用户手动打开后独立重试成功，读取真实界面通过；不将首次失败改写为通过。随后新建快捷指令测试因手机锁屏无法继续，未取得动作输出或导入端到端证据。
- 用户选择“稍后继续”，暂停手机操作；当前无运行中的测试。下一步：解锁手机，创建并运行同机 Tailscale Get Status／Find Devices → JSON → AgentInbox 动作，验证冷启动预览、确认保存、daemon 与 VPN 恢复；不重复旧 SDK 验收。
- 本机证据 `evidence/physical-shortcuts/`：签名构建、profiles 校验、安装启动、真机预览测试及快捷指令界面测试结果。开发签名已就绪不再是阻塞项；完整链路仍未完成。
