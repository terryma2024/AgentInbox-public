# Device administration immutable patch review

结论：`merge / human_review_required`。未发现必须修改的代码问题。该标签来自补丁风险分类：本地数据库权限和持久撤销状态使其不适合自动合并；它不新增审批要求，也不授予部署权限。本轮只读审查没有执行产品代码、操作真实数据库、创建真实凭据或部署服务。

使用 `assess-patch-risk` 技能。按本次明确指定的交付位置保存本报告及 [结构化结果](../evidence/device-admin-review.json)，没有修改补丁、生产源码、测试或核心文档。

## 绑定的审查对象

- Repository：`/Users/developer/Projects/AgentInbox`
- Base：`647021ebd55eadf5fee6b3ede974de0dbd9c3046`
- 不可变补丁：`/private/tmp/agentinbox-device-admin-review.patch`
- SHA-256：`b26950f33fdd5c0b9f5f0d3f146c7c7392b3534514f80b6b787a8db17dfb7747`
- 精确范围：`src/main.rs`、`src/lib.rs`、`src/store.rs`、`src/apns.rs`、新增 `src/device_admin.rs` 与 `tests/device_admin.rs`。六个 postimage 的 SHA-256 及 Git blob 均与 metadata 一致。

生产变更由 native `main → device-admin` 和现有 `relay → self-revoke / APNs worker` 两条路径进入。无新依赖、schema migration、远程管理 endpoint、host 协议或凭据配置变化；本地 list/revoke CLI 是新增接口。Mac/host-a host 守卫可以保持原版，本次候选部署作用域可限 Japan relay/operator。

## 边界挑战结果

| 边界及源码 | 具体反例 | 核实结果与合法对照 |
| --- | --- | --- |
| 本地打开与元数据：`src/device_admin.rs:59–154` | 缺失路径、最终 symlink、0644 DB、错误 schema；误用 `Store::open` 会创建/恢复业务状态 | `lstat`、owner/mode、不可被其他用户写的直属目录、NOFOLLOW 和前后 dev/ino 检查；list 仅 READ_ONLY，revoke 仅 READ_WRITE，无 CREATE，完全不调用 `Store::open`。合法私有 schema 可列出，输出仅 id/name/revoked/pushActive，不查询 hash/token/业务正文。uid0 明确属于本地管理员。 |
| 配对 membership 与事务：`src/device_admin.rs:40–46`、`src/store.rs:329–334,468–476` | 未知 device、重复 revoke、最后一步取消 push 失败 | membership 与四步操作位于同一 IMMEDIATE 事务，未知 paired id 在写前报错；重复操作幂等。故障 trigger 在末步失败时，operator 和 self-revoke 的 marker/credential/active/outbox 全部回滚；成功后才输出 JSON。 |
| 角色隔离：`src/main.rs:17`、`src/relay.rs:147–170,256–271` | host key 调远程 revoke、撤销一个 paired device 误改其他设备/已领取答案 | 未增加网络管理接口；host 调 self-revoke 仍 403；operator 只针对 `device_credentials` 已存在 id。在线测试确认被撤销 key 后续 401，其他 device/host 可用，relay PID、已领取 request/response 不变。 |
| JWT 后发送门：`src/apns.rs:59–98`、`src/store.rs:432–434` | batch 已取出后 JWT 文件工作阻塞，随后设备被撤销 | request 构建完且 JWT/file 工作结束后，发送前重新联结同一 outbox、device、原 request；要求仍 pending/due/active、未撤销、原请求 pending 且未过期，查询失败也不发。FIFO 屏障测试实际观测 localhost proxy 无网络启动；合法待发 job 通过当前态谓词。 |
| 迟到结果：`src/store.rs:442–462` | revoke 已 cancelled 后，旧 send 的成功、临时失败或永久失败结果到达 | UPDATE 限定 `state='pending'`，三类迟到结果均不改变 cancelled、attempts、next；正常 pending job 保留既有成功/重试/失败逻辑。 |

APNs live check 与 HTTP send 之间没有跨网络原子性。已经完成 live check 获得授权或已经在途的请求无法撤回；本补丁不承诺撤销返回时所有旧通知均消失。缓存 batch 被撤销后在 JWT 结束前的场景有明确保护，不能将其扩大为任意发送时序保证。HTTP 旧已认证请求也不被本地操作强制中断；后续认证拒绝由既有认证路径验证。

本地 OS 权限是 operator 的授权边界；这不是限制拥有该 DB 写权限的同 uid 或 root 对数据库另行修改的机制。运维应以 DB owner 运行，例如已部署服务用户 `agentinbox`，避免 root 创建 WAL/SHM 后造成 owner 不一致；这不授予额外系统权限。

## 验证证据与限制

已检查 [RED](../evidence/device-admin-red.txt)、[GREEN](../evidence/device-admin-green.txt) 和 [完整原生回归](../evidence/device-admin-all-tests.txt)。五个语义场景均在旧实现失败、候选通过；它们观察实际 HTTP 权限/进程存活、SQLite 状态、故障回滚和受控 proxy，而非只验证新函数返回值。

完整回归实际 exit 0，由实现代理和 root 确认；本审查独立复核冻结的六个 postimage 未变。日志为 **61 passed / 0 failed / 1 ignored**。61 个 passed 含一个 `fixture_engine_process` 入口，因此默认 60 个实质 case；ignored 是需要显式旧二进制的 `binary_rollback`，不是 fixture。当前候选的 ignored rollback 尚未在本审查中运行，不能计为通过。此前版本的回滚记录不能代替当前候选结果。

本审查没有另行执行 subject-controlled tests，以保持只读、无网络/凭据的审查边界；使用冻结候选的已有运行证据。未将 Linux 构建/部署、真实 APNs 送达或实体设备闭环描述为本轮已验收。后续候选发布仍需匹配二进制及变更作用域，原有升级 drain/guard 约束继续适用。

## 风险分级与恢复

| 维度 | 结论 | 依据 |
| --- | --- | --- |
| 出错影响 | high | 共享 relay 的持久撤销与推送授权可能影响设备访问及通知。 |
| 回归可能性 | low | 事务与状态条件局部且明确，关键反例已有 RED→GREEN 和完整回归。 |
| 回归保护 | partial | 本机真实进程/DB/proxy 证据充分；没有当前候选 Linux rollout、真实 APNs 或回滚实跑。 |
| 可恢复性 | managed | 无 migration，可回滚 relay 二进制；已提交撤销应持久保留，代码回滚不等于取消撤销。旧 worker 会失去新防护。 |
| 审查置信度 | high | 精确 artifact、六 postimages、调用链、边界及针对性证据均已核对。 |

不合并的风险独立存在：遗失 paired key 缺少本地原生撤销入口；旧四步撤销可能部分提交；JWT 阻塞后的旧 batch 会发出；迟到结果可覆盖 cancelled。上述旧行为由 RED 证据直接支持。没有发现阻断本补丁合并的具体缺陷，也没有用尚未进行的真机或 Linux 验收推断代码漏洞。
