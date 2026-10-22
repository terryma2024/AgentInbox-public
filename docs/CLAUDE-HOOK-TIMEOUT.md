# Claude 真实 hook 到期后的本机待答界面

2026-10-15 单轮观察通过：普通交互 Claude Code 2.1.299 的原 `AskUserQuestion` 在 AgentInbox 等待上限结束后显示原生 Alpha/Beta 选择界面，继续等待本机回答。没有发送任何 PTY 按键或有效答案；原工具结果数为 0，没有 `allow` 或其他工具调用。

本轮使用已信任的独立 `claude-interactive` 工作目录、临时 `--settings`、空 `--setting-sources`、空严格 MCP 配置，只开放 `AskUserQuestion`。使用本项目独立 loopback 原生 relay/host/helper、公开 development-only fixture token、独立 IPC/state 和专用 tmux socket；`codexSocket=null`。未改全局设置、已安装服务或真实凭据，未配对、未接触 Japan 服务或手机。

## 可观察结果

| 项目 | 本轮结果 |
| --- | --- |
| 原始工具 | 唯一一次 `AskUserQuestion`，题目 `AGENTINBOX_CHOOSE_ROUTE`，Alpha/Beta 单选 |
| 绑定 | 真实 hook 的 session、prompt/turn、tool-use/native-request/item 与 pending 产品一致；runtime 对应本轮 CLI PID 和启动时间 |
| 时间配置 | helper 5 秒；Claude 外层 hook 10 秒；host 配置 TTL 60 秒 |
| helper 返回 | 4.741509 秒，exit 0，原样输出 `{}`；外层 10 秒没有杀进程 |
| 实际 CLI 界面 | helper 返回至少 2 秒后，同一 CLI 仍显示原题、`1. Alpha`、`2. Beta` 及 `Enter to select · ↑/↓ to navigate · Esc to cancel` |
| 原始工具结果 | 清理前、清理后均为 0；其他工具 0；最终 `AGENTINBOX_RECEIVED` 标记 0 |
| 旧产品 | `expired`；到期后一次 Beta 迟到提交返回 409 `request no longer pending` |
| 派发证据 | fixture SQLite 中该请求 response 数为 0；host 无该请求的 response-dispatched 事件；原 CLI 无 tool_result |
| 清理 | 本轮 CLI、专用 tmux 和两个 fixture 子进程均退出，私有 runtime 已删除 |

helper 5 秒与 host 到期并非两个独立时钟：host 使用 `min(hostTTL, helperDeadline)`，且时间戳精度会影响实际经过时间。绑定 deadline 到期、EOF 与 helper 读取上限可能竞争。本轮不判断哪一个先发生，也不将 4.741509 秒描述成完整 5 秒 read timeout；结论是原生 helper 在外层 hook 超时前正常结束，随后真实 CLI 保留原问题供本机回答。此结论同时有实际原生界面及原始工具记录支持，未仅凭 `{}` 推断 UX。

## 证据与范围

可交付脱敏结果：[claude-hook-timeout-summary.json](../evidence/claude-hook-timeout-summary.json)。编排脚本：[claude-hook-timeout.py](../scripts/claude-hook-timeout.py)。脚本保留单轮 attempt 防重入保护，观察 wrapper 只围绕原生 helper 记录耗时并原样转发输出，未伪造 IPC peer 或 hook 身份。

原始本机证据位于 `evidence/claude-hook-timeout/`，整目录已忽略：`native-hook.json`、`pending-binding.json`、`helper-return.json`、`screen-after-helper-return.txt`、两个 `native-audit-*.json`、`result.json` 与 `cleanup.json`。交付摘要保留原始证据 SHA-256，剔除 session/tool/request/PID、绝对 transcript 路径及临时配置。

这次观察覆盖真实普通 CLI 的临时隔离 hook 配置及实际本机待答 UX。它没有验证用户默认全局 hook 链、实体手机、配对、APNs、真实审批工具或 Beta 成功采用；不扩张为手机完整闭环验收。
