# Ubuntu 普通 Codex CLI 真实单选闭环（2026-10-15）

限定验收通过：host-a 的标准 Codex CLI0.162.1通过既有managed daemon0.162.1，原等待问答从host进入临时relay，测试客户端提交Beta，原引擎结构化工具结果确认采用。未用手机/APNs，不能代替Ubuntu真机端到端验收。

## 原入口与准确关联

用户唯一已信任scope为 `/home/developer/Projects/agent`。初始只读检查发现无该范围的正常Codex/Claude CLI；daemon loaded=[]；已安装用户host保持draining=true、activeHooks/activeRequests/submitting均0。未解除它的排空状态。

新建独立tmux socket `agentinbox-ubuntu-e2e-20261015`，session question、pane%0；直接运行 `/home/developer/.local/bin/codex`（无wrapper/launcher、无--no-daemon、无另起引擎、无历史恢复）。本会话使用原生 `/plan` 以调用request_user_input，模型按CLI原规则变为medium，不修改全局配置。未接受信任提示或任何真实工具审批。

| 字段 | 实际绑定 |
| --- | --- |
| 产品hostId | host-a-isolated-e2e |
| 原daemon | PID1805212，启动2026-10-10 04:22:49 |
| 普通CLI | PID1496486，启动2026-10-15 01:19:25 |
| session/thread | example-id-61173458abfb |
| turn | example-id-7084f14107e9 |
| native request | 0 |
| 原item/call | example-id-2ad21ef07b34 |
| 产品request | example-id-96b32090126d，revision1 |
| response | example-id-a759662452fa |

临时原生relay只监听127.0.0.1:18787；host使用不同hostId、独立state及私有IPC，只有此新thread的显式pin，captureLoadedNative=false。身份为公开fixture测试常量，不是实际设备/服务器密钥，未创建生产持久设备凭据。正常机器host设置、启动入口与scope均未改变。

## 真正采用证明

题目严格为 `AGENTINBOX_CHOOSE_ROUTE`，产品q0-o0实际标签Alpha、q0-o1实际标签Beta。提交前核对原session/turn/item、pending、revision1及未过期。经产品API只提交一次q0-o1，没有终端代答或工具审批。

原session的原turn rollout中：

- 仅一次function_call，name=request_user_input、call_id精确匹配原item；没有命令或文件工具。
- 恰好一次匹配call_id的function_call_output，解析严格等于 `{"answers":{"route":{"answers":["Beta"]}}}`。
- 原turn task_complete字段精确匹配原turn，last_agent_message为AGENTINBOX_RECEIVED:Beta。
- relay终态adopted；host证据nativeResolved、originalTurnCompleted、nativeToolResult均true。

adoptionMarker关闭，exactAnswerEcho=false；采用结论来自精确原工具结构化结果，不依赖最终文字回显或HTTP200。原CLI界面也显示AGENTINBOX_RECEIVED:Beta。

完整独立证明：`evidence/ubuntu-live/adoption-proof.json`、native-binding.json、response.json、terminal.json、host.log。

## 授权复核及清理

自动审批第一次把被测Agent“不执行命令/不修改文件”的模板约束误读为禁止外部测试宿主准备；动作未执行。向同一审批机制提供用户直接批准实现/构建/本地联调、真实请求闭环及新同模板Beta题的原文，仅复核一次后获准。没有换工具或间接绕过，模板对被测Agent始终有效。记录approval-review.json。

短期host先drain并确认三项0，然后逐PID核对exe/角色/配置/cwd，仅停止新CLI1496486、host1498248、relay1498247；三自有进程均退出，127.0.0.1:18787关闭，专用tmux退出。保留测试证据和原rollout历史。

正常daemon1805212与Herdr919456/1012695均保留；已安装用户host仍draining=true，三项0。daemon保留本次idle thread及其管理的cua-driver1496702（parent1805212，sleeping）；未盲杀MCP缓存、未archive历史。三自有进程退出不代表daemon所有子进程退出。cleanup.json与sidecar-status.json准确记录此限定。

## 尚未证明

本轮仅证明Ubuntu标准CLI、单题Beta、同机原生host/relay/测试客户端的精确采用路径；使用了显式测试thread pin，不能外推默认captureLoadedNative自动发现。Ubuntu Claude、Herdr归属、Desktop、真实iPhone/APNs/Widget、双主机同一relay竞答与故障恢复、异值/同时键盘手机竞争均仍需分别验收。来源元数据仍显示source=vscode/originator=codex-tui，不能据此认定Desktop入口。
