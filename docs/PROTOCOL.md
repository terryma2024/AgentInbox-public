# 本地 API v1

开发 HTTP 默认 127.0.0.1:8787；已部署 relay 的后端仍为 loopback，由获准的 tailnet HTTPS8443 提供私网入口。除 `POST /v1/pair` 外，API 使用 `Authorization: Bearer <角色凭据>`，不记认证值。host 与 device 身份分离；hostId 来自认证凭据，正文或查询不能覆盖。时间为 Unix 秒。

## 请求与答案

2026-10-22 分步回执已部署至 relay；引擎支持仍按入口区分。新字段及兼容语义见本文“回复分步回执”和 [本轮验证边界](REPLY-RELIABILITY.md)。

Request JSON（Swift Codable 同名）：

```json
{"requestId":"opaque-id","revision":1,"expiresAt":1792000000,"state":"pending","kind":"choice","hostId":"mac-mini","engine":"codex","runtimeId":"daemon-pid-start","sessionId":"thread","turnId":"turn","nativeRequestId":"native-rpc-id","itemId":"item","title":"请选择","body":"问题正文","options":[{"id":"o1","label":"Alpha"},{"id":"o2","label":"Beta"}],"multiSelect":false,"createdAt":1791999400,"updatedAt":1791999400}
```

完整原生参数存于仅 host 可见的 native JSON；device 视图移除 native。问题内容、选项和可审阅审批摘要保留在设备可见字段；无法完整展示的审批留在原生界面。原生未提供的 turn／prompt 等身份可为 null，不制造字段；缺少足以精确绑定的必要身份时拒绝接管。展示 pane／launchSurface 不参与授权，unknown 来源不能用于猜测路由。

请求可带 `projectPath`、`sessionLabel` 及 `decisionContext:{taskGoal,blockingReason,impactScope,originalContent}`。上下文字段为可选字符串或 null；缺失／空白在手机显示“未知”。originalContent 保存面向决策的完整原始参数 JSON 字符串，含全部问题、选项说明或命令与工具参数，独立于摘要；不整体开放 host 专用 native。新请求的 decisionContext、projectPath、sessionLabel 一起纳入 bindingDigest；没有 decisionContext 对象的历史请求保留旧算法。详见 [数据来源及验证边界](DECISION-CONTEXT.md)。

多题采用 `kind="questions"` 和 `questions:[{id,header,prompt,options:[{id,label}],multiSelect,allowText}]`。原生单题也可保留 questions 作题面，但答案编码仍由 kind 决定：

```json
{"responseId":"uuid","requestId":"opaque-id","revision":1,"optionIds":["o2"],"text":null,"answers":{}}
```

仅 `kind="questions"` 使用嵌套 answers，例如 `{"question-native-id":{"optionIds":["o2"],"text":null}}`，并保持顶层 optionIds 为空、text 为空。其他单题使用顶层 optionIds／text，answers 必须为空。选择与非空文字互斥；所有多题均须回答，选项必须属于原题且不得重复。客户端在写入稳定 journal 前验证，relay 与 host 再验证。

同一设备、相同 responseId 与内容幂等返回已存记录及当前状态；不同内容或不同拥有者返回 409。新的旧 revision、过期／终态候选返回 409，非法选项或混合编码返回 400。设备仅提交产品选项 ID，由 host 映射原始标签。题目变化不能编辑旧题再套用答案：旧请求失效，新题采用独立产品 ID／原生绑定；终态不能回 pending。

## 设备与通用读取

| 方法与路径 | 结果／限制 |
|---|---|
| GET /v1/capabilities | 经认证，返回 replyProgressVersion=1、bindingDigestVersion=1；404 才作为旧协议能力，断线或畸形结果不视为兼容成功。 |
| POST /v1/pair | 一次性短期码换设备身份；成功消费一次，设备密钥仅返回一次。实际配对证据见 STATUS.md。 |
| GET /v1/requests | 当前设备可见请求，UI 最近历史最多 200 条；host 身份仅返回自己的请求。不是升级完整性接口。 |
| GET /v1/requests/{id} | 精确请求，包含当前 state 与 responseId；host 不能读取别的 host 请求。 |
| POST /v1/requests/{id}/responses | 仅 device，路径／正文 requestId 必须相同；成功为 submitting，不能据此宣称 adopted。 |
| GET /v1/hosts | hostId、name、online、lastSeen；心跳不证明原 callback 仍活跃。 |
| POST /v1/devices/token | 仅 device；body 为 {token,environment}，APNs 通知仅通用提示／不透明 requestId。 |
| POST /v1/devices/revoke | 设备自撤销，持久拒绝后续认证并取消待发 push；仅删除本机 Keychain 不等于服务器撤销。 |

