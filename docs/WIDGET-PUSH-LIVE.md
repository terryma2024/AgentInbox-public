# Widget 自动刷新修复现场 · 2026-10-15

五分钟after时间线仅请求系统在其后重载，现场最后可核对的更新仍来自手动RefreshIntent。普通alert APNs与Widget直接回复各自通过，不能推导自动刷新可用。新增iOS26 Widget专用推送路径，保留iOS17基线和手动刷新；未开WidgetKit开发模式绕过预算，仍不承诺固定刷新间隔。

原生checkpoint6080c6f已构建Mac ARM64与Linux静态ELF，默认82项通过/0失败，2项需指定旧产物的演练各另跑1通过（不重复计数）。同一日本relay已在fresh两host守卫全零后升级为0.1.0-widget-push，PID744651；旧release、SQLite与unit受限备份保留，网络/身份/APNs key未变。Mac host1709恢复原待命；Ubuntu保持原drain，正常daemon/Herdr未重启。新Widget开发profile使用原证书、原手机和原共享组。

真机候选已安装并取得Widget系统token，既有DeviceSecret和认证Inbox仍正常。但新注册没有抵达server。仅观测版本确认失败阶段persistCounter/unconfirmed，发生于Keychain pending保存和POST之前；具体synchronize原返回false尚未直接记录，不能先归因为Apple系统故障。见[诊断](../evidence/widget-push-physical-register-diagnosis.json)。

最小修复已完成：NSUserDefaults计数是缓存，synchronize布尔不再阻断；Keychain pending必须持久成功后才发送，server最高registrationRevision拒绝迟到/异内容重放，原类型/溢出守卫保留。模拟false的2例先RED后GREEN；最终47项通过/0失败/0跳过，Debug/Release无签名构建和原证书严格签名候选完成，Release24个DEBUG标记剔除。证据：[回归](../evidence/ios-widget-push-sync-false-verification.json)、[签名候选](../evidence/ios-widget-push-sync-fix-signed-candidate.json)。

手机开发连接16:27后断开，CoreDevice仍paired但tunnel unavailable，Xcode不再枚举物理目标；这不是模拟器验收。最终修复候选尚未安装。用户重新连接后继续安装，核对原syncBool与真实注册；随后必须实测Widget APNs接受、App不在前台且不点刷新时Provider取新题和主屏幕实际显示，再测终态自动更新。尚未创建本轮新的真实Agent隔离题；旧三题都已adopted，无遗留待答。尚未向Apple更换或扩大key范围。


## 重新连接后的真实结果

用户重新连接后，严格签名的最终47项回归候选安装成功，原配对保留。等待原网络失败的有界退避到期后完成注册，无删除退避或重置身份。已有 Sandbox key 接受 Widget topic，初始 generation1/acked1；未新建、读取或扩大 APNs key。

17:03 App 回到后台，桌面 Widget 当时为空。17:04:52 原标准 Codex CLI 创建 native17 隔离题；无手动刷新、无前台启动、无开发预算绕过，17:05:00.719 Provider 取得同一 requestId/revision，实际桌面显示 Alpha/Beta。对应 generation2/acked2，创建到 Provider 首次匹配8.719秒。17:10用户在 Widget 点Beta并确认仍在桌面，扩展begin/end各一次，App事件缓冲完整且无激活；唯一 responseId 由原 session/turn/call 采用，17:10:16任务完成。APNs后续generation4/acked4。首次回答后桌面仍显示提交中，原引擎采用与组件终态显示分别验收，后者继续观察。

证据：[完整白名单记录](../evidence/iphone-widget-push-automatic-proof.json)、[原任务事件](../evidence/iphone-widget-push-original-items.json)、[自动新题桌面](../evidence/iphone-widget-push-auto-question.png)。前文“连接断开/未安装”是当时检查点，已由本段更新；同步布尔本身仍未直接捕获，不能把假设写为根因。


终态观察结果：17:16:25 系统确实再次调用Provider；约13秒后取题失败，仍保留17:10的提交中缓存，桌面明确显示“连接暂不可用，请稍后刷新”。这与未收到任何重载不同；APNs generation4/acked4不能证明此次数据获取成功。该窗口内App事件仍只有原4条，无手动刷新/前台启动。终态自动显示未通过，具体手机网络错误码尚未捕获。观察窗口结束后才打开App进行独立连通诊断，不能把随后前台刷新作为自动通过。


## 回答后回执显示改进

新增只读收敛：Provider初次正常GET仍保留12秒网络超时；若服务器完整列表含submitting，再在5秒追加策略/结果接纳预算内最多读取4次，暂停最多0.75秒、后读网络超时最多1.25秒且按剩余预算裁剪。错误、取消、迟到结果保留最后成功列表，不推断采用，不重新POST，不修改journal。5秒不是整个Provider或底层网络的硬耗时上限，也不是后台私网超时根因的修复。

12项新行为测试先真实RED（15条断言失败）后GREEN；新12＋原Submission6共18通过，完整核心59通过/0失败，5个明确依赖专用配对或relay环境的用例未启用。已用原证书/profile完成严格签名Debug、Release构建，iOS17基线和24个DEBUG标记剔除检查通过，并安装到原手机。新的真机回执显示轮次另验收。见 `evidence/ios-widget-receipt-refresh-verification.json`。


## 新版真机闭环通过（17:30–17:32）

原App退后台后新题7ed6548a/native18自动显示，生成至Provider匹配5.726秒，generation5/acked5。用户只点Widget Beta并确认留在桌面；无App激活、深链或RefreshIntent，唯一正式手机response被原session/turn/call采用，输出AGENTINBOX_RECEIVED:Beta。交互触发Provider在17:31:49.868开始、17:31:53.986返回完整adopted列表；距点击开始5.228秒，后续真实主屏幕截图确认“暂无待决问题”，未手动刷新。后续APNs generation7/acked7。该终态成功来自交互触发的Provider与只读收敛，不宣称“终态推送单独唤醒”已验证。

[最新精确证明](../evidence/iphone-widget-receipt-terminal-proof.json)、[原生事件](../evidence/iphone-widget-receipt-original-items.json)、[实际桌面](../evidence/iphone-widget-receipt-terminal-home.png)。前轮后台网络超时仍作为真实失败保留，尚未覆盖断网/锁屏完整矩阵或承诺固定刷新间隔。截图曾出现无关Apple账户验证弹窗的原图未纳入仓库；终态截图不含该弹窗。
