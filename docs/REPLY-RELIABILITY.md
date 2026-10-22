# 回复可靠闭环 · 2026-10-22

本轮完成分步回执协议、持久化与恢复、App/Widget 状态解释和本地验证。**第 2 项的真实原生归属与真机完整验收仍未完成，不能标记整项通过。** 本轮没有替换生产服务、安装手机或向真实 Agent 发送测试答案。

## 当前能确认什么

| 界面步骤 | 依据 | 当前入口边界 |
|---|---|---|
| 已提交 | relay 中与确切 requestId/responseId 绑定的持久答案记录；新协议带 submitted 回执 | 本地保存 journal 或 HTTP 请求发出均不算提交成功 |
| 原调用已接收 | 完整绑定、唯一候选、已领取及可归属的结构化原生证明 | 当前 Codex/Claude 适配器尚未获得足以排除同值竞答的胜者来源证明，不生成这一新里程碑 |
| 任务已继续运行 | 已验证的接收证明之后，同一原执行链的后续进展证明 | 当前入口不凭答案匹配、resolved、helper 写成功或自然语言 marker 推进此步 |

Codex 官方 [`ServerRequestResolvedNotification` 定义](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/typescript/v2/ServerRequestResolvedNotification.ts)只有 threadId/requestId，没有获胜客户端标识。结构化原答案匹配可以证明原调用产生了这项答案内容，仍无法排除本机提交了相同内容。当前适配器因此仅报告 `nativeObservation=answerSourceUnconfirmed`，保留旧版 adopted 生命周期兼容；新版界面显示“原调用答案匹配，来源未确认”，不点亮已接收或已继续。Claude 当前适配器采用同样的保守归属边界。

新协议对收到的可归属 host 证明执行绑定、类型、因果顺序和幂等检查；当前正向三步用例是**受信任 host 协议 fixture**，不是现有原生引擎已经提供了这些证明。不能将它们外推为 Codex/Claude 的新增真实支持。

## 实现与恢复

- 请求以固定字段、规范 JSON 和 SHA-256 绑定主机、引擎实例、原会话/轮次/调用、内容版本、题面和期限；初次提交若携带错误摘要会被拒绝。
- SQLite 新增独立 reply_progress 表，不改变旧表列布局；答案和 submitted 同事务保存。旧 adopted 不生成新里程碑；旧答案历史时间未知则保持 null。
- received/continued 累积合并、幂等、不回退；continued 必须带匹配的 received 和后续位置。错身份、空证明、错类型、证明冲突或不合法版本均拒绝。设备只读阶段时间及原因，不取得原始证明、sourceDigest 或 transcript 路径。
- claim 与派发标记维持至多一次。host 在派发前保存原请求、答案和 transcript 前缀边界；旧输出、重写前缀、错调用或重复输出不能产生新的匹配结论。
- 断线重送持久回执，不重送原答案。原生 callback 不随 host 重启继承；已接收的受信任 fixture 记录在 host/relay 重启后保留接收证明、将无法继承的后续观察标为 unknown。冲突 409 归档，网络/能力失败保留待发回执。
- 旧升级守卫仍能看见待确认 continuation：upgrade-status 的兼容 unknown 聚合包含它，新字段 unknownRequests 给出真正 state=unknown 的数量；新版守卫核验 awaitingContinuation，且不重复计数。
- App/Widget 共用进度规则。另一份获胜答案不能被显示成当前本地原答案的成功；待确认接收/继续与 unknown 记录可继续查看，Widget 优先下一道有效待答。
- 新 journal 使用 flock、私有文件、fsync、原子 rename 和目录 fsync，绑定中继连接代次、非秘密配对代次、请求版本及摘要。切换配对/中继后旧缓存和迟到结果失效。旧 defaults journal 仅供核对，不能由 Widget 换一个新 responseId 自动重投。

## 验证与证据

本地完整结果、日志和截图位于忽略目录 `evidence/reply-reliability/`；以下统计不重复累计同一测试的多次运行。

| 检查 | 结果与范围 |
|---|---|
| 原生全套 | 123 个方法通过、3 项条件忽略、0 失败；通过方法含 1 个恢复子进程入口，即 122 个实质方法。忽略项为 2 个需指定旧二进制的演练和 1 个由父测试启动的模拟 daemon 入口 |
| iOS 单元 | 133 个方法执行，127 通过、6 个需显式配置的集成用例跳过、0 失败 |
| 核心模拟器 UI | InboxUITests 8 项通过；最终里程碑展示用例另复跑通过，不另加唯一方法数 |
| iOS Release | generic iOS/iphoneos、无签名构建通过；不等于安装或真机运行 |
| 独立审查 | 首轮 3 项边界问题已用失败回归复现并修复；完整提交范围复审未发现可执行问题 |

新增测试验证分步推进、重复与冲突提交、完整原生绑定、旧题/期限、旧版 adopted、证明乱序、来源不确定、升级兼容、同状态回执冲突归档、已有证明重启保留、App/Widget journal 与缓存隔离。原生解析测试分别验证原输出和其后进展，拒绝跨会话/轮次/调用和不相连的 Claude parent 链。

此前并行 Xcode 构建时既有 helper 超时断言曾在 7.02 秒失败；单独复测为 6.88 秒，后续完整运行经过该测试为 6.62 秒，最终整套通过，未放宽 7 秒阈值。原生全套中发现的旧假 relay 能力接口缺失和旧 JSON 全等预期，均通过补全 fixture 的真实协议响应修正，生产代码仍对不明能力拒绝推进。

## 剩余验收

需要真实引擎提供或实测建立胜者来源证明，才能给相应入口开启新 received/continued 里程碑；不能用额外自然语言标记绕过这一边界。真实手机 App/Widget、物理键盘与手机竞答、候选已领取后的现场争用、网络切换与真实引擎重启均需要独立新题、原调用结果和唯一派发证据。本轮模拟引擎与协议注入不是这些项目的通过证明。

旧原生二进制回滚及生产安装仍是独立现场/兼容演练；默认条件忽略用例不计通过。当前代码、[设计](superpowers/specs/2026-10-22-reply-reliability-design.md)和[实现计划](superpowers/plans/2026-10-22-reply-reliability.md)保留在工作分支，供部署前审阅。
