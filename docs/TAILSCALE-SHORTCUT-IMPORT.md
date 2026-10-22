# 历史兼容：从 iPhone Tailscale App 导入设备

> 2026-10-21 最新主流程已改为 [Screens 式只读 API 关联](FEATURE1-TAILSCALE.md)，不再要求快捷指令。本文仅描述保留的兼容入口；API 已关联时须使用自动刷新，不能混入手工快照。以下快捷指令现场待办不再是主流程交付门槛。

本流程中的“独立 Tailscale App”专指 **iPhone 上安装的 Tailscale App**。在同一台 iPhone 上运行快捷指令，把设备导入 AgentInbox；Mac 不作为手机导入的运行依赖。

## 已核实能力与边界（2026-10-21）

[Tailscale 官方文档](https://tailscale.com/docs/features/mac-ios-shortcuts)确认 iOS 的 `Find Devices` 可查询设备，`Get Status` 提供 `Account Name` 和 `Connected`。本机 macOS Tailscale 1.104.1 的 AppIntents 元数据包含设备 `ID`、`Name`、`IPv4 Address`、`IPv6 Address`、`MagicDNS Address`、`Is Online`；本机快捷指令实际执行 `Find Devices` 返回了设备列表，变量属性菜单也展示了 ID 和地址字段。目标 iPhone 的已安装版本已通过 devicectl 确认为 1.104.1。

上述 Mac 端核查用于建立字段契约，不等于 iPhone 快捷指令到新版 AgentInbox 的真机端到端验收。用户创建现有开发证书后，App／Widget profiles 与代码签名已验证，新版已覆盖安装并启动；真机 JSON 无效输入、预览取消与取消后重启检查通过。快捷指令现场链路继续验证；不以旧 SDK 的登录或旧版 App 结果代替新流程验收。

## 在 iPhone 创建快捷指令

1. 在 iPhone 的 Tailscale App 完成登录并连接 VPN，然后打开同一台手机的“快捷指令”App，新建“导入 AgentInbox 设备”。
2. 添加 Tailscale 的 `Get Status`，保留其 `Account Name` 与 `Connected` 属性。不要在快捷指令里填写 Tailscale API key、节点密钥或 AgentInbox 设备密钥。
3. 添加 Tailscale 的 `Find Devices`（中文界面可能显示“查找 Devices”）。导出完整列表时不要设置在线筛选或数量限制。
4. 对每个 Device 执行“重复每一项”，在循环内用“词典”构建设备对象，按下表选择重复项目的对应属性。ID 必须来自 Device 的 ID，不能填 IP 或名称。无法提供的可选字段可省略；不要把缺失的在线状态填成 false。
5. 使用循环结果组成 `devices` 数组，再创建总词典：`schemaVersion` 使用数字 `1`，`account` 使用状态的 Account Name，`connected` 使用状态的 Connected，`devices` 使用设备词典数组。布尔值须保持布尔类型，不使用文本 `"true"`／`"false"`；数字版本不使用文本 `"1"`。
6. 将总词典转换为 JSON 文本（可用“从输入中获取文本”，输入选择总词典），把文本传给 **AgentInbox → 导入 Tailscale 设备 → 设备快照 JSON**。该动作前台打开 AgentInbox 预览；用户确认替换后才保存，不会打开内置登录或创建 Tailscale 节点。
7. 确认账号与设备数，点“确认替换设备快照”。在“机器”页刷新服务状态；进入识别到的 daemon，确认中转地址，再按应用层一次性码配对。已有配对不会被导入覆盖。

设备字段映射：

| JSON 键 | Tailscale Device 属性 | 要求 |
| --- | --- | --- |
| `id` | ID | 必填文本，稳定设备身份 |
| `name` | Name／名称 | 必填文本 |
| `ipv4Address` | IPv4 Address | 可选，必须属于 Tailscale IPv4 网段 |
| `ipv6Address` | IPv6 Address | 可选，必须属于 Tailscale IPv6 网段 |
| `magicDNSAddress` | MagicDNS Address | 可选，不用于任意域名探测 |
| `isOnline` | Is Online | 可选布尔值；若当前属性选择器不提供则省略，界面显示未知 |

系统和 AgentInbox 产品版本不从快捷指令猜测，通过主机的只读 daemon 发现响应补齐。导入期间不同账号的设备快照整体替换，现有应用配对独立保留。切换 Tailscale 账号后应重新运行导入；AgentInbox 不能读取其他 App 的当前账号，旧快照不代表当前 Tailnet。

## JSON 示例与其他导入入口

以下仅为公开 fixture，替换为快捷指令的实际字段：

```json
{
  "schemaVersion": 1,
  "account": "fixture@example.com",
  "connected": true,
  "devices": [
    {
      "id": "fixture-node-1",
      "name": "fixture-host",
      "ipv4Address": "100.100.1.2",
      "ipv6Address": "fd7a:115c:a1e0::1",
      "magicDNSAddress": "fixture-host.example.ts.net",
      "isOnline": true
    }
  ]
}
```

也可以在 iPhone AgentInbox 的“机器 → 导入 Tailscale 设备”粘贴 JSON，或选择导出的 UTF-8 JSON 文件，然后点“预览设备”和“确认替换设备快照”。`agentinbox://tailnet-import` 只打开该导入页，不接受凭据或自动保存。取消预览、无效数据、存储失败不替换现有内存设备；预览不会修改磁盘。

每次导入最多 256 KiB、512 台设备；必填文本最长 256 UTF-8 字节。重复的同一 ID／相同内容合并，冲突内容拒绝整次导入；改名或 IP 变化按账号与 ID 更新，同名不同 ID 保持区分。清除设备快照不清 Keychain 配对。快照保存在 App 私有受保护且不备份的目录，不保留输入里的未知字段。

## 连接与故障含义

导入时间和导出时的在线／VPN 状态均为快照。当前 App 和 Widget 使用 iPhone 系统网络路径；VPN 必须由 iPhone 的 Tailscale App 维护。服务超时只能表明连接受限或服务不可达，不能断定 VPN 已断开、机器离线或 ACL 拒绝。明确 401／403 才显示应用权限拒绝；无主机心跳与认证失败分开显示。

主机仍需显式启用只读发现监听：

```sh
agentinbox host /absolute/private/host.local.json \
  --discovery-listen 100.100.1.2:8788 \
  --discovery-relay-url https://relay.example.ts.net:8443
```

地址是示例，须使用已配置的主机 Tailnet IP 和中转地址。设备导入不会修改主机、ACL、Tailscale Serve 或应用配对；发现探测不携带设备凭据。ATS 明文例外只覆盖 Tailscale IPv4／IPv6 CIDR，其他地址继续使用 HTTPS；[Apple 官方配置说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)。前台及网络路径变化会重新探测；App 挂起、进程终止、锁屏时的 APNs 与 Widget 回传仍须按功能 7 单独实测。
