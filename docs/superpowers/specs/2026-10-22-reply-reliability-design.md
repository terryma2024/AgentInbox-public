# 回复可靠闭环设计

日期：2026-10-22。对应 [下一版需求第 2 项](../../NEXT-REQUIREMENTS.md#2-回复可靠闭环)。

状态：用户于 2026-10-22 确认本文设计；本地代码、协议与模拟器验证已完成。当前适配器缺少同值竞答胜者归属证明，保守报告来源未确认；尚未部署或完成本项现场验收。实际结果及限制见 [回复闭环记录](../../REPLY-RELIABILITY.md)。

## 1. 目标与范围

用户应能分别确认答案已保存在 relay、已被原调用接收、原任务在该答案之后已继续执行。任一步缺少自己的证明，就停在已知步骤，并明确说明等待、未知或该入口暂不能证明。

本轮覆盖 Rust relay/store、host 的 Codex/Claude 适配证据、App 与 Widget 共享回复模型及恢复逻辑，维护既有主机、引擎实例、会话、轮次、原调用、版本和期限绑定。验证重复提交、旧题、竞答、断线及进程重启。Tailscale、决策上下文扩充、Widget 排版优化、自检工具和通知策略不在本轮扩展范围内。

保留现有 `RequestState` 字符串和单次派发机制，在其旁边增加持久回执。直接增加状态枚举会影响旧客户端和升级守卫；完整事件日志会扩大本轮数据模型，均不采用。

## 2. 当前代码与证据基线

- `src/store.rs`：答案按 responseId、内容和设备所有者幂等；同题只有一份候选；claim 先提交事务再返回；已 claim 的 submitting 在 relay 重启后变 unknown。receipt 目前只校验 claimed、responseId 和非空 evidence，没有三步独立证明协议。
- `src/host.rs`：本地派发标记和 receipt outbox 防止重放。Codex 当前主要等待 resolved、原答案证据和 turn 完成；另有测试用自然语言 marker 路径。Claude AskUserQuestion 通过原 tool_use_id 的结构化 tool_result 确认采用，此后没有独立的继续运行观察阶段。
- `ios/Shared/ReplySubmission.swift`：先读精确请求、验证并保存原答案，再提交。`ResponseJournal` 采用进程间锁，但只按 requestId/revision 索引，记录本身不是服务器接收证明。
- `ios/Shared/Models.swift`：尚未解码 request 上的获胜 responseId，也没有独立进度模型。真实 App 使用提交回执的 state；固定设为 submitting 的是演示分支。
- 2026-10-22 本轮已运行 `cargo test --locked --offline --test core_state --test recovery_round2`：10 个状态测试、4 个恢复场景及 1 个子进程 fixture 方法通过。有效业务场景共 14 个，不等于新增功能已通过。
- 既有 [本机与手机竞争记录](../../CONCURRENCY-LOCAL-PHONE.md)覆盖手机候选入库但未领取前本机抢先；领取后竞争和物理键盘同时操作仍待验证。[恢复第二轮](../../RECOVERY-ROUND2.md)为模拟引擎进程测试。

## 3. 三步语义与既有状态

| 步骤 | 唯一推进依据 | 不足以推进的信号 |
|---|---|---|
| 已提交 | relay 事务已持久保存绑定原请求、原版本、设备所有者和确切内容的 response；客户端核对回执 requestId/responseId | 本地 journal、按钮点击、请求已发出、任意 HTTP 200 |
| 原调用已接收 | host 读取到原调用的结构化采用结果，且答案与这份候选完全匹配；relay 校验精确绑定并持久保存证明摘要 | claim 成功、socket 写成功、helper 退出、Codex resolved 单独出现、自然语言回显 |
| 任务已继续运行 | 在接收证明之后，同一原执行链出现可验证的后续执行或成功完成记录，且没有跨轮次、跨进程代次或跨会话 | 心跳在线、新 turn 开始、别的会话输出、时间流逝、原答案本身 |

继续运行只表示曾观察到后续进展，不表示整个任务完成、当前仍活跃或业务执行成功；界面用说明文字澄清这一点。

`state` 继续表示现有生命周期：pending、submitting、adopted、handledLocally、expired、invalidated、unknown。新增回执表示已经证明的里程碑，两者分开保存：

- 新协议的 received 可将 submitting/unknown 对账为 adopted；原调用已接收之后继续观察 continuation，不能因为 state 已终结而立即删除观察对象。
- continuation 未知、观察超时或 host 重启，不把 adopted 回退为 unknown，也不擦除 received；仅把“后续执行尚无法确认”写到 continuation 的观察状态。
- unknown 表示无法确认派发/采用结果，不表示未提交。存在 response 时“已提交”仍有依据。
- handledLocally 表示原调用由本机处理，不证明手机候选被接收；即使手机已提交，也不能显示它的 received/continued。
- 旧 host 的 adopted 不自动生成新 received/continued；新版界面明确显示“旧版采用记录；未提供分步回执”。

## 4. 请求与答案绑定

请求创建时由 relay 计算不可变的 `bindingDigest`：SHA-256，输入使用固定字段集合和确定性 JSON 序列化，覆盖 hostId、engine、runtimeId、sessionId、turnId、nativeRequestId、itemId、requestId、revision、expiresAt，以及 kind、title、body、options、questions、multiSelect、allowText、operationSummary。对象键排序，数组顺序保留，缺失可选字段统一为 null。摘要不含 state、updatedAt、回执、展示来源或私有 native 路径。

客户端通过精确 GET 比较 journal 中的 bindingDigest；host 通过该摘要及原 native callback 再核验。身份字段缺失时仍沿用各适配器的接管要求，不制造 turnId 或原调用 ID。题面或选项变化创建新的产品请求和原生绑定，不能修改旧题再复用答案。

答案仍使用稳定 responseId、requestId、revision 和原内容。relay 从认证得到 host/device 身份，正文不能覆盖。responseId 复用只有同所有者、同原始语义内容才幂等，不能改选项或文字。期限只限制首次提交/派发；同一已保存答案的幂等查询和确切迟到证明允许对账，不因此重新派发。

## 5. 持久回执与 API

### 数据存储

新增独立 `reply_progress` 表，不改变已有表的列数，避免破坏旧二进制的无列名 INSERT。主键绑定 requestId，关联唯一 responseId，存 bindingDigest、submittedAt（可空）、received 证明、continued 证明及 continuationObservation。各步骤合并后单调保留，未知状态不能覆盖已有证明。

新 response 与 submitted 元数据必须同事务提交。旧 response 可从现存持久记录证明“已提交”，没有历史提交时间则返回 null，不伪造发生时间。旧请求摘要按上述固定规则计算，不改变原题面；旧 adopted 的 evidence 不升级为新证明。

### 读取

新增经认证的 `GET /v1/capabilities`，明确 `replyProgressVersion: 1` 和 bindingDigest 算法版本。App/host 在连接配置代次内读取，失败保持错误或明确旧协议能力，不能把网络错误当作兼容成功。

精确请求、设备列表、host 启动快照和提交回执增补可选 `bindingDigest`、`replyProgress`；现有字段保留。`replyProgress` 包含 schemaVersion、requestId、responseId、bindingDigest、submitted、received、continued、continuationObservation；submitted 的有无表达是否已持久提交，时间未知与步骤不存在须可区分。

设备只接收阶段、服务器记录时间和脱敏原因枚举，不接收 transcript 路径、原始结果、答案摘要或完整证明材料。设备可依据 relay 的绑定结果展示；relay 仍信任认证 host 的原引擎观察，不能声称自己独立验证了引擎。

### 写入与合并

沿用 `POST /v1/host/receipt`，新增可选、版本化的 `replyProgress` 证明包，保留原 state/evidence。新协议采用回执必须携带精确 requestId、responseId、revision、bindingDigest 及原生身份；relay 验证认证 host、获胜候选、claimed 和整组不可变绑定。

received/continued 使用有限的适配器证明类型，拒绝空对象、任意字符串、未知类型、错版本和错绑定。每份证明有稳定 proofId、sourceDigest 和原生事件定位信息；不把主机时间顺序当作原执行因果顺序。

continued 包必须同时携带该 received 证明，允许网络乱序时一次验证并补齐前置里程碑。相同 proofId/内容幂等；同 proofId 不同内容返回 409。较低阶段迟到不回退进度、不覆盖终态证据。handledLocally/expired/invalidated 与 received 冲突时拒绝并保留 host 冲突证据，不擅自选胜者。

旧协议 receipt 继续按现有规则接收，但不会生成 received/continued。新 host 必须确认 relay 支持版本 1 后才发送新证明；旧 relay 下仅走明确的旧协议能力，不能因 HTTP 成功推断新字段已被保存。

新增仅 host 可读的 `GET /v1/host/reply-progress?incomplete=true`，完整列出本 host 已 received 但未 continued、且尚需恢复观察的记录，不受 UI 200 条限制。读取不 claim、不派发，不把旧 callback 复活。

## 6. 原引擎证明

证据解析拆成可独立测试的接收检测和后续进展检测，复用现有适配器映射，不把整个 host 循环改成通用工作流框架。

### Codex

received 要求匹配原 runtime/session/turn/call 的结构化 `function_call_output`，其 JSON 结果与该 response 映射后的原生结果相同。`serverRequest/resolved` 是辅助关联信息，不能单独证明采用了手机的那份答案。测试用 adoption_marker 不得推动新分步进度，也不得继续作为新版 host 采用结论的充分依据。

continued 使用该接收输出之后、同原 turn 的原生后续 item/事件或成功 turn 完成。解析器必须验证事件所属会话、turn 和因果/文件顺序；输出之前的 agentMessage 或 turn 完成、另一个 turn 的进展不能命中。只有完成通知且没有可关联的答案输出时不推进。

审批入口若当前原生接口没有可核对选项结果的证明，保留旧能力标记；新步骤明确“此入口尚无法证明”，不能把提问入口的证明方法外推到审批。

### Claude

AskUserQuestion received 沿用精确 session、可用的 prompt_id、tool_use_id、questions/answers 和非错误 tool_result 匹配，并记录匹配结果的原生记录标识。

continued 要求 transcript 中后续 assistant/tool 执行记录位于该 tool_result 的原执行链上。优先用 uuid/parentUuid 关系证明从该结果继续；仅按相同 session、文本相邻或时间先后不足以证明。不能建立可靠执行链时只显示 received，continuation 标为当前入口无法证明。PermissionRequest 不沿用 AskUserQuestion 的答案匹配规则；无原采用证明时不补造 received。

两个适配器均只读观察原引擎事件，不向正常任务增加诊断问题、标记提示或额外 turn。

## 7. host 生命周期与断线恢复

host 继续保持唯一 lease、持久派发标记和原 callback 绑定。received 后保留只读观察对象，后续循环不得再次 claim 或输出答案。观察到 continued 或达到原有回执观察预算后结束活动观察；超时只记录 continuation unknown，已证明 received 保留。

回执在发送前落私有 outbox、文件 fsync、原子 rename 和目录 fsync。每份累积证明独立且不可被较低阶段覆盖；目录遍历顺序不影响最后结果。网络断开后只重送回执，不重放答案；relay 已有相同或更高证明时幂等清理，冲突进入现有私有归档。

host 重启先 flush 已存证明，再对账 pending/submitting 和 incomplete continuation。未派发的旧 callback 失效；已 claim 但无采用证明保持 unknown。已 received 的记录可以只读检查原绑定 transcript；runtime、路径归属或执行链无法验证时记 continuation unknown，绝不附着到新 callback。

relay 重启仍把已 claim、尚无接收证明的 submitting 收敛为 unknown，持久 progress 不丢失；随后确切原证明可以对账。已 received/continued 不受此次规则回退。

升级守卫继续计入活动观察、启动对账和 outbox，并在 `upgrade-status` 增补 `awaitingContinuation` 计数；新版 host 核验能力及合法计数。只有 unknown、unsupported 或 confirmed 的非活动 continuation 不阻止排空；仍需对账的观察不能被静默遗漏。实施时覆盖旧 guard/新 relay、旧 host/新 relay 的兼容用例，部署必须先排空并备份，不能用旧版零 outstanding 代替新版完整检查。

## 8. App、Widget 与 journal

`DecisionRequest` 解码获胜 responseId、bindingDigest 和 progress；新增字段可缺省，兼容旧 relay。App 与 Widget 使用同一进度解释器，分别展示三个步骤及未证实原因；接收后仍在等待 continuation 的请求可在当前记录查看，不能因 adopted 自动消失得只剩成功标签。Widget 保持优先下一条有效待答，上一条阶段不阻挡答题。

提交成功必须核对 response requestId、responseId 及新协议绑定；回执错绑视为未知，不把其 state 写给当前题。刷新对账也要比较服务器获胜 responseId，另一设备或本机处理不能被认作本 journal 的采用。

journal 保存原答案和不可变请求快照摘要，采用 App/Widget 共享的原子文件写入、fsync 及现有跨进程锁。按中继连接代次、应用配对代次、requestId/revision 隔离，配对代次使用本地随机非秘密标识，不保存认证 token 或其散列。

旧 journal 留作历史，不静默绑定到新中继或新配对；无法核对来源的旧记录只供查看，禁止自动提交。切换中继、重新配对或视图消失后，旧在途结果不得写入新缓存或更新别的请求。连接变化前已发出的 POST 不能假定已取消，需要回到原连接只读对账。

本地保存但 POST 结果不明时显示“发送结果未知，原答案已保存”；不可提前显示“已提交”。默认只读刷新，无定时盲重发。只有精确请求仍 pending、未过期、绑定和版本相同、原 journal 所有上下文仍匹配时，才允许用户明确点击“重试原答案”，复用 responseId 和内容；若期间服务器已提交，服务端幂等仍只保留一份。

## 9. 竞答裁决

relay 事务只允许一个手机候选；host 单次领取和本地派发标记只允许一次输出。最终采用归属必须由原引擎实际结果决定，不能用“先提交”“先 claim”推断。

- 本机先答，手机候选未领取：沿用 handledLocally，只读关联迟到 responseId，不领取手机候选。
- 手机已领取或已输出，但原引擎实际采用本机另一个答案：只有原调用结构化结果能明确证明本机处理时才报告 handledLocally；否则 unknown。手机 received/continued 均不得生成。
- 两端答案相同且原生接口不能证明来源：记录来源无法确认，不能因为内容相同就声称手机回复被采用。新版 received 需要原生输出与本次 dispatch 的可靠因果关联；证明不足保持 unknown。
- 处理完成后的重复、旧 Widget、旧通知、其他机器/轮次/进程代次响应一律不能产生新的派发或套用到下一题。

若真实引擎协议无法提供上述来源证明，验收记录该组合的限制；不通过更宽松的字符串匹配消除 unknown。

## 10. 验收矩阵

| 场景 | 必须断言 |
|---|---|
| 三步分开推进 | 只提交、接收后暂停、继续运行三种 fixture 各自停在正确步骤；HTTP/写入/marker 不误推进 |
| 同答案重复提交 | 同 responseId/内容/设备反复与并发提交，唯一候选、至多一次领取/派发，返回当前进度 |
| 内容或所有者冲突 | 同 responseId 改内容、换设备、换请求拒绝，旧记录不变 |
| 旧题与期限 | 旧 revision、已换题、过期、终态、旧 Widget 的首次提交拒绝；当前新题不受影响 |
| 精确绑定 | 错 host/runtime/session/turn/call/item/摘要/版本均拒绝，不串题；缺失必要身份不接管 |
| 手机间竞答 | 并发不同答案只有一份获胜；失败方不能显示自己的 received |
| 本机与手机竞争 | 覆盖候选未领取、已领取、已派发三个窗口；核验原调用唯一实际结果和派发次数 |
| 同值竞争 | 无来源证明时不冒认手机采用；来源可证明时才推进 |
| POST 成功但响应丢失 | journal 恢复后精确读取获胜 responseId；不盲重试、不产生新 ID 或额外派发 |
| claim 响应丢失 | relay 已 claim，host 未拿到答案时保持未知，重启不再输出 |
| received 后暂停/退出 | 保留已接收，continued 未证实；不把“已接收”显示成任务完成 |
| 回执断线、重复与乱序 | received/continued 在 relay 提交前后丢响应均可幂等恢复；高阶段先到也验证前置证明；不回退 |
| host/relay 重启 | 原 callback 不继承，outbox 恢复，已证明步骤不丢失，不重新 claim/输出；新问题独立完成 |
| App/Widget 重启与切换 | journal 锁/原子落盘、配对与中继隔离、迟到响应丢弃，旧答案不误投新环境 |
| 旧协议与数据库回滚 | 新旧 host/client/relay 组合可识别能力；旧 adopted 不伪造步骤；新增表不破坏旧二进制；证明保留 |
| 排空与升级 | 活动 continuation、未完成对账、outbox 和能力查询失败阻止就绪；超时 unknown 可明确收敛 |
| 证据缺失或损坏 | transcript 缺失、截断、身份变化、错误 tool_result、乱序事件、未知证明版本均保守拒绝 |

验证层次依次为 store/API 状态测试、适配器真实格式 fixture、隔离 host/relay 故障注入进程测试、iOS 单元与模拟器 UI、独立真实 Codex/Claude 测试任务及 iPhone App/Widget。模拟引擎、受控 TUI 和物理键盘分别标记，不互相替代；未通过组合写明限制。

现场证据记录完整绑定、唯一结果、输出次数和每步证明来源，敏感原文及路径只留本地忽略的 evidence。跨机器时钟不直接用于判断先后，采用原执行链和事务因果关系。

## 11. 实施边界与完成条件

预计涉及 `src/store.rs`、`src/relay.rs`、`src/host.rs`、`src/adapters/`、`ios/Shared/{Models,ReplySubmission,Storage,API}.swift`、App/Widget 展示及对应测试；证据解析和进度规则采用小模块，避免继续把逻辑堆到 host 主循环。更新 PROTOCOL、STATUS 和需求第 2 项的证据入口。

先完成设计审阅，再编写实现计划及测试，按接口/存储、host、客户端、恢复/竞答顺序实施。生产服务替换、设备安装和现场操作要在具体构建与排空结果可审阅后执行，不能用源码通过代替已安装版本行为。

完成条件是三步语义和绑定有自动化证据，异常矩阵无重复派发或串题，真实入口按各自实测结果标注。未提供原生来源证明或 continued 能力的组合保持明确限制，不宣称全部支持或全部现场验收通过。
