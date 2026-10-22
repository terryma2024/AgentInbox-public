# 身份与安全边界

设备与host采用各自独立角色密钥；Tailscale只限制传输入口，不授予API角色。host密钥只能操作绑定hostId，device不允许读取native参数、领取回调、上传原请求或确认adopted。推送仅通用中文提示+opaque requestId，正文经鉴权API获取。不上传完整对话和Agent登录凭据，不记录Authorization/APNs token/私钥。

生产配对流程：relay本机管理员通过短时一次性配对码授权设备；relay原子消费配对码、返回一次新设备密钥，手机存Keychain，relay只存密钥摘要和deviceId/撤销时间。配对码一次消费、10分钟失效、速率限制，不放推送或URL日志。真实配对秘密及持久配置仅在用户明确授权后于本机/受限服务器完成；开发固定fixture token仅loopback+独立开发数据库。当前实现范围以测试与STATUS为准，设计不等于实现。

撤销：设备密钥撤销后所有读取/提交/推送token注册拒绝。host撤销后不允许新请求和回执。已submitting请求必须人工对账或原引擎证明，不能因为撤销或网络恢复自动重派。

重放保护：产品requestId/revision/期限、全局responseId+内容一致性、SQLite事务唯一获胜、host领取记录与原生request/item/session/turn/runtime完整复核。相同ID同内容只返回已有状态；不同内容拒绝。pending不能直接标adopted。回调失去活体、主机重启、派发结果不确定→unknown/invalidated，禁止盲重发。

Unix IPC只放0700目录、socket0600；helper不能跨用户、跨host或跨旧runtime。hook stdout只有协议结果；未回复/失败/超时绝不默认批准。Claude自身超时可能退回本地提示，应明确显示并以实际引擎行为为准。

网络：开发loopback HTTP。真实Tailscale私网监听仍需用户授权，生产TLS终止或HTTPS不因私网而省略；未批准公网绑定不可开启。APNs p8仅relay受限文件，ES256 token在内存生成，苹果私钥不发到聊天、不进Git。
