# 默认普通 Claude 全局 hooks 真实闭环

2026-10-15，Mac mini，原生transcript记录Claude 2.1.299。普通Claude以零参数启动（没有--settings、--setting-sources、--tools、--session-id、SDK或自定义wrapper），在用户已信任的精确claude-interactive目录只输入一次获准AGENTINBOX_CHOOSE_ROUTE隔离prompt。全局settings保持原样，真实PreToolUse AskUserQuestion通过已安装helper的原IPC进入临时原生host、本地relay；Beta被原引擎唯一结构化tool_result采用。

| 字段 | 本轮真实值 |
| --- | --- |
| 普通CLI | nativePID1599，Thu Oct 15 10:07:11 2026，参数[] |
| 原session | example-id-daa002b1dc3b |
| 原prompt | example-id-156d8b7e77de |
| 原tool_use_id | example-id-a72b39f9cab3 |
| 产品request / response | example-id-528716419f7c / example-id-7354c117b4df |
| 采用 | adopted；原session/prompt/tool唯一tool_result，原questions完整匹配，answers.AGENTINBOX_CHOOSE_ROUTE=Beta |

原transcript工具审计仅一次AskUserQuestion，其他引擎工具调用0，serverResponseCount1。没有读文件、命令、写文件/设置工具或真实审批。最终marker不参与采用判据。原SessionStart按用户默认配置自然运行，本轮没有修改或替换它；其自身行为未提升为单独验收项。

## 同一道题的真实活 hook 排空延期

- 原hook等待时调用本轮native binary的hostctl prepare-upgrade：exit1，draining=true、activeHooks=1、activeRequests=1、submitting=0、readyForUpgrade=false；阻碍为active native requests remain。
- drain保留该原callback。仍向同一request/revision提交已授权Beta，原tool_result精确采用；没有另开题、恢复历史或重派答案。
- 完成后同hostctl命令exit0，readyForUpgrade=true，三项活跃计数、pendingReceipts、relayOutstanding全部0。

这证明真实Claude活hook会延期升级且排空时已有答案仍可采用，不证明活callback期间已切换二进制。实际本轮安装服务切换发生在最初ready=true、无callback时。

## 生产隔离与恢复

先fresh升级gate、准确LaunchAgent job/PID/start/command/SHA核对，才bootout本项目新版job。临时host用同hostId和原IPC，但stateDir仅为生产state/ipc私有目录；初始只有hook.sock，否则拒绝。codexSocket=null、captureLoadedNative=false，scope仅claude-interactive。测试relay仅127.0.0.1:8883，使用明确公开development-only常量，无日本/手机凭据或配对。

生产state顶层drain、outbox、dispatch不交给fixturehost。测试完成先关闭自己CLI、确认临时host无callback/提交/回执，再停止临时host/relay；按ipc-cleanup-manifest精确保存本轮文件并清空IPC目录，不移动整个生产state、不删除生产顶层内容。

恢复同一新版LaunchAgent PID1709，release=0.1.0-upgrade-guard；binary SHA256为553f2131319e84bf85eae34dc2e514aae57c170fcb06e3fc33851f2d2f950a1f，前后一致。恢复后独立prepare-upgrade exit0、ready=true、drain/startup=true，三项/outbox/relay计数全部0。自己的测试host1593、relay1591、CLI1599及专用tmux已核实退出。

全局settings SHA256前后一致（bdc38f48f23d7e8311de28e1662ee1fee08eb89eefdfc26067d4626558c2f829）；生产state所有非IPC文件SHA列表前后一致，原drain保留。没有保存globalsettings全文/backup或环境值。未停止正常Codex daemon/Herdr，未改源码/STATUS/聚合升级报告，没有stage/commit。

## 证据与提交边界

证据目录evidence/claude-default-live；adoption-proof.json、active-hook-upgrade-deferred.json、completed-hook-upgrade-ready.json、tool-audit-and-restored-guard.json、independent-handoff-check.json和cleanup.json是脱敏断言摘要，便于负责人审核后选择保留。

运行态必须排除：host-token（明确公开本地fixture值，仍当运行文件排除）；relay.json（公开测试身份）；host.json（本地配置/IPC路径）；relay.sqlite及-wal/-shm/.relay.lock；host.log/relay.log；test-state-preserved/；beta-response.json、beta-submit-result.json、owned-processes.json、installed-job-before-stop.json等运行请求与进程文件。original-native-binding.json含本轮无秘密问题、私有transcript/scratchpad路径与hook元数据，不含settings/env/真实key，仍建议作为原始运行证据排除，仅提交脱敏proof。

baseline.json和production-after.json只存settings SHA/事件结构/生产文件SHA列表，没有生产文件正文；原始运行证据与配置仍由负责人统一.gitignore。执行脚本evidence/claude-global-prep/run-after-go.py含显式公开fixture常量，不是真实密钥，脚本本轮只执行一次，无失败循环。

本轮不覆盖真实iPhone/APNs、日本relay链路、Claude真实工具审批、文字/多选、同时竞答、自然超时和活二进制切换。普通默认全局hook的单题Beta原生采用与真实活hook排空延期可单独标为已测。
