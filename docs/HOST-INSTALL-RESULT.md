# 用户执行端安装结果（2026-10-14）

> 以下保留初次安装与历史阶段事实。2026-10-15 三个本项目服务已更新至 `0.1.0-upgrade-guard`，APNs 已受限配置 Sandbox、手机仍未配对；当前结果以 [空闲升级记录](IDLE-UPGRADE-RESULT.md) 和 [支持矩阵](STATUS.md) 为准。

用户已明确批准 HOST-INSTALL-REVIEW.md 中 Mac/host-a 用户服务、Claude hook最小合并及host key600。此次仅安装独立AgentInbox，不改源码、不新建或回答Agent题，不停止正常Codex daemon/Herdr。

## Mac mini

- release：`/Users/developer/Library/Application Support/AgentInbox/releases/0.1.0/agentinbox`，SHA256 `7314b6e04a7b64b3e8f8b0dcc7a8a18242714ee4a479f62a5ab9e778d9ba7c29`。
- host.json、host.token同一Application Support目录；均600。token仅从日本已有受限文件SSH传送，无聊天/仓库副本。
- state700，IPC为state/ipc/hook.sock0600；日志在logs/。
- LaunchAgent：`~/Library/LaunchAgents/dev.matianyi.agentinbox.host.plist`，plutil lint通过，已bootstrap，PID35721，runs1。负责人先对原临时host33203精确drain、核对三项0并仅终止该进程，才启动新服务。
- scopes只有既有P0 `codex-round2` 与 `claude-interactive` 两目录。captureLoadedNative=true，仅与当前daemon原生回调关联。
- 原socket只读inspect成功peerPID91603；loaded原CLI idle。launchSurface仍unknown，不借此宣布Desktop/Herdr已支持。

## Ubuntu host-a

- developer用户目录`/home/developer/.local/share/agentinbox`；static x86_64 ELF release/0.1.0/agentinbox，SHA256 `7113dd64f0851a852a1325ca8d646a416acc5e81ac210fd9a1dd60a4340588a1`。
- host.json、host.token600，state700、IPC600。host-host-a key经两条SSH管道直接传送，无本机持久中间文件或输出。
- unit：`~/.config/systemd/user/agentinbox-host.service`，systemd-analyze --user verify通过，enabled/running，PID1444070、NRestarts0、UMask0077。已有Linger=yes，未创建或改变此权限。
- scope只有用户已信任的`/home/developer/Projects/agent`。
- 原socket只读inspect成功peerPID1805212，loaded=[]。这是Ubuntu原协议兼容与用户服务连通证明，尚不是Ubuntu真实请求/回答采用证明。

## 两端Claude合并与TLS

各用户现有settings均SessionStart1；逐字段保留全部其他设置与现有hooks。仅追加PreToolUse（AskUserQuestion|Bash|Read|Write|Edit）与PermissionRequest（Bash|Read|Write|Edit），命令为对应新binary＋私有IPC，helper300秒、原hook timeout305秒。合并前备份600在各独立AgentInbox目录`claude-settings.backup-20261014.json`，替换前确认源逐字等于备份。settings本身收紧600。安装不代替普通Claude CLI真实hook加载与返回验收。

两host指向已批准tailnet HTTPS `https://relay.example.ts.net:8443`，独立机器身份mac-mini/host-a。当前hostctl均startupReconciled=true，activeHooks/activeRequests/submitting=0；没有未知callback被继承。独立伪造无原Claude runtime、非授权cwd的helper安全探针均输出 `{}`，未创建问题/默认allow。

## 验证证据与维护

`evidence/mac-host-install-prepared.json`、`mac-installed-native-inspect.json`、`mac-host-install-start.json`；`host-a-host-install-prepared.txt`、`host-a-host-install-start.txt`、`host-a-host-installed-status.txt`以及两端installed-helper-failclosed.json。Ubuntu enable后首次即时hostctl遇到IPC尚未建立的NoSuchFile，随后只读复核成功；没有重启或复试安装。

升级/回滚必须先hostctl drain并核对activeHooks、activeRequests、submitting三项0，unknown仅对账不重发。旧Claude配置备份包含原用户设置，不能上传或输出。真实Codex/Claude、iPhone/APNs和Widget回答验收由负责人继续，不能将此次安装验收写成采用证明。

2026-10-15后续待命：真实手机仍未被Mac mini检测/配对，负责人在两端三项0时置drain，保留服务/心跳、原CLI本机处理，不让新Claude hook等待空手机。手机签名配对后，仅解除各自私有drain标记即可恢复已批scope，无须重装或改原启动命令。
