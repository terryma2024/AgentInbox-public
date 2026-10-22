# host-a 漏报恢复与全目录捕获 · 2026-10-17

已修复本轮发现的捕获配置问题，并按用户后续要求启用 host-a 当前用户的全目录模式。生效基线为北京时间 **2026-10-17 16:21:17**（UTC 08:21:17.788840）：仅基线之后新建的会话可捕获；447个旧会话标识持久排除，旧会话的新 turn 也不会被接管。Mac／host-b 的目录范围未扩大。

## 原因与恢复

现场原 host active/enabled、心跳正常，但 draining=true；只有 `/home/developer/Projects/agent` 被批准并配置为精确 scope。此前联调后保留的 drain 阻止新请求捕获，最近的新 Codex 会话则在 `/srv/example-project/.worktrees/example-worktree`，也不匹配原范围。因此这些请求没有进入 relay，尚未进入 APNs 发送环节；不能据此把每次漏报都归为 Apple 送达故障。

先在本地活动、回执 outbox 和 relay pending/submitting/unknown 全0后，仅移除原自有 drain 标记，不改 scope、不重启服务。原测试目录的新 Codex0.163.0 隔离题 `example-id-76fb24eb12eb` 随即被捕获，APNs首次发送 sent、attempts1、无错误；本机Alpha被原call唯一采用并完成，relay handledLocally、无设备答案。用户随后报告收到一条提醒，时间与自检相符，但未读取手机requestId，故不将该反馈写为某条通知的精确真机送达证明。

用户先批准新增精确 worktree、仅新会话，随后明确要求取消目录限制。最终部署采用显式 `captureAllDirectories:true`，不是把 `/` 当递归 scope。

## 配置与保护

```json
{
  "captureAllDirectories": true,
  "scopes": [],
  "captureLoadedNative": true,
  "threadIds": []
}
```

这只是目录策略片段；完整实例还保留原 hostId、身份文件、relay、socket、state 和私有 `excludedSessionIds`。后者必须写入本机基线，不能把示例片段替换成完整配置。该开关缺省 false，其他机器旧配置仍精确匹配 canonical cwd；旧二进制不支持这个开关。

全目录模式中，Codex初始 thread/list 和每一页均不带cwd过滤，仍要求原生session已loaded且waiting、UID／daemon代次匹配、绝对cwd能canonicalize为真实目录；排除的session在attach/resume之前拒绝，显式pin不能覆盖。未经attach的callback不能发布。Claude IPC也遵循该目录开关和session排除，但本轮真实新验收只覆盖Codex，不将Ubuntu Claude列为远程回复通过。

ID基线来源为只读state DB、既有rollout文件名UUID、原daemon loaded/list，以及Claude main-session文件名：Codex443、Claude3、loaded2，去重后447。只收集标识，不读旧会话正文或登录凭据。基线与配置保存在目标机0700项目目录／0600文件，未上传Git。启用后自有host日志与排除集合交叉检查：被排除session attach数0。

## 排空与安装

独立release为 `~/.local/share/agentinbox/releases/0.1.0-all-directories/agentinbox`，Linux x86_64静态ELF，SHA256 `4853cb712fb10e4078e3c8a89d7d54e50fc500dddf5b5177c7939719303d8a61`，无INTERP/NEEDED。目标机器没有安装开发语言运行时。

仅在host prepare-upgrade完整ready、draining=true、本地三项／回执／relay未决全0时切换本项目用户服务。配置／unit先0600备份，核对原字节不变，再原子替换；原身份、token、持久状态、Claude settings与hooks保持原样。一轮第二次就绪检查曾未放行，脚本恢复旧捕获状态，未停止服务或换配置；首次退让的具体blocker未被保留，不能猜测原因。之后只读检查确认各计数0、relay认证读取约0.35秒，单次守卫重试通过，未放宽检查。

原host2367211切为3355156；新服务active/enabled、NRestarts0、startupReconciled=true、draining=false。原Codex daemon2367003及其代次不变，没有重启正常Codex、Herdr或日本relay。旧release与配置备份保留，回滚也须排空，不能用不认识全目录／exclusion字段的旧版直接恢复活动捕获。

## 启用后真实自检

新普通零参数Codex0.163.0从用户正常交互zsh环境启动，cwd为 `/home/developer`，明确在所有旧scope之外；没有launcher、wrapper或--no-daemon。仅本测试会话使用原生/plan，隔离prompt禁止文件、命令、设置及其他工具，只问AGENTINBOX_CHOOSE_ROUTE。

| 绑定／结果 | 本轮实际值 |
| --- | --- |
| 产品request | `example-id-796b93484bf4` |
| 原session | `example-id-483de580c14b`，不在447个排除ID中 |
| 原turn | `example-id-176fb7e84802` |
| 原item/call | `example-id-76386000e27a` |
| 发现／发送 | 已安装全目录host自动捕获，projectPath=/home/developer；APNs outbox sent、attempts1、无错误 |
| 原生采用 | 逐PID/start/cwd/pane及pending绑定核对后，仅在自有测试终端一次Enter选Alpha；原call唯一结构化 `{"answers":{"route":{"answers":["Alpha"]}}}`，原turn完成并输出AGENTINBOX_RECEIVED:Alpha |
| relay终态 | handledLocally，responseId=null；没有设备回复 |
| 清理 | 只关闭专用tmux／CLI3355877；捕获保持开启，原daemon peer仍2367003，host三项0 |

APNs接受发送不是新版本真机送达或Widget回传证明；这轮没有要求手机回答，也未替用户处理实际项目问题。旧0.162.1的真实iPhone／Widget记录继续保留，不能直接等同于本次0.163.0全部路径验收。

## 回归与日常检查

完整 `cargo test --locked`：**100 passed、0 failed、3 ignored**。其中2项需要指定旧二进制，另1项是只由fixture启动的mock daemon子进程入口；该子进程已在实际进程测试中执行。iOS未改、未重跑。新增目录／IPC与原生WS分页测试先真实RED后GREEN，含默认关闭、任意目录、空scope显式开启、旧session/pin优先级、unsolicited callback、loaded/waiting条件和每页cwd策略。原生mock曾因macOS accepted socket继承nonblocking标志而握手中断；仅测试端显式恢复blocking后保留原握手超时，完整回归通过，生产PID／UID校验未弱化。

```sh
~/.local/share/agentinbox/releases/0.1.0-all-directories/agentinbox hostctl ~/.local/share/agentinbox/state/ipc/hook.sock status
systemctl --user status agentinbox-host
```

日常正常捕获应为draining=false；机器在线仅表示心跳，不能单独证明未暂停、范围覆盖或原callback仍有效。维护／联调后须恢复用户期望的捕获状态，不能把此前无手机时遗留的drain继续当日常默认。不要通过重启Codex、自动批准、盲目PTY输入或重放旧答案做健康检查。

正常使用仍直接运行原来的 `codex`。本次仅新会话生效，恢复／继续旧会话不会发送新问题。原始证据与备份只在host-a私有 `staging/missing-push-20261017/` 与Mac本地测试日志中，不进入Git。
