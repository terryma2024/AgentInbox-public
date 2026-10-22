# 原生核心实际接口与边界

## 运行

Rust 1.96.1；Cargo.lock 锁定依赖。`cargo test --locked --offline`；依赖首次下载使用 `cargo fetch --locked`。

开发：`target/debug/agentinbox relay --config evidence/local-dev/relay.json`。
指定本地已有测试配对码：追加 `--pair-code-file evidence/local-dev/pair-code`。此文件不是 APNs 凭据；每次导入只允许一个新码。配对码不自动生成，也不打印手机密钥。码 SHA-256 存储，10 分钟过期，只能成功使用一次；失败每分钟最多 5 次（当前是 relay 全局限速）。导入仅在启动时；活跃 hook 时不能为导入新码强制重启。

relay 原生监听仍仅允许 loopback。用户已授权并安装 Mac LaunchAgent、Ubuntu 用户 systemd host 与日本 systemd relay；获准的 Tailscale Serve 提供仅 tailnet HTTPS8443，后端仍为 127.0.0.1。Mac 与 Ubuntu 已验证该私网入口的真实 TLS 证书，未启用 Funnel、未改 ACL，既有 Xray 443 保留。当前本 App 专用 Sandbox APNs 密钥已配置在 relay 受限文件中；实体手机签名安装不等于配对、APNs 注册或送达通过，手机本轮已重新连接并启动App，正式配对与推送步骤正在联调。

当前日本 relay 为 `0.1.0-device-admin`；Mac／Ubuntu host 保持 `0.1.0-upgrade-guard`，继续 drain，本轮只重启 relay 一次。安装历史见 [HOST-INSTALL-RESULT.md](HOST-INSTALL-RESULT.md)、[LINUX-DEPLOYMENT.md](LINUX-DEPLOYMENT.md)，最新 relay 切换与原生设备管理只读验证见 [DEVICE-ADMIN-DEPLOY-RESULT.md](DEVICE-ADMIN-DEPLOY-RESULT.md)，此前三个服务的 guard 切换见 [IDLE-UPGRADE-RESULT.md](IDLE-UPGRADE-RESULT.md)，入口支持见 [STATUS.md](STATUS.md)。

## 配置 schema

```json
{
  "listen": "127.0.0.1:8787",
  "database": "/absolute/path/relay.sqlite",
  "credentials": [
    {"id":"device-id","role":"device","token":"<fixture-or-provisioned-token>","hostId":null,"revoked":false},
    {"id":"host-id","role":"host","token":"<provisioned-host-token>","hostId":"mac-mini","revoked":false}
  ],
  "apns": null
}
```

配置认证 token 由受限文件保存：host token 为 0600；已安装 relay 配置按专用用户／组最小权限保存（受控服务组可读的 0640、上级目录 0750），不得向其他用户开放。本项目 fixture 为公开、非秘密测试常量，不能用于实际设备或服务器。真实配对设备的 API 密钥仅在响应里返回一次，SQLite 保存 SHA-256；iOS 必须使用 Keychain。数据库、WAL、SHM与排他锁限制 0600。每次请求重读配置，配置撤销即时生效；手机主动撤销还会持久写 SQLite，重启不会恢复其认证权限。

APNs 配置替换 `null`：

```json
{"teamId":"<Apple Team ID>","keyId":"<APNs Key ID>","topic":"<App Bundle ID>","privateKeyPath":"/protected/path/AuthKey.p8"}
```

生产值和密钥文件只由已授权的本地／服务器受限配置提供，不粘贴到聊天。APNs worker 为 Rust reqwest/rustls 原生 HTTP/2，p256 签 ES256（worker内JWT复用50分钟后更新），不依赖 Node/Python/curl。通知只含通用中文提示和不透明 requestId；collapse ID 用 SHA-256 64 位十六进制，expiration 使用原问题到期时间。推送 outbox 持久化；临时失败 60 秒后重试，永久错误标失败。410 只禁用无效推送 token，不撤销设备 API 密钥。本项目 Sandbox 密钥已受限配置，但实体手机当前尚未完成配对、token 注册和送达验收；payload／队列测试不能证明 iPhone 收到通知。

## HTTP

除 `POST /v1/pair` 外，所有 API 使用 Bearer。设备 role 不能使用 host API；host role 不能提交手机答案；hostId来自认证凭据，正文/查询不能覆盖它。

- `POST /v1/pair`：`{"code":"一次性码","name":"iPhone"}` → `{"deviceId":"opaque","token":"仅返回一次的设备密钥"}`，免 Bearer。
- `POST /v1/devices/revoke`：已认证设备自撤销，`{}` → `{"revoked":true}`。后续请求 401，并取消待发推送。
- `POST /v1/devices/token`：`{"token":"APNs 十六进制 token","environment":"sandbox"}` → `{"registered":true}`；也支持 `production`。新 token 注册时补入当前 pending 问题的 outbox；request/device 唯一索引阻止重复注册重复入队。
- `GET /v1/host/responses?requestId=<opaque-id>`：本 host 单请求领取；`hostId`可选，提供时必须相符。事务标记 claimed 后才发送 HTTP 响应；连接丢失不能再次领取。缺 requestId 返回 400。
- 请求详情/列表包括当前 `state` 与 `responseId`；设备视图移除 `native`。host只能读取自身请求。
- host receipt 的 requestId、responseId 与凭据 hostId 三重校验；adopted必须是已领取响应，并有非空原引擎 evidence。unknown 可以用精确原采用证明对账为 adopted，但不允许重新派发。

