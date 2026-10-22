# 协议参考

2026-10-14读取当前官方说明；实现仍以版本锁定、现场原引擎证据和测试为准。

- Claude hooks：https://code.claude.com/docs/en/hooks
- Herdr socket API：https://herdr.dev/docs/socket-api/ （当前方法说明成功仅确认入队，不能证明执行；会话snapshot需要重新对账，不能以焦点授权）
- Apple Widget interactivity：https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- Apple APNs token：https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns

没有复制HAPI源码或引入其运行时。已有P0是用户资产，仅有限协议经验复用；P0常量与文件槽不可直接推广。

APNs topic专用密钥及环境配置、一次性下载依据：https://developer.apple.com/help/account/keys/create-a-private-key/ 。实际登记为本App唯一topic＋Sandbox，不把此key称为Production适用。
