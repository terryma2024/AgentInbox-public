# 原生适配器与验收范围

2026-10-17新增：host默认仍以scopes精确过滤；显式captureAllDirectories=true可省略目录限制（建议scopes=[]），Codex初始／分页thread/list都不带cwd过滤。旧session exclusion优先于显式pin，绝对canonical真实cwd、原daemon UID／代次及request绑定仍必须验证。host-a当前已启用全目录／仅新会话，见[恢复记录](HOST-A-CAPTURE-RECOVERY.md)。

本实现直接连接现有 Codex managed app-server 的 Unix WebSocket；host 不启动 Codex 引擎、不使用 launcher、wrapper 或 `--no-daemon`。连接先 initialize，然后只读 loaded/list 与指定 canonical cwd 的 thread/list，只对已经加载且正在等待的明确原 thread 执行 thread/resume(excludeTurns:true)，用于接收原 callback。未加载的历史任务拒绝附着。

每条原生回调完整参数保存在 host 私有状态；产品绑定包括 hostId、真实 daemon PID+启动时间/Claude CLI PID+启动时间、原 session/thread、turn/prompt（原工具无此字段则 null）、native RPC/tool_use_id、item/call_id。发送前核对完整 callback、产品 requestId、revision、deadline、选项映射、daemon generation；先原子领取 relay response，再本地 fsync 一次派发 claim。无法确认成功时只标 unknown，不自动重发答案。

Codex 在当前 CLI 0.162.0 / daemon 0.162.1 现场，source/originator 元信息可能显示 vscode/既有探针名称，即使任务从普通 CLI 新建。因此来源分类暂不可信。产品支持一次配置captureLoadedNative=true与授权canonical scopes，此后捕获该既有daemon中已加载、仍等待的原生请求，无需每任务登记threadId或改变CLI启动；界面launchSurface=unknown，不据source/originator/pane推断来源。默认该捕获选项关闭；显式threadIds可用于硬pin验收。daemonPid/daemonPeerPid为null时从当前Unix连接真实peerPID、同UID及managed app-server命令确认实例，重启时从新连接重新发现；显式PID只作测试硬pin。2026-10-14 Mac 历史验收的 socket peer 为91603；它不是可长期复用的当前 PID。验收原CLI入口仍需全新thread、精确cwd、loaded状态与独立pane/CLI进程证据。Ubuntu 与 Herdr 已有各自限定入口的真实闭环，见下表；Desktop 不能由这些 CLI 结果推断支持。

## 当前真实入口范围

| 入口 | 已通过 | 保留边界 |
|---|---|---|
| Mac 标准 Codex CLI | 允许目录内自动捕获、原生单选 Beta、模拟器 App／主屏幕 Widget 回复采用。 | source/originator 与 pane 元数据不单独提供授权；真实审批、完整同时键盘竞答等分别验收。 |
| Ubuntu host-a 标准 Codex CLI／既有 daemon | captureLoadedNative=true、threadIds=[]，host 先于新CLI运行，无预登记 thread/session，真实 Beta 的唯一原工具结构化结果 adopted。 | 使用临时独立 host/relay 与已信任 scope；不是当前手机链路、Ubuntu Claude 或所有常驻配置验收。见 [UBUNTU-AUTODISCOVERY.md](UBUNTU-AUTODISCOVERY.md)。 |
| Mac Herdr 独立命名 session/pane 的标准 Codex CLI | 用该 CLI 自身 /status 和独立进程证据核实 thread，host 显式 pin 原 thread，测试客户端提交 Beta 后原工具唯一结果 adopted、迟到候选409。 | 通用 pane↔thread 自动映射、共享daemon hook路由、多pane/同名项目、pane替换和Herdr重启仍未通过；不能把限定pin扩展成任意pane自动应答。见 [HERDR-LIVE-RESULT.md](HERDR-LIVE-RESULT.md)；[无 pin 新轮](HERDR-AUTODISCOVERY.md) 因模型 capacity 未产生题，未计通过。 |
| Mac 普通 Claude CLI 2.1.299，默认零参数 | 原有全局 PreToolUse 实际加载，经私有IPC返回Beta，原工具唯一结构化结果 adopted；真实活hook延期升级、原题完成后ready。 | 不推断审批、文字、多选或同时键盘竞争支持。见 [CLAUDE-DEFAULT-LIVE-RESULT.md](CLAUDE-DEFAULT-LIVE-RESULT.md)，早期隔离配置见 [CLAUDE-LIVE-RESULT.md](CLAUDE-LIVE-RESULT.md)。 |
| Codex Mac App／Claude Desktop Code tab | 尚未通过。 | 原Desktop历史一次无ID创建仍未知；没有借CLI结果接管或宣称清理完成。 |

