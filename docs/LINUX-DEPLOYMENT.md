# Linux relay 实际部署记录（2026-10-14）

> 以下保留初次安装与历史阶段事实。2026-10-15 三个本项目服务已更新至 `0.1.0-upgrade-guard`，APNs 已受限配置 Sandbox、手机仍未配对；当前结果以 [空闲升级记录](IDLE-UPGRADE-RESULT.md) 和 [支持矩阵](STATUS.md) 为准。

日本 `relay-host` 的 AgentInbox relay 已从初装 `0.1.0` 安全升级至独立 release `0.1.0-jwt-cache` 并运行。负责人按用户授权启用 HTTPS Certificates 后，已配置并验证仅 tailnet 的 [HTTPS 8443](https://relay.example.ts.net:8443)。后端仍是 `127.0.0.1:8787`，Funnel 没有启用、ACL 没有变化；既有 Xray `*:443` 的 PID 551464 前后保持一致。

## 实际安装与运行

- 目标：Ubuntu 26.04 LTS、x86_64、Tailscale 1.102.2，tailnet IP `100.64.0.10`。
- 当前原生静态 ELF：`/opt/agentinbox/releases/0.1.0-jwt-cache/agentinbox`，7,117,968 bytes；SHA256 `7113dd64f0851a852a1325ca8d646a416acc5e81ac210fd9a1dd60a4340588a1`。服务器上的 SHA256、`file`、readelf 与实际无配置 usage 执行均核对通过。无 `INTERP` 或 `NEEDED`；usage 按预期退出 1。
- 专用无登录用户／组 `agentinbox`；release 目录 root:root 755；配置目录 root:agentinbox 750；状态目录 agentinbox:agentinbox 700。
- `/etc/systemd/system/agentinbox-relay.service` 已验证、enabled、active；服务执行原生 ELF，只监听 `127.0.0.1:8787`。`NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`UMask=0077` 和仅状态目录可写均已核对。不安装任何目标机语言运行时。
- 配置 `/etc/agentinbox/relay.local.json` 为 root:agentinbox 640，APNs 为 null。SQLite 及 relay lock 为 agentinbox:agentinbox 600。

初次 service 执行失败 `203/EXEC`：安装时 `umask 077` 使两个新建父目录 `/opt/agentinbox` 与 `/opt/agentinbox/releases` 为 700。只将这两个本项目目录改为批准的 755 后，专用用户 usage 与正式 service 均成功。没有改变既有目录、服务、Xray 或 nginx。该过程保留在诊断证据中。

## 凭据位置与配对状态

凭据仅在服务器受限文件中生成，未输出到聊天或证据日志。

| 身份 | 绑定 hostId | 服务器文件 | 权限 |
| --- | --- | --- | --- |
| `host-mac` | `mac-mini` | `/etc/agentinbox/host-mac.token` | root:root 600 |
| `host-host-a` | `host-a` | `/etc/agentinbox/host-host-a.token` | root:root 600 |
| 尚未 seed 的配对材料 | 手机就绪后通过正式配对生成设备身份 | `/etc/agentinbox/pairing.code` | root:agentinbox 640 |

未创建静态 device 测试密钥。`pairing.code` 只生成文件，未写入数据库，因此 10 分钟配对期限尚未开始。常驻 unit 没有 `--pair-code-file` 参数，避免重启重复插入同一码。没有手动写 SQLite，也没有为配对停止有活回调的服务。之后需由负责人在手机就绪时安排获准的首次 seed。

## 实际 HTTP 与持久化检查

服务器现有系统 Python 仅用于一次性部署探针，不属于服务运行依赖。探针在进程内读取受限 token，日志只记状态和验证结果。

- 无鉴权 `/v1/requests`：401。
- 两个 host 的 own request 列表：200，初装均为空。
- host-mac 尝试绑定 host-host-a 的 claim 与 heartbeat：403。
- host credential 尝试 device revoke：403，未执行撤销。
- own mac-mini heartbeat：200。
- 保留 24 条空闲 HTTP keep-alive 连接后，新鉴权请求：200，0.0005 秒，原测试超时保持 4 秒。
- 重启前确认两个 host 的请求均为空；只重启本项目 service。原 heartbeat 经重启仍持久化，服务恢复 active/enabled，请求仍为空。

这证明实际 Linux 原生 relay 的安装、鉴权边界、调度与持久化。tailnet HTTPS 后续验证已完成（见下文）。手机正式配对／撤销、真实 APNs、Widget 或 Ubuntu 原生 Agent 的采用验收由对应负责人继续处理。

## host-a 只读检查

用户修复 SSH 配置后只读连接成功：Ubuntu 24.04.4 LTS、x86_64、kernel 7.0.0-31-generic、tmux 3.4、Tailscale 1.102.2，tailnet IP `100.64.0.11`。非登录 SSH PATH 中未找到这些 CLI，随后只读检查用户已有 `.local/bin` 并用 `--version` 确认：`/home/developer/.local/bin/codex` 0.162.1、`claude` 2.1.289、`herdr` 0.9.3。版本查询只设置探针进程内 PATH，未改变持久 shell 配置。未安装 host、CLI、hook 或 service，未读取 Agent 登录凭据。

## 证据

- `evidence/linux-native-patched-release.log`：本地最终静态构建。
- `evidence/linux-relay-host-smoke.log`：服务器原生 ELF 和 usage。
- `evidence/linux-relay-host-service.log`：目录修正后的 service 与权限。
- `evidence/linux-relay-host-http-validation.json`：实际鉴权与 keep-alive。
- `evidence/linux-relay-host-persistence.json`：空状态安全重启与持久化。
- `evidence/linux-relay-host-https-setup.log`：Serve 管理门槛，授权 URL 不记录。
- `evidence/linux-relay-host-final-state.log`：最终服务、权限、端口与 smoke 文件清理。
- `evidence/linux-host-a-inventory.log` 与 `evidence/linux-host-a-cli-versions.json`：Ubuntu Agent 目标只读 inventory 与现有 CLI 版本。

安装前确认同名用户／组、目录、service、8787／8443 与 Serve 配置不存在。本项目隔离 `/tmp` smoke 文件已逐项删除；正式 release、受限配置和数据库保留。

## 已批准 HTTPS 设置的浏览器准备

MagicDNS 已启用。优先使用无秘密入口 [Tailscale DNS 管理页](https://login.tailscale.com/admin/dns)，设置名称是 **HTTPS Certificates → Enable HTTPS**；无需修改现有 MagicDNS 或 ACL。该设置按 Tailscale 页面要求确认所发证书的机器域名与 tailnet 名称进入公开 Certificate Transparency 记录。[官方 HTTPS 文档](https://tailscale.com/docs/how-to/set-up-https-certificates)

管理启用前，CLI 的精确 consent URL 与原提示仅保存在服务器 root:root 600 文件，内容未放入证据或聊天。HTTPS 验证完成后，两个不再需要的受限文件已清理。此 agent 未打开浏览器或读取登录凭据；负责人顺序完成了已批准的 HTTPS 管理设置。

[官方 Serve 文档](https://tailscale.com/docs/features/tailscale-serve)说明交互 consent 流程的 Funnel 默认启用选项。因此优先只在 DNS 页启用 HTTPS；若确需使用 consent 页面，应核对实际界面并保持 Funnel 关闭。当前授权不包括 Funnel 或 ACL 变更。管理设置完成后，已成功运行批准的 `tailscale serve --bg --https=8443 http://127.0.0.1:8787` 并完成私网 TLS 验证。

`host-a` 已有活动 Codex daemon 与 Herdr 进程及 Unix listener，tmux default socket 文件存在但此次 `list-sessions` 返回 1。仅检查进程名、PID/父 PID、可执行路径、listener 与 socket 元数据；没有读取命令参数、pane 内容或 Agent 协议 payload，没有接管、回题或改设置。证据为 `evidence/linux-host-a-process-metadata.json` 和 `evidence/linux-host-a-socket-metadata.json`。

## JWT 缓存必要修复的安全升级

47 项原生测试和 Mac release 完成后，冻结 `src/apns.rs` 的 provider JWT 50 分钟缓存改动。Linux 仅增量重编本项目包，全部 38 项源码／vendor／许可证摘要匹配。

服务器升级前两次检查两个 host snapshot 为空；只读计数 requests、responses、outbox、devices、device_credentials、pair_codes 均为 0，APNs 为 null。新文件安装在 `/opt/agentinbox/releases/0.1.0-jwt-cache`，不覆盖运行二进制，原 `/opt/agentinbox/releases/0.1.0/agentinbox` 的摘要仍与旧值一致。通过 SQLite backup API 保存一致性备份 `/opt/agentinbox/backups/inbox-before-0.1.0-jwt-cache.sqlite`（root:root 600，父目录 700），没有手改或覆盖活数据库。

新 release 原生 usage 与 ELF 检查通过；保存原 unit 为新 release 中的 `agentinbox-relay.service.previous`，候选 unit 经 `systemd-analyze verify` 后只修改 `ExecStart` 路径。最后一次空状态检查通过才执行 daemon-reload/restart。

服务 active/enabled，实际 `/proc/MainPID/exe` 指向新 release。无鉴权 401、两个 host own snapshot 200／空、跨 host claim／heartbeat 403、host device-revoke 403。升级后 heartbeat 与升级前备份完全一致，所有六张队列表仍为 0。凭据、APNsnull、未 seed 的 pairing、Tailscale/Funnel/ACL 均未变化。

证据：`evidence/linux-jwt-cache-preflight.json`、`evidence/linux-jwt-cache-upgrade.log`、`evidence/linux-jwt-cache-native-verification.json`。APNs真实推送仍需后续专用密钥与 Apple 实机验收；本次未生成 Apple key 或使用浏览器。

## 私网 HTTPS 已完成验证

Serve CLI exit 0，最终配置仅有 `TCP.8443.HTTPS=true` 与 `relay.example.ts.net:8443` 的 `/` handler，代理到 `http://127.0.0.1:8787`。`AllowFunnel` 没有任何条目，等效没有启用 Funnel；没有运行 Funnel 命令或修改 ACL。Xray 443 的 PID 551464 前后相同。

Mac 与 host-a 分别用系统现有 curl 访问该正式域名：未鉴权 `/v1/requests` 返回 401，各自受限 host token 访问 `/v1/host/requests` 返回 200，返回记录均属于对应 hostId。四次 curl 全部 exit 0、`ssl_verify_result=0`；不使用 insecure TLS 或手工 resolve。探针 token 只在内存与 SSH/curl stdin 中传递，没有记录原响应、Authorization header 或在 host-a 写文件，没有 claim 或修改 callback。验证当时两个列表为空。

正式 URL：`https://relay.example.ts.net:8443`。执行端负责人已收到 HTTPS startup 门槛通过通知，随后 host 安装与原生采用由该负责人执行；本 agent 未接管 Agent 会话。

证据：`evidence/linux-serve-8443-setup.json`、`evidence/linux-private-https-client-validation.json`、`evidence/linux-serve-consent-cleanup.log`。APNs 仍为 null；真实 Apple 推送／手机与 Widget 验收不由这些 HTTPS 结果替代。

## APNs 配置后续

负责人在两host排空三项0且server无pending/submitting/unknown后，注册并仅配置本App Topic Specific Sandbox key9646XYP9ZX；p8仅relay受限文件640，原credentials保留，安全重启后Mac通过TLS认证ownsnapshot=[]，恢复两host捕获。临时Mac下载校验一致后清理。证据apns-configuration.json；没有设备配对/Token，不能声称推送送达。Production未配置。
