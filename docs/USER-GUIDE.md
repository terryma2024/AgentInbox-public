# 用户操作指南

当前实体目标是 **Example iPhone 16 Pro / iOS 26.6.1**，独立 App 已签名安装。你已确认手机在同一 tailnet，本轮重新连接后 App 已启动；已批准的受限配对码复制和 seed 已执行，首枚已到期未消费、临时副本已清理，正式配对尚未完成。真实推送注册／送达和真机 Widget 仍待验收，现有码时效见 [本轮记录](IPHONE-LIVE-20261015.md)。当前两端 host 保持 drain，Agent 继续原来的本机交互；详细状态见 [STATUS.md](STATUS.md)。

## 保持原来的启动方式

Mac／Ubuntu 用户服务运行 host，日本 relay 保存请求、回执和 push outbox。Claude 通过获准安装的最小 hook helper 接回原请求，Codex 连接已有 managed daemon。你继续在 tmux／Herdr 输入原来的 codex 或 claude；无需统一启动命令、wrapper、SDK 宿主或 --no-daemon。

已测范围包括 Mac Codex 单选和模拟器主屏幕 Widget、零参数默认全局 hooks 下的 Mac Claude 单选，以及 Ubuntu 无预登记 thread 的 Codex 自动发现／真实 Beta 采用。Herdr 已测的是独立命名 pane 中核实原 CLI／thread 后显式 pin 的原生 Beta 返回；通用 pane↔thread 自动映射仍未通过。Codex Mac App 的历史未知创建仍未知，CLI 成功不代表 Desktop 入口通过。

## 手机就绪后首次连接

打开手机的 Tailscale 与独立 AgentInbox 设置，核实私网 HTTPS 地址。现有入口为 [relay-host 私网 HTTPS8443](https://relay.example.ts.net:8443)；Mac 与 Ubuntu 已验证其证书，手机实际连通仍待现场确认。

已安装 App 可直接经同一 tailnet 配对，无须持续连接 USB。手机就绪后再继续已批准的受限配对码步骤，在 App 输入短期单次码；App 收到的设备密钥保存在 Keychain。当前实体手机尚未完成 relay 配对，历史模拟器的配对／共享 Keychain 证明不能替代这一步。手机就绪与配对完成后，再按维护流程恢复限定 scope 捕获。

通知正文只说有任务等待回复，点击后经认证读取具体题目。真实 APNs 注册、送达与真机 Widget 要分别确认；签名安装和已配置 APNs 密钥不表示手机已经收到推送。

## 回答请求

“待决”显示问题和机器。打开精确题目后选择选项、输入中文说明，或按题目允许选择多项；文字与选项互斥。选择和原内容绑定到同一 requestId／revision，host 再绑定原 session、turn、item 和 runtime。

“提交中”只表示答案已进入队列；“原任务已采用”必须等精确原引擎回执。“结果未知”时先查状态，不重复原操作。已在本机处理、过期或失效的题目不能再次提交新答案。

Widget 简短单选可直接回答；长题、多题、文字、多选与摘要不完整的审批打开对应 App 请求页。Widget 刷新时间是快照时效，推送与收件箱独立工作。真实手机 Widget 还需要现场验收。

发送前断网后，已保存的原答案保持不变。恢复网络后，仅当准确同 requestId／revision 仍待回答，才使用“重试原答案”，沿用同一 responseId。提交中、结果未知或终态仅刷新。题目变化时，旧题失效、新题有独立绑定；旧通知或 Widget 不能把旧答案投到下一题。

## 设备和机器状态

设备丢失时由操作者在 relay 使用[本机设备管理命令](DEVICE-ADMIN.md)核对并撤销该设备，后续认证拒绝并取消待发 push；仅移除手机本地 Keychain 不等于服务器撤销。机器离线显示最后心跳；心跳在线也不证明旧 callback 可以重启继承。

日本 relay 已在排空后升级至 `0.1.0-device-admin`；Mac／Ubuntu host 保持 `0.1.0-upgrade-guard` 继续 drain 待命，旧版均保留。最新服务状态见 [DEVICE-ADMIN-DEPLOY-RESULT.md](DEVICE-ADMIN-DEPLOY-RESULT.md)，手机配对和恢复捕获仍待手机在线后继续。

## 更新与恢复

当前新版维护命令为 `agentinbox hostctl SOCKET prepare-upgrade`：先置 drain，再检查本地活动、持久回执和认证 relay 的 pending/submitting/unknown。仅 readyForUpgrade=true、draining=true 时退出 0；离线、未解决结果、旧 relay 不支持接口或检查失败都延期。单看 status 三项为零还不够，命令也不会自动停止进程或更新版本。

有活跃 hook 时保留原请求完成的机会，不强关 callback。未知结果只对账，不盲重派；host 重启后旧原生 callback 失效。隔离新旧二进制回滚已证明同一测试数据库保留原回复和幂等，但不代表所有已安装服务、真实引擎或活跃生产 hook 的升级／回滚均已验收。具体操作由维护流程执行，见 [OPERATIONS.md](OPERATIONS.md)。

本轮已恢复手机在线，按短期码时效完成正式配对后继续已授权推送和 Widget 调试；过期码不能盲重seed。