实体手机已签名安装，但当前离线，真实配对／APNs／真机Widget仍暂缓。历史模拟器闭环与当前服务版本分别见 [STATUS.md](STATUS.md)；不把构建或安装等同原请求采用。

## 原引擎采用与失败处理

采用证明：Codex 必须原 request resolved + 原 turn completed，并验证本机该原 thread rollout 中原 turn 的 function_call_output.call_id 等于原 itemId，output JSON与实际派发结果精确一致。控制测试还可使用原 turn 最终文本精确回显（adoptionMarker）；它不是通用产品采用判据。没有匹配回执则 unknown。文件修改审批缺少完整原diff时不上传不派发，交回本机。命令审批显示完整command与cwd；原生行为采用证明尚不完整时只确认提交，不能列为“已采用”。

Claude helper 只读取 native hook JSON，经 stateDir 内权限0700目录/0600 Unix socket联系host；读取deadline、实际CLI父进程 PID+启动时间。PreToolUse(非AskUserQuestion)仅观察原tool_use_id并立即返回空输出；PermissionRequest缺失tool_use_id时只与同一runtime/session/prompt且同一tool_input唯一PreToolUse匹配，歧义拒绝。AskUserQuestion通过原PreToolUse updatedInput返回，保留questions并写answers。返回输出只是提交；原 transcript 中必须sessionId、promptId(若存在)、原tool_use_id和结构化toolUseResult.questions/answers精确相等，才确认采用。PermissionRequest目前缺乏通用精确采用证明，结果保守unknown。

helper超时、host不在线、身份缺失、秘密问题或权限摘要不完整时输出 `{}`，不包含allow。此行为把决策交回原工具；用户需按已验证工具版本核对其实际原生超时UX，不能宣称自动拒绝或批准。host有效期取min(hostTTL,helperDeadline)，socket EOF立即失效；单个hook写失败只把该请求unknown，不导致其他任务退出。host重启不能继承callback。

终态先写host私有receipt-outbox并fsync，再提交relay；断网恢复/host重启仅重送同终态回执。发送前只读对账responseId，解决手机已提交、本机先采用且host尚未领取的竞争；不会为此领取或派发手机候选。server采用回执丢失会保留unknown/终态待同步记录。

每个hostId在固定/tmp私有UID目录有OS排他flock lease（不受TMPDIR改变影响），同一Mac第二host实例启动失败，不会使第一实例callbacks失效。Ubuntu独立机器使用独立hostId。崩溃遗留IPC只有取得本hostId排他lease、路径为本UID私有stateDir内socket、无symlink且connect确认ConnectionRefused时才移除；活server绝不覆盖。启动旧请求对账失败时保留gate，拒绝新callback，恢复后持续对账，旧终态先落outbox。冲突终态回执归档保留证据，遍历队列防第101条饥饿。空收件箱host每10秒独立心跳。`hostctl SOCKET status`返回activeHooks/submitting/activeRequests，`drain`创建私有drain标记，停止新hook/新附着并保留已有callbacks。这三个计数全为0不足以许可升级：新版 `hostctl SOCKET prepare-upgrade` 还检查startupReconciled、可读且为空的持久receipt-outbox，以及认证relay的本host完整pending/submitting/unknown聚合。仅draining=true且readyForUpgrade=true时exit0；命令不自动停进程或切版本。

远端guard HTTP查询预算2秒，普通API仍15秒；旧relay缺少 `/v1/host/upgrade-status` 返回404或任何认证／网络／快照错误均拒绝放行。SIGTERM不等于排空，版本回滚不继承旧callback；失败回滚同样需fresh检查，无法确认门槛时停在故障状态并报告。Mac host与日本relay已更新本轮新版，两执行端host保持drain；Ubuntu已安装host的最终版本由负责人安装结果确认。本次实际服务切换见 [IDLE-UPGRADE-RESULT.md](IDLE-UPGRADE-RESULT.md)，统一入口范围见 [STATUS.md](STATUS.md)。维护细节见 [OPERATIONS.md](OPERATIONS.md)、[UPGRADE-GUARD-REVIEW.md](UPGRADE-GUARD-REVIEW.md)。

