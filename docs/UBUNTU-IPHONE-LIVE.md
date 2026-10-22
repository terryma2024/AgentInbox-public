# Ubuntu 经日本 relay 的真实 iPhone Widget 采用（2026-10-15）

已通过 Ubuntu 标准 Codex CLI → 已安装 host-a host → 正式日本 relay → 原已配对 iPhone Widget → Ubuntu 原请求采用。复用 Mac 测试的同一正式设备身份和 APNs 配置，没有临时测试 relay、预填 thread、另起引擎、launcher、wrapper 或 --no-daemon。

开始前原 daemon1805212 loaded=[]、已批准scope `/home/developer/Projects/agent` 无Codex/Claude进程，用户host1781909处于drain且计数0。仅移除本项目此前的drain标记，配置仍captureLoadedNative=true、threadIds=[]，其余scope/身份未改。在独立tmux `agentinbox-iphone-host-a-20261015` 正常零参数启动Codex0.162.1，CLI1983895；仅本会话 `/plan` 用于原生问答。

原任务只允许一次AGENTINBOX_CHOOSE_ROUTE原生问答，禁止文件/命令/设置操作。自动捕获产品request `example-id-c5af44711900`，原session `example-id-d2102726dc59`、turn `example-id-2a62ff1074a4`、native2、call `example-id-c31f82d695f5`。

Widget Provider在App后台、无手动刷新时约16秒取得准确题目；其后该请求的Widget answer begin/end各一次，正式设备唯一response `example-id-4c687e96bcd7` 选q0-o1/Beta。原call仅一次结构化function_call_output，answers.route.answers严格为[Beta]，原turn完成且输出AGENTINBOX_RECEIVED:Beta；服务器adopted。App事件未激活/深链，无终端代答。新题Widget推送generation8/acked8，回答后generation10/acked10；APNs接受不单独当作界面更新证据。

初次回答后缓存仍为submitting，随后手机在用户自己的Apple账户认证页；未操作或记录密码/验证码，也未把该页截图入库。用户确认回到桌面后独立复核：真实主屏幕显示“暂无待决问题”，同一Ubuntu请求缓存为adopted且无错误。Provider在17:40:41.363读到终态，距Widget点击开始84.928秒；整个记录窗无RefreshIntent或App激活/深链，事件缓冲未满。服务器复核唯一回复、adopted、全部未决0，generation10/acked10。此次Ubuntu免开App/免手动刷新终态显示通过；不承诺固定延迟，也不把Provider触发原因断言为终态推送单独唤醒。此轮也不计普通alert通知送达或两主机并发竞答通过。

测试完成后prepare-upgrade确认全部本地活动/receipt/relayOutstanding为0，恢复原drain状态，只关闭核实PID/cwd的本轮专用tmux。host仍1781909、NRestarts0，正常daemon1805212保留；daemon的idle thread/MCP缓存不盲删。未修改正常Herdr或其他会话。

[完整精确证据](../evidence/ubuntu-iphone-widget-adoption-proof.json)、[原引擎结构化事件](../evidence/ubuntu-iphone-original-items.json)。旧的临时本地relay测试保留在UBUNTU-AUTODISCOVERY.md；本轮首次补足正式日本中转与真实手机Widget路径。
