# 本机与手机异值竞争 · 2026-10-15

范围：原Mac标准Codex CLI 0.162.0／既有daemon 0.162.1、原正式iPhone Widget与日本relay。仅已批准测试目录与单次request_user_input的Alpha/Beta隔离题；无真实工具审批。受控tmux输入只用于测试，产品回传仍使用原daemon请求响应接口。本机输入不等于物理键盘证据。

## 本机先答：原生采用与手机终态通过

产品请求example-id-d7079cfbfd48，原turnexample-id-a16dd0cda5d1，原example-id-97d8d1933b8d。绑定记录包含原daemon运行代次；核对PID36153、原cwd、原session/turn/call尚未有输出、TUI只有一道问题且默认选中Alpha后，仅发一次空Enter。没有文字、方向键或重复输入；发送失败也不盲重试。

原call唯一结构化Alpha、原turn完成并回显AGENTINBOX_RECEIVED:Alpha。relay为handledLocally，responseCount0；主动在手机打开这一精确请求页，实际截图显示“已在本机处理”，选项与提交按钮隐藏，缓存同为handledLocally。该检查是有意打开App的终态验证，不是Widget免开App直答，也没有手机迟到Beta实际提交。

## 首次竞争预备：过期取消，未计通过

example-id-7939f64aa5fa，原turnexample-id-b1ca7d639a78，原example-id-c3205b0e74d9。准备耗时过长、初始180秒观察窗口早于手机动作结束；续窗口按原有效期截止，也没有观察到手机AnswerBegin。两个控制器都0次Enter。22:28:16请求expired，relay手机response0。仅对精确PID/cwd且仍在此题等待的自有CLI按一次Escape清理；原rollout记aborted by user与turn_aborted interrupted，没有Alpha/Beta采用。不把取消输出当实际答案，不把未发生的竞争计成功。

随后先运行监测再生成新题，并改用原请求实际有效期。活动列表按设计不含native字段，控制器首次因KeyError在任何输入前退出；已改为只读认证GET该请求详情补齐完整绑定，再运行同一道题，未重复创建请求、未领取响应或重发答案。

## 手机先答：唯一Beta与本机取消通过

example-id-9ff8ae79bb6e，原turnexample-id-fd477e183632，原example-id-954c65c5b044。正式手机唯一Beta被原call采用，原turn完成并回显AGENTINBOX_RECEIVED:Beta，relay adopted。用户确认点击一直留在桌面。

手机AnswerBegin1792075931.485598，控制器读取到它1792075942.270670，约10.785秒后，IntentEnd此时已存在；原工具结果已经写入。控制器取消本机输入，Enter次数0，没有对已完成请求补发Alpha。因观察延迟未形成实际本机竞争，只计手机先答与本机及时放弃，不算同时竞答。

## 最后一轮服务器受理触发

使用先启动的只读SQLite观察器，限定本机host/session、题名、创建时间和唯一请求；观察正式手机response记录落库，不调用host响应领取API、不更改relay或凭据。原CLI仍等待时才允许一次空Enter；请求已解决、临近过期、进程/代次/绑定不符即取消。输入意图先落盘，输入后任何结果未知都不重试。

本轮实际发生竞争并通过，胜者为受控本机Alpha。

| 字段 | 精确绑定 |
|---|---|
| 产品request | example-id-1a4a206075a4，revision1 |
| 原runtime | 91603:Sat Oct 10 04:35:26 2026 |
| 原session | example-id-dfe6b7e7212f |
| 原turn | example-id-804de7312db6 |
| 原native request / call | 25 / example-id-a3f9b24a6a8d |
| 正式手机response | example-id-6a490a3fbc37，Beta=q0-o1 |

正式设备device-example-id-3e053159c47f的Beta已被relay事务接收；只读观察时claimed0。控制器收到此事件后，重新核对原call没有输出、原turn未完成、PID/cwd/daemon代次仍匹配且TUI在Alpha选项等待，才只发一次空Enter。原call在23:13:47.304写出唯一结构化Alpha，23:13:52.588原turn完成并回显AGENTINBOX_RECEIVED:Alpha。

relay最终handledLocally，手机Beta记录保留但claimed仍0，主机不存在此request的dispatch标记；Beta未派发到原引擎，也没有下一题或重复工具结果。手机缓存同为handledLocally且error=null，Widget在23:13:48.275的Provider结束时已无当前题，实际桌面截图确认自动清空。本轮窗口没有刷新Intent、App激活或深链；之后才主动打开精确请求页做终态检查，真实截图显示“已在本机处理”、无选项与提交按钮；此检查不混入Widget直接操作窗口。

控制器从本机观察到候选到开始Enter约38毫秒，Enter命令返回约46毫秒；这些差值只使用同一Mac时钟。服务器事件时间反而晚于本机读取时间约205毫秒，说明跨机器时钟不可直接相减；不据此推算网络延迟或宣称物理同时。事件发送后才被读取的因果顺序、当时仍等待的原call与唯一Alpha输出共同证明这轮“手机候选已排队、本机在host领取前抢先”的实际竞争。

此结果不覆盖手机候选已被host领取或已派发之后的争用。只读代码审查预测，若host已经持有Beta而原call却采用另一答案，当前逻辑可能等待45秒后标unknown；这不是本轮实测路径，不当作已通过或已证实故障。通用产品也不能把任意不匹配/解析失败直接推定为本机采用。

收尾host activeHooks/activeRequests/submitting全0，原专用CLI保留空闲，正常daemon91603与Herdr未重启，临时观察器已正常退出。本轮没有修改、重建或部署产品运行时代码、服务定义或凭据。临时开发测试控制器不作为执行端/服务器常驻产品依赖。

物理键盘与手机同时操作仍待独立验收。日志、绑定、截图与临时控制器保存在本地忽略的evidence；不会提交此目录。
