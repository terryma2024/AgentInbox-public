# 本项目自有服务空闲升级 · 2026-10-15

范围沿用已批准的三台 AgentInbox 服务部署；源码冻结提交 `d171b59b9b6d233956108c048c6ba73a773dc259`，具体清单见 [IDLE-UPGRADE-20261015.md](IDLE-UPGRADE-20261015.md)。没有恢复数据库快照、修改凭据、配对码、APNs、原全局 hooks、正常 Codex daemon 或默认 Herdr。手机离线，两 host 保持 drain。

## 已执行

- 日本 relay：固定新 release `/opt/agentinbox/releases/0.1.0-upgrade-guard/agentinbox`，Linux SHA256 `fa74df1ca0dd08ae2eeb71e44b9bd18ca8dfb41db327511f42642d3d7aa2537f`。fresh 两次聚合全零，在线 SQLite backup 根用户600／父目录700，保留旧 unit 与旧 release，仅 ExecStart 二进制路径改变，一次服务重启后 active/enabled。新 upgrade-status 未认证401，两 host 认证200且各自三项零。
- Mac host：固定新 release `~/Library/Application Support/AgentInbox/releases/0.1.0-upgrade-guard/agentinbox`，Mac SHA256 `553f2131319e84bf85eae34dc2e514aae57c170fcb06e3fc33851f2d2f950a1f`。两次本地排空和认证远端零检查后，仅切换自身 LaunchAgent 的 ProgramArguments[0]。新实际进程路径吻合，启动对账完成，drain保留，三活动计数、回执、远端未决均零，prepare-upgrade ready=true。旧 release 和原 plist 备份保留。
- host-a host：固定新 release `/home/developer/.local/share/agentinbox/releases/0.1.0-upgrade-guard/agentinbox`，同一已校验 Linux SHA256。两次 fresh 本地／认证远端全零后，只替换用户 unit 的 ExecStart 二进制路径并重启本项目 host 一次。实际进程新路径吻合、active/enabled，仍 drain、startupReconciled=true、三项活动/回执/远端未决均零，prepare-upgrade ready=true。正常 Codex/Herdr 的 PID、启动时间和可执行文件前后完全相同。旧 binary、旧 helper 与 unit 备份保留。

Mac 正常 daemon91603、wrapper25959、默认Herdr4646 的 PID与启动时间在切换前后相同。精确 PID 仅表示当次核验，后续 CLI 独立测试可正常替换本项目 host 自身 PID，不应拿旧 PID 作永久身份。

## 审阅与失败边界

Mac 具体切换脚本先只读审阅；发现并修正无条件失败回滚分支。现在只有重新确认本地drain、启动完成、三项零／outbox空，且认证自身relay pending/submitting/unknown零后才能停止新job回旧版；无法确认就保留现场。Linux脚本遇异常也不自动重启或回滚。

[Mac 切换证据](../evidence/service-upgrade-mac-result.json)、[relay 切换证据](../evidence/service-upgrade-linux-relay.json)、[Ubuntu host 切换证据](../evidence/service-upgrade-linux-host-a.json)、[Mac 脚本审阅摘要](../evidence/mac-idle-upgrade-script-review.json)。

本次只证明真实空闲服务的版本替换与验证；隔离 [二进制回滚](BINARY-ROLLBACK-RESULT.md) 没有回滚已安装服务。两者都不能替代活跃真实 hook 的强关风险、真实手机/APNs、键盘同时竞答或完整双主机端到端验收。
