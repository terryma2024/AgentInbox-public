# 2026-10-15 空闲版本升级清单

沿用用户已批准的日本 relay、Mac LaunchAgent、host-a 用户 systemd 安装范围。本次只更新这些既有 AgentInbox 服务的固定 release 路径；不新增服务、权限、网络、身份、签名、配对码或 APNs 凭据。手机离线，保持两端 drain，不接管新题。

## 不可变候选

- Mac ARM64 `dist/macos-arm64/agentinbox` SHA256 `553f2131319e84bf85eae34dc2e514aae57c170fcb06e3fc33851f2d2f950a1f`。
- Linux x86_64 static `dist/linux/agentinbox` SHA256 `fa74df1ca0dd08ae2eeb71e44b9bd18ca8dfb41db327511f42642d3d7aa2537f`。
- 新 release 名称 `0.1.0-upgrade-guard`。保留旧 release，不覆盖运行二进制。
- 源码审查见 UPGRADE-GUARD-REVIEW.md；本次不涉及 schema 迁移。源码/二进制清单见构建证据。

## 前置门槛与顺序

1. Mac/host-a：draining、startupReconciled 均 true，activeHooks/activeRequests/submitting 三项均 0；receipt-outbox 无条目。只读记录正常 daemon/Herdr PID 和启动时间。
2. 日本 SQLite：pending/submitting/unknown、已领取提交、推送 outbox 均 0；pair_codes/device_credentials/devices 均 0。只聚合，不输出问题或秘密。任意不符延期。
3. relay 先升级：独立 release 中安装并校验 Linux 二进制，受限 SQLite online backup 和旧 unit 备份；仅替换 ExecStart 的二进制路径，参数和配置完全保留，不带 --pair-code-file。verify 后只重启本服务一次；认证 upgrade-status 两 host 均零，未认证仍 401。
4. Mac/host-a host 后升级：各自独立 release 和旧服务定义备份，仅替换主服务二进制路径。切换前再查排空；只重启各自 AgentInbox job。现有 Claude helper 保持原兼容二进制，勿再次编辑全局 settings。
5. 新 host 启动对账完成、仍 draining、三项零，prepare-upgrade ready=true、pendingReceipts=0、relayOutstanding=0；私网 TLS、服务常驻状态、正常 daemon/Herdr 身份均验证。

## 回滚

若自身服务验证失败，保留所有数据库和 state；在没有 callback/提交且排空可核实时，恢复已备份服务定义指向旧 release。不得恢复数据库快照覆盖后续状态，不重放 unknown。若门槛无法确认，停在故障状态并报告，禁止强关活 hook。

同一数据库跨新→旧→新二进制的隔离演练已通过：native-binary-rollback.json；它使用明确模拟的引擎采用结果，验证二进制兼容、去重和旧 relay 拒绝新 guard，不是活跃真实 Agent 升级证明。实际服务执行结果另记 IDLE-UPGRADE-RESULT.md。
