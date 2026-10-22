# 真机 Widget 点击排查 · 2026-10-15

实体 iPhone16Pro/iOS26.6.1；正式配对、同一 Keychain身份和App Group、前台及后台真实APNs送达、手机App回复被原Codex采用均已单独通过。**第三道新题已通过真实中号Widget免开App直接回答。** 以下保留之前边界，未把第二轮App回复改写为Widget通过。

## 已观察到的边界

用户添加中号组件后，Provider独立认证成功；14:57时间线仍为空，新题14:58产生。请求after300秒不保证系统按时调度，本轮到15:03仍为旧缓存。增加组件内只读RefreshInboxIntent，与Provider复用认证读取/缓存逻辑，openAppWhenRun=false。签名构建并更新App/Widget后由App正常启动做版本初始化；不把这一步计为Widget自主及时刷新。

第二道隔离题example-id-e61d672117c9，callback15，原turnexample-id-8c7435b7f2d5；实际唯一Beta结果与原turn完成均严格通过，但用户确认先自动打开App、随后在App中选择Beta。因此只计第二次App回复通过，不计Widget直答。两道题各有不同产品request、原turn/callback，未复用旧答案。

iOS通知列表中第二题的UNPushNotificationTrigger也已确认，问题产生时App在后台。真机Widget共享Keychain取题成功与Widget按钮行为分别记录，不互相替代。

## 诊断而非猜测修复

源码及签名metadata中的AnswerDecisionIntent/RefreshInboxIntent均openAppWhenRun=false，未使用前台协议或打开App调用；metadata extraction成功。Apple官方示例允许外层widgetURL与Button(intent:)共存，当前没有证据直接删除父URL。

刷新label当前只有caption图片、plain样式，点击范围可能过小；这是待验证假设，尚不能断言用户误点或平台有缺陷。Apple DTS对同类image-only Button建议在label中设置44×44 frame和contentShape。先观察一次无待答题的刷新点击，再决定修复。

DEBUG InteractionDiagnostics：AppGroup共享defaults中按interactionTrace.PID分开记录，每进程NSLock、最多64条，只含固定事件enum、时间、bundle/PID与可选合法UUID/revision；无问题正文、回答、码、token或完整URL。记录Widget refresh/answer开始结束、App前后台与deep-link事件。初始文件记录未通过设备读取接口观察到，已移除；当前defaults版已实际读取到App启动/active基线。Release App/Widget构建通过且15项DEBUG标记均不在产物。

下一步只让用户在桌面点一次刷新，无新题、无回答；若只出现App.openedURL而无widgetRefreshBegin，支持点击落入父链接区域；若Intent记录与App激活并存，继续按时间与bundle排查执行路径。没有完整事件时不作负面推断，不重复提交已采用题。

## 工具边界

XCTest Runner签名编译通过但系统automation初始化60秒超时，0测试体执行；用户确认Enable UI Automation原本打开、无密码确认弹窗。DDI compatible/usable、developer mode启用、paired且解锁。原因未确定，不盲重跑。

Xcode27 Device Hub明确提示屏幕共享需iOS27+；手机26.6.1不能用该入口，未升级手机或关闭安全设置。此版本限制不作为XCTest超时已确诊根因。

证据：[第二题精确采用](../evidence/iphone-widget-attempt-adoption-proof.json)、[后台真实APNs](../evidence/iphone-background-apns-proof.json)、[Release诊断移除](../evidence/ios-widget-release-verification.json)。

参考：[Apple Widget交互](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)、[Apple DTS命中区域](https://developer.apple.com/forums/thread/800099)。

## 第三题最终通过

新产品request example-id-5f0a43cebd88，原sessionexample-id-dfe6b7e7212f、turnexample-id-c670ba1a479f、callback16、item example-id-ed835802f0a2，response example-id-b167ad0524f5。创建后未启动App做前台刷新；用户在桌面Widget刷新取到此UUID后点Beta，并确认留在桌面。

DEBUG记录Widget扩展独立刷新，随后对该request/revision的widgetAnswerBegin/End各恰好1；本测试窗口没有appOpenedURL、appViewStarted或appBecameActive，且App此前明确进入后台。两个进程buffer均未达到64上限，因此未发生因buffer满而丢失后续激活记录的已知边界。

日本relay正式手机身份只有一条回复，选项q0-o1；原同call恰好一次function_call_output解析为Beta，同turn完成并输出AGENTINBOX_RECEIVED:Beta，终态adopted。无终端代答、引擎替换、历史恢复或另起会话。截图仍是桌面Widget，显示提交中；组件最终状态有系统刷新延迟，不以截图替代原引擎采用证据。

[真实Widget精确证明](../evidence/iphone-widget-native-adoption-proof.json)、[原生事件](../evidence/iphone-widget-traced-original-items.json)、[原始桌面截图](../evidence/iphone-widget-native-home.png)、[当前源码26项回归](../evidence/ios-widget-core-regression.json)。

先前刷新观察有10次Intent与1次深链打开，最后一次刷新无后续激活；[完整观察](../evidence/iphone-widget-refresh-observations.json)没有声称整个窗口只点击一次。没有把第一轮开App原因最终归咎于父URL、按钮大小或平台bug；第三轮按精确新请求已证实直接路径可用。系统时间线仍不保证及时，手动刷新是独立只读入口。

下一步：Ubuntu经同一日本relay真实回传、物理键盘同时竞答、过期通知/Widget与故障矩阵、Desktop/Herdr通用身份映射仍需分别验收。
