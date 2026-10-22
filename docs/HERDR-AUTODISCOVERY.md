# Herdr 默认自动发现：本轮未进入原生问题阶段

2026-10-15，Mac mini。本轮按一轮限制启动独立host（先于新HerdrCLI），从头到尾captureLoadedNative=true、threadIds=[]、daemonPid/daemonPeerPid=null；只授权既有P0 codex-round2精确目录，配置SHA未改变。没有把CLI身份注册到host，也没有修改为pin。

**结果：未验收。唯一隔离prompt后，模型返回 `Selected model is at capacity. Please try a different model.`；原生thread状态systemError，TUI回输入框。没有产生request_user_input、没有产品request、没有response、没有adopted。** 这是模型容量阻碍，不是自动捕获接口失败的证据；不据此宣称自动发现通过，也不把此前显式pin成功升级为本轮成功。未换模型或重发问题。

## 实际准备与身份

- baseline只读检查：既有daemon真实peer91603；授权目录3个既存thread无等待题，loaded快照完整，避免临时host捕获未知旧问题。
- hostId=herdr-auto-smoke，独立state/IPC和localhost127.0.0.1:8884 relay，明确公开development-only身份；生产host继续draining，未停止或切换。
- Herdr 0.9.3/protocol22，自有named session agentinbox-herdr-auto-20261015，独立workspace/tab/pane；standard codex --no-alt-screen，既有shared daemon0.162.1，CLI0.162.0，无launcher/--no-daemon/历史恢复。
- 自有CLI nativePID2566（Node入口2555），启动Thu Oct 15 10:12:05 2026；pane.process_info与其自身/status一致，原threadexample-id-5c7486b9797b。这些只作为测试入口证据，没写入host配置，也没拿pane名称/焦点/同cwd猜授权。
- 初始更新提示仅按明确Esc skip，未更新或改trust。切/plan后仅发一次已获准AGENTINBOX_CHOOSE_ROUTE prompt；其约束不读文件、不命令、不改文件/设置，只Ask一次并回显Beta。

原thread rollout审计工具调用数0；容量错误发生在题产生前。原生状态systemError与TUI回输入框分别记录，不能把输入框或working视为工具采用。无native题可供验证，因此没有发送任何答案或真实审批。首轮relay启动路径因空格缺少shell引号exit127，修正命令后服务正常；未因此重发任何Agent prompt，创建CLI前已确认startupReconciled=true。

## 清理与原服务

本轮结束fixturehost prepare-upgrade exit0、ready=true，activeHooks/activeRequests/submitting/pendingReceipts/relayOutstanding全0，先置drain再准确核对PID/start/command。仅停自有host2341、relay2363、named Herdr2377，后者关闭自有CLI2566/2555；五PID均核实不存在，官方session delete仅删除本轮已停止命名session状态。

默认Herdr4646、正常Codex daemon91603和已恢复新版安装host1709均仍为原启动身份。安装host release=0.1.0-upgrade-guard，SHA553f2131319e84bf85eae34dc2e514aae57c170fcb06e3fc33851f2d2f950a1f，drain/startup=true，三项0。未停止默认server、未发默认pane输入、未改生产host/globalsettings或源码，未归档/删除原thread历史，未盲杀shared daemon的sidecars。

## 脱敏证据与运行文件边界

- not-exercised.json：无题/无答案/无采用、systemError与容量原因、无pin配置不变。
- baseline.json、cli-process-provenance.json：准备边界及自有入口；cli-native-status.json已经省略账户/用量行。
- cleanup.json：exact self-owned资源退出与原正常服务状态。

建议负责人默认排除整个evidence/herdr-autodiscovery运行目录；尤其host-token（公开测试常量但作为运行态排除）、relay.json/host.json、relay.sqlite及wal/shm/lock、state/、host-config-sha-start.txt、question-submit.json和完整pane/status快照。可审核保留not-exercised.json/baseline.json/cleanup.json这类脱敏断言；本轮未保存globalsettings全文/backup/env、生产token或日本/手机身份。没有stage/commit，也没有继续Claude-in-Herdr或双主机同模型试验。

此前Herdr显式原thread绑定的Beta采用仍见HERDR-LIVE-RESULT.md；默认captureLoadedNative的Herdr入口真实采用继续保持未验收。通用pane↔thread映射也仍未证明，界面launchSurface应保持unknown。
