# 验收状态 · 2026-10-23

主屏 Widget 待办体验：正式 App／Widget 已覆盖安装，保留原配对与地址。真实 iPhone 中号主屏的双击唯一派发、旧点击不答新题、切题展开、准确文字详情及接收反馈通过；两份答案分别回到隔离原调用并继续。测试题和身份已清理，生产配置核对恢复。iOS 单元执行 156 项／6 条件跳过／0 失败，App UI 回归 10 项、模拟器三种尺寸流程通过；纯发送中画面和同步失败仍保留模拟器边界，未冒充真机已测。详见 [实现与验收边界](WIDGET-INBOX-EXPERIENCE.md)。

消息式原文更新：完整问题、选项说明、命令及参数按可读消息展示与复制，单元 139 通过／6 条件跳过、长原文 UI 通过，新版已覆盖安装到真机。恢复 USB 与手机 Tailscale 连接后，更新后的真实 iPhone 长问题和长命令复验均通过：消息首行及原文末尾完整可见，问题答案只派发一次且原调用接收并继续，命令拒绝返回原工具且未执行命令。生产服务与采集正常、配置保持不变，临时验收请求及身份已清理。

决策上下文：生产 relay、三台正式 host 及真实 iPhone App／Widget 已升级；长问题与长命令审批详情真机验收通过，新增内容绑定答案。问答的一次回复获原生接收及继续运行证明，命令由手机拒绝；缺失的任务目标和影响范围明确为“未知”。临时测试请求／身份已清理，三台正常 host 恢复采集。见 [部署、验收与边界](DECISION-CONTEXT.md)。

## 回复可靠闭环原生与真机验收（2026-10-22）

可选 Codex 原生胜者证明、原调用输出核对及独立继续运行观察已实现；生产 relay 已升级，真实 iPhone App 三步闭环与 App 已停止时的 Widget 独立验收均通过，第 2 项按该实测组合完成。Rust 全套 130 通过、0 失败、3 忽略；原生扩展 12 个新增测试、所在模块共 44 项通过，受控真实引擎与生产 relay 的重复提交、丢回执响应、host 退出恢复和同值竞答均通过。未替换现用 Mac/Linux Codex；未扩展 Codex 与当前 Claude 仍保持“来源未确认”。[回复闭环记录](REPLY-RELIABILITY.md)及[来源核查](REPLY-NATIVE-PROOF-AUDIT.md)区分实际支持、确定性模型和未验证组合。

## 当前方案变更（2026-10-21）

功能 1 当前方案为“只读 API 关联 Tailscale＋复用 iPhone VPN”。实机 Screens 首次关联确认使用 Tailnet ID＋客户端密钥；用户确认此前记忆有误，并明确选择按现有方案继续，在手机填写只读凭据做真机验证。此前免填凭据的网页授权要求由本次决定替代；不创建额外节点，不要求快捷指令。

只读 API 版本已实现并安装。既有完整单元 101 通过／6 条件跳过、核心 UI 7 通过；按钮可见性及随系统深浅色自适应已修复、回归并安装。本轮真实凭据关联、设备目录同步、手动刷新和冷启动恢复已通过；原应用 Keychain 配对状态仍可用。已安装 host 的私网发现／应用认证／在线心跳经授权临时升级验收通过并完整恢复；Wi-Fi → 蜂窝 → Wi-Fi 的前台返回、手动刷新及原中继认证也已通过；用户随后确认本轮目标完成；真实改名／地址变化仍保留为未验收。最新范围见 [FEATURE1-TAILSCALE.md](FEATURE1-TAILSCALE.md)。

真机首次填入 Client ID 而非 Tailnet ID，设备接口返回 404，被原版笼统显示成“设备信息无效”。用户确认混淆后使用正确 Tailnet ID，真实只读关联成功。正式版已补充 General 页面取值说明和设备接口专用 404 提示；新增错误回归先 RED 后 GREEN，API／存储相关 16 项通过。开发签名构建与 strict codesign 通过，并已实际覆盖安装，临时诊断版移除。

首次 API 目录为 7 台，后续刷新为 6 台；差异仅旧 `agentinbox-iphone` 不再出现在后续响应中，未确定远端变化原因。正式版刷新及重启后刷新各 1 项真机检查通过，目录缓存均为 API 来源、重启后稳定 ID 集合一致且更新时间推进；检查未读取或记录凭据。证据在忽略目录 `evidence/tailscale-api/physical-proof.json`、`physical-final-refresh-v2.log`、`physical-final-relaunch-test.log`。首次脚本固定 7 台造成的失败保留，不将实时目录变化计为产品失败；修正后按当前目录核对。

