# 第一组并发验收 · 2026-10-15

## 双主机异值回答已通过

同一正式日本 relay、同一正式 iPhone 设备身份，两个标准零参数 Codex CLI 的原请求在同一只读 SQLite 事务快照中同时为 pending。Mac CLI 0.162.0／原 daemon 0.162.1，Ubuntu CLI／原 daemon 均为0.162.1；不替换启动入口。两题均只调用一次 request_user_input，无其他工具调用。

| 原执行端 | 产品 requestId | 原 session / thread | 原 turn | 原 native request / call | 手机答案 |
|---|---|---|---|---|---|
| host-a | example-id-4eab0b2a8356 | example-id-2449912e2b55 | example-id-69337ae52e0e | 3 / example-id-cf3f782cba49 | Beta |
| mac-mini | example-id-dab6d131c27a | example-id-dfe6b7e7212f | example-id-68e6adf6d2a3 | 19 / example-id-f740dcdbe52c | Alpha |

两条回复均来自原正式设备 device-example-id-3e053159c47f，revision1；各一条唯一response。Ubuntu response example-id-2a2477d09ef1，Mac response example-id-977a385b0b00。

各原call恰好一份结构化工具输出：Ubuntu route.answers=[Beta]，Mac route.answers=[Alpha]；各原turn完成且回显 AGENTINBOX_RECEIVED:对应实际值。两请求最终adopted，无跨机器误投或重复原生输出。原daemon运行实例完整绑定已保存本地，窗格名称未用于授权。

用户确认两次回答都留在主屏幕。Widget扩展分别有AnswerBegin/End；从第一答题Intent到第二题完成的窗口内无App激活。此前20:17:44有过一次App深链并于20:18:00回桌面，不能把整个生成题目至结束期间说成从未打开App；它发生在20:24:57第一答题前，未提交答案。

## 自动切题首轮未通过

用户在host-a回答后仍看到旧题，手动点组件刷新才显示mac-mini，随后选Alpha。因此本轮只计双主机同时待答、Widget异值回传通过，不计免手动刷新切题通过。

时间线（北京时间）：

- 20:24:57.735：host-a Widget Beta Intent开始；20:25:08.898结束。
- 20:25:10.902：原call输出Beta。
- 20:25:13.708：Intent触发的Provider结束，仍选host-a。
- 20:25:16：服务器记录adopted；20:25:17.095 host记录原生采用终态。
- 20:25:21.296：用户手动刷新；20:25:24.533 Provider选mac-mini。
- 20:25:31.119：Mac Widget Alpha Intent开始；20:25:34.843原call输出Alpha。

旧选择逻辑直接取列表第一个pending/submitting/unknown。host-a较新且尚在提交中，挡住了另一道真实pending题；短暂只读等待早于终态落库结束。不能据此保证APNs或系统调度的实时性，也不能通过把提交中假定为已采用来切题。

## 有限修复与验证

自动模式现在优先选择尚未过期的pending请求；没有有效pending才显示submitting/unknown。页面保留“另N项提交中／结果未知”，原状态和回复日志不改变。显式固定requestId仍严格固定，不会在消失或终态时默默转给另一题。Provider诊断与实际选题使用同一逻辑；未增加POST或答案重试。

新增6项选题回归，旧行为实际3失败，修复后完整iOS核心65通过／5个需显式fixture的条件用例跳过／0失败。现有12项有界只读刷新回归保留。原证书/profile的Debug真机与Release构建通过、严格验签通过，已安装同一iPhone。只读审阅无阻塞问题。新版真机免手动刷新切题已在下面独立复测通过；这次实际结果不等于系统自动唤醒的实时保证。

真机暗色待答截图已补看，题目、Alpha/Beta与机器标签可读。新增其他回执提示行的长题布局还需截图复核。

## 清理与后续边界

Ubuntu用户host已prepare-upgrade排空：activeRequests、activeHooks、submitting、pendingReceipts、relayOutstanding全0，readyForUpgrade=true，恢复原draining=true。只关闭本轮专用tmux内PID2062050的CLI；正常daemon1805212和Herdr未停止。Mac原有专用CLI保留空闲，正常daemon91603未重启。

物理键盘与手机异值同时竞争、旧Widget真实重放、断网与升级矩阵尚未完成；本轮两个主机的原引擎与其各自答案准确对应，不外推Desktop、Claude或Herdr自动归属。tiny_http独立补丁仓库仍是后续工程整理项。

详细快照、原工具结果、交互事件、截图与构建日志在本地被Git忽略的evidence目录，未上传仓库。

## 新版复测预备阶段（未形成双待答）

第一次新版复测准备时，Mac新题example-id-5347f69df425在Ubuntu草稿提交前，已收到正式iPhone Widget的Beta并adopted。扩展记录携带这个新requestId，服务器回复与新原生请求一致；用户点击时看到的机器标签尚待核对。该次只形成一道题，不能计双待答或自动切题通过。Ubuntu第二题草稿尚未提交，已暂停等待核对用户所见机器标签，不盲目再发题。

## 新版完整复测通过

用户随后说前次可能记错并要求重测。未实施未经证实的SwiftUI身份/渲染修复，也未新建模拟器身份；使用已安装fbfdd84的新选题逻辑再生成两道独立原题。

| 执行端 | 新requestId | 原turn | 原call | 唯一手机responseId | 原结果 |
|---|---|---|---|---|---|
| host-a | example-id-a49ee2739667 | example-id-5e694aef8655 | example-id-b7f655dcb9d0 | example-id-405d2a3850cc | Beta，adopted |
| mac-mini | example-id-b6372f94b608 | example-id-09cdc444c635 | example-id-bdbb5447d46c | example-id-cf82e7e6a079 | Alpha，adopted |

Ubuntu sessionexample-id-cc24274ee434/native4，Mac仍为原sessionexample-id-dfe6b7e7212f/native21；原daemon运行实例未变。两题21:21:02/21:21:05创建，第一手机答题21:21:38才开始；Ubuntu已采用后，Mac仍pending，随后21:28:38收到Alpha。各精确原call一份结构化工具输出、各原turn完成且回显对应实际值。

此次用户在第二个双pending快照完成前已点击Ubuntu，取证脚本的“双pending”断言失败，未保留为成功快照。本轮用完整创建/答题/原工具结果与Mac持续pending时间线核对重叠；首轮独立保留了同一事务双pending快照，不能把本次失败断言说成通过。

Widget10055本轮事件未达到64条上限（取证时总26条）：两个精确request分别AnswerBegin/End各一次；整个复测窗无widgetRefreshBegin/End、App激活或深链。21:21:46.440 Provider自动选Mac，距第一点击约8.014秒；用户只点host-a Beta后停下，实际桌面截图确认mac-mini待回答，再指引Alpha。用户确认两次均留桌面。21:28:44.915 Provider读到两题adopted并无当前题，之后实际桌面截图确认“暂无待决问题”；无手刷或前台App辅助。因此新版自动切题、不同主机的不同答案准确采用和终态自动清空独立通过。

此前“显示host-a却回复Mac”的反馈缺点击时像素，用户后来表示可能记错；本次没有复现。保留为缺证的历史疑点，既不据此宣称已证实误投，也不宣称某项未经实现的渲染修复已解决它。

收尾再次确认Ubuntu各活跃计数、待发回执与relayOutstanding全0，恢复原draining=true；仅关闭专用CLI2082749，原daemon1805212与Mac原daemon91603不变。下一项仍是本机输入与手机异值竞争，尚未开始。
