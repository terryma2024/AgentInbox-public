# 执行端持久安装准备（尚未执行）

> 本文保留原授权清单。用户后续已明确批准并完成该限定范围，当前安装结果见 [STATUS.md](STATUS.md)；不是等待重复确认。新的机器、scope、网络或凭据范围不由此自动授权。

日本relay已部署并创建独立host-mac／host-host-a身份，但执行端用户服务和Claude hook安装尚未批准。以下为准备范围；启用前由用户确认实际项目范围，不能默认接管已有任务。

## Mac mini

- 二进制：`~/Library/Application Support/AgentInbox/releases/0.1.0/agentinbox`；固定release不覆盖运行文件。
- 独立配置/host key：同一Application Support目录内受限文件（600），state目录700，IPC0600；密钥从日本服务器已有受限host-mac文件经SSH传输，不进入聊天或仓库。
- 用户级LaunchAgent：`~/Library/LaunchAgents/dev.matianyi.agentinbox.host.plist`，使用现有用户，非root，不停止或替换Codex/Herdr。
- Codex观察已有managed daemon Unix socket；按授权canonical项目scopes发现已经加载的当前待决回调；不恢复冷历史，不另起引擎，无wrapper。
- Claude：只合并新增 `PreToolUse`（观察原tool_use_id；AskUserQuestion等候正式回答）与 `PermissionRequest` 两个事件到 `~/.claude/settings.json`；现有SessionStart保留。Native helper命令为新独立binary＋私有IPC；超时输出{}并退回原引擎，不默认allow。先写受限备份，生成不含现有秘密的差异，再安装。
- 当前只读已知该文件有SessionStart一个entry，其他settings/env不输出、不改变。

## Ubuntu host-a

- 用户developer，现有CLI在 `/home/developer/.local/bin`：Codex0.162.1、Claude2.1.289、Herdr0.9.3；不是安装新CLI或统一启动入口。
- 新binary在`~/.local/share/agentinbox/releases/0.1.0/agentinbox`，配置/host-host-a key600、state700；使用已验证x86_64静态ELF。
- 用户systemd `~/.config/systemd/user/agentinbox-host.service`，不会安装root host service；是否需要loginctl linger为单独持久权限，当前不设置。
- 配置真实现有Codex socket和授权canonical项目scopes；原sessiondaemon实际协议与Linux peer身份须先只读验证，不能直接把Mac成功记为Ubuntu通过。
- Claude hook仅合并用户已有settings，保留其他配置；scope内专用普通CLI才能证明产品闭环，未验证目录的信任由用户本人完成。

## 升级与验证

任何已有实例先drain，activeHooks/activeRequests/submitting均0后才切换；已有unknown仅对账，不重派。安装服务定义先lint/verify。实测两机器独立请求与同名项目；原引擎唯一结构化采用才为adopted。没有说明来源的terminal映射不直接send-keys，Herdr与Desktop独立验收。

默认不开放任意目录；授权scopes与专用测试目录需要确认后填入真实配置。可以先沿用Mac两个P0专用目录以免影响正常任务：codex-round2和claude-interactive；Ubuntu专用题目录由用户确认信任。项目的普通源码、构建、localhostfixture测试继续不依赖该安装批准。