按后续要求，Tailscale 设备行已改为只显示域名与 IPv4／IPv6，其他机器信息留在详情。签名新版已实际覆盖安装；既有导入／API 存储回归 16 项通过，真机逐台核对 6 行的域名和全部 IP 通过，夜间截图已目检。证据为忽略目录 `evidence/tailscale-api/address-only-physical.log` 和 `address-only-screenshots/`。长地址允许换行，缺失字段显示未提供。

设备详情现已显示 Tailscale 域名，并加入“设置为中继服务器”。点击后沿用当前协议／端口，通过所选域名验证中继 API 与现有应用配对，成功才保存；失败保留原地址。该验证独立于 8788 主机发现，切换时隔离 App／Widget 的旧缓存、迟到请求和旧组件操作。完整单元 111 通过／6 条件跳过，核心 UI 7 通过；签名正式源码构建已覆盖安装。真机成功／失败路径通过：不可达候选没有改动地址，当前 已保存中继 域名认证成功且配对保留；深色截图已目检。真实跨独立中继迁移未验收，配置变更提交由单元测试覆盖。证据见忽略目录 `evidence/tailscale-api/relay-selection-physical-v2.log`、`relay-selection-full-unit-v2.log`、`relay-selection-ui-regression-v2.log` 及 `relay-selection-screenshots/`。

新增启动／返回前台的 VPN 引导：未检测到本机 Tailscale 隧道时提示打开独立 iPhone App，早期确认后以裸深链接唤起，后发现会触发签名错误；当前修正为明确前往 Tailscale 的 iOS App Store 页面，由用户打开／安装。只读接口检测、不自动修改 VPN；共享 IPv4 网段单独匹配视为未知，避免误判其他 VPN。原始缺失功能及 IPv4 误判回归先 RED 后 GREEN，完整单元 118 通过／6 条件跳过；核心 UI 7 通过，签名构建、strict codesign 与最终覆盖安装通过。复审无剩余 P1／P2；用户手动断开后的提示及 Tailscale 进入前台曾通过，深色提示截图已目检；该测试遗漏 Tailscale 内部签名错误页，不能计为完整成功。未删除 Tailscale，未将 App Store 回退单元测试计为真实卸载验收。最初两次检查误用了旧测试工程 App，修正 xctestrun 的目标及依赖路径为正式构建后通过，失败日志保留。证据在忽略目录 `evidence/tailscale-api/vpn-guidance-disconnected-physical-v3.log`、`vpn-guidance-physical-proof.json` 与 `vpn-guidance-screenshots/`。

