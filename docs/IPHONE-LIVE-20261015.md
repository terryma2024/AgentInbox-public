# 实体 iPhone 联调 · 2026-10-15

## 最新结果：自动正式配对与真实 APNs 已通过

2026-10-15 14:40后，用户明确授权生成替代码并全程操作同一 iPhone。先使用现有 App／Widget 专用 profile 及现有 wildcard 测试 profile 签名构建并安装；未创建新证书或 Apple 对象。两host与relay五项全空、正式身份0后，仅重启relay一次导入唯一新码。新PID742341，原unit、Restart=on-failure恢复，runtime override删除；保留所有旧到期码行。

XCTest首次真机运行在启用UI automation阶段60秒超时，0测试体执行；没有对该失败盲重跑。改用已安装正式Debug App的单次私有JSON入口，调用与设置页相同的PairingService/API/Keychain流程；手机已有正常通知授权。**配对成功**，正式deviceId为 `device-example-id-3e053159c47f`，KeychainPresent=true、authenticatedInbox=true、notificationAuthorizationStatus=2；服务器同ID登记sandbox APNs，旧绑定未消费。手机Documents实际只余诊断与结果JSON，短期输入文件已删除；Mac600副本也已删除。问题正文与长期token/码没有进入证据。

配对后仅恢复Mac host限定测试scope，不重启host；原先准备的标准CLI、原daemon91603和原thread继续使用。隔离模板禁止文件／命令／设置操作，只有route问题。产品request `example-id-736f8c1cae05`、原session `example-id-dfe6b7e7212f`、原turn `example-id-0deaf9d88ff3`、callback14、item `example-id-490793056dd0`。

**真实APNs送达通过**：服务器outbox1首次sent，手机系统`deliveredNotifications`含`UNPushNotificationTrigger`且不透明requestId等于该产品request。不是模拟器注入，不仅是APNs token注册或HTTP200。原生手机截屏也显示该唯一待决题。用户于14:55:42在正式App点Beta／提交；服务器唯一回复responseId example-id-a83d62e98908，device与已配对手机一致。原同call恰好一次function_call_output解析为 {"answers":{"route":{"answers":["Beta"]}}}；同turn在14:55:44完成且输出AGENTINBOX_RECEIVED:Beta。relay终态adopted，三个原生证据true，非marker判定。真实手机App闭环已通过，当时不由App回复推定真机Widget。后续第三道新题已单独以Widget扩展事件、无App激活和原生采用三方证据通过，见[真机Widget结果](WIDGET-PHYSICAL-DEBUG.md)。

DDI只读检查compatible/usable，设备developerMode enabled、paired、解锁；用户确认无UI自动化弹窗，用户确认独立Enable UI Automation原本已打开。Xcode Device Hub随后明确提示当前手机需iOS27+才能屏幕共享；当前26.6.1不满足，没有升级手机。XCTest初始化超时原因未定，不把该版本限制作为XCTest已确诊根因。未修改安全设置、密码、TCC或其他App，未重新生成配对码。严格Beta-only真机UI测试已签名编译，目前未重跑相同失败；本轮11项模拟器回归通过、Release无签名构建通过且5个DEBUG入口标记不在Release二进制。

证据：[自动配对](../evidence/iphone-automatic-pairing-proof.json)、[真实APNs送达](../evidence/iphone-real-apns-delivery-proof.json)、[精确原生绑定](../evidence/iphone-real-beta-native-binding.json)、[11项与Release验证](../evidence/ios-auto-pairing-regression-verification.json)、[签名元数据](../evidence/ios-physical-auto-pair-signature.json)。[真实手机原任务采用证明](../evidence/iphone-beta-original-adoption-proof.json)。

用户已添加中号Agent待决Widget，其Provider在App非前台时独立取题认证成功，共享Keychain/Group真实链路可用。新Widget隔离题request为example-id-e61d672117c9，原turnexample-id-8c7435b7f2d5，callback15，与第一题不同。该轮后来自动开App，用户在App回答，只计App采用；第三道新题 e7c15bb5/callback16 才单独通过真机Widget免开App直答，详见最新结果。以下各节是此前过期窗口历史，不代表当前仍需配对。


