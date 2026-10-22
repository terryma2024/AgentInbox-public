# Widget 自动更新实施计划

用户现场已确认时间线请求after300秒后长期停旧；普通alert APNs已真实送达，但当前没有Widget专用推送。真机iOS26.6.1支持WidgetPushHandler；iOS17基线保留时间线与手动刷新。两者都受系统调度，不能宣称秒级保证。

## 协议与归属

- 新认证POST /v1/devices/widget-token，仅device角色，绑定认证身份而非body.deviceId。
- body：token（32–256 hex）、environment（sandbox/production）、active（bool，默认true）、registrationRevision（正int64，必需）；响应registered:true。与普通alert token分开保存；相同内容注册幂等，不因Provider取题产生推送反馈循环。
- 同一认证device持久化最高registrationRevision；旧revision409且零写入，同revision同normalized内容幂等成功，同revision异内容409，更高revision且同内容不制造推送。GET同路径仅device返回registrationRevision（未注册0），不返回token。客户端AppGroup锁内持久counter，按max(local,server)+1分配，网络未知保留同revision/body幂等重试；OS状态变化使用更高revision。不能以wallclock或outbox generation冒充注册顺序。flock本身不足以防HTTP超时后迟到旧包。
- iOS26 WidgetPushHandler上传token及是否仍有配置；App/Provider可用WidgetCenter.currentPushInfo补偿注册。需要Widget扩展aps-environment及有效profile。长期设备密钥不变，不再配对。
- Widget推送payload只有aps.content-changed=true；apns-push-type=widgets；topic默认配置App bundle ID＋.push-type.widgets。APNs密钥仍只留日本relay；不把正文/答案/原生callback/token写日志。真实topic与凭据范围以Apple接受结果验证，不猜测为成功。

## 原生relay

只增加Widget token/合并更新队列表，不更改既有responses/native-binding状态机和alert表结构。每设备单个递增generation，worker取snapshot并只确认已发送的generation；并发新变化不能被旧ack清除。注册/轮换、request创建、submitting及终态/过期/重启unknown变化触发队列；同内容幂等注册和同状态回执不制造更新。

push worker有界重试、合并/限流；网络未知只重试无副作用的Widget刷新通知，不重派Agent答案。发送前检查撤销和当前token；旧410/失败不能失效轮换后的token或复活撤销；失败只记录安全状态码/已知原因枚举。撤销与现有事务保持一致；旧二进制回滚不删除新增表，新worker仍检查旧撤销标记。

## 并行分工与验收

原生负责store/relay/apns及测试；iOS负责Widget/Shared API/注册及profile源配置与测试；负责人负责Apple能力/profile核查、部署审查、真机验证与支持矩阵。源文件不交叉修改。

先RED/GREEN验证幂等注册、角色/设备隔离、generation竞争、token轮换、撤销、重启/旧DB兼容及payload无正文；Swift验证JSON/认证/失败不覆盖原设备密钥，保持17可构建。再构建Mac/Linux原生产物与iOS签名候选，审查后排空，仅升级relay/本App，旧服务可回滚，正常daemon/Herdr不停止。不创建新APNs私钥。

真机核心：App在后台，不点刷新；创建获准隔离题，关联服务器Widget推送结果与Provider新requestId/刷新时间及屏幕。提交后观察终态自动更新；HTTP200不算Widget已刷新。失败则记录真实送达/Provider/显示各阶段，保留普通通知和手动刷新。Ubuntu下一轮暂不启动。
