# 日本 relay device-admin 限定升级结果

2026-10-15：按 `DEVICE-ADMIN-DEPLOY.md` 已批准清单完成。仅升级日本 `agentinbox-relay.service`，重启恰一次；未重启 Mac 或 Ubuntu host。

源码 commit `2d021a5cdce5d4a018845abcf3498a3a1974fca2`，审查 patch `b26950f33fdd5c0b9f5f0d3f146c7c7392b3534514f80b6b787a8db17dfb7747`。实际运行文件 `/opt/agentinbox/releases/0.1.0-device-admin/agentinbox`，SHA256 `790a3c490663a180cd636d45a95ac23198999331b14a80aed41b30e8ac737429`；PID `737393 → 738473`，active/enabled。上传后核验 SHA、静态 x86_64 ELF（INTERP0/NEEDED0）及 Linux 原生 usage，包含 device-admin。

操作前与重启前 fresh 两 host 的 prepare-upgrade 均 ready/draining/startup=true，activeHooks、activeRequests、submitting、pendingReceipts、relayOutstanding 全零，回执目录仅计数为零。server 先核对 schema，再只读聚合 pending/submitting/unknown、claimed、outbox、pair_codes、devices、device_credentials、revoked_credentials，九项均零。只替换 unit 的 ExecStart 二进制路径；原 `/etc/agentinbox/relay.local.json` 路径、全部参数与其余 unit 字节保持一致，经 systemd-analyze verify 后重载定义，再次检查零门槛才 restart。

升级后：

- localhost 与私网 HTTPS 的无认证 upgrade-status 均 401；mac-mini、host-a 各自认证得到 200 且三个远端状态全零。私网 curl 的 `ssl_verify_result=0`，无 insecure 或手动 resolve。
- SQL 九项仍全部为零；新 service actual executable、SHA、active/enabled 均实测匹配。
- 以既有数据库 owner 运行 `runuser -u agentinbox -- /opt/agentinbox/releases/0.1.0-device-admin/agentinbox device-admin /var/lib/agentinbox/inbox.sqlite list`，exit0，结果 `{"devices":[]}`。该命令前后 relay PID 均为 738473；DB/WAL/SHM/父目录的 uid/gid/mode 及命令前后 inode 均保持一致。
- Mac host PID1709、SHA553f2131…；Ubuntu host PID1781909、SHAfa74df1c…；保持原 upgrade-guard 二进制、原 PID、drained/fresh ready 五项零。原 Ubuntu Codex/Herdr 五个进程的 PID/exe/内核启动时间一致；Xray551464、nginx709483/709484/709485、tailscaled320415 的 PID/exe/start ticks 亦一致。

在线 SQLite 备份 `/opt/agentinbox/backups/inbox-before-0.1.0-device-admin.sqlite`，root600、父目录700；旧 unit 备份 `/opt/agentinbox/releases/0.1.0-device-admin/agentinbox-relay.service.previous` root600。旧 `/opt/agentinbox/releases/0.1.0-upgrade-guard/agentinbox` 保留并复核 SHAfa74df1c…。未恢复或覆盖活数据库。

未实际 revoke、配对或创建设备身份，未读配对码/APNs 私钥，未改配置、凭据、APNs 设置、hooks、网络、ACL 或 Funnel。两枚现有 host token 仅在远端进程内用于本 host 身份认证，不经参数/日志/工具输出传递。未做手机或 APNs 投递验收。

独立证据见 `evidence/device-admin-deployment-result.json` 及同前缀 before/last-before-restart/after/candidate/prepared/switch/native-list/private-tls/backups-final JSON。一次准备断言因预设 relay.json 与实际 relay.local.json 路径不同而在任何 mutation 前停止；只读确认实际 invocation 后保留既有配置继续执行。SCP 传输期间旧 relay 一直运行；未发生额外 restart 或 rollback。
