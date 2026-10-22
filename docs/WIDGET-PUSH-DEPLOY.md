# Widget 自动更新：候选升级审查

本轮修复用户现场观察到的定期刷新不及时。`TimelineReloadPolicy.after` 是系统调度请求，不是五分钟定时器；现有普通提醒推送不能唤醒 Widget Provider。新增 iOS26 WidgetKit 专用推送，保留 iOS17 时间线和手动刷新。此文是候选操作范围，尚不表示安装或验收通过。

## 代码与权限范围

- Rust relay 增加独立 Widget token 和合并更新队列；旧回答状态机、原生 callback、普通提醒通道保持独立。新接口只接受已认证的 device 身份，并用独立单调registrationRevision拒绝超时后迟到的旧token注册；GET仅返回版本元数据。重试仅发送无副作用的刷新通知。
- 同一 App/Widget 使用已确认的共享 Keychain 设备身份，不重新配对。Widget token 与 device-key、普通提醒 token 分开。推送只含 `aps.content-changed`，无问题正文或答案。
- Apple Developer 的独立 Widget ID `dev.matianyi.agentinbox.widget`（EXAMPLE_RESOURCE_ID）本轮已按既有独立App/Widget推送授权启用 Push Notifications；旧 Widget profile `example-id-7a556fb25749` 没有 aps entitlement。需要为这个扩展启用 Push，并重新生成其开发 profile，仍选已有开发证书、同一 iPhone 与同一 App Group。主 App ID、旧 App、证书、私钥不更换。
- 复用日本 relay 已有本 App Sandbox APNs key；不读取或转移私钥。现有 topic-specific key 是否覆盖 Widget topic，必须依据 APNs 实际结果核验；如需扩大密钥权限，先报告具体拒绝原因与差异，不自动扩大。

## 安装顺序与恢复

1. 完成 Rust 状态/并发/恢复及 HTTP 认证回归、Swift 注册与回答回归、Mac 与静态 Linux 构建、iOS17基线兼容检查及 Release DEBUG 标记检查。记录最终源码与产物哈希，独立审查后冻结。
2. 手机 App 更新保留现有 Keychain 配对和组件。使用同一既有证书与新 Widget profile 签名，不上传 App Store Connect、不发布。安装后完成一次初始化，再回主屏幕建立验收窗口。
3. 日本 relay 仅部署独立新 release，保留当前 `0.1.0-device-admin` 与 unit 备份；SQLite 在线备份使用700目录/600文件。两个 host 先按升级守卫排空；任一活 hook、请求、submitting、unknown、待回执或启动对账不就绪即延期，不强关 daemon/Herdr。
4. 保持同一配置、APNs私钥、设备/host身份、loopback8787、现有tailnet HTTPS8443和systemd权限，仅切 ExecStart 至新 release。SQLite 增加新表，不删除或改写旧表布局。只重启本项目 relay。
5. 检查服务/二进制SHA、未认证401、两host认证状态、正式设备仍有效、旧普通alert token仍存在且独立。恢复之前由本轮设置的 Mac drain；Ubuntu原有drain保留，不启动下一题。
6. 回滚需再次排空，切旧二进制并使用同一活数据库；不以备份覆盖新状态。旧服务忽略Widget新表。若旧版本执行撤销，新版恢复后仍必须尊重旧撤销标记；测试覆盖该路径。结果未知不重发Agent答案。

## 真机通过条件

App已退后台且不点Widget刷新，不用WidgetKit开发模式绕过预算。只创建已授权的 AGENTINBOX_CHOOSE_ROUTE 隔离模板。证据分别记录：正式Widget token注册（无token值）、队列generation与APNs安全结果、Provider取到新requestId及时间、实际屏幕显示新题；提交后再观察终态自动刷新。HTTP200或Provider执行本身都不等于屏幕已更新。

仍受iOS调度/预算约束，不承诺秒级或固定五分钟。普通APNs提醒与App收件箱继续独立工作。未通过的阶段记录为未通过，不改变既有真机Widget直接回答的单独通过结果。

## 已完成的签名准备（非推送验收）

Portal Widget ID已复核Push Notifications=1，原开发profile经同一证书/原手机选择重建。新Widget UUID `example-id-c9b4c2e89758`，App UUID `example-id-d3d79863a3d0`保持不变。收紧后的只读检查器两角色全部检查通过，新profile仅按UUID安装到Xcode；未生成证书或APNs key，未更新手机App或日本服务。证据：`evidence/ios-widget-push-profile-validation.json`。

## 永久拒绝的受控恢复

APNs明确永久拒绝（topic/key/设备token不适用）会持久阻断该Widget注册；普通请求变化、Provider重复注册及进程重启不会解除，也不影响普通提醒token。先修复已确认的配置原因；如涉及扩大Apple key范围，须先说明并取得对应授权，不能靠重复发送碰运气。随后本机操作员可使用新原生命令 `device-admin DATABASE retry-widget DEVICE_ID` 仅为指定的已配对、未撤销、仍active的Widget重新排队；递增tokenVersion使旧在飞410/ack失效，保留registrationRevision与Agent答案/alert通道。未修复原因时不要反复执行。此命令的存在不代表已经对正式手机执行。

## 已执行限定升级（注册仍待修复）

checkpoint `6080c6f`：Rust默认82通过/0失败/2忽略，两项忽略均另行指定真实旧产物通过；iOS44通过/0跳过，最终Debug/Release unsigned及原证书签名校验通过。Linux静态SHA `2f850cb48f0685993a874d80e744cc2901602d002cf64455f609234bcae8a6c1`。两host fresh prepare-upgrade全零才切同一relay，PID742341→744651，旧release保留；SQLite备份与旧unit在原700目录/600文件，监听、配置、APNs key和host binary未变。首次候选校验发生于scp未结束，被SHA守卫拒绝且零变更；待scp退出0后完整SHA复验才安装。systemd-analyze verify退出0，输出的Xray/cloudmonitor等旧unit警告未修改无关服务。

手机新版App/Widget安装实际成功，原device身份与认证Inbox保持。Widget系统token已产生，但客户端新注册尚未成功持久到relay（安全元数据counter已分配、暂无Widget表行），正在加固定阶段诊断；尚无Widget APNs或无手动刷新显示通过。Ubuntu升级后首次host认证状态不可达，随后私网HTTP401/TLS验证0，下一次prepare-upgrade readytrue；未改网络。Mac当前仍是本轮drain，Ubuntu仍保持原drain。详细检查点见`evidence/widget-push-deploy-checkpoint.json`。


## 重新连接后验证

最终修复候选已在原手机实际安装，正式 Widget 注册和现有 key/topic 均成功。新题在 App 后台、无点击刷新的桌面自动出现，随后 Widget Beta 被原 native17 精确采用；终态自动刷新仍在观察。部署及签名候选中的旧连接阻塞字段已更新，详细证据见 `evidence/iphone-widget-push-automatic-proof.json`。没有重新配对、扩大 APNs key 权限或改动正常 Agent daemon。


后续已安装只读回执收敛修复，新native18真实Widget闭环通过：自动显示新题、原任务采用Beta、交互后Provider读取adopted且桌面清空；无App前台或手动Refresh。详见 `evidence/iphone-widget-receipt-terminal-proof.json`。这不等于终态推送单独唤醒或后台私网故障矩阵通过。
