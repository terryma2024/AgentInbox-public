# 真机自动填写配对表单（历史预填工具）

**后续进展**：本页描述的14:25窗口已过期；当前已用DEBUG一次性私有文件入口自动完成正式配对，Keychain、真实APNs与手机App Beta原任务采用均通过，不需要再填码。新入口、限制与证据见[IOS.md](IOS.md)、[最新真机记录](IPHONE-LIVE-20261015.md)。下文保留早期LLDB仅预填的历史边界。

用户询问能否代为在已确认iPhone输入配对码。本轮已在同一实体iPhone16Pro／iOS26.6.1、既有手动签名Debug App上通过完整公开dummy预检，无新增签名身份、profile或系统权限；没有重建或重装App。它是Mac上Xcode/LLDB的开发联调工具，不是产品host/relay运行依赖，也不充当Agent launcher。

## 实测动作

Xcode正常start-stopped启动此App并附着精确PID后，恢复App并切到设置页。仅在本App进程的主线程，按唯一公开placeholder匹配服务地址／配对码UITextField；重复或缺失匹配均拒绝。真实输入码来自本App私有Documents/agentinbox-phone-prefill.txt，必须regular、0600、至多128字节、trim后32位十六进制；删除临时文件成功后才通过UITextField文本与editingChanged更新正常SwiftUI表单。URL固定为已核验日本tailnet HTTPS8443，不读取Keychain。

公开dummy由32个零组成，不是有效配对码。实际devicectl传入文件33bytes／600，真机表达式验证输入32字符后立即清空，并删除手机文件。helper finally正常detach，App恢复执行。没有网络配对提交，没有新设备身份，没有真实APNs或Widget验收。

[真机预检结果](../evidence/iphone-automatic-prefill-preflight.json)包含确切PID、physical入口及helperSHA；[开发helper](../ios/Tools/agentinbox_phone_prefill.py)不含秘密。该预检是一次独立开发场景，不增加历史iOS唯一测试方法计数。

## 下一次有效窗口

旧码已经过期，不能重复seed；此前用户许可限定于复制既有码，因此已请求单独确认替换新码与自动送入本App，用户已明确批准，后续已原子替换既有受限文件的新码并native seed，真实自动代填成功；下文保留执行规则。新码时效和结果见本轮实际记录。

获准后先确认同一实体设备／当前App PID和设置页仍就绪，fresh检查两host完整排空、relay未决及回执为空。新码只在既有日本受限文件生成，按原批准路径Mac700目录／600文件传递；不进入argv、聊天、日志、截图或仓库。直接copy到本App的上述私有路径，再使用已验证helper（preflight=False），仅输出成功布尔及元数据。手机临时文件由helper读取后删除，Mac副本在正式配对后删除。

正常配对仍由设置页发起，设备密钥由App原逻辑进入Keychain。当前没有验证自动激活SwiftUI配对按钮；填好后可能仍需用户点一次“配对此iPhone”。系统通知授权需在手机正常确认，不能据自动填入就声称真实配对、APNs或原引擎采用通过。

## 开发执行要点

LLDB的device select使用当前CoreDevice UUID，PID必须由本轮devicectl launch取得，不照抄过期PID。remote attach异步，helper等待stopped并核对主UI线程后才执行；执行后无论成功或失败都detach。命令批处理的退出0不代表Python脚本成功，必须存在本轮proof、核对其内容／helperSHA以及手机文件清理，不能只读进程exit code。

原型曾遇到异步附着生命周期、Objective-C类型信息及无返回值import状态判定问题，均先诊断再修正；此前失败未填真实码或提交请求。源码／Rust服务与已安装App未改动。

实现参考：[Apple UIControl动作派发](https://developer.apple.com/documentation/uikit/uicontrol/sendaction%28_%3A%29)；实际能力与限制以本轮真机proof为准，不以文档代替现场结果。

## 正式码实际代填结果

用户批准“允许生成新码并自动填入”后，先fresh验证同一实体手机、现有App PID5871、解锁状态和两host完整排空。日本受限文件原子替换为唯一新随机码，旧过期DB行保留；仅重启本项目relay一次导入，轮询确认SQLite新行及API401后恢复原unit/Restart策略。新码有效至 **2026-10-15 14:25:41（Asia/Shanghai）**。

按已验证helper SHA，通过Mac700/600私有文件安全copy到本App私有Documents，再以preflight=False实际填写地址与码；手机临时文件已由helper删除，debugger正常detach。没有手动输入、截图或日志中的码值，没有复制长期key/APNs密钥，没有重签名或重装App。Mac临时副本仍600/Git忽略，正式pair成功后清理。

代填完成时未提交pair，不能计为正式配对；需要手机点一次“配对此iPhone”，再点“启用推送通知”并确认系统通知。下一步仍须验证Keychain、APNs及Widget。证据：[新码生成与原生seed](../evidence/iphone-new-code-seed-result.json)、[实际真机代填](../evidence/iphone-automatic-prefill-result.json)。