本轮由用户重新连接同一 Example iPhone 16 Pro／iOS26.6.1 并明确要求继续。硬件 UDID 与既有确认记录一致；CoreDevice 初始显示 unpaired，正常 manage pair 后恢复 paired。已安装 dev.matianyi.agentinbox 的版本1.0／build1，实际 launch 成功，无重新签名、安装或修改其他 App。

用户已确认 App 设置配对页及 Tailscale 就绪。按已明确批准的限定流程，既有日本配对码安全复制至 Mac `evidence/local-dev/iphone-pairing-code.txt`；目标目录原权限755的首道检查在传递前拒绝，随后按批准范围收紧700，文件以 O_EXCL／NOFOLLOW 创建为600，Git忽略。内容仅本机 TextEdit 显示，不进入聊天、日志、截图或仓库；没有复制长期身份或 APNs 私钥。成功配对后删除本机临时副本。

已先 fresh 核对两 host 的 drain／startup／ready 和五项计数全零。日本维持 device-admin release；runtime dropin 暂设 Restart=no，仅重启 relay 一次导入现有码，随后移除 override 并恢复原 unit／Restart=on-failure，不再次 restart。初始维护命令整体返回1，未保留具体异常；没有盲重试。后续独立只读确认新 PID740157 active、API401、pair_codes唯一一行未消费、有效至 **12:50:17（Asia/Shanghai）**，runtime override已删除、原有效ExecStart无seed参数。不能把首次命令整体称为通过，也不能把seed称为设备配对。

目前正式 iPhone pair、Keychain存储、APNs token注册与实际送达、真机Widget和原引擎采用仍待验证；没有用测试客户端消费正式配对码。原来两host保持drain，正常daemon/Herdr不停止。

证据：[限定传递](../evidence/iphone-pair-code-transfer-result.json)、[seed后的独立核验](../evidence/iphone-pair-code-seed-result.json)。

## 首次配对窗口结果

12:51:25独立核验：该码已在12:50:17过期、used=0，pair_rate无请求记录，正式设备／active push设备均0。不能确定是尚未点击还是手机网络路径没有到达relay，需手机页面提示区分。没有生成替代码或再次seed，也未消费码作为测试。已删除本机600临时副本；TextEdit如仍显示旧内容，该码已失效，应关闭旧窗口。

本轮专用零参数Codex CLI只准备原生Plan模式、未发题未答；按精确PID／启动时间／唯一tmux socket核对后关闭该空闲session。正常daemon/Herdr与relay不因此重启，两host继续drain。没有产生可用于宣称APNs或原任务采用的真实请求。

[首次窗口与清理证据](../evidence/iphone-first-pair-window-result.json)。下一步先收集手机点击配对后的实际提示或确认尚未输入，再准备下一次有效窗口；原码不能重复seed。


## 自动代填预检

用户随后确认尚未输入，并询问能否代为输入。已在同一真机完成公开dummy的私有容器传入、UITextField正常editingChanged填写、立即清空、手机文件删除与debugger detach；没有新的有效码或设备身份。流程与待批替代码边界见 [IPHONE-AUTOMATIC-PREFILL.md](IPHONE-AUTOMATIC-PREFILL.md)。


## 新码已自动填入

后续用户已明确批准新码及自动代填。2026-10-15 14:16:21实际完成同一真机App的正常UITextField代填，手机文件已删除，调试器已detach；新码有效至14:25:41。两host保持drain，新relay PID741746正常运行、原unit与自动重启策略恢复，无正常Agent/Herdr重启。原到期码行保留，没有重新激活原码。

正式pair须手机点一次按钮，通知权限须正常确认；代填结果不代表这些步骤已完成。当前为下一步准备了独立tmux的标准Codex CLI（本轮R2记录），没有发隔离题或答案。详情见[自动代填实测](IPHONE-AUTOMATIC-PREFILL.md)。
