# 构建、部署和回滚

2026-10-17更新：host-a现为全目录／仅新会话且draining=false，旧447会话排除。当前状态以[恢复记录](HOST-A-CAPTURE-RECOVERY.md)和[STATUS](STATUS.md)最新日期为准；下述旧阶段的继续drain／待手机配对描述是历史记录。维护结束须恢复用户期望的捕获状态，心跳在线不能替代hostctl确认。

本项目已有日本 relay、Mac LaunchAgent、host-a 用户 systemd、限定 scope 的最小 Claude hooks，以及 tailnet HTTPS／本 App Sandbox APNs 的部署授权和实际安装记录。本文维护流程适用于这些自有服务；新增机器、目录、网络范围或其他账户不由此自动授权。

## 候选产物与当前安装

Mac／Linux 最新原生产物已构建，升级守卫和设备管理均有独立审查。**日本 relay 当前为 `0.1.0-device-admin`；Mac／Ubuntu host 保持 `0.1.0-upgrade-guard` 和原 PID，继续 drain。** 旧 release、在线 DB 备份和服务定义保留；最新排空、单次 relay 重启、认证、私网 TLS 与只读设备列表见 [DEVICE-ADMIN-DEPLOY-RESULT.md](DEVICE-ADMIN-DEPLOY-RESULT.md)，三个服务此前的 guard 升级见 [IDLE-UPGRADE-RESULT.md](IDLE-UPGRADE-RESULT.md)。

已有版本与路径见 [HOST-INSTALL-RESULT.md](HOST-INSTALL-RESULT.md)、[LINUX-DEPLOYMENT.md](LINUX-DEPLOYMENT.md)。日本 HTTPS 为仅 tailnet 的 8443，后端仍 loopback；Funnel／ACL 未改变，既有 Xray 443 保留。服务器密钥、Agent 登录凭据和含原用户配置的备份不进入仓库或日志。

Mac 开发构建为 `cargo build --locked --release`，原生回归为 `cargo test --locked --offline`。Rust/Cargo 仅构建机器需要；运行端使用原生二进制与系统设施，SQLite bundled，HTTP/TLS 采用 Rust 依赖。Linux x86_64 musl 产物用 `./scripts/build-linux-musl.sh` 构建，见 [LINUX.md](LINUX.md)；其他架构必须独立构建核验。

每个 release 保存独立路径和 SHA-256，保留旧产物，不覆盖正在运行的文件。数据库用 SQLite backup API 在线备份或停写后备份；schema 变更需明确兼容性，不能拿旧二进制盲读不兼容 schema。

## 新版 host 升级守卫

当前新版提供：

```text
agentinbox hostctl /absolute/private/state/ipc/hook.sock prepare-upgrade
```

命令先置 drain，再在 host 事件循环检查就绪。**仅 readyForUpgrade=true 且 draining=true 时退出 0；延期、错误、旧版不支持或状态无法确认均退出非零。** 它只报告，不停进程、不替换二进制、不重启服务。

成功必须同时满足：

- activeHooks、activeRequests、submitting 全部为零，startupReconciled=true。
- 私有 receipt-outbox 为空且可读；残留或损坏／不可读状态保守阻断。
- 认证 relay 的本 host 全部 pending、submitting、unknown 总数为零。完整聚合不依赖 UI 最近 200 条或不含 unknown 的启动 callback 快照。
- 远端 hostId 与凭据绑定相符，计数为合法非负整数且无溢出；认证失败、断线、畸形快照、非成功 HTTP 均拒绝。

仅该远端 guard HTTP 查询使用 **2 秒预算**；原 get_json／post_json 的 15 秒行为不变。这个预算不代表整个控制命令的端到端耗时保证。控制 reader 提前关闭不应终止 host；drain marker 写失败返回结构化拒绝并保留进程。

旧 relay 没有 `GET /v1/host/upgrade-status` 时返回 404，新 guard 必须 fail closed；不能把它当成零。新 CLI 对旧 host 的未知操作也不能放行。首次从旧版本迁移须按具体 fresh preflight 方案做等价完整对账与受控切换，不能删除错误检查以绕过版本不兼容。旧 `status`／`drain` 的三项零值不足以证明远端 unknown 或持久回执为空。

## 排空与实际切换

先停止接收新 hook／callback，保留原活跃请求完成的机会。有活跃 helper、任何 submitting、unknown 或待送回执就延期；不得用超时 kill 达成“排空”。原 callback 是临时能力，host 重启不能继承，结果不确定不能盲重派。

完整就绪后，记录旧路径／摘要、数据备份、配置和服务定义，按已授权的具体计划切到独立新 release。验证原生 usage、监听、角色认证、host 完整状态和心跳，并保留 drain。本轮手机已重新连接，正式配对与通知注册仍待完成，空闲升级成功不意味着可以立即恢复手机应答捕获。

relay 重启前同样确认无未解决的领取／提交与待处理回执；重启会把已领取 submitting 保守改为 unknown。升级后要检查原请求、响应 ID 和状态，而不是通过重放答案消除 unknown。Mac host 使用原用户 LaunchAgent，Ubuntu host 使用原用户 systemd；不能让 relay 隔离账户读取用户 Agent 登录资料。

## 回滚

回滚前也先排空，使用明确兼容的旧 release，保留同一数据库。恢复数据库快照会丢失后续回复并可能制造重放，不能直接覆盖活数据库。无法确认 schema 兼容时暂停切换并对账。

[当前新旧原生二进制回滚证据](../evidence/device-admin-binary-rollback.json) 使用真实旧／新 Mac 产物和同一独立测试数据库：原 responseId 保留、相同答案仍幂等、零新领取；新 host 面对旧 relay 的缺失 guard 接口拒绝升级。其原引擎结果是模拟 fixture，installedServicesChanged=false，不代表已回滚任何已安装服务，也不替代活跃生产 hook 升级／回滚现场验收。

## 权限与网络

配置及 host token 为 0600，state 为 0700，私有 IPC 为 0600；正式 relay 配置按专用用户／组的最小权限保存。部署模板仅作参考，绝对路径和身份必须核实。开发 relay 默认 loopback；已批准的 tailnet HTTPS 通过既有入口访问，不为方便绑定 0.0.0.0，也不扩大既有授权范围。

APNs 需要 relay 到 Apple 443 的 HTTP/2 出站与准确时钟。通知仅含通用提示／不透明 requestId，题目正文仍经认证 API 读取。本轮已执行获批的限定配对码复制与seed，正式手机配对和APNs送达仍待验收，见 [STATUS.md](STATUS.md)。


## 设备撤销

日本服务已有本机 `device-admin` 命令，使用数据库 owner 的既有 OS 权限，无网络管理身份。列出与准确撤销命令、事务保证和已发送推送的边界见 [DEVICE-ADMIN.md](DEVICE-ADMIN.md)。当前真实服务器只执行空列表，未撤销真实设备；不要用撤销或配对来做健康检查。