## host API

以下路径仅接受 host 角色，设备调用拒绝：

| 方法与路径 | 结果／限制 |
|---|---|
| POST /v1/host/requests | 携带 native 创建初始 revision=1 的绑定请求；相同原生绑定不能创建另一产品请求。 |
| GET /v1/host/requests | 本认证 host 的完整 pending／submitting 启动快照，不受 UI 200 条限制；不含 unknown，不可单独用作升级判断。 |
| GET /v1/host/reply-progress?incomplete=true | 本认证 host 完整的已接收、仍 awaiting continuation 记录；只读、不领取、不恢复旧 callback。 |
| GET /v1/host/responses?requestId={id} | 必须指定精确 requestId，只领取一次；可选 hostId 必须与认证 host 一致。事务先持久标记 claimed 才发送 HTTP 回复。 |
| POST /v1/host/receipt | {requestId,responseId,state,evidence}；核对认证 host、原请求、获胜 responseId，执行合法终态迁移。 |
| POST /v1/host/heartbeat | body 的可选 hostId 必须匹配凭据，更新本 host 心跳。 |
| GET /v1/host/upgrade-status | 本 host 的完整 pending／submitting／unknown 聚合，见下文。 |

领取连接不确定时不再次派发；claimed submitting 在 relay 重启时变 unknown。host 重启先持久对账旧 callback，在恢复完成前拒绝新接管。终态回执先写私有 outbox 并 fsync，重连只重送回执；手机已提交但本机先处理的竞态，只读对账精确 responseId，不为此领取手机候选。

adopted 必须对应已领取的响应和非空原引擎采用证据摘要；HTTP 200、helper 输出或最终自然语言标记不自动等于采用。unknown 可凭精确原采用证明对账为 adopted，不允许由此重新执行。relay 依赖受信任 host 的证据，不能独立证明引擎采用；证据摘要不上传整段对话。实际入口覆盖见 [STATUS.md](STATUS.md)。

## 升级状态与本地维护命令

新版认证接口返回：

```json
{"hostId":"mac-mini","pending":0,"submitting":0,"unknown":0,"unknownRequests":0,"awaitingContinuation":0}
```

聚合绑定认证 host，查询不能切换归属；不返回问题内容。过期 pending 会收敛为 expired；submitting 与 unknown 不能通过到期自动当作已采用。该接口没有 UI 历史截断，也不能用不含 unknown 的启动快照替代。

2026-10-22 新版将 awaitingContinuation 加入兼容 unknown 聚合，确保只累加旧三字段的守卫仍会拒绝未完成观察；unknownRequests 才是精确的 state=unknown 数量。新版核验 awaitingContinuation 为合法计数且不大于 unknown，汇总旧三字段时不重复添加它。已接收但重启后无法继承的观察明确收敛为 continuation unknown，接收证明不回退。

新版的本地命令 `agentinbox hostctl SOCKET prepare-upgrade` 先置 drain，返回原状态字段及 `readyForUpgrade`、`pendingReceipts`、`relayOutstanding`、`upgradeBlockers`。仅 draining=true 且 readyForUpgrade=true 时 exit 0；任何本地活动、启动对账未完成、持久 outbox 非空／不可读、远端 pending/submitting/unknown 或检查失败均拒绝。未查询远端时 relayOutstanding 可为 null。

远端 guard 查询预算为 2 秒；既有普通 HTTP 客户端预算仍是 15 秒。旧 relay 的 404、认证失败、断线、畸形／错误 host 快照及非法计数一律 fail closed。命令不停止 host 或 relay，也不切换版本；实际排空、切换与回滚流程见 [OPERATIONS.md](OPERATIONS.md)。三个已授权服务已更新至支持此接口的 release；安装证明见 [IDLE-UPGRADE-RESULT.md](IDLE-UPGRADE-RESULT.md)。

Widget 快照提交携带原 requestId／revision；App 与 Widget 共享不可改写 journal。同题重试保留同一 responseId 与内容，仅在服务器仍 pending 且 revision 一致时向 relay 重试；submitting、unknown 或终态只刷新，不重新派发原引擎。

## 回复分步回执

