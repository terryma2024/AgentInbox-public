# 普通 Claude CLI 产品闭环验收

2026-10-15，Mac mini，Claude Code 2.1.288；AgentInbox最终release原生二进制。本轮真实通过：普通交互CLI → 原生PreToolUse(AskUserQuestion) → 私有Unix IPC临时host → 本地relay持久化 → Beta测试客户端提交 → 原helper返回updatedInput → 原引擎产生精确tool_result → relay adopted。

本轮不是stdio权限宿主或另起引擎回放。旧精确目录已由用户信任，启动时直接识别，没有接受新增trust；未改旧目录配置。只允许AskUserQuestion，不加载MCP/slash命令，原transcript只有一次AskUserQuestion，没有读文件、命令、修改或真实工具审批。

| 绑定 | 真实值 |
| --- | --- |
| host | claude-local-smoke；与已安装host独立 |
| 原CLI PID/启动时间 | 44569 / Thu Oct 15 01:18:09 2026 |
| 原session | example-id-0d5749e42383 |
| 原prompt | example-id-0124d43eb5dd |
| 原tool_use_id / item | example-id-f4b0008bf5a5 |
| 产品request / revision | example-id-c9709f00b692 / 1 |
| response | example-id-43300ae752e2 |
| 结果 | adopted；结构化answers.AGENTINBOX_CHOOSE_ROUTE=Beta |

采用证明包含同session、同prompt、同tool_use_id的唯一tool_result，并比较toolUseResult.questions与原hook问题完整相等、answers结构精确匹配。没有以最终AGENTINBOX_RECEIVED:Beta、HTTP200或字节写入作为采用判据。本地数据库只有一个response；已完成题再次提交同Beta的新responseId实测HTTP409，原tool_result仍只有一次。

## 配置加载边界

本轮普通CLI使用 `--settings evidence/claude-live/settings.json --setting-sources ""`，专门验证临时测试配置实际加载原生hook。settings位于新AgentInbox项目，启动工作目录是用户已信任的精确 `.../p0/tasks/claude-interactive`。完整精确参数见evidence/claude-live/launch.json。

空setting-sources使这次新CLI不加载原用户global/project hooks，避免与已安装且drain的helper叠加。已安装host及其drain保持原样；本轮不声称默认无额外参数启动的全局hooks已经加载或混合hook链已通过。要验收“一次安装后沿用默认启动”，仍需独立配置装载测试。

独立host codexSocket=null，只授权claude-interactive；relay仅监听127.0.0.1:8879，身份为明确公开development-only测试常量，不使用模拟器身份或日本server身份，没有APNs或新增持久凭据。产品未知launchSurface未凭tmux猜测；本轮入口由自己新建的精确CLI进程/专用pane另行证明。

## 证据与资源清理

- evidence/claude-live/launch.json：普通CLI启动参数、临时settings来源；prompt.txt是获准Beta隔离模板。
- original-hook-binding.json：原hook与产品完整绑定，仅本轮无秘密问题。
- adoption-proof.json：精确原工具采用、单响应与迟到重复拒绝。
- post-submit-observed.json：对应原tool_result与产品adopted快照，含本轮问题结果，未上传完整对话。
- cleanup.json：独立host44519先drain三项0，再核对准确PID/start/command退出；本轮relay44508和已完成专用CLI44569清理，三PID及专用tmux server均核实不存在。

正常Codex daemon91603/wrapper25959、默认Herdr4646、已安装host35721均保留。未修改旧测试配置、已安装host范围或drain，未创建未知Desktop任务。没有源码修改。

本轮未验收：Claude PermissionRequest真实工具审批（未授权）、中文文字、多选、自然过期、本机键盘竞答、断网跨设备、原生Desktop Code tab、Ubuntu Claude、真实iPhone/APNs、默认启动全局hook装载。旧P0这些入口的部分证据仍属于P0，不提升为本轮产品支持。

## 默认配置装载边界的只读补充

2026-10-15只读检查用户默认settings、该精确目录project/local settings、祖先目录和Mac managed-settings路径；未修改任何配置，未创建新Agent题。`claude doctor`的本机帮助明确说明读取当前目录settings；在原已信任目录执行退出0，未报告invalid settings，但没有输出逐事件实际加载hook链，因此不能用doctor成功代替真实hook加载验收。脱敏元信息见evidence/claude-live/default-config-readonly.json。

| 默认来源 | 只读结果 |
| --- | --- |
| 用户settings | SessionStart matcher `^(startup|resume|clear|compact|fork)$`：非AgentInbox、未发现直接P0命令标记；副作用未评估，也未执行此hook测试。PreToolUse matcher `AskUserQuestion|Bash|Read|Write|Edit` 与PermissionRequest matcher `Bash|Read|Write|Edit`：AgentInbox命令，未发现直接P0命令标记。 |
| 精确目录 `.claude/settings.json` / `.claude/settings.local.json` | 均不存在；未发现额外祖先project/local settings。 |
| Mac managed-settings.json | 此路径不存在；未验证其他管理员政策/插件动态hook。 |
| 旧P0目录顶层 `settings.json` | 仍存在P0 PreToolUse(`AskUserQuestion|Bash`)与PermissionRequest(`Bash`)；旧P0通过显式 `--settings`加载。此文件不是上述默认project/local路径，未证明普通无参数启动会加载它；不要继续沿用旧P0显式参数。 |

用户默认settings已经存在AgentInbox全局hook配置，因此临时 `--settings`不是产品必需的结论；它只是本轮控制验收来源的方法。现有全局hook已配置与事件真实加载/返回是两项证据：默认无额外参数CLI的真实事件链、已安装drain helper `{}`返回与其他hooks组合、解除drain后的原题采用，仍未验收。只读检查未解除drain、未扩大scope、未自动处理真实工具审批。命令正文、其他settings字段、环境值和秘密未打印或保存。
