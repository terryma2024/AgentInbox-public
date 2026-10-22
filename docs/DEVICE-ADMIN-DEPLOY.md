# 本机设备管理修复：日本 relay 限定升级

沿用用户已批准的 relay-host AgentInbox relay 部署范围。本轮仅升级日本同一 systemd 服务的原生 release；不新增用户、权限、网络监听、管理凭据、APNs 配置或手机身份。Mac/host-a host 的守卫与协议未变，保持原 `0.1.0-upgrade-guard` release/drain，不重复重启。

源码 commit `2d021a5cdce5d4a018845abcf3498a3a1974fca2`，审查不可变 patch `b26950f33fdd5c0b9f5f0d3f146c7c7392b3534514f80b6b787a8db17dfb7747`。Linux 候选 SHA256 `790a3c490663a180cd636d45a95ac23198999331b14a80aed41b30e8ac737429`，静态 x86_64，无新 schema 或依赖。

1. fresh 两端 host：drain/startup 完成、三项活动／持久回执／认证远端三状态均零。server只读聚合 pending/submitting/unknown、claimed、outbox、pair_codes、devices/device_credentials/revoked_credentials 全零；若不符延期，不强停。
2. 独立安装 `/opt/agentinbox/releases/0.1.0-device-admin/agentinbox`，校验 SHA、native usage；保留 guard release。SQLite online backup 到 `/opt/agentinbox/backups/inbox-before-0.1.0-device-admin.sqlite` root600／父700；旧 unit 备份保留。
3. 只替换 unit 的 ExecStart 二进制路径；全部参数/config/worker凭据不变，不带 pair-code-file。verify 后再 fresh 空闲检查，只重启本项目 relay 一次。
4. 新 relay active/enabled/actual-exe/newSHA；未认证401，两host认证upgrade-status各自零，私网TLS验证正常。两host保持原二进制与drain，原 Codex/Herdr不停止。
5. 以既有 DB owner `agentinbox` 运行新原生命令 `device-admin /var/lib/agentinbox/inbox.sqlite list`，只读输出应为空设备列表；确认同一 relay PID仍运行、DB/WAL/SHM归属不变。**不执行真实设备 revoke**，不seed或消费配对码，不创建任何设备凭据。

失败时保留现场；回滚前须 fresh 核实同样零门槛，不能确认就不停止不确定进程。保留同一数据库，禁止恢复旧备份覆盖活数据。代码回滚不会撤销已持久撤销的设备。本轮实际执行结果另记 DEVICE-ADMIN-DEPLOY-RESULT.md。
