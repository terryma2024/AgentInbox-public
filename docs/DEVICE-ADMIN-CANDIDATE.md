# 本机原生设备撤销候选

> 本文保留源码候选阶段的验证记录。后续已重建当前产物并完成日本 relay 限定上线，见 [DEVICE-ADMIN-DEPLOY-RESULT.md](DEVICE-ADMIN-DEPLOY-RESULT.md)；当前操作见 [DEVICE-ADMIN.md](DEVICE-ADMIN.md)。

本改动只在新源码与隔离原生测试中实现，尚未部署。当前已安装的0.1.0-upgrade-guard二进制不因此获得新命令；Mac/Linux产物需重建核验，并按既有获批的本项目部署范围与排空清单上线；新增范围须另行确认。没有新增数据库schema、网络管理role、监听地址或管理密钥。

固定CLI语法：

```sh
agentinbox device-admin /absolute/existing/inbox.sqlite list
agentinbox device-admin /absolute/existing/inbox.sqlite revoke device-<opaque-id>
```

操作者在relay所在机器以数据库所属服务用户运行，使用该用户既有OS数据库访问权限，不需要丢失手机的raw API key。root虽可凭既有权限访问，但运维应切换为数据库owner执行，避免新建WAL/SHM文件的所有者变化。例如日本服务器的服务用户为agentinbox时：

```sh
runuser -u agentinbox -- /path/to/candidate/agentinbox device-admin /absolute/existing/inbox.sqlite list
runuser -u agentinbox -- /path/to/candidate/agentinbox device-admin /absolute/existing/inbox.sqlite revoke device-<opaque-id>
```

`list`只列已配对设备deviceId/name/revoked/pushActive，不返回API key摘要、APNs token或问题正文；`revoke`仅接受实际存在于device_credentials的配对设备ID，不把host提升为管理设备。未知ID失败，重复撤销返回成功并保留撤销状态。

数据库必须已经存在，为当前有效用户所有或由root操作者访问的regular file、权限0600；拒绝文件symlink、不安全直属父目录及打开时身份/权限变化。SQLite使用READONLY列表、READWRITE撤销及NOFOLLOW，没有CREATE、schema迁移、recovery、relay排他lease或服务重启。校验仅检查兼容表结构，不读取requests正文。无效路径/缺失DB/错误schema失败且不创建数据库。

自撤销API与本机管理命令共享同一SQL事务helper。BEGIN IMMEDIATE内统一写revoked_credentials、device_credentials.revoked、devices.active和取消该设备pending push outbox；最后一步失败会回滚全部四步。未改变requests/responses、claimed、responseId或原callback状态。运行relay逐请求读取SQLite凭据/撤销表，新事务提交后后续API认证立即拒绝该设备，无须重启。

## 推送撤销边界

worker取批次后，生成JWT/构建HTTP请求之后、真正.send前，再查该job仍pending且到达重试时间、设备active且未撤销、原请求pending且未过期；查询失败也不发送。晚到push_result只可更新仍pending的记录，不能把cancelled恢复为pending/sent/failed或增加重试计数。

授权检查与HTTP开始之间仍有在途窗口，已授权/已提交APNs的请求无法撤回。这不声称完全无竞态的推送撤回，也没有引入sending状态或新schema。

## 验证证据

新增tests/device_admin.rs共5个强语义测试，全部先在旧实现失败（evidence/device-admin-red.txt），再通过（device-admin-green.txt）：

1. 真实native relay持续运行、真实临时fixture配对：list不泄漏hash/key/APNs token；operator撤销后新API401，其他设备/host仍有效、PID不重启，原claimed submitting请求及response原样保留；重复撤销幂等。
2. SQLite trigger在最终cancel步骤抛错，self-revoke和operator两条入口全部回滚，原设备认证仍有效。
3. 缺失DB不创建、错误schema不改、未知/无效ID拒绝、symlink/非0600拒绝、有效private DB可读。
4. 已取批次后撤销，dispatch predicate为false；晚到成功、临时失败、永久失败均不能复活cancelled或更改重试元数据；过期原题也不授权。
5. 真实worker在JWT FIFO上确定性暂停，撤销后释放公开fixture key，发送前必须重查并跳过网络。测试强制localhost假代理，永不转发到Apple；RED明确捕获旧worker会启动网络，GREEN不再启动。

全套cargo test当前61 passed / 1 ignored（原56项passed+新增5项passed；ignored为显式旧二进制case），cargo fmt --check通过；evidence/device-admin-all-tests.txt保存完整结果。tiny_http既有两条unused/dead_code警告未在本改动处理。动态配对只生成临时测试身份，0700测试目录/0600临时DB用毕删除；没有读真实数据库/凭据、调用日本配对或真实APNs、操作Agent任务、修改线上服务或提交Git。