2026-10-22 唤起修正：用户报告“Could not sign device / Unable to verify deeplink”；裸 `tailscale://` 被 Tailscale 当作签名入口，不是无副作用的普通启动 API。[官方问题](https://github.com/tailscale/tailscale/issues/14679)保留未解决的普通启动诉求。已删除该调用及 scheme 查询，按钮改“前往 App Store”，多一步由用户点“打开”或安装，直接自动唤起目标暂未实现。回归先 RED 后 GREEN，完整单元 118 通过／6 条件跳过，签名构建与覆盖安装通过，独立复审无 P1／P2；正式修正版真机已通过“提示 → 官方产品页 → 商店打开 Tailscale → 无签名错误页”，最终深色提示截图已目检。用户重新连接后的首次检查在 XCTest 初始化阶段超时、测试体 0 执行；重试发现提示。随后只读核对独立 Tailscale 显示 Not Connected 且无签名错误页，本机接口无 Tailnet 地址，当前提示与状态一致，未认定为已连接时误判；用户随后确认 iPhone 显示 Connected，正式 App 返回不再提示的真机检查通过；原保存中继已配对 `/v1/hosts` 认证另 1 项通过，手机回到收件箱。用户已澄清此前可能只是打开 App 未手动连接，未证实另有自动掉线故障。证据为忽略目录 `evidence/tailscale-api/vpn-deeplink-fix-*.log` 与 `vpn-guidance-connected-physical*.log`、`vpn-store-physical.log`、`vpn-store-screenshots/`、`vpn-guidance-connected-physical-v3.log` 与 `vpn-connected-relay-physical.log`。

原始 Screens 式目标继续核验：当前 Rust 完整回归 95 通过／2 条件忽略，arm64 Release 与当前 iOS Release 设备构建通过。主 App／Widget 实际签名的 Keychain 组隔离再次核对通过，工程无内置 Tailscale SDK。手机最新 API 快照仍为同一 6 个稳定 ID，更新时间推进。本机临时运行当前原生 discovery 模块后，真实 iPhone 的设备行 → 发现描述 → 原配对认证保存中继 → 未注册 host 保持等待心跳的检查通过，临时监听已关闭。首轮失败仅为组合标签查询，已保留。该组件检查本身不等于生产 host 已启用发现；当时 Mac mini 服务仍用旧二进制、无发现参数，未更改或重启。随后授权的已安装 host 正向验收、恢复及网络切换结果见下一段；真实改名仍待验收；详见 [执行清单](superpowers/plans/2026-10-21-tailscale-readonly-api.md)。证据为忽略目录 `evidence/tailscale-api/native-discovery-physical-v2.log`、`goal-native-regression.log`、`goal-native-release-build.log`、`goal-ios-release-build.log`。

2026-10-22 已授权临时验收：Mac mini 三项活动计数重核为 0，`prepare-upgrade` 无阻塞后，以独立目录新版临时启用 `REPLACE_LOCALLY_DISCOVERY_IP:8788` 只读发现，保持排空。真实 iPhone 在用户确认的 Wi-Fi 下完成设备描述发现、原保存中继认证、原配对保留及已注册 Mac mini 在线心跳，1 项检查通过。首轮仅“在线”整行标签查询失败，改为同一单元格内后代字段后通过，无产品代码更改。随后已恢复原二进制、字节一致的 LaunchAgent 和配置、非排空状态；启动核对完成且三项活动为 0，8788 关闭，临时产物清理。此为临时升级验收，不是永久启用发现。用户确认 Wi-Fi 基线及蜂窝数据后，蜂窝下刷新及原中继认证 1 项通过，6 个稳定 ID 不变且时间推进；随后用户确认已重新连接 Wi-Fi 且 Tailscale Connected，返回无未连接提示、手动刷新和原中继认证再 1 项通过；三阶段同一组 6 个稳定 ID，更新时间依次推进。此项不等于后台无人操作恢复或自动路径变化刷新时限验收。用户本轮不做设备改名，真实改名／地址更新仍未验收。证据在忽略目录 `evidence/tailscale-api/installed-host-wifi-physical-v2.log`、`installed-host-restoration.log`、`installed-host-proof.json`、`network-cellular-physical.log`、`network-wifi-return-physical.log`、`network-switch-proof.json`。

此前网页路线实验：官方 OAuth App 注册拒绝 `devices:core:read`（400 invalid scopes）；用户批准的临时管理凭据已撤销，原只读凭据保留，无新增节点。Screens 的管理控制台网页登录与首次关联原生表单已分别实测，详见 [核查记录](TAILSCALE-WEB-AUTH-INVESTIGATION.md)。

此前快捷指令版 Rust 95 通过／2 条件忽略，iOS 单元 88 通过／5 条件跳过，UI 6 通过，Release 无 SDK；Apple Development 签名、profiles 校验及覆盖安装／启动、真机 JSON 预览取消通过。快捷指令首次自动启动失败，用户手动打开后界面检查通过，后续配置因锁屏暂停。这些是旧阶段证据，不计为 API 新流程完成。

以下为截至 2026-10-17 的既有验收记录，保留其原范围与限制。

独立项目采用 Rust 1.96.1＋bundled SQLite＋Swift。本表区分旧 P0、本项目真实入口、模拟进程测试和当前安装状态；正常 Codex daemon、默认 Herdr 与旧 Happyword 保持原状。

## 当前交接

2026-10-17：host-a漏报已定位为遗留drain＋仅测试目录范围。用户明确要求不限目录／仅新会话，已在16:21:17（北京时间）启用captureAllDirectories，447个旧会话标识持久排除，新host3355156保持开启；正常daemon2367003、Herdr、日本relay未重启。原范围外/srv/example-project的新Codex0.163.0真实捕获、APNs首次发送、本机Alpha唯一采用及handledLocally通过；未将APNs接受等同真机送达。完整原生100通过／0失败／3 ignored（2条件演练＋1子进程入口）。[恢复、证据边界与当前操作](HOST-A-CAPTURE-RECOVERY.md)。以下按日期保留历史drain／版本记录，不当作当前host-a配置。

2026-10-16 20:01：[host-b Claude2.1.301本机复测](HOST-B-CLAUDE-LOCAL.md)通过真实默认hook捕获、原生helper自然到期、同题恢复本机选择及唯一Beta工具结果。直接SSH的403与未加载用户zsh既有代理环境相符；正常shell输入零参数claude后成功，未改登录／代理／settings。relay原题expired、设备回复0，手机远程采用仍待验。自有CLI与tmux已清理，host／relay原PID保持。

2026-10-16 16:11：host-b Claude 默认普通CLI只读菜单确认三条hook实际加载，部署后helper四项合成负向检查均零发布；真实问答在工具调用前被上游403拒绝（本地auth status仍为loggedIn=true），未执行自然超时或本机Beta采用，未改登录／网络／全局设置。测试CLI已清理，host保持在线、零活动。手机验收按用户选择暂缓。

2026-10-16：host-b 用户级 host 已部署，仅 example-project 精确目录、部署后新会话；94个旧会话持久排除。默认 Claude hooks 已最小合并，原设置保留。真实 Codex0.162.1 CLI／既有0.163.0 daemon自动发现及本机 Alpha→原 call 唯一结果→handledLocally通过；手机回传、Claude真实问答、Herdr和Desktop仍单独待验。原生回归92通过／2条件忽略。relay身份原子热加载、PID未变，现有host状态恢复。见[部署与边界](HOST-B-DEPLOY.md)。

实体目标是用户确认的 **Example iPhone 16 Pro / iOS 26.6.1**。本轮已由正式 App 自动完成单次码配对、Keychain 保存、经 Tailscale 私网认证取题与 Sandbox APNs 注册。新码未在界面或日志显示，手机输入文件与 Mac 临时副本均已删除，既有身份不覆盖。**真实 APNs 送达已通过**：手机系统 deliveredNotifications 中发现 UNPushNotificationTrigger，其 requestId 精确匹配本轮标准 Codex CLI 原请求；relay outbox 首次 sent。见 [配对证据](../evidence/iphone-automatic-pairing-proof.json)、[真实送达证据](../evidence/iphone-real-apns-delivery-proof.json)。随后用户在手机点 Beta／提交；正式设备唯一回复被原 session/turn/call 采用，终态 adopted，原任务输出 AGENTINBOX_RECEIVED:Beta。见 [真实手机采用证明](../evidence/iphone-beta-original-adoption-proof.json)。**真机中号Widget直答已通过第三道新题**：Widget扩展begin/end各1，测试窗内无App激活或深链，唯一Beta回复被原Codex同session/turn/call采用并完成；这道题未通过App前台预刷新。见[精确证据](../evidence/iphone-widget-native-adoption-proof.json)、[边界与此前排查](WIDGET-PHYSICAL-DEBUG.md)。

真机签名 App／Widget 与 UI Runner 均使用已有开发证书和 profile；没有新增 Apple 凭据。XCTest Runner 在启用 UI automation 的系统初始化阶段60秒超时，**测试体0执行**；DDI只读检查 compatible/usable、developerMode启用、paired、手机已解锁。用户确认没有系统弹窗，Enable UI Automation 原本已打开。Device Hub 后续明确显示屏幕共享要求 iOS27+，当前26.6.1不能使用；XCTest超时原因仍未定，未将两者混为同一根因。未绕过密码、修改安全设置或重复运行相同失败。

本轮Widget修复前，日本 relay 为 `0.1.0-device-admin`；本轮在两 host 和远端队列全空时，仅重启 relay 一次导入替代码，runtime override已清理、原unit和Restart策略恢复，当时PID742341。本轮Widget后端已在fresh两host排空后升级至`0.1.0-widget-push`/PID744651，旧release和SQLite/unit受限备份保留，配置/网络/密钥不变。Mac／Ubuntu host保留 `0.1.0-upgrade-guard`，未重启；Mac已在配对后移除自己的drain标记，仅允许原两测试目录，Ubuntu继续drain。现有daemon和默认Herdr保持原状。唯一正式设备ID为 device-example-id-3e053159c47f。

## Widget 自动更新真机结果（2026-10-15）

修复版已签名安装到用户确认的 iPhone16Pro/iOS26.6.1，保留原 Keychain 配对。正式 Widget token 注册成功，日本 relay 使用原 Sandbox APNs 密钥接受 Widget topic，无新增或扩大密钥权限。原失败阶段为 persistCounter；同步布尔降为缓存观测后恢复，但未直接采到原布尔值，因此不把该值当作已证实的系统根因。

新隔离题 `example-id-b3de388798fe` 已在 App 后台、没有手动刷新或预算绕过时自动显示于桌面。创建后 8.719 秒 Provider 读到准确 requestId/revision，实际主屏幕截图同时核实。用户直接点 Widget Beta 并保持桌面；唯一正式手机回复由原 session/turn/native17/call 采用，原任务完成并输出 `AGENTINBOX_RECEIVED:Beta`。终态推送 generation4/acked4；后续后台Provider在17:16:25确实重载，但约13秒取题超时，桌面保留提交中并显示连接错误。终态自动显示本轮未通过，手机网络超时根因继续核查。见[真机白名单证据](../evidence/iphone-widget-push-automatic-proof.json)、[原始引擎事件](../evidence/iphone-widget-push-original-items.json)、[现场记录](WIDGET-PUSH-LIVE.md)。

新版在17:30–17:32完成另一轮：新题 `example-id-3340d7e8017b` 自动显示；用户Widget点Beta，原native18唯一采用并完成，App保持后台、无手动刷新。交互触发Provider经只读收敛读到adopted，桌面实际清空；距点击开始到Provider最终读取5.228秒。见[新轮完整证明](../evidence/iphone-widget-receipt-terminal-proof.json)。这不将前轮网络失败改写为成功，也不证明终态推送单独唤醒。

`after300` 和 Widget 专用推送均受系统调度/预算约束，不承诺固定刷新间隔。普通 APNs 提醒与 App 收件箱独立。原生默认82项通过、两项旧产物演练各通过；Swift最新核心59项通过/0失败，5个专用环境用例未启用。Mac仅恢复本轮测试范围，Ubuntu原drain保持，下一轮跨主机真机链路尚未开始。

## 本项目已经实测

| 入口／能力 | 实际结果与范围 |
|---|---|
| Mac 标准 Codex CLI，既有共享 daemon | 允许目录内自动发现当前加载的待决请求；无 launcher、wrapper、--no-daemon 或另起引擎。单选 Beta 经 iOS 正式提交服务被原请求采用。 |
| 真 iPhone App → 日本 relay → 原 Mac CLI | 真实推送到达后，正式手机身份的唯一 Beta 回复被原 session/turn/call采用，原turn完成；无终端代答或另起引擎。 |
| 主屏幕 Widget → 同一原 CLI | 已确认iPhone16Pro/iOS26.6.1真实中号Widget点Beta后App未激活，Widget扩展独立鉴权、唯一原session/turn/call结果adopted；用户与DEBUG事件双核。另有iOS26.4模拟器独立证据。 |
| 本机／手机顺序竞争 | 本机先答后 handledLocally、迟到手机候选 409；手机先答后 adopted，受控终端拒绝晚到 Enter。不是任意物理键盘与手机同时异值竞答的验收。 |
| 多手机候选 | SQLite 与真实 HTTP 的 8 候选仅一个获胜，精确领取不能取另一会话答案。 |
| 配对、共享 Keychain、撤销 | 临时模拟器设备的一次码消费、Keychain 保存、认证读取、重放拒绝、撤销后 401 和测试密钥清理通过；当前实体手机配对、Keychain与认证取题也已单独通过。 |
| Mac 普通 Claude CLI，默认全局 hooks | 零参数启动，没有 --settings/setting-sources 覆盖，现有全局 hook 实际加载；同原 session/prompt/tool_use 的唯一 Beta 结果 adopted。真实活 hook 等待时升级守卫延期，原题完成后才 ready；设置和生产状态哈希不变，服务已恢复待命。 |
| Ubuntu 标准 Codex CLI，无 thread pin 自动发现 | host-a 原 managed daemon 下，临时 host 的 captureLoadedNative=true、threadIds=[]，host 先于新 CLI 运行；无需预先登记原 thread 即捕获真实等待题，测试客户端提交 Beta，唯一原 call 结构化结果 adopted。 |
| Herdr 独立命名 session／pane | 通过 CLI 自身 /status 与进程证据核实归属，host 显式 pin 原 thread；测试客户端提交 Beta，原工具唯一结构化结果 adopted。通用 pane↔thread 自动映射未通过；无 pin 自动发现新轮被模型 capacity 阻止，未产生题，不计通过。 |
| App／Widget 中文界面 | 待决、详情、中文文本、多选、历史、机器、设置与精确深链；长题、多题、文字和摘要不完整的审批转 App 对应请求。 |
| Claude 等待到期的真实 UX | 普通 CLI 临时隔离配置下，原生 helper 在外层 hook 超时前返回 {}；同一原题回本机待答，原 tool_result=0，迟到答案409、零派发。未将问题等待推断为工具审批通过。 |
| 恢复与排空 | 四个隔离进程场景通过：活跃 hook 延期升级、新 hook 拒绝、host 重启失效旧 callback、claim 回复丢失变 unknown 不重派、采用回执 outbox 跨 host／relay 重启精确对账。原引擎与 tool_result 明确模拟。 |
| 本机设备管理与撤销 | 原生管理命令与自撤销共享单一事务；临时设备撤销后即401、其他身份有效，故障全部回滚，晚到 worker 结果不能复活 cancelled。真实日本服务只验证空列表、同 PID 与权限不变，未撤销真实设备。见 [操作说明](DEVICE-ADMIN.md)。 |
| 新版升级守卫 | prepare-upgrade 先置 drain；本地活动、持久 outbox、启动对账及认证 relay 的 pending/submitting/unknown 任一未清均拒绝。断开控制 reader 与 drain 写失败不终止 host；旧 relay 404 拒绝放行。 |
| 原生新旧二进制回滚 | 独立真实旧／新 Mac 二进制、同一测试数据库完成切旧／再升级；保留原 responseId、同答案幂等、零重新领取。原引擎结果模拟，已安装服务未被该测试改变。 |
| Mac／Linux 原生产物 | Mac ARM64 Mach-O；Linux x86_64 musl 静态 ELF。Linux relay 在日本 Ubuntu 26.04 原生运行、鉴权、keep-alive 与持久化通过；本轮新版本的实际安装与就绪检查见升级记录。 |

入口证据：[Mac 原 CLI 采用](../evidence/adapters-live/codex-beta-adoption-proof.json)、[模拟器真实主屏幕 Widget](../evidence/ios-widget-native-proof.json)、[本机先答](../evidence/adapters-live/keyboard-first-result.json)、[手机先答](../evidence/adapters-live/phone-first-result.json)、[Claude 默认全局 hook](CLAUDE-DEFAULT-LIVE-RESULT.md)、[早期限定配置](CLAUDE-LIVE-RESULT.md)、[到期实际待答界面](CLAUDE-HOOK-TIMEOUT.md)、[Ubuntu 无 pin 自动发现](UBUNTU-AUTODISCOVERY.md)、[Herdr 独立 pane](HERDR-LIVE-RESULT.md)。

恢复与维护证据：[四个模拟引擎进程场景](RECOVERY-ROUND2.md)、[升级守卫独立审查](UPGRADE-GUARD-REVIEW.md)、[当前产物新旧二进制回滚](../evidence/device-admin-binary-rollback.json)。这些隔离题和维护测试不能替代真实手机、所有 Agent 入口或已安装服务的升级验收。

## 版本与支持矩阵

| 引擎／入口 | 本项目实测 | 当前边界 |
|---|---|---|
| Codex 0.162.0 CLI / 0.162.1 daemon，Mac tmux | 自动捕获、真实iPhone App/中号Widget单选Beta回传、模拟器Widget、两主机同时待答异值回传、本机/手机先答及手机候选未领取时的受控TUI竞争通过。 | source/originator 不用于猜测终端归属，launchSurface 仍可为 unknown。中文／审批虽有 P0 与编码回归，真实产品采用覆盖尚不足。 |
| Claude Code 2.1.299，Mac 普通交互 CLI | 零参数默认全局 hooks 的单选 Beta 和真实活 hook 排空延期通过；早期 2.1.288 隔离配置也有单独证据。 | 产品审批／文字／多选和同时键盘竞争尚未验收；旧 stdio 宿主九项不作为普通 CLI 支持依据。见 [默认启动报告](CLAUDE-DEFAULT-LIVE-RESULT.md)。 |
| Ubuntu Codex 0.162.1，host-a 专用 tmux／原 daemon | 无预登记 thread/session 的自动发现、单选 Beta 原任务采用通过。 | 已在相同已信任scope补足安装后的host-a host、正式日本relay及原iPhone Widget Beta采用，见[真机记录](UBUNTU-IPHONE-LIVE.md)；Ubuntu已独立核验免开App/免手动刷新终态显示，Provider约85秒后读到adopted；跨主机双待答异值Widget回传已单独通过（两题间手刷），Claude与Herdr仍待验收。早期 pin 证据见 [UBUNTU-LIVE-RESULT.md](UBUNTU-LIVE-RESULT.md)，当前自动发现结论见 [UBUNTU-AUTODISCOVERY.md](UBUNTU-AUTODISCOVERY.md)。 |
| Ubuntu Claude 2.1.289，普通零参数 CLI | 首轮未见发布；补充一轮通过唯一 transcript 精确证明输入受理，随后 API 错误发生在任何工具调用前。 | 没有原生问题或采用，错误具体 provider／状态码未确定；不算 hook 故障或回复通过，见 [两轮边界](UBUNTU-CLAUDE-DEFAULT.md)。两轮均清理并恢复原待命服务，无第三次启动。 |
| Herdr 0.9.3，Mac 独立命名 pane／标准 Codex CLI | 精确核实 pane／CLI／thread 后显式 pin，真实 Beta adopted、迟到候选 409。 | 自动 pane↔thread 映射、共享 daemon hook 路由、多 pane 同名项目、pane 替换／移动、Herdr 重启、Claude-in-Herdr 与 Ubuntu Herdr 未通过。默认 Herdr 未被接管。无 pin 新轮因模型 capacity 未产生原请求，见 [尝试结果](HERDR-AUTODISCOVERY.md)。 |
| Codex 原生 Mac App | 未通过。 | 历史一次创建无 ID 的状态仍未知；没有用 CLI 成功代替 Desktop，也未宣称清理完成。 |
| Claude Desktop Code tab | 未通过。 | Chat／Cowork 不作为替代。 |
| Example iPhone 16 Pro / iOS 26.6.1 | 已安装，自动正式配对、Keychain、私网认证取题、APNs注册与真实远端推送送达通过。 | 手机App与中号Widget Beta原任务采用均通过，Widget期间App未激活；仅这款真机/版本及单选模板。XCTest Runner超时，硬件按钮由用户正常点击，非自动UI测试成功。 |
| APNs | HTTP/2 worker、通用 payload、持久 outbox、JWT 缓存回归通过；本 App Sandbox 密钥已受限配置。 | 本轮已有真实手机 UNPushNotificationTrigger 与精确 requestId 送达证明；尚未覆盖断网/锁屏完整矩阵，iOS26 Widget 专用推送已真实接受并自动显示新题；回答后交互触发Provider已在新一轮自动读到采用终态并清空桌面；前轮后台取题超时保留为失败。 |
| 日本 relay／私网 HTTPS | 新版已安装、认证完整升级状态通过；仅 tailnet HTTPS8443 的 Mac／Ubuntu 证书验证通过。 | Funnel／ACL 未改变，既有 Xray 443 保留。手机到 relay 的私网 TLS 配对、认证取题及 APNs 注册已通过。 |

早期验收以 iOS 17 为源码基线，尚未做 iOS 17 实机兼容验收。当前已移除 TailscaleKit，App／测试与 Widget 的源码部署基线均恢复为 iOS 17.0；源码基线与 iOS 17 实机验收分别记录。

## Widget 明暗外观修复（2026-10-15）

用户指出的暗色白字配浅米色背景已通过真机截图复现。Widget背景由固定RGB改为系统自适应secondarySystemBackground，原证书/profile签名安装到同一iPhone；暗色真机与模拟器浅色/暗色实际桌面已复核可读，模拟器恢复原浅色，真实手机外观设置未改。Debug真机、模拟器与Release构建均通过，保留iOS17源码基线。空状态/连接错误状态与本轮真实并发题的暗色待答选项均已截图复核可读。截图与详细证明只在本地忽略的evidence目录。

## 第一组并发测试（2026-10-15，自动检查点）

新增5项仅cfg(test)的原生来源匹配回归：本机Alpha不可认作手机Beta，其他session/turn/call的Beta也不匹配，原正确Beta可以匹配。完整cargo test --locked实际87通过/0失败/2 ignored；新5项已计入，先前40项定向运行不重复相加。两项需指定旧二进制的回滚演练本轮未运行。未改产品host行为、部署服务或凭据；这些测试不等于整个host事件循环竞争或物理键盘竞答通过。

本轮双机同时pending与正式iPhone Widget异值回传已通过：host-a原call唯一Beta，Mac原call唯一Alpha，两原turn完成且adopted。用户两次都留在桌面，但两题间手动刷新，故自动切题未通过。已定位较新submitting挡住另一台pending；修复自动优先有效pending并保留其他提交中/未知提示，显式pin不换题。新增6项先3失败，修复后iOS核心65通过/5条件跳过/0失败，签名Debug与Release构建/验签通过并安装；新版独立真机复测已通过：新Ubuntu Beta后约8秒Provider自动选Mac，截图确认后Mac Alpha唯一采用，两题各原turn完成；本轮无手动刷新或App激活，最终桌面自动清空。复测专用CLI2082749已关闭，host恢复原drain，正常daemon/Herdr保留。见[详细结论](CONCURRENCY-PHASE1.md)与[计划](superpowers/plans/2026-10-15-concurrency-phase1.md)。tiny_http独立补丁仓库按用户意见留作后续整理，本轮不改。

## 本机与手机异值竞争（2026-10-15）

[真实记录](CONCURRENCY-LOCAL-PHONE.md)：本机受控Alpha先答，原任务唯一Alpha、relay与手机准确页handledLocally、无手机候选；手机Widget Beta先答，原call唯一Beta/原turn完成，控制器发现已答后取消Enter；最后一轮正式手机Beta入库后，原题仍等待，受控本机仅一次Enter抢先Alpha，原call唯一Alpha/原turn完成，relay与手机handledLocally，Beta未领取/未派发，Widget自动清空。本轮无产品运行时代码或服务更改。

这是受控TUI与真实iPhone的竞争，不能算物理键盘同时操作；host已领取/已派发手机候选后的争用仍未验收。预备题曾因监测窗口过早结束而过期，两控制器都0次输入，精确隔离turn已中断清理，失败没有计成功。详细截图/绑定/日志仅本地evidence，不入Git。

## 自动化结果与已知限制

Widget推送阶段的此前原生检查点：默认82通过/0失败/2 ignored；两项指定旧二进制的演练各自另行通过。最新 iOS 核心59通过/0失败，5个需显式配置专用配对/relay的用例未启用；新只读回执等待的12项先RED后GREEN。签名Debug、Release、iOS17源码基线与24个DEBUG标记剔除均通过。见 [原生结果](../evidence/native-widget-push-test-summary.json)、[iOS结果](../evidence/ios-widget-receipt-refresh-verification.json)。下面保留更早阶段的统计，不能与当前测试重复相加。

设备管理阶段的历史默认原生全套实际退出 0：**61 passed、0 failed、1 ignored**。passed 中有一个 recovery 子进程 fixture 入口，默认为 **60 个实质测试**。忽略的显式新旧二进制回滚已用当前 Mac release 另跑 **1 passed**；合并为 **62 个唯一方法／61 个实质测试**，不重复计数。[六文件精确检查点](../evidence/device-admin-six-postimage-checkpoint.json) 记录测试前后 SHA 和审查补丁一致，[当前 release 回滚](../evidence/device-admin-binary-rollback.json) 记录同一测试数据库的兼容与幂等。早期 guard 版本的 [56项默认运行](../evidence/native-round2-full.json) 和 [旧回滚](../evidence/native-binary-rollback.json) 保留作历史。

历史全套中曾有 HTTP 8 候选的三个请求达到 4 秒超时。tiny_http idle worker 未扣排队预留的饥饿路径已有确定性 RED／GREEN、保留许可的最小修复与真实 24 连接 keep-alive 回归，未放松超时或绑定。已证明并修复该设计缺陷，但不能断言那次历史超时必由此导致。见 [http-scheduler-red.txt](../evidence/http-scheduler-red.txt)、[http-scheduler-green.txt](../evidence/http-scheduler-green.txt)、[http-keepalive-green.txt](../evidence/http-keepalive-green.txt)。

APNs JWT 50 分钟缓存回归通过。iOS历史27个唯一测试方法通过；本轮新增AutomaticPairingTests 11项通过。最终当前源码Protocol9＋Submission6＋AutomaticPairing11合计26项回归通过、0失败/跳过（15项属历史方法，不新增重复计数），另有Release与15项DEBUG标记移除验证。真机UI测试体0执行，不计成功。历史测试包括最终独立 ID／Group 的跨进程 Provider 鉴权、唯一回复与清理复验，见 [IOS.md](IOS.md)。

仍缺物理键盘／手机同时异值竞答与手机候选已领取后的争用、旧通知／Widget 与真实题目变化全链路、Agent 退出／PID 重用／pane 替换／同名项目完整现场矩阵、双执行端键盘／手机同时竞争（双主机同时待答的异值Widget回传已通过，自动切题首轮手刷、新版独立复测免手刷通过）、活跃生产 hook 的实际升级与回滚。隔离模拟恢复、真实二进制回滚和实际空闲服务升级均不等于这些项目已通过。

Ubuntu新增真实Widget入口：[正式日本relay与原任务采用](UBUNTU-IPHONE-LIVE.md)，独立原生证据包含唯一工具结果，不能外推Ubuntu Desktop/Claude/Herdr。测试后恢复原drain，用户服务和正常daemon保留。

## 当前安装、授权与下一步

Apple Developer 主 App、Widget 和 Group 已注册关联，主 App Push 已启用；Widget扩展Push已在本轮后台启用并重建profile，专用推送自动显示新题已通过，回答后免手动刷新终态显示已通过新一轮；App Store Connect 独立 App 为 EXAMPLE_APP_STORE_ID，无构建上传、审核或发布。实体安装证据见 [ios-physical-install-proof.json](../evidence/ios-physical-install-proof.json)，签名过程见 [IOS-device-signing.md](IOS-device-signing.md)。[早期设备未就绪记录](../evidence/ios-device-identity-pending.json) 仅作历史，不作为当前型号、签名或连接状态。

用户已批准现有证书签名安装、独立服务器／用户服务部署、既有 tailnet HTTPS 和本 App 专用 APNs 密钥。已安装 Mac LaunchAgent、host-a 用户 systemd 与最小 Claude hooks 的限定范围保持不变；初次安装和旧版本历史见 [HOST-INSTALL-RESULT.md](HOST-INSTALL-RESULT.md)、[LINUX-DEPLOYMENT.md](LINUX-DEPLOYMENT.md)；三个服务首次 guard 升级见 [IDLE-UPGRADE-RESULT.md](IDLE-UPGRADE-RESULT.md)；最新仅日本 relay 的设备管理升级见 [DEVICE-ADMIN-DEPLOY-RESULT.md](DEVICE-ADMIN-DEPLOY-RESULT.md)。

本轮已按用户“生成新码并全程操作 iPhone”的明确授权完成正式配对，不需要再输码。最新一枚码已单次消费，旧到期码未重新激活；本机临时副本已删，无 APNs 私钥转移。第一题已由用户在实体 App 提交 Beta 并精确采用；第二个独立 Widget 隔离题使用新 request/turn/callback，不复用旧答案。用户已添加中号组件，独立 Provider 认证通过，系统时间线未按请求的5分钟刷新，已增加组件内只读刷新按钮。第二道题也精确采用，但用户明确在App内回答，不能计Widget直答。诊断已观察到真实刷新Intent；第三题 e7c15bb5/native16 单独通过真实Widget免开App采用，先前第二轮仍只计App回复，未改写历史结果。见 [最新真机记录](IPHONE-LIVE-20261015.md)。
