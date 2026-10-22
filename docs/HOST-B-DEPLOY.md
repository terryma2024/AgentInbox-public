# host-b 执行端部署 · 2026-10-16

## 当前可用范围

用户级 host 已启用并在线，仅接入 `/home/developer/Projects/example-project` 精确 canonical cwd、部署后新建的 Codex／Claude 会话。部署前会话即使后续产生新 turn 也排除；父目录、子目录、`.worktrees` 和其他项目不属于 scope。保留普通 CLI 启动方式，不使用 wrapper、launcher 或 `--no-daemon`。

已通过本机先答的真实 Codex 闭环：新普通 CLI 自动捕获单选，受控本机 Alpha 被原工具唯一采用、原 turn 完成，日本 relay 为 handledLocally、device response 数为 0。Claude2.1.301的默认hook真实捕获、自然到期和本机Beta唯一采用也已通过，见[本机复测](HOST-B-CLAUDE-LOCAL.md)。尚未通过 host-b 的手机／Widget 远程回传、Claude远程回复采用、真实工具审批、Herdr pane 映射或 Desktop；不得沿用 host-a 的入口证据。

## 安装现场

- SSH alias `host-b`，用户 developer，Ubuntu 24.04.5 x86_64，Tailscale 100.64.0.12。原 user systemd 和 linger 已存在，没有改变 linger。
- 普通 Codex CLI 0.162.1；同一既有 managed daemon 0.163.0，控制 socket `/home/developer/.codex/app-server-control/app-server-control.sock`，SO_PEERCRED UID1000、PID3901816、启动时间 2026-10-16 06:42:38。
- Claude 2.1.300 普通零参数 CLI 在该目录打开到输入页，没有目录信任提示；实际问答在工具调用前被上游403拒绝。Herdr 0.9.3 未操作。
- 原正常 Herdr、Claude、两个 Codex daemon 未停止或替换；部署首轮只使用两个独立 tmux socket；后续 Claude 本机验证使用第三个独立 socket。每轮结束逐 PID／generation／cwd 核对后仅清理自己的 CLI。daemon 历史和其子进程未盲目清理。

原生二进制为 `/home/developer/.local/share/agentinbox/releases/0.1.0-new-sessions/agentinbox`，SHA256 `4032f3ef42298522dab333eb6ea87258333bf80c8fe2eaedf6db879f9bf678ef`。Linux x86_64 musl 静态 ELF，无动态 INTERP／NEEDED；服务不需要安装 Node、Bun、Python、Go 或 Rust。现场 Python 只用于一次性部署检查，不是产品运行依赖。冻结旧 release 保留，但它不认识 exclusion 字段，不能用于本次“只接新任务”策略。

配置 `/home/developer/.local/share/agentinbox/host.json` 和 `host.token` 均为 0600，base／state／IPC 目录 0700。用户 unit 为 `~/.config/systemd/user/agentinbox-host.service`，systemd-analyze verify 通过、enabled，UMask0077、NoNewPrivileges、Restart=on-failure。首次进程 PID1274417，验收时 active、NRestarts=0、startupReconciled=true、draining=false、activeHooks/activeRequests/submitting 全0。

## 只接新会话的保护

新增可选配置 `excludedSessionIds`，缺省为空，保持旧配置兼容。Claude 在观察 permission／构建请求／发布之前检查，缺失或空白 session 交回原工具 UX，返回空 hook output，不批准操作。Codex 在 `attached.insert` 和 `thread/resume` 之前检查；显式 thread pin 也不能覆盖 exclusion，callback 必须属于已 attach 的 session。

部署基线 UTC `2026-10-16T04:43:06.584671+00:00`：Codex state DB ID 与既有 rollout 文件名 UUID 共77，Claude main-session 文件名 UUID 共17，原 daemon loaded/list 为0，合并排除94。只读取 ID，不读取旧对话正文或登录凭据；IDs 持久写入私有配置，计数与 cutoff 写入 `session-baseline.json`。恢复旧会话仍被排除。要扩大 scope／接入旧会话须另作授权，不按窗格名、焦点或项目同名猜测。

