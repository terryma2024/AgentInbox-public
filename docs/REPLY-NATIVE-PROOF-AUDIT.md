# 原生回执来源核查 · 2026-10-22

从清理后的 `b04cdbf` 继续实现。用户已同意扩展原生接收接口，并要求保留原答案内容。当前路线是可选的 Codex 原生扩展、host 独立核对原调用输出，以及独立观察后续执行；未替换现用的 Codex。

## 安装版协议与归属缺口

本机 `codex-cli 0.163.0-alpha.11` 的实际 experimental schema 中，`ServerRequestResolvedNotification` 只有 `requestId`、`threadId`，初始化响应也没有接收证明能力。[官方说明](https://learn.chatgpt.com/docs/app-server#toolrequestuserinput)指出，回答及 turn 清理都可能产生 resolved，因此不能据此确认答案获胜。

两端提交相同答案时，resolved、原调用答案匹配和 turn 继续可以完全一致。仅增加等待或匹配更多文字无法区分胜者。未扩展的 Codex 和当前 Claude 保留“来源未确认”，不生成 received/continued。

## 已实现的可选原生扩展

可复查的补丁、固定源码版本、归档摘要、构建及真实引擎测试入口在 [`native/codex/`](../native/codex/README.md)。首次使用需显式设置私有回执目录，并在 host 配置 `nativeReceiptDir`；默认不启用。

- manifest 绑定 Unix socket 对端 PID、引擎实例随机标识及私有目录。
- host 在 fsync 派发记录后发送 `_agentinboxReceipt` 元数据；它位于答案 map 外，引擎在 analytics 和原回调前移除，原答案内容不变。
- 引擎只在取走共享待答回调且成功交给原接收端时，写入独占、不可覆盖、fsync 的私有胜者文件。本机先答、取消或接收端已消失均不为手机写证明。
- host 同时验证完整原回调、答案、派发标识、绑定摘要和原调用结构化输出，才发布 received。原生胜者文件本身不足以推进此步。
- received 后继续观察同一原执行链，再独立发布 continued；暂时缺失输出仍等待，超时保留 received 并明确未知。
- 重启只读恢复旧派发的私有证明和 transcript，不继承旧 callback、不重发答案。新进程可以使用新目录，不能因此把新调用当成旧调用。

这是同一用户下的受信任本地渠道，不是抵抗该用户恶意进程的远程证明。

## 当前验证

| 层次 | 结果与边界 |
|---|---|
| 固定版本 Codex | 12 个新增测试通过；其所在 outgoing 模块共 44 项通过，二者不重复累计 |
| 真实引擎双客户端 | 手机获胜与同值本机获胜均通过；原答案不变，胜者证明分别为 1 和 0 |
| host / relay | Rust 全套 130 通过、0 失败、3 项条件忽略；两轮独立范围复审通过 |
| 生产 relay 路径 | 三步回执、重复提交幂等、唯一派发通过；模型为确定性本地 Responses provider，原生进程与 relay 为真实实现 |
| 故障注入 | 回执响应丢失后仅重试回执；received 后 host 被终止再恢复同一证明；候选已领取后的同值本机竞答不冒认手机获胜；每例至多一次派发 |
| 真实 iPhone App | 新题一次提交，依次看到三个独立里程碑；接收后暂停时第三步未确认，释放后才确认继续运行 |
| 真实 iPhone Widget | App 已停止时，一次精确 Beta 点击；先显示接收，释放原执行后确认 continued，完成题离开活动组件；全程未打开 App |

真机暴露的前台轮询错误已修复：无身份的 SwiftUI task 捕获启动时 inactive 场景状态，随后虽已进入前台仍跳过刷新。诊断先复现，改为随 phase 重启后，新题 App 验收通过。取消中的网络结果不再写入界面或清空主机列表。

## 安装及发布边界

relay 已按排空、私有备份、独立产物和健康检查流程升级，正常 host 采集已恢复。现用 Mac/Linux Codex 未替换；带原生扩展的引擎只在 Mac 隔离运行。

iPhone 使用现有产品身份签名。App/Widget 运行时代码构建路径检查及严格签名验证通过；测试包内的单元测试仍含本地路径，整个测试包只用于本地验收，不是发布产物。原生 Codex 测试二进制仍含第三方依赖构建路径，保持本地忽略，不能作为发布产物。

本轮没有实测物理键盘竞答、外部模型服务、Linux 扩展版 Codex 或桌面 App 嵌入扩展。上述受控场景不外推这些组合。私有协议、原调用标识、截图、部署值及原始日志均只留忽略目录 `evidence/reply-reliability-native/` 和 `.superpowers/native-reply/`，公开文档只保留脱敏结论。
