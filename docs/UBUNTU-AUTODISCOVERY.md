# Ubuntu Codex 默认自动发现真实闭环（2026-10-15）

验收通过：host-a标准Codex CLI0.162.1由原managed daemon0.162.1服务，host配置captureLoadedNative=true、threadIds为空，在未预先登记thread/session的情况下发现原等待问题，产品API提交Beta，原引擎精确采用。现场约09:29–09:33，Asia/Shanghai。

## 入口及隔离

唯一已信任scope为`/home/developer/Projects/agent`。开始前只读原daemon loaded=[]，同scope没有其他Codex/Claude CLI待答，原有空闲zsh保留；已安装用户host保持draining=true、三项0。先启动不同hostId的临时原生host与localhost relay，再在独立tmux启动`/home/developer/.local/bin/codex`，普通CLI直接连接现有daemon。无launcher、wrapper、--no-daemon、另起引擎或历史恢复。

本会话原生/plan启用问答工具，未改全局配置、权限或目录信任。新任务模板禁止文件、命令、设置操作，只问AGENTINBOX_CHOOSE_ROUTE并回显实际答案。用户明确批准外部OS测试编排和Beta答案；未替用户批准真实工具操作。

临时host身份host-a-auto-e2e，relay仅127.0.0.1:18788，身份为公开fixture测试常量；未创建真实设备凭据，没有读取、复制、seed或消费任何配对码，没有手机配对操作。

## 自动发现事实

- host.json为`captureLoadedNative:true`、`threadIds:[]`，daemonPid、daemonPeerPid、adoptionMarker均null。
- host先于新CLI运行；没有把后来观察到的session/thread写入配置，也没有逐任务登记。
- host日志只有一次scoped-live-attach，对应新CLI原session；所有匹配仍受唯一canonical scope、原daemon/请求绑定和等待状态守卫限制。
- source元数据仍不用于入口分类；launchSurface=unknown，本轮CLI来源由独立tmux/pane和进程证据确认。

配置原件及摘要见`evidence/ubuntu-autodiscovery/host-config.json`与adoption-proof.json，日志见host.log。

| 绑定 | 实际值 |
| --- | --- |
| 原daemon | 1805212，2026-10-10 04:22:49启动 |
| 普通CLI | 1742643，2026-10-15 09:29:16启动 |
| 临时host/relay | 1742632 / 1742631 |
| 新session | example-id-67039311ddd5 |
| 原turn | example-id-987683247c36 |
| 原request | 1 |
| 原item/call | example-id-d080e3188b5b |
| 产品request | example-id-b288e0858acd，revision1 |
| response | example-id-32d4e41911a3 |

## 精确采用证明

进入relay的唯一请求body严格为AGENTINBOX_CHOOSE_ROUTE，q0-o0标签Alpha、q0-o1标签Beta。提交前重新核对pending、revision、期限、原新CLI session/turn/item绑定；只通过fixture设备API提交一次q0-o1，没有终端代答。

独立读取该原session/原turn的rollout，原call恰好一次request_user_input，其function_call_output也恰好一次，解析严格等于：

```json
{"answers":{"route":{"answers":["Beta"]}}}
```

原turn task_complete精确匹配该turn，last_agent_message为AGENTINBOX_RECEIVED:Beta。relay终态adopted，证据nativeResolved/nativeToolResult/originalTurnCompleted均true。adoptionMarker关闭、exactAnswerEcho=false，结论依赖结构化原工具结果。turn-item-audit.json另核对没有其他tool item类别/命令/文件操作。

## 清理与边界

临时host先drain并核对三项0，随后逐PID检查exe/配置/cwd，仅停止三自有进程CLI1742643、host1742632、relay1742631以及专用tmux；18788监听已关闭。正常daemon1805212和Herdr919456/1714469保留；已安装用户host仍draining=true、startupReconciled=true、三项0，未改变scope或常驻配置。

daemon保留本次idle thread/MCP缓存，cua-driver1742849属于原daemon1805212，未盲杀、未archive历史。三自有进程退出不代表所有daemon子进程退出。cleanup.json记录精确限定。

本轮通过Ubuntu标准CLI的自动发现、单选Beta及本地原生host/relay/测试客户端返回原任务采用。Ubuntu Claude、Herdr身份映射、Desktop、真实iPhone/APNs/Widget、跨机器同一relay、断网/升级与键盘手机同时异值竞争仍须分别验收。手机不在Mac旁时，本轮没有用任何码或模拟手机验收替代这些步骤。未改源码或统一STATUS矩阵。