5个新回归含配置默认值、pin 不覆盖 policy、真实隔离 host IPC 的旧 Claude 问答／permission／缺失 session 零发布及新 session 发布。完整 `cargo test --locked` 为92通过、2条件忽略、0失败。独立只读代码审查未发现绕过；Codex mock RPC 排除路径、跨 turn／重启的专用回归仍是后续测试缺口，未宣称这些独立场景已跑过。

## 身份、relay 与 hooks

用户已批准 host-b 独立身份、受限 SSH 传递、空闲 relay 维护及指定目录 Claude hooks。新的 host-host-b key 只保留在日本 `/etc/agentinbox/host-host-b.token` 与目标机 host.token 的0600文件，通过 SSH 流传输，不在 Mac 落盘、不进入聊天／日志／仓库；未传 APNs 或 Agent 登录密钥。

Mac／host-a 各自 prepare-upgrade 均 ready：本地三项、durable receipt 和 relay pending/submitting/unknown 全0，且 drain 已置。日本创建受限 SQLite 一致备份与配置副本 `/opt/agentinbox/backups/host-b-20261016/` 后，只追加新身份、原子替换640配置。实际部署版本每次请求重读配置，无须重启；relay PID744651 全程保留。三台 host 自己的 upgrade-status 均200且身份匹配，跨 host responses 请求均403。正式手机、APNs、现有身份、网络设置不变。维护后 Mac drain 恢复 false，host-a 原 true 保留。

Claude `~/.claude/settings.json` 先完整0600备份至本项目 `staging/claude-settings.before.json`，核对源字节未变后原子合并。原 SessionStart1和其他字段全部保留；追加 PreToolUse1（AskUserQuestion|Bash|Read|Write|Edit）、PermissionRequest1（Bash|Read|Write|Edit），指向新 release helper、私有 IPC，内层300秒／外层305秒。host 的 cwd 与 session 双重守卫决定是否接入；未接入时空输出回原生 UX。没有代答真实审批或代为信任目录。

## 本次真实 Codex 证据

零参数普通 CLI PID1275209，经原 daemon3901816；仅新测试 session `example-id-59014cc66003` 被自动 attach。threadIds为空、captureLoadedNative=true、adoptionMarker关闭。原生 `/plan` 仅作用于此测试会话。

隔离 prompt 禁止文件、命令、设置及其他工具；只问 AGENTINBOX_CHOOSE_ROUTE / Alpha、Beta。产品请求 `example-id-d0a854e57445`，原 turn `example-id-63900fad0063`，原 call `example-id-27527db4734a`。核对专有 CLI PID/start/cwd、唯一新 thread、relay pending／无 response、期限和终端仍显示同题 Alpha 后，受控本机仅一次 Enter。

原 rollout 恰好一条同 call 的 function_call_output，解析严格等于 `{"answers":{"route":{"answers":["Alpha"]}}}`；原 turn task_complete 恰好一次、最终 AGENTINBOX_RECEIVED:Alpha。relay handledLocally，responseId=null、response行0，host回到三项0。不是物理键盘竞答，也不计手机回传。

## Claude 默认入口本机检查 · 16:08–16:11

本轮按用户选择先做本机验证，不要求手机操作。新普通零参数 Claude CLI PID2509706，独立 tmux、同一批准目录，全局 settings 未变。仅提交一次禁止文件／命令／设置／其他工具的 AskUserQuestion 隔离模板；CLI 立即显示 `Please run /login · API Error: 403 Request not allowed`。只读 `claude auth status` 同时报告 loggedIn=true、authMethod=claude.ai、apiProvider=firstParty；因此只能确认实际上游拒绝，不能断定本地已退出登录或猜测403根因。本轮没有重试请求、重新登录、读写登录凭据、修改网络或接管现有任务。

