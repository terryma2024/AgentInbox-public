# 升级守卫独立审查

审查日期：2026-10-15。最终范围是不可变 v2 补丁 `/private/tmp/agentinbox-upgrade-guard-review-v2.patch`，base `6769e87`，SHA-256 `dd156b9a76ca08613a32ab8cfaf18471646a08db26306edd3ce08e8f20654d2b`。已核对原始字节和八个修改文件的 Git postimage blob。v1 SHA `82b1b99704e4d2230c12b02bbffc626c1bfc67448b248965c27c10d4766f724f` 与原评估保留；v2 仅增强测试 fixture 和同步屏障，五个生产文件的 blob 不变。本报告不覆盖未来修改。

结论：**merge / human_review_required**。v1 的测试同步缺口已由 v2 的真实旧版 RED / 新版 GREEN 关闭；没有剩余有依据的生产阻断项。生产路径未发现会错误放行升级、越过 host 角色隔离或破坏原 15 秒客户端行为的源码缺陷。此标签仅是补丁审查建议，不授权升级任何已安装服务。

## v1 发现与 v2 关闭证明

**[P2，v2 已关闭] v1 的断开控制 reader 测试不能证明请求已被处理。** `tests/upgrade_guard.rs:193` 的 `abandoned_control_client_does_not_crash_host_or_drop_callbacks` 先发送并关闭一个 status 连接，再用另一个 status 检查存活。`src/host.rs` 对每个连接使用独立 reader 线程后发送到 mpsc，因此第二条 status 可以先到队、先返回；Fixture 随后的 Drop 会杀掉 host，首条控制操作的失败写入可能尚未发生。

该问题有现成反例：[upgrade-guard-red.txt](../evidence/upgrade-guard-red.txt) 中，此项在旧实现仍使用 `writeln!(stream, ...)?`、可以传播断开写错误时已经显示 `ok`。因此 v1 不能把它视为这次生命周期修复的有效 RED 证据。新实现 `src/host.rs:450` 使用 `let _ = writeln!` 本身符合要求；问题在回归测试的观察顺序与证明强度。

v2 已把首条请求换成 drain、完整关闭该连接，等待本测试私有 drain marker 可见后，再发送新的 status 验证 host 存活。marker 是进入首条事件处理的可观测屏障；下一条正常状态响应证明其失败写入已被跨过。屏障使用原有 3 秒期限和 thread::yield_now，没有增加固定 sleep 或放宽超时。fixture 新增的 AGENTINBOX_TEST_BINARY 仅选择测试子进程，默认仍用 Cargo 本次二进制，不进入产品配置。

[control-disconnect-old-binary-red.txt](../evidence/control-disconnect-old-binary-red.txt) 中，修正后的测试对已封存旧 Mac 二进制失败，第二次 status 返回 ConnectionRefused。已只读核对该旧二进制 SHA-256 为 `7314b6e04a7b64b3e8f8b0dcc7a8a18242714ee4a479f62a5ab9e778d9ba7c29`。v2 的 [upgrade-guard-green.txt](../evidence/upgrade-guard-green.txt) 三项全部通过，包含同一断开控制 reader 用例。此证据关闭 v1 的 false-negative 缺口。

## 已核对的生产行为

- `main -> hook::control -> host IPC`：prepare-upgrade 在同一 host 事件循环先写 drain，再检查本地 activeRequests / activeHooks / submitting 和 startupReconciled。新 hook 与 Codex callback 发布继续受 drain 阻断。命令不停止进程、不替换版本。
- `src/host.rs:1183`：receipt-outbox 非空或读取失败均拒绝。局部阻断时无需远端成功即可确定不能升级。
- `GET /v1/host/upgrade-status -> Store::upgrade_status`：计数绑定认证凭据的 hostId，覆盖全部 pending、submitting、unknown，不受历史列表 LIMIT 200 或启动快照省略 unknown 影响。查询参数不能改变认证 host，设备角色不能使用此路径，响应不含题目或 native 内容。
- 远端检查：hostId 不符、缺字段、负数、非整数、溢出、认证失败、断线、非成功 HTTP 均拒绝。旧 relay 没有新接口时返回 404，客户端转 Err，不会把空/缺失快照当成零。
- `get_json_bounded` 的 2 秒预算只用于新 guard；既有公开 get_json / post_json 仍传 15 秒。no_proxy 与请求 Connection: close 保持原行为。
- drain marker 写入失败返回 JSON error / readyForUpgrade=false 并保留 host；控制 reader 断开后的写错误不再向 host::run 外传播。普通 status/drain 的主要返回字段保持兼容，新 CLI 对错误 JSON 返回非零；旧 host 不认识新操作时也不能被新 CLI 视为 ready。

## 证据与风险

v2 的 [upgrade-guard-green.txt](../evidence/upgrade-guard-green.txt) 有三个 guard 测试通过。此前读取的完整 guard/HTTP GREEN 记录有八个 HTTP 进程用例通过；[upgrade-guard-first-green-attempt.txt](../evidence/upgrade-guard-first-green-attempt.txt) 也保留该 HTTP 子集通过记录，但该早期组合运行整体包含另一项当时尚未修复的 guard 失败，不能称为整组通过。HTTP 所测生产实现与 v2 相同。`upgrade_status_is_host_bound_and_includes_unknown_without_question_contents` 实际检查跨 host 数据、设备/非法 token 拒绝、unknown 纳入和采用证明恢复后的计数变化。[upgrade-drain-failure-red.txt](../evidence/upgrade-drain-failure-red.txt) 确实展示旧版在 marker 写失败时没有结构化返回；其 GREEN 测试观察 host 继续可用。本次审查只读使用这些日志，没有重跑被审主体代码。

错误就绪判断的影响为 high：它可能促使操作者停止持有原 callback 的共享 host。v2 回归可能性评为 low，保护为 partial：本地守卫、持久化阻断、HTTP 隔离及真实旧/新版差异均有保护，但没有执行已安装服务的实际版本替换和跨平台上线；生产边界的源码控制均已追踪。没有数据库 schema 迁移或自动进程替换；回滚/关闭守卫仍需要有序确认 callbacks、outbox 和 unknown，不能用回滚重建已丢失的原 callback。新 HTTP 契约、鉴权边界和持久 drain 使其不属于自动合并候选。

[v2 结构化风险评估](../evidence/upgrade-guard-review/assessment-v2.json) 已通过 assess-patch-risk JSON validator，退出码 0；[v1 历史评估](../evidence/upgrade-guard-review/assessment-v1.json) 保留原 revise 建议。最终评分和建议仅绑定 v2 SHA。真机、已安装 Mac/Ubuntu/Japan 服务升级、版本替换和回滚不在本次只读审查范围。