其他 JSON 字段见 PROTOCOL.md。当前 initial revision必须 1；题目变化应 invalidated旧请求，再发新产品 requestId（原生请求ID实际改变时）；没有编辑旧题 revision 的 API。相同原生绑定不允许创建另一产品请求；终态不能回 pending。

## 恢复与测试

同一数据库只运行一个 relay：数据库路径旁 OS 排他文件锁拒绝第二实例。启动把已经领取的 submitting 改 unknown；未领取回复保留等待唯一领取。pending不自动伪造已采用；host必须重新验证活跃 runtime，旧 callback不能继承。SQLite 中 evidence只是 host 提供的证明摘要；relay没有能力独立确认引擎采用。

**2026-10-14 历史快照**：`evidence/native-all-tests.txt` 记录当时 28 项原生测试通过（13 adapter、10 core state、1 role、1 APNs payload、3 HTTP 子进程），包括并发唯一获胜、旧 revision/过期、响应ID内容冲突、领取后进程重启unknown、不重派、精确receipt对账、host隔离与即时撤销、一次性配对及持久撤销、outbox重启/重试/永久失败/新token补投。`evidence/outbox-red.txt`保留补投修复前真实失败。这组 28 项不是当前测试总数。

最新设备管理修复全套为61 passed、0 failed、1 ignored；passed含1个内部fixture入口。显式旧新二进制回滚已用当前release另跑通过，合并62唯一方法／61实质测试，见 [精确源检查点](../evidence/device-admin-six-postimage-checkpoint.json)、[当前回滚](../evidence/device-admin-binary-rollback.json)。完整入口边界以 [STATUS.md](STATUS.md) 为准。

一次早期 HTTP 黑盒运行出现连接重置，保留在 evidence/relay-process.txt；单独复现通过。之后定位环境代理干扰，原生私网client禁用环境proxy，黑盒Client也直连；tiny_http禁止手动Connection响应头，原生client使用Connection: close请求头，全组回归。目标是轻量请求接口，原生client采用短连接；不是远程终端服务。

新增完整启动与在线接口：`GET /v1/host/requests` 只供host角色，SQL先按凭据hostId与pending/submitting筛选，不受App历史200条限制；含当前responseId，不能继承native callback。`POST /v1/host/heartbeat {}` 按凭据hostId写服务器时间，空收件箱也每10秒更新，30秒无心跳显示离线；正文hostId若提供必须匹配。


## 完整升级门槛

`status`／`drain` 的 activeHooks、activeRequests、submitting 三项零值只说明本地内存状态，不足以许可升级。新版 `agentinbox hostctl SOCKET prepare-upgrade` 先置 drain；仅本地三项零、startupReconciled=true、私有 receipt-outbox 可读且为空，并且认证 relay 的本 host 全部 pending／submitting／unknown 为零时，返回 readyForUpgrade=true、draining=true 并 exit 0。它不自动停止进程、替换版本或恢复旧 callback。

完整聚合使用 `GET /v1/host/upgrade-status`，不受历史 200 条限制，也不遗漏 unknown。仅 guard 的远端 HTTP 查询预算为 2 秒，普通 HTTP 调用仍是 15 秒。旧 relay 的 404、认证失败、断线、错误 host、畸形或非法计数均拒绝升级；不能把失败当作空队列。控制 reader 断开或 drain 写失败不应终止 host。回滚也必须 fresh 核对门槛；无法确认时保留故障状态并报告，不能强关活 hook 或恢复数据库覆盖后续回复。见 [PROTOCOL.md](PROTOCOL.md)、[OPERATIONS.md](OPERATIONS.md)、[UPGRADE-GUARD-REVIEW.md](UPGRADE-GUARD-REVIEW.md)。


真实普通 Claude 的绑定等待期限结束后，helper 在外层 hook 超时前正常输出 `{}`，同一原题仍显示本机待答选项，未生成工具结果；到期旧答案409、无派发。该现场结果使用临时隔离配置，具体机制与范围见 [CLAUDE-HOOK-TIMEOUT.md](CLAUDE-HOOK-TIMEOUT.md)，不能推断 PermissionRequest 自动批准或拒绝。


设备丢失后的本机撤销使用 `agentinbox device-admin DATABASE revoke DEVICE_ID`，数据库 owner 的现有 OS 权限即可操作，不创建数据库、不迁移或执行启动 recovery。原子撤销、发送前重新授权与在途边界见 [DEVICE-ADMIN.md](DEVICE-ADMIN.md)。
