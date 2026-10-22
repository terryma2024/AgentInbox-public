# 原生二进制回滚隔离演练

## 升级守卫版本的历史演练

实际命令：

```sh
AGENTINBOX_TEST_BINARY="$PWD/dist/macos-arm64/agentinbox" \
AGENTINBOX_PREVIOUS_BINARY=/private/tmp/AgentInboxRollbackBaseline/macos-arm64/agentinbox \
AGENTINBOX_ROLLBACK_EVIDENCE="$PWD/evidence/native-binary-rollback.json" \
cargo test --locked --offline --test binary_rollback -- --ignored --nocapture
```

退出 0，1 项通过。旧版 SHA256 `7314b6e04a7b64b3e8f8b0dcc7a8a18242714ee4a479f62a5ab9e778d9ba7c29`；新版 `553f2131319e84bf85eae34dc2e514aae57c170fcb06e3fc33851f2d2f950a1f`。

真实新旧原生进程只监听隔离 loopback，沿用同一 SQLite。模拟引擎的 adopted 回执在回滚后保持原 responseId；同 ID 同答案幂等，领取为空；新版 host 连接旧 relay 会 fail closed，进程继续存活；重新升级后 prepare-upgrade ready=true。所有测试子进程自行清理。

没有使用真实 Agent/手机，没有修改已安装服务，也没有恢复数据库快照。常规 cargo test 中这一项标记 ignored，必须指定旧二进制另跑，不能把 ignored 当通过。完整证据：../evidence/native-binary-rollback.txt 和 ../evidence/native-binary-rollback.json。


## 当前设备管理产物复验

保持上述旧基线 `7314b6e04a7b64b3e8f8b0dcc7a8a18242714ee4a479f62a5ab9e778d9ba7c29`，以当前 Mac ARM64 产物 `3175290d95e5af1f3062d156e97d61af540442513db48c7ebf81cb07d53a7dc8` 再执行同一显式测试（输出改存 `evidence/device-admin-binary-rollback.json`），实际退出 0、1 passed。当前源码为 `2d021a5cdce5d4a018845abcf3498a3a1974fca2`。

[本轮结果](../evidence/device-admin-binary-rollback.json) 与 [完整输出](../evidence/device-admin-binary-rollback.txt) 证明原 responseId、同答案幂等与数据库保留，零重新领取；旧 relay 缺 guard 接口时拒绝升级，切回新版本后 ready=true。旧基线特意早于 guard，用于验证接口缺失的拒绝路径，并非当前已安装服务的相邻上一版。

原引擎 adopted 证据仍为明确模拟的 fixture；没有真实 Agent、手机或已安装服务参与，也没有测试撤销身份可以被“回滚恢复”。常规套件 ignored 的同一个方法另跑一次，不重复计数。
