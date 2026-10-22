# 日本 relay 一次性配对码 seed 方案

> 以下保留原准备方案。用户本轮恢复手机在线、明确确认配对页就绪后，已按限定范围执行受限复制与seed；实际结果和失败边界见 [IPHONE-LIVE-20261015.md](IPHONE-LIVE-20261015.md)。不能重复照本方案导入已seed的同一码。

手机目前离线，限定配对码传递已获用户批准但尚未执行；未读取、复制或激活。手机准备好真 iPhone API连接与输入后才执行，已安装 App 可通过同一 tailnet 配对，无须持续连接 USB。此次只读preflight已完成，没有读取配对码内容，没有seed、restart、消费码或创建设备/凭据。

## 历史 preflight（不是当前版本路径）

2026-10-15 08:02:54（Asia/Shanghai）历史现场；下列 PID、路径和计数只记录当时，不能直接用于后续 seed：

- Mac/host-a已安装host均draining=true、startupReconciled=true，activeHooks/activeRequests/submitting三项0。
- 日本agentinbox-relay.service active/running，PID732051；User/Group=agentinbox，UMask0077，ProtectSystem=strict、ProtectHome=yes，唯一可写服务目录/var/lib/agentinbox。
- 实际ExecStart为 `/opt/agentinbox/releases/0.1.0-jwt-cache/agentinbox relay --config /etc/agentinbox/relay.local.json`。无现有dropin，Restart=on-failure、5秒、NRestarts0。
- DB为/var/lib/agentinbox/inbox.sqlite；requests空；pending/submitting/unknown计数0，已领取submitting计数0，pair_codes计数0、未用未过期计数0，APNs注册/active设备0，动态device凭据0，pending outbox0。APNs配置存在（未读取任何私钥/token值）。
- /etc/agentinbox/pairing.code为33bytes、0640 root:agentinbox；服务用户可读。只读取元数据，不输出或读取码内容。

元数据见 evidence/pair-seed-preflight.json。当前日本 relay 已升级至 `0.1.0-device-admin`，见 [实际部署记录](DEVICE-ADMIN-DEPLOY-RESULT.md)；当前部署以 [STATUS.md](STATUS.md) 为准。执行前重新读取当前 unit 的完整 ExecStart、实际二进制及摘要，并重新检查两端 prepare-upgrade、持久回执和 relay 完整未决／已领取计数；任一不清或无法确认均延期，不强制排空。

## 为什么使用短期runtime dropin

现有原生binary支持 `relay --config ... --pair-code-file ...`：进程启动时仅一次读取受限文件，trim后验证码长度8..128，SQLite保存SHA-256摘要与expiresAt=启动时刻+600秒。INSERT不是upsert：相同码曾seed过即会冲突，不能盲目重复重启。

在/run而非/etc放root受限dropin，仅覆写这一个unit的ExecStart并暂设Restart=no。暂停自动重启避免seed成功后偶然崩溃导致同码重复seed循环。删除runtime dropin并daemon-reload后恢复原Restart=on-failure；不再restart当前进程。当前进程argv仍可能显示一次性参数，但下一次正常启动从原unit命令启动，不复seed。

不修改常驻配置，不动Tailscale Serve、Xray、正常Codex/Herdr或host排空标记。

## 待负责人执行的具体顺序

这些步骤尚未执行：

1. 手机已显示正式配对页，私网HTTPS连接可达，用户准备输入；重新核对排空及DB元数据。需要十分钟内完成一次正式pair，不能提前seed等手机。
2. 确认/run/systemd/system/agentinbox-relay.service.d/90-pair-seed-once.conf不存在及无冲突；创建专属目录0700、文件0600。内容仅路径，不含码或token：

```ini
[Service]
ExecStart=
ExecStart=CURRENT_VERIFIED_BINARY relay --config /etc/agentinbox/relay.local.json --pair-code-file /etc/agentinbox/pairing.code
Restart=no
```

示例的 `CURRENT_VERIFIED_BINARY` 必须替换成刚核实的当前 unit 二进制绝对路径，保留当前所有原参数，仅追加一次性 `--pair-code-file`。它不是可直接安装的模板；不得照抄历史 jwt-cache／guard 路径而倒退推送 worker。若当前命令或参数与示例不同，按实际 ExecStart 构造并核对，不覆盖现有选项。

3. `systemctl daemon-reload`，核对该unit有效ExecStart与Restart=no，使用systemd-analyze verify检查。只执行一次 `systemctl restart agentinbox-relay.service`。
4. 确认unit active、新PID、loopback API/HTTPS可达；只读SQL核验pair_codes总数从0变1且未用未过期计数1。不要查询hash、code、token内容，不用测试客户端尝试/pair。
5. seed验证后立即删除仅该runtime文件；目录若为空可rmdir。`systemctl daemon-reload`，核对有效ExecStart无--pair-code-file、Restart恢复on-failure。**不再restart**。原常驻unit/config均不修改。
6. 由正式iPhone App执行一次 `/v1/pair`，响应设备密钥只进入正式Keychain。配对码通过用户批准的本地输入路径交给手机，不进入普通聊天、日志、仓库、截图或test fixture。配对后仅查询计数验证used码/设备凭据；APNs token由App注册，不替用户制造token。

## 失败与过期边界

如果第一次启动失败，先记录非秘密错误/服务状态与pair_codes计数，删除runtime dropin并daemon-reload恢复原unit；不得再用同码seed重试。码可能已入库，即便服务启动未完成。恢复基础服务或重新发码应由负责人按实际证据处理，不能直接删除DB行、恢复旧DB快照或盲改秘密文件。

如果600秒过期，手机pair应拒绝；同一文件再次seed仍可能因相同hash冲突而失败。不要自动创建替代码或凭据，不要消费码作为健康检查；由用户/负责人另行批准本地秘密更新流程。

seed只保存配对码摘要，不代表设备已配对；设备注册不代表APNs发送成功；APNs200不代表真机显示；Widget刷新/按钮原引擎采用仍须独立验收。