运行示例：

```sh
agentinbox relay --config /absolute/relay.json
agentinbox host /absolute/host.json
agentinbox hook /absolute/state/ipc/hook.sock 60
agentinbox hostctl /absolute/state/ipc/hook.sock status
agentinbox hostctl /absolute/state/ipc/hook.sock drain
agentinbox hostctl /absolute/state/ipc/hook.sock prepare-upgrade
agentinbox inspect-codex /absolute/codex.sock /absolute/allowed-cwd
```

`inspect-codex`只读原生元信息，不显示问题正文或对话。所有终端输入API均不作为生产答题方案；测试专用终端按键只有现场明确核对原绑定后才使用。未知原Desktop任务不接管。

## 历史真实闭环（2026-10-14）

以下保留当日原请求、采用与限制证据；其“本轮”“仍未验收”均指2026-10-14当时，不代表当前统一支持矩阵。2026-10-15新增Ubuntu自动发现、Herdr限定pin、Claude隔离配置和实体签名安装分别见上文及 [STATUS.md](STATUS.md)。

全部使用新建的隔离普通CLI任务，只问一次选项并回显实际答案；禁止读文件、执行命令、修改文件或设置。原CLI沿用正常managed daemon。用户明确授权本轮Beta答案后才作提交；先前e53d435e请求已过期，旧绑定提交实测HTTP409，随后仅中断精确匹配的旧原turn，未派发答案。没有接受新增目录信任或真实工具审批。

| 入口 | 产品requestId | 原native request / turn | 结果与证据 |
| --- | --- | --- | --- |
| 正式iOS ReplyDraft→ReplySubmission | example-id-1681f513cc4a | 9 / example-id-42cffe7ccc9a | adopted，原call恰好一次Beta；adapters-live/codex-beta-adoption-proof.json，ios-codex-adoption.json |
| 本机键盘先答 | example-id-6242441ef840 | 10 / example-id-00643bf7fe27 | handledLocally；原call一次Beta，迟到手机答案HTTP409；adapters-live/keyboard-first-result.json |
| 正式iOS先答 | example-id-0569e0e4143d | 11 / example-id-b7f7cbeca3cf | adopted；迟到键盘动作因已采用在发送前拒绝，未按Enter；adapters-live/phone-first-result.json，ios-codex-phone-first-proof.json |
| 实际模拟器主屏幕Widget Beta按钮 | example-id-7cdc9f91b977 | 12 / example-id-54b9d8958933 | adopted；App保持非前台，无API测试客户端或键盘代答；adapters-live/widget-native-adoption-proof.json，ios-widget-native-proof.json |

Widget案例responseId为example-id-df9609c0858a，原itemId为example-id-f8d55ec86c47，原session为example-id-f4cddfd01f4d。精确原session/turn/call的rollout中仅一条function_call_output，output解析等于 `{"answers":{"route":{"answers":["Beta"]}}}`；原request resolved、原turn completed与nativeToolResult同时成立。adoptionMarker关闭，exactAnswerEcho=false。验收使用原生工具结果而非最终marker。

终端来源佐证来自专用tmux socket agentinbox-e2e-20261014的pane%2、cwd codex-round2、CLI PID96591及启动时间；这些字段用于本轮入口核验，不作为产品授权绑定。完成后专用CLI已idle，host activeHooks/activeRequests/submitting均0。正常Codex daemon及默认Herdr未停止。

evidence/adapters-tests.txt记录本轮24项适配器/helper/并发排他/超时/断网恢复回归（18+3+3），全部通过；完整项目测试以root保存的最新全套结果为准。

**当时历史未验收列表（2026-10-14）**：真实iPhone/APNs、Ubuntu实际运行、Herdr身份映射、原生Desktop入口、Claude产品普通CLI端到端、完整断网跨设备闭环、异值/同时本机与手机竞答。该列表不覆盖后续新证据：Ubuntu实际运行与无pin自动发现、Herdr显式pin原任务采用、Claude隔离配置单选、实体签名安装已有各自记录；Herdr自动映射、真实手机配对/推送等当前边界以 [STATUS.md](STATUS.md) 为准。当时两个顺序用同值Beta；它们不能证明同时竞争的胜者来源。原生精确tool result证明答案值采用，对于同值本机/手机同时候选不能独立证明来源，不能把API候选互斥当作完整键盘竞答通过。通用审批没有完整采用证明，当前仅提交后结果未知；不标为支持已采用。