新请求读取/列表和答案提交回执增加 bindingDigest、可选 replyProgress。bindingDigest 使用版本 1 固定字段的规范 JSON 与 SHA-256，涵盖 requestId、revision、hostId、engine、runtimeId、sessionId、turnId、nativeRequestId、itemId、expiresAt、kind、title、body、options、questions、multiSelect、allowText、operationSummary。对象键排序、数组顺序保留、缺失可选字段为 null。新增答案可带 bindingDigest，不匹配时 409；旧客户端省略仍兼容，原请求绑定及答案校验继续执行。

设备侧进度示例（示意值，不是现场证据）：

```json
{"schemaVersion":1,"requestId":"request-1","responseId":"response-1","bindingDigest":"0000000000000000000000000000000000000000000000000000000000000000","submitted":{"at":1001},"received":null,"continued":null,"continuationObservation":"unobserved"}
```

只有持久 response 才有 submitted，旧记录无历史时间时 at=null；缺少进度不等于证明未提交。新版客户端也可按旧协议精确 responseId 记录确认提交，但不会由此推定接收或继续。received/continued 的设备视图仅给服务器记账时间；原证明与摘要只供认证 host 对账。

host 在原 receipt 中增加 replyProgress 证明包：schemaVersion=1、上述完整身份字段、bindingDigest、获胜 responseId、received、continued、continuationObservation。原 state 必须为 adopted，候选必须已 claim。received 证明类型只接受 codex.function_call_output 或 claude.tool_result；continued 只接受 codex.next_item、codex.turn_completed 或 claude.assistant，并与请求 engine 一致。每份证明包含稳定 proofId、64 位十六进制 sourceDigest、正整数 position；continued 另有 receivedProofId，且 position 必须严格在 received 之后。continued 包必须携带同一 received，不能单独提交后续证明。

relay 以事务累积、幂等合并。同 proofId 不同内容拒绝，较低阶段迟到不回退；空证明、错绑定、非因果顺序或不合法版本拒绝。observation 为 awaiting、unknown、unsupported、confirmed；confirmed 必须同时有 continued。真实执行及获胜来源仍由受信任 host 负责证明，relay 不独立查看引擎 transcript。

当前适配器只有答案内容匹配而无胜者归属证明时，发送 nativeObservation=answerSourceUnconfirmed，保持旧 adopted 状态但不创建 received/continued。此标记不能与新证明同时出现或覆盖已有接收证明；后续真正可归属的证明可以替代先前的不确定观察。旧 adopted 亦不自动补齐新步骤。自然语言 marker 不再是新版 host 的充分采用依据。

可选 Codex 扩展通过 `nativeReceiptDir` 显式启用。host 验证私有 manifest 与实际 Unix 对端，派发前持久记录，并在 JSON-RPC result 的答案 map 外附加 `_agentinboxReceipt`。引擎在原回调仲裁位置记胜者、剥离元数据；host 还须验证原调用结构化输出才发布 received，后续原链进展独立发布 continued。胜者文件缺失不触发重发；历史恢复只读旧绑定，不继承 callback。文件与版本契约见 [native/codex](../native/codex/README.md)。

新 host 发送这些字段前验证 relay 能力；未知能力/网络失败保留持久回执，不能把旧 relay 忽略扩展字段的 200 当作分步成功。outbox 对每个累积证明独立持久保存，顺序不影响合并；认证 relay 的确定 409 冲突进入私有归档，断线继续重送回执，绝不再输出答案。

新 journal 绑定连接代次、随机非秘密配对代次及原请求摘要，以 flock、私有文件、fsync/rename 持久保存。旧 defaults journal 只读核对，不自动迁移到新身份或被 Widget 换 ID 重投。提交回执必须匹配原 requestId/responseId，客户端在配置代次变化后丢弃在途结果；本地 journal 不是已提交的服务器证明。


## 本机设备管理

`agentinbox device-admin DATABASE list|revoke DEVICE_ID` 使用 relay 数据库 owner 的既有 OS 权限，未新增 HTTP 管理接口。list 仅返回设备元数据；revoke 与设备自撤销共享单一 IMMEDIATE 事务，未知 ID 拒绝、重复撤销幂等，提交后后续认证拒绝并取消 pending push。该操作不改答案状态，不重新领取或派发原请求。发送前 worker 重查与在途推送限制、实际命令见 [DEVICE-ADMIN.md](DEVICE-ADMIN.md)。
