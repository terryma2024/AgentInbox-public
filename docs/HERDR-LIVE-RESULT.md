# Herdr 标准 Codex CLI 产品入口验收

2026-10-15，Mac mini，Herdr 0.9.3 / protocol 22、标准Codex CLI 0.162.0、既有managed daemon 0.162.1（PID91603）。本轮真实通过：独立Herdr命名session/pane中启动标准CLI，原题经本项目原生host、本地relay和测试客户端提交Beta，原引擎精确工具结果确认采用。不是Herdr终端输入代答。

## 本轮绑定与采用证明

| 字段 | 真实值 |
| --- | --- |
| Herdr命名session | agentinbox-herdr-e2e-20261015，初始为空，独立于default |
| workspace / tab / pane / terminal | w1 / w1:t2 / w1:p2 / term_65dd6fee8e4f12 |
| CLI进程 | native94530、标准Node CLI入口94522；均Thu Oct 15 09:30:41 2026 |
| 原thread | example-id-b13dedfcc17c；由该CLI自身/status明确显示 |
| 原turn / native RPC | example-id-56dca92249d4 / 13 |
| 原item/call | example-id-e763ce18263f |
| 产品request / revision | example-id-fd5661b1ebb5 / 1 |
| response | example-id-c589d28bb47f |
| 采用 | adopted；原session/turn/call仅一条function_call_output，结构为answers.route.answers=[Beta] |

原turn只有一次request_user_input调用、一次task_complete；数据库仅一个response。采用证据同时包含nativeResolved、nativeToolResult、originalTurnCompleted；adoptionMarker关闭、exactAnswerEcho=false，没有以最终marker、HTTP200或PTY字节写入代替采用。完成后同题新responseId的迟到Beta实测HTTP409。

原始CLI由Herdr layout.apply的command argv运行 `codex --no-alt-screen`；使用正常CLI发行入口与既有shared daemon，无SDK/自定义launcher、--no-daemon、另起引擎或历史恢复。CLI初始更新提示只用Esc按明确skip选项跳过，没有更新/修改设置。原CLI/status确认Local background server与新session，再仅在自己的空闲pane使用/plan和一次获准隔离prompt。host的thread/resume(excludeTurns:true)只是附着已在daemon等待的原回调，不是冷恢复历史任务。

目录严格限定用户已信任的 `.../p0/tasks/codex-round2`；prompt禁止读文件、执行命令、修改文件或设置，只问AGENTINBOX_CHOOSE_ROUTE一次并回显实际答案。原rollout证明没有其他工具调用。本轮未接受trust、操作真实工具审批或使用Alpha答案。

## 归属验证与明确限制

Herdr pane.process_info提供准确shell/native进程、cwd；CLI启动时间由OS核对。thread归属另由该CLI自身/status取得，不以pane名称/焦点/共享daemon PID/相同cwd推断。Herdr等待时正确把自有非focus pane识别为blocked。测试host显式pin这一已核实thread及daemon peerPID，产品launchSurface仍为unknown。

本轮自有Herdr快照缺少agent_session，因此通用Herdr pane↔thread自动映射和shared-daemon hook路由仍未通过。默认Herdr只读metadata在问题前后均未出现新thread引用，不能由此证明所有hook都正确路由。未检查用户既有pane内容，也未向default发送任何输入；没有改全局配置、默认布局或已安装host drain。

本轮为了核实入口采用显式测试thread pin，不声称产品可以仅凭Herdr blocked元数据安全自动发现/应答任意pane。不需把这一测试pin变成用户统一启动命令；默认captureLoadedNative模式已有其他入口证据，但其Herdr自动映射仍需单独验收。多pane同名项目、pane替换/移动、Herdr重启、Claude-in-Herdr、Ubuntu Herdr、Desktop、真实手机/APNs与同时键盘竞答均未覆盖。

Herdr官方API明确说明输入成功仅确认入队，不保证命令执行，也没有产品requestId的原子输入条件；本项目不把它作为答题核心。[Herdr socket API](https://herdr.dev/docs/socket-api/)。本机schema的pane.read API枚举为recent_unwrapped（CLI展示名为recent-unwrapped），证据中首次只读枚举错误后按实际schema修正，未重复执行任何prompt或答案。

## 本地隔离与证据

本轮仅127.0.0.1:8881独立relay，hostId=herdr-local-smoke，使用明确公开development-only fixture常量，无手机、日本server身份、APNs或秘密配对。host/relay均最终Rust release原生二进制；未修改src或STATUS共享矩阵。

关键证据在evidence/herdr-live/：

- initial-empty-snapshot.json、workspace-created.json、codex-layout-created.json：创建自有named session中的精确返回ID。
- cli-process-before-status.json、cli-native-status-screen.json：原pane实际CLI进程与CLI自身session（账户/用量行已省略）。
- original-native-binding.json：完整原回调与产品tuple以及派发前CLI进程核对。
- adoption-proof.json：精确原工具采用、唯一response与迟到重复409。
- own-question-snapshot.json、default-thread-check-before.json、default-thread-check-after.json：自有blocked检测及默认session仅做metadata匹配的限定。
- cleanup.json：自有host先drain三项0，再准确PID/start/command核对；只向自有socket发server.stop；记录的Herdr93537、host95828、relay95812、CLI94522/94530均核实退出，自有stopped session随后通过官方session delete精确删除。

正常Herdr4646、Codex daemon91603/wrapper25959与已安装host35721均保留；未盲杀daemon共享MCP/驱动缓存。删除本轮Herdr session不代表清除了shared daemon所有sidecar或原thread历史；测试题已完成，未归档/删除其他任务。
