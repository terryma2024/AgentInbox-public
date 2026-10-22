# Linux 空闲版本升级实际结果（2026-10-15）

已按 `docs/IDLE-UPGRADE-20261015.md` 完成日本 relay → host-a 用户 host 的限定升级。候选为 commit `d171b59b9b6d233956108c048c6ba73a773dc259`，Linux binary SHA256 `fa74df1ca0dd08ae2eeb71e44b9bd18ca8dfb41db327511f42642d3d7aa2537f`，source manifest SHA256 `49e2dbcf964e87a6807255155efb649e31edf94924c13794910850e4085ebb7f`。两项自有服务各 restart **1 次**，均 active/enabled；没有自动回滚分支或后续额外 restart。

| 目标 | unit | 当前二进制 | PID |
| --- | --- | --- | --- |
| relay-host relay | `/etc/systemd/system/agentinbox-relay.service` | `/opt/agentinbox/releases/0.1.0-upgrade-guard/agentinbox` | 737393 |
| host-a 用户 host | `/home/developer/.config/systemd/user/agentinbox-host.service` | `/home/developer/.local/share/agentinbox/releases/0.1.0-upgrade-guard/agentinbox` | 1763802 |

升级前只读确认 SQLite schema，再聚合 pending/submitting/unknown、claimed、outbox、pair_codes、devices/device_credentials，全部为 0。两个 host 保持 drain，host-a activeHooks/activeRequests/submitting 均 0、startupReconciled=true、receipt-outbox 无条目。旧 relay 的新 guard endpoint 返回预期 404，没有用有限历史列表冒充 unknown 计数。

relay 独立 release 安装、SHA/ELF/native usage 检查通过。两次聚合排空通过后，保留在线一致性数据库备份 `/opt/agentinbox/backups/inbox-before-0.1.0-upgrade-guard.sqlite`（600，父目录700）及旧 unit `/opt/agentinbox/releases/0.1.0-upgrade-guard/agentinbox-relay.service.previous`；只替换 ExecStart 二进制路径，参数完全保留。新 endpoint 无鉴权401，mac-mini/host-a 两个已认证 host 的 pending/submitting/unknown 均为0。未还原或覆盖活数据库，旧 JWT-cache release 保留。

随后 host-a 在新目录安装同一静态二进制。切换前两次 fresh hostctl status 三零、drain/startup true、receipt-outbox0，且经证书验证的自身 host-bound 三状态计数为0。备份旧 unit `/home/developer/.local/share/agentinbox/releases/0.1.0-upgrade-guard/agentinbox-host.service.previous`，仅替换主服务 ExecStart binary path。原兼容 Claude helper 和旧 `0.1.0` 二进制保留。

新 host 启动后仍 draining/startupReconciled=true，三项计数0；`prepare-upgrade` 返回 readyForUpgrade=true、pendingReceipts=0、relayOutstanding=0、upgradeBlockers=[]。正常 Codex/Herdr 的 PID、启动时间、可执行路径在切换前后完全一致。没有读取其 argv、任务或 pane 正文，没有接管或回题。

最后在正式私网 HTTPS 上复核新 endpoint：无鉴权401，两个 host均200／三状态全0，curl TLS verify0，没有 insecure 或手工 resolve。没有更改 network/Funnel/ACL、config、APNs key、配对码、凭据或全局 hooks；仅受限 host token 在进程内用于自身计数查询，没有输出值。Mac服务由root另行处理，本 agent未修改Mac服务或四份核心文档。

完整脱敏证据：`evidence/service-upgrade-linux-result.json`；阶段证据包括 `service-upgrade-preflight-linux.json`、`service-upgrade-linux-relay.json`、`service-upgrade-linux-host-a.json`、`service-upgrade-linux-tls.json`。这是实际空闲／排空服务升级证明，不是带活回调热升级、真实回滚或手机/APNs验收证明。

若后续验证失败，不能无条件停新job或恢复旧unit。必须重新确认fresh drain/startup/三零/outbox及认证自身pending/submitting/unknown全零；relay还需重新检查未解决、claim与outbox门槛。无法确认则保留现场并报告，不强关callback，也不恢复快照覆盖活数据库。