CLI 本地只读 `/hooks` 菜单实际显示 `3 hooks on 3 events`：用户级 PreToolUse、PermissionRequest，以及保留的 Herdr SessionStart 各1。这个证据证明新普通 CLI 加载了全局 hooks，不证明真实 AskUserQuestion 返回成功。真实 hook 没有产生，原计划300秒自然回退及本机 Beta 采用均未执行。

安装后原生 helper 另做4项明确合成的负向检查：已排除旧 Claude session、空 session、缺失 session、越界 cwd。各项退出0、stdout严格为 `{}`，约0.084秒；同一 host 认证队列检查前后均为空，全程没有产品请求、答案或审批。这些是部署后 helper／IPC 负向验证，不能代替真实引擎调用。没有绕过 runtime 校验去伪造一个可派发 callback。

settings SHA256 前后相同；host PID1274417、active/enabled、NRestarts=0、startupReconciled=true、draining=false，三项活动计数全0。只关闭自己的新测试 CLI 和专用 tmux；原服务、正常 Codex/Claude/Herdr与秘密未改。原始私有证据保留在 host-b 本项目 `staging/claude-local-timeout/`，不进入 Git。真实问答验收需先由用户恢复该机 Claude 的正常上游可用性，不发送密码或 token 到聊天。

## Claude 正常 shell 复测 · 19:49–20:01

用户恢复可用性后，直接SSH启动的CLI仍403；只读对照发现用户交互式zsh加载既有代理变量，而直接exec的自有测试CLI没有。改为独立tmux里的正常zsh输入零参数claude后，2.1.301即产生真实AskUserQuestion，已安装host发布到日本relay。无需改登录／代理／settings，也没有产品代码变更。

原helper300秒自然等待结束后，relay expired，原生同题恢复本机选择，回答前原tool_result0；受控本机Beta产生唯一同session／prompt／tool-use结构化结果并输出AGENTINBOX_RECEIVED:Beta。relay保持expired、response行0，手机未参与；不计远程采用或同时竞答。自有测试CLI／tmux已清理，host与relay均保留原PID。详细证据与限制见[本机复测记录](HOST-B-CLAUDE-LOCAL.md)。前面的16:08失败记录保留，不继续将403推断为账号不可用。

## 日常使用、升级与回滚

安装一次后在该精确目录沿用 `codex`／`claude` 普通启动；新任务出现可捕获请求时进入同一收件箱。现有旧会话保持排除。长问题、文字、多选或审批根据 App 现有功能展示；只有真实验收的入口才可标为可回复。

```sh
systemctl --user status agentinbox-host
journalctl --user -u agentinbox-host --since today
~/.local/share/agentinbox/releases/0.1.0-new-sessions/agentinbox hostctl ~/.local/share/agentinbox/state/ipc/hook.sock status
~/.local/share/agentinbox/releases/0.1.0-new-sessions/agentinbox hostctl ~/.local/share/agentinbox/state/ipc/hook.sock prepare-upgrade
```

升级先 prepare-upgrade，只有 readyForUpgrade=true 且本地／outbox／relay 全空才切 release；unknown 不盲重发，进程重启不继承 callback。保留身份、exclusion 配置和当前 SQLite，不把旧数据库覆盖新状态。旧不含 exclusion 的二进制不可直接回退到活动捕获；需要回退时先 drain 并停用本项目 host，等待兼容版再恢复。停用 hook 只删除本项目精确 command；原 settings 若有后续修改，不能整份备份回写。共享 relay 此次无需重启；如未来确需维护，仍执行所有 host 排空守卫。

下一步：实际手机／Widget→host-b 原任务采用；Claude 默认全局 hooks 的真实单选／文字及原 tool_result；原生0.163竞争与故障恢复、Herdr／Desktop分别验收。部署无需再提供地址、密钥或许可；Claude真实捕获与本机回退已通过；手机远程采用验收待操作窗口。
