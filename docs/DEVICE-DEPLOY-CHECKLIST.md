# 当前最短操作清单 · 2026-10-15

用户已确认目标是Mac mini USB上的iPhone16Pro/iOS26.6.1，Trust与开发者模式已完成。独立App与Widget已使用现有Apple Development证书、各自新开发profile手动签名并成功安装；共享Keychain/AppGroup和development推送权限全部核验通过。无新签名私钥、无自动provision、无旧App修改。

日本relay、Tailscale私网HTTPS8443、本AppTopic Specific Sandbox APNs密钥、Mac/host-a用户host与最小Claude hooks均已按既有批准安装。Funnel关闭，ACL/Xray保留，不重复请求这些批准。

本轮用户重新连接手机，CoreDevice恢复正常paired，已装App launch成功，用户已确认设置配对页与Tailscale就绪。已批准的受限码复制与seed已执行，首枚已到期未消费、临时副本已清理；时效与实际记录见[IPHONE-LIVE-20261015.md](IPHONE-LIVE-20261015.md)。已安装后网络配对不要求持续USB。真实APNs/Widget仍未验收。

后续手机操作：

1. 解锁后打开“Agent收件箱”→“设置”，服务地址填 `https://relay.example.ts.net:8443`；手机Tailscale必须连接同一tailnet。远程launch遇到锁屏时正常拒绝，不绕过手机解锁。
2. 首枚码已到期，不再输入或盲重seed；用户已批准新码，现已自动填入真机，截止14:25:41只需点“配对此iPhone”；无需抄码。配对码只通过本机受限文件/本地输入交付，不发聊天、日志或仓库。手机正式pair返回的设备密钥直接存Keychain。
3. 配对成功后在App点“启用推送通知”并完成手机通知授权；收到通用APNs提醒、App独立取题与Widget直接回复分别验收。尚未消费码/注册真实APNs token，不把安装算推送通过。

两执行端host仍drain待命，三项0，不让新hook等候未配对手机。配对及推送注册准备好后，只恢复已批准的测试scope，产生获准Beta隔离题；不代答真实工具审批。

真实APNs送达、主屏幕Widget答案被原任务采用、文字/多选准确页面、同时键盘竞争、故障恢复与双主机完整矩阵仍须分别验证。Production密钥/分发、上传构建、审核和发布未做；不发送私钥或token到聊天。
