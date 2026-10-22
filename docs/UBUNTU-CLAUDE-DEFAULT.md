# Ubuntu 默认 Claude 单题检查

2026-10-15：执行了一次已批准的普通零参数 Claude CLI 隔离题。结果是 **未完成问答验收**：65 秒内本地 relay 未收到全局 hook 发布的题目，请求总数为 0；未提交 Beta，也未重发问题、切换模型、账号或权限。底层 CLI/provider 原因未确定，不把该超时解释成模型容量问题。

执行前确认 Claude 2.1.289 已登录，精确工作目录 `/home/developer/Projects/agent` 已获既有信任，无其他 Claude 进程及项目级 settings 覆盖。用实际已安装新版 `hostctl prepare-upgrade` 的 fresh ready=true、draining/startup=true、五项计数全零作为暂停自身 user service 的前置门槛。

隔离 relay 仅监听 `127.0.0.1:8883`，使用公开开发 fixture 身份、APNs=null。fixture host 沿用原 `hostId=host-a` 与全局 hook IPC 路径，stateDir 仅为原 production IPC 子目录；`captureLoadedNative=false`、无 Codex socket。启动一个拥有唯一 tmux server 的 `claude` 零参数会话，只发送一次已批准的 AskUserQuestion Alpha/Beta 模板。未接受登录、信任、文件、命令或设置审批。未产生日本 relay、手机或 APNs 的 fixture 流量。

超时后只关闭本次拥有且 PID generation 一致的 CLI/tmux。fixture host 排空门槛 fresh ready=true、draining/startup=true 且所有计数全零后，才停止 fixture host/relay。精确清理原 stale socket，并将已证明属于测试的 drain 状态移入独立证据目录；没有移动 production state 目录。随后恢复原 systemd user service，未改 unit/config/credentials/hooks。

恢复核验：

- `agentinbox-host.service` active/running，PID `1772526`，新版 `0.1.0-upgrade-guard`。
- 二进制 SHA256 `fa74df1ca0dd08ae2eeb71e44b9bd18ca8dfb41db327511f42642d3d7aa2537f`。
- fresh `prepare-upgrade` exit 0、ready=true、draining/startup=true；activeHooks、activeRequests、submitting、pendingReceipts、relayOutstanding 均为 0，blockers=[]。
- 原 unit、全局 Claude settings、production state 文件摘要及顶层目录模式均未变化；IPC 顶层恢复为唯一 `hook.sock`。
- 本次 CLI、tmux、fixture host、fixture relay 均已退出；既有 Codex/Herdr PID、可执行文件与内核启动时间逐项一致。
- `cleanup.errors=[]`，没有第二次试题或补发。

证据位于 `evidence/ubuntu-claude-default/`：`preflight.json`、`run-linux.py`、`run.log`、`remote-evidence.json`、`final-readonly-verification.json` 和 `summary.json`。独立远端 fixture 证据保留于 `/home/developer/Projects/agent/.agentinbox-claude-default-20261015`，目录未纳入 AgentInbox production state。未复制 Claude 登录凭据、其他会话内容、配对码、APNs key 或生产 token。

原始 tool_result/Beta adoption、active-hook defer 与 late candidate 409 在本次均未发生，因此此记录只证明单次尝试安全结束与 production 恢复，不构成 Ubuntu 原生问答闭环通过证据。


## 已批准的第二轮受理观测

随后按既有隔离 Beta 测试授权进行一次补充观测，用已安装 fa74df… immutable native binary，不构建当前源码，不换模型/账号/权限。首次准备在暂停服务和启动 CLI 之前，因错误地要求目标 transcript 目录已存在而停止；该前置假设已修正为“缺失目录记空快照，由 CLI 自己创建”，不据此解释第一轮原因。此准备停止未消耗 CLI 启动次数；独立实际第二轮仅启动一个零参数 Claude 会话。

第二轮证据确认：本轮唯一新 transcript 中，用户消息恰一次匹配已批准 prompt 的 SHA256 `590f554b38228dbf189f4b65b288246e88fd247c208c061c5547cbc780383745`，cwd/session 一致。未执行受控额外 Enter；未再次粘贴。输入受理后出现 `isApiErrorMessage=true`，native 工具调用数为 0，fixture 请求数为 0，Beta 提交数为 0。白名单诊断未能确定 HTTP 状态或更具体错误类别，不能宣称 provider 容量、配置或 adapter 失败。65 秒原观察期限结束后停止，没有第三次启动。

已优先完成清理恢复：新版 production user host PID `1781909` active/running/enabled、draining/startup=true；fresh prepare-upgrade exit0/ready=true、五项计数全零、blockers=[]。unit/global settings/production state 摘要未变，IPC 恢复唯一 socket；所有自有 fixture/CLI/tmux 进程退出，既有 Codex/Herdr PID、exe 与内核启动时间逐项一致。

独立证据：`evidence/ubuntu-claude-default-round2/summary.json`、`remote-evidence.json`、`owned-error-classification.json`、`run-live.log` 与实际执行脚本 `run-linux-observation.py`。只保存固定状态/错误类别与已知 prompt SHA、绑定标识；未保存原始终端画面、对话正文、账号、环境或秘密。旧会话正文未读取。本轮证明了输入已受理后的 API 错误边界；原生 Ask/Beta adoption、active-hook defer、late409 仍未在 Ubuntu 此试验中验收通过。
