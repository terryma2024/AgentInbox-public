# 私网部署准备（尚未执行）

relay在127.0.0.1运行，手机无法直接访问Mac的loopback。建议在日本服务器沿用已经安装的Tailscale，按用户批准配置仅tailnet可达的HTTPS反向代理，转发到本机relay8787；既有Tailscale的serve能力可作为候选，无需新增Node/Python服务。必须先核对实际Tailscale版本、MagicDNS/HTTPS启用状态、tailnet ACL和DNS名称，不能假设开通或代为生成证书。

部署前确定：服务器Tailscale地址/域名、Linux架构、服务用户、独立目录、SSH访问方式；App BundleID/APNs topic/设备iOS版本。用户在各机器本地受限文件配置凭据，不把私钥或token发到聊天。

具体审批应覆盖：安装本项目relay/host的服务定义、仅私网HTTPS的反向代理/监听、tailnet ACL（若需要）、设备配对和APNs文件配置。收到服务器信息后先展示实际文件和命令，再执行。不能把本说明当网络或部署授权。禁止使用Funnel、公网0.0.0.0监听或默认放开SSH。

配置上线后分别实测：iPhone访问认证API、未配对与撤销访问401、APNs真实送达、Widget直接选择→原任务精确采用、中文文字→原请求、两机器并发原生绑定。模拟器通知注入不计APNs验收。
