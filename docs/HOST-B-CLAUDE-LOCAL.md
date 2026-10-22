# host-b Claude 普通入口与本机回退 · 2026-10-16

本轮通过：Claude Code 2.1.301 普通零参数启动，默认全局 PreToolUse AskUserQuestion 经已安装原生 host 发布到日本 relay；无人远程回答时自然到期，原生问题恢复本机选择；本机 Beta 被原 session／prompt／tool-use 唯一采用。本轮不需要手机操作，不计手机回传或审批验收。

## 启动环境差异

用户确认 Claude 已可用后，首个复测直接从非交互 SSH 启动 CLI，仍在工具调用前返回 `403 Request not allowed`。只读比较发现：这个自有测试进程没有六个 HTTP_PROXY／HTTPS_PROXY／ALL_PROXY 大小写变量，而用户正常交互式 zsh 全部存在；两者解析为同一 Claude 可执行文件。没有输出变量值或读取 Agent 登录凭据。

随后只改变启动路径：在新的独立 tmux 中打开用户正常登录 zsh，再输入 `claude`，CLI 实际参数为空。新 CLI 确认继承既有代理变量，默认 Haiku 5.5 未覆盖，同一隔离模板即成功调用 AskUserQuestion。这个对照支持启动环境差异是本轮直接 SSH 失败的原因；不能仅凭403把账号判为失效。没有新设代理、修改网络、创建 wrapper、改登录状态或恢复用户旧 settings。

产品使用方式仍是在现有 tmux／Herdr shell 输入原来的命令。测试框架直接 exec 可执行文件不能替代用户的正常 shell 环境。

## 原请求与实际结果

| 项目 | 本轮证据 |
| --- | --- |
| scope | `/home/developer/Projects/example-project`，新会话，不在94个部署前排除ID中 |
| 普通 CLI／shell | PID588211／586846；独立 tmux，零参数 CLI，没有 --settings／launcher／SDK |
| 产品 request | `example-id-1c4cd26e3ed1`，revision1 |
| 原 session | `example-id-0569f4700e3a` |
| 原 prompt／turn | `example-id-e2c497794157`，取自真实 hook，没有臆造 |
| 原 tool-use | `example-id-999cdcc99bb5` |
| 原 engine runtime | `claude:588211:Fri Oct 16 19:52:17 2026` |
| 实际 helper | PID590185，原生已安装二进制，私有 IPC，参数上限300秒 |
| 产品等待窗口 | 北京时间19:53:05创建，19:58:04到期；host 使用 min(hostTTL, helperDeadline) |
| 到期前 | running PreToolUse hook，host activeHooks1／activeRequests1／submitting0，无答案 |
| 到期后、按键前 | relay expired、responseId=null；原CLI显示同题 Alpha／Beta；原 tool_use1、tool_result0，helper已退出、host三项0 |
| 本机回答 | 严格核对自有PID／generation／cwd、pane、原题、期限和无回复后，一次Down选择Beta，再核对可见Beta，单次Enter确认 |
| 原生采用 | 同session／prompt／tool-use 恰好一条 tool_result，原 questions 完整相同，answers严格为 `{"AGENTINBOX_CHOOSE_ROUTE":"Beta"}` |
| 最终输出 | `AGENTINBOX_RECEIVED:Beta`，其他引擎工具调用0 |
| 日本relay | 原产品请求保持 expired，独立只读SQLite确认 response行0，relay PID744651未变 |

到期后没有默认批准或自行回答。Claude 在 PreToolUse 等待期间尚未显示原生问题；本机选择是在 hook 等待结束后进行，不能算本机／手机同时竞答。远端产品请求已过期，所以本机后续答案不会将它改成远程 adopted；原任务本机采用和远端回调期限分别记录。

本轮没有包装 helper 采样 stdout／exit code，不宣称实测到了 `{}` 或某个精确系统读超时；可观察证明是原helper退出、host请求排空、真实CLI原题保留以及回答前原tool_result为0。deadline、EOF与读取超时谁先生效未区分。Claude 2.1.301 在 hook 等待中尚未把 tool_use 写入 transcript；hook返回后才出现该原工具条目，未把前期0条误判为没有调用。

## 清理与保留

全局 settings SHA256 与本轮启动前相同，保留用户恢复后的配置，未整份回写旧备份。host 仍为原PID1274417、active/enabled、NRestarts0、startupReconciled=true、draining=false、活动三项0。仅按自有PID／启动时间／cwd／pane清理两个测试CLI及独立tmux；正常daemon、Herdr和用户任务未停止。没有新增凭据、服务切换或产品代码修改。

原始绑定、自然到期快照、原生事件、helper身份、一次性输入意图、采用证明与清理记录仅保存在 host-b 私有 `~/.local/share/agentinbox/staging/claude-local-interactive/`；直接SSH失败记录保留在 `claude-local-round2/`，均不入Git。手机／Widget→host-b远程采用、真实工具审批、文字／多选、活callback争用仍需分别验收。
