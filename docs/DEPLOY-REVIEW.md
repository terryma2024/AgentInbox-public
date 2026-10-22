# 下一阶段具体操作清单（等待授权）

> 本文保留原授权清单。用户后续已明确批准并完成该限定范围，当前安装结果见 [STATUS.md](STATUS.md)；不是等待重复确认。新的机器、scope、网络或凭据范围不由此自动授权。

## 已核对的目标

- `ssh relay-host` 当前使用已有 root SSH 身份；Ubuntu 26.04、x86_64、Tailscale 1.102.2。
- 仅 tailnet 地址：`100.64.0.10`、`relay.example.ts.net`。
- `tailscale serve status` 当前没有配置；公网 `*:443` 是既有 Xray。保留该监听与现有 nginx 8080/8081。
- 本阶段部署 relay；该服务器未安装 Codex/Claude，不能算 Ubuntu Agent 执行端验收。

## 服务器变更（批准后执行）

1. 先将最终静态二进制传到 `/tmp/agentinbox-smoke-0.1.0/agentinbox`，核对 SHA256、`file`、无动态依赖，执行无配置的 usage 退出；不读取 Agent 凭据。
2. 新建无登录服务用户／组 `agentinbox`；目录 `/opt/agentinbox/releases/0.1.0`（root 所有、755）、`/etc/agentinbox`（root:agentinbox、750）、`/var/lib/agentinbox`（agentinbox、700）。发布仅本项目二进制，不安装 Rust/Go/Node/Python 工具链。
3. 独立配置 `/etc/agentinbox/relay.local.json`（root:agentinbox、640）；SQLite `/var/lib/agentinbox/inbox.sqlite`（600）。只监听 `127.0.0.1:8787`。初期 APNs 为 null；凭据创建只在获得对应授权后本机完成，不传聊天或记日志。
4. 安装项目 `deploy/agentinbox-relay.service` 到 `/etc/systemd/system/agentinbox-relay.service`；`systemd-analyze verify` 后 `daemon-reload`、enable/start。该进程以 agentinbox 运行，ProtectSystem/ProtectHome、NoNewPrivileges、PrivateTmp、UMask0077。
5. 私网 HTTPS 拟用 `tailscale serve --bg --https=8443 http://127.0.0.1:8787`，避免既有公网443。执行前再检查8443与Serve状态；只给tailnet，不使用Funnel，不改防火墙／SSH／既有代理。若HTTPS或ACL需要新增管理设置，暂停并列出实际差异，不自动扩大权限。
6. 验证未配对401、角色隔离、精确绑定、撤销；持久化与服务重启仅在没有提交／活回调时进行。记录实际 Linux 执行结果，再删除本项目 `/tmp` 烟测文件。

本次服务初装不覆盖已有文件。发现同名用户、目录、服务或监听有不明归属时停下核对，不直接替换。后续升级先排空、保留旧release与数据库备份；不强关活hook、不回滚覆盖活数据库。

## Apple 与真 iPhone（单独授权）

- 用户已允许创建独立 App 记录。拟定 App `dev.matianyi.agentinbox`，Widget `dev.matianyi.agentinbox.widget`，团队 `YOUR_TEAM_ID`，App Group `group.dev.matianyi.agentinbox`，SKU `agentinbox-20261014`。
- 新增 App/Widget 专用标识及 App Group，启用本 App 的 Push Notifications、App Groups、共享 Keychain；仅使用适用的已有开发签名证书。若需要新签名私钥或证书，先说明具体要求；不自动生成。
- 在连接并信任的 iPhone 17 Pro / iOS26 上安装本项目 App+Widget，并请求该 App 的通知权限；不修改旧 App。手机的开发者模式／设备信任必须由用户本人确认。
- APNs 选择适用已有密钥或由用户在后台手动创建；私钥仅写到relay受限文件（agentinbox只读），不放仓库、不输出到聊天。若授权代建，需独立明确授权具体 Apple APNs key；仅创建 App 不包含此授权。
- 配对只创建设备自己的 Keychain 密钥和独立 host 身份，随后测试撤销；不读取或上传 Agent 登录凭据。
- 验收真实 APNs → App独立收件箱 → Widget短选／中文详情回复 → 原生精确采用。模拟器通知注入不计数。

## 仍需信息

Ubuntu Agent 执行端是否另有机器？需其 Tailscale 地址／已有 SSH alias、CPU 架构、Codex/Claude 与 tmux/Herdr 环境。Mac用户级 LaunchAgent、Claude用户级hooks差异会另给精确文件与当前配置合并方案，再获安装批准。
