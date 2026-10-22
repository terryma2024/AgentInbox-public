# 已配对设备的本机管理

此功能使用 relay 数据库所属账户的既有 OS 权限；没有网络管理 API、额外管理密钥或新监听端口。源码为 `2d021a5cdce5d4a018845abcf3498a3a1974fca2`，Linux 静态产物 SHA256 为 `790a3c490663a180cd636d45a95ac23198999331b14a80aed41b30e8ac737429`。日本限定上线已完成，见 [DEVICE-ADMIN-DEPLOY-RESULT.md](DEVICE-ADMIN-DEPLOY-RESULT.md)；Mac／Ubuntu host 保持守卫版本，详见 [STATUS.md](STATUS.md)。

## 列表与撤销

在日本服务器 `ssh relay-host` 后，以数据库 owner 运行，避免 root 创建不同归属的 WAL／SHM：

```sh
runuser -u agentinbox -- /opt/agentinbox/releases/0.1.0-device-admin/agentinbox \
  device-admin /var/lib/agentinbox/inbox.sqlite list
```

列表只返回 deviceId、name、revoked、pushActive，不输出 API key、密钥摘要、APNs token 或问题正文。当前实体 iPhone 未配对，不能从空列表推断已经撤销了真实设备。

设备丢失时，从列表核对准确 deviceId，再将下列 `DEVICE_ID` 替换成它；实际撤销应由有权限的操作者明确指定目标：

```sh
runuser -u agentinbox -- /opt/agentinbox/releases/0.1.0-device-admin/agentinbox \
  device-admin /var/lib/agentinbox/inbox.sqlite revoke DEVICE_ID
```

未知／无效 ID 拒绝，已撤销的同一 ID 再撤销保持成功与原状态。命令不需要丢失手机的 token，也不重启 relay。手机上的自撤销 API 与此命令使用同一事务逻辑；仅删除本机 Keychain 不会撤销服务器身份。

## 生效范围

一个 IMMEDIATE 事务同时写入持久撤销标记、设备凭据撤销、推送设备停用、该设备 pending outbox 取消；任一步失败全部回滚。事务提交后后续设备 API 请求认证拒绝，不影响其他设备／host，也不改写原 requests、responses、claimed 或 callback 状态。撤销不会把结果未知的答案变成可重发。

推送 worker 在构建请求后、发送前重查当前设备、撤销、队列与原问题期限；晚到的发送结果不能把 cancelled 队列恢复为 pending／sent／failed。授权检查到网络发送之间仍有在途窗口，已授权或已提交 Apple 的推送无法撤回，手机已展示的通知也无法据此收回。

列表以 READONLY、撤销以现有数据库 READWRITE 打开；不会 CREATE、迁移 schema 或执行 relay 启动 recovery。数据库需为安全属主的 0600 常规文件，直属父目录不能被其他用户写入；symlink、不安全路径、缺失数据库或错误 schema 均拒绝。

## 已验证与限制

[五个 RED／GREEN 原生测试](DEVICE-ADMIN-CANDIDATE.md) 覆盖真实临时 relay 上的即时 401／其他身份仍有效、四步事务故障回滚、路径保护、晚到 worker 结果，以及 worker 在 JWT 阶段暂停后撤销并确认不发网络。测试只使用临时身份；假代理不向 Apple 转发。

真实服务器只验证只读列表与服务持续运行，未执行真实设备撤销。列表安装证明不能替代 iPhone 配对、APNs 送达或丢失手机现场撤销验收。
