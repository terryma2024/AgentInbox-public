# 恢复与排空第二轮：隔离进程级验收

日期：2026-10-15。新增测试为 `tests/recovery_round2.rs`。本轮运行真实的本地 relay、host、hostctl 子进程，模拟 hook 引擎仅由测试二进制的独立子进程承担。该子进程使用明确的 `SIMULATED-ENGINE-PROCESS:<pid>` runtime，直接连接测试专用私有 Unix IPC，并生成模拟结构化 tool_result。它不是 Claude、Codex 或手机。

没有创建配对凭据、调用真实 Agent、读取秘密、安装服务或接触正常 daemon / Herdr。所有认证字符串均为测试源码内固定公开 fixture；每个场景使用独立 hostId、临时 SQLite/state、loopback 端口与私有 IPC。结束时仅清理本轮持有的 Child 句柄、线程和自己的临时目录。现有 Mac、Ubuntu、日本服务器服务未被本测试访问或重启。

## 结果

| 场景 | 实际观察与断言 |
|---|---|
| 活跃 hook 排空 | `hostctl drain` 返回 draining=true、activeHooks=1、activeRequests=1，表明此时必须延期升级；随后新 hook 被拒绝，relay 未新增问题。原问题仍能完成，原 IPC 只收到一次正确的 Fixture Beta，模拟结果被采用后本地三个活动计数归零。 |
| host 崩溃与旧 callback | 杀掉并等待自有 host，使用相同 state 重启。旧 pending 变 invalidated，旧候选返回 409，旧 IPC 派发次数为零。随后不同 tool_use_id 的新问题只收到自己的答案，旧候选未映射到新问题。 |
| 已提交 claim 的 HTTP 回复丢失 | fault proxy 将真实 relay 返回的非空 claim 隐去并向 host 返回 503；只读检查测试 SQLite 中精确 responseId 的 claimed=1。host 重启后旧请求为 unknown，旧 IPC 零派发，新候选 409，再次 claim 为空；之后的新问题仍可准确完成。 |
| 已派发后的采用回执断线 | 模拟引擎已收到一次答案并写入精确 tool_result，proxy 阻断 adopted receipt，在 relay 提交前返回 503。确认 SQLite 的原 candidate 已 claimed，relay 仍 submitting，host adopted receipt 已存在私有 outbox。先停止自有 host、重启自有 relay，观察原请求 unknown；恢复回执后重启自有 host，保存的原采用证明使同一请求对账为 adopted，outbox 清空、再次 claim 为空、原 IPC 累计仍只派发一次。 |

本文件不把活动计数检查说成已经执行了版本切换。`prepare-upgrade` 命令、远端 outstanding/unknown 以及 outbox 对升级就绪性的阻断，由独立的升级守卫测试负责；本文件四个场景只依赖原有 status/drain 协议。

## 重现与证据

```sh
CARGO_TARGET_DIR=/private/tmp/agentinbox-review-target cargo test --locked --offline --test recovery_round2 -- --nocapture
```

需要允许测试创建临时 loopback listener 与 Unix IPC。此次实际退出码 0，四个场景全部通过；Cargo 显示五个 test 方法，其中 `fixture_engine_process` 是供子进程复用的内部入口，在父测试进程不执行场景，不额外计入业务验收。

- [完整原始日志](../evidence/recovery-round2/process-tests.txt)
- [场景结果、原生/产品绑定与源 SHA-256](../evidence/recovery-round2/results.json)

结果 JSON 中记录 requestId、revision、hostId、runtimeId、sessionId、turnId、nativeRequestId、itemId，以及场景的最终状态和派发次数。证据采集运行前后源码 SHA-256 一致；该快照只代表这次运行，后续源修改应以新的全套日志为准。

HTTP 客户端超时保持 4 秒，状态等待 5 秒，hostctl IPC 读超时 3 秒；模拟引擎回调读超时 12 秒，原请求期限 60 秒。没有通过增大已有测试超时绕过失败。

## 限定

这是模拟引擎的进程级恢复和状态/唯一派发证明。它不能替代真实 Claude hook 采用格式、真实 Codex 断线事件、物理键盘/手机同时竞答、真 iPhone/Widget/APNs、Ubuntu 执行端、活跃生产 hook 升级、二进制替换和回滚的现场验收。模拟结构化结果获得 adopted 仅说明本测试绑定与恢复链路正确，不构成真实引擎入口的新增支持声明。
