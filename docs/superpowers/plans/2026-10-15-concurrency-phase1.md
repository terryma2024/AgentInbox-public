# 第一组并发验收计划 · 2026-10-15

> 执行方式：用户已明确授权开始，在本会话按 executing-plans 推进；独立子任务仅做只读审阅与自动回归，无额外计划批准步骤。

**目标：** 验证同一正式 relay 下两执行端同时待答的准确归属、重复与旧绑定拒绝，以及本机输入与手机异值竞争；各层证据独立计结论。
**范围：** Rust已安装host/relay、Codex原有daemon、标准零参数CLI、正式iPhone及既有设备身份。只允许已批准Mac两测试目录与Ubuntu `/home/developer/Projects/agent`。无真实工具审批，无文件/命令/设置工具调用；不改变启动入口，不新建凭据、不改正常daemon或Herdr。
**文档：** `docs/PROTOCOL.md`、`docs/ADAPTERS.md`、`docs/STATUS.md`。

## 0. 用户插入的暗色问题

- [x] 真机截图复现固定浅背景与暗色白字冲突；仅改系统自适应背景。
- [x] 原证书/profile签名安装；真机暗色、模拟器明暗桌面及Release构建通过。模拟器恢复原模式。
- [x] 修复独立提交8527be0，所有图片和详细结果留本地忽略的evidence。

## 1. 自动基线与现场接手

- [x] core_state10、relay_process8、adapters_outbox3、tiny_http_scheduler1，本轮22通过。
- [x] adapters18通过；新增来源匹配5项通过，完整原生回归87通过/0失败/2 ignored（新5项已含，不重复累加）。未重跑两项需显式旧二进制的回滚演练。
- [x] Mac专用CLI36153/原daemon91603空闲，host三项0；Ubuntu scope无Agent进程，host1781909原draintrue，原daemon1805212仅载入上次已完成的idle thread。
- [x] 启题前重读状态；只在确认无正常任务后恢复Ubuntu原drain，启动本轮专用tmux内零参数Codex，核实Plan模式。

## 2. 双主机同时待答与异值手机答案

- [x] 两个原任务都只调用一次request_user_input，题名AGENTINBOX_CHOOSE_ROUTE、选项Alpha/Beta，等待真实答案后只回显实际值；禁止所有其他工具，禁止第二题和后续任务。
- [x] 保存两题完整host/runtime/session/turn/native/item/productId/revision/expiry绑定，SQL同一快照证明同时pending。窗格与机器标签仅展示。
- [x] 手机先对host-a选Beta，待组件切换准确mac-mini后选Alpha。若显示机器或题状态不符即停止，不套用答案；组件迟滞时可独立验证App准确请求页，但不得混计Widget直答。
- [x] 两原call各恰好一次结构化输出且不同值，两个turn完成，正式设备各唯一response，核对无跨host/session领取和新回调误投。

## 3. 重复、旧绑定和键盘竞争

- [x] 自动测试覆盖同responseId幂等、同ID异内容拒绝、旧revision/终态/下一题绑定拒绝及并发唯一获胜；新增原生来源匹配拒绝localAlpha与phoneBeta混认、跨session/turn/call同值混认。均为mock或适配器层，不计真机键盘竞争。
- [x] 本机Alpha与手机Beta使用另一道单题隔离fixture，先固定唯一原绑定与可见TUI等待。自动TUI最多只发一次空Enter，禁止文字、方向键、延时重试或下一题；已resolved则取消发送。tmux没有原子request条件，此路径仅为受控测试输入，不是产品答题方案。
- [ ] 需要真实物理键盘证据时，由用户在已打开的准确专用终端正常按键；手机Beta由用户点击。结合异值原工具结果、手机Intent事件和服务端记录分类键盘先、手机先、近同时尝试；没有证明时间重叠就不计同时通过。
- [x] 不同层级成功不能互相替代。发现未知结果立即停止该请求重试，保留原现场并继续不依赖它的测试。

## 4. 收尾与交付

- [x] 全部原任务采用或本机处理且outstanding0后，用prepare-upgrade核对receipt与callback全零，恢复本轮Ubuntu原drain。仅清理精确PID/cwd的自有CLI，保留正常daemon/Herdr及idle线程历史。
- [x] 更新支持矩阵，标明通过与缺口。只提交源码/测试/文档，evidence目录始终不入Git。tiny_http独立补丁仓库明确留到后续整理，本轮不改。

当前检查点：双机同时pending、手机Widget host-a Beta / Mac Alpha、各原call唯一异值输出与turn完成已通过。用户两次均留桌面，但题间手动刷新；自动切题尚未通过。已定位submitting优先挡题并修复，6项新测试先3失败，完整iOS核心65通过/5条件跳过；原签名Debug/Release通过并安装，等待新版免手刷复测就绪。Ubuntu原drain已恢复、专用CLI2062050已关闭，正常daemon/Herdr保留。详见CONCURRENCY-PHASE1.md；物理键盘竞争未开始。

新版复测预备阶段：Mac新题先于Ubuntu第二题发出即被手机Widget Beta采用，尚未形成两题同时待答；已暂停发题并核对点击时机器标签，不计自动切题通过。Ubuntu本轮新CLI2082749保留尚未提交的题目草稿，host暂为drainfalse；收尾仍需排空和恢复原drain。

最新检查点：新版全新两题63483ecb / 445f659d独立通过无手刷切题，host-a Beta / Mac Alpha各原call唯一结果、各原turn完成、正式设备唯一response、最终桌面自动清空。详细证据本地留存，未上传。新版复测双pending瞬时断言错过窗口，不算成功快照，重叠用完整时间线验证；首轮同事务双pending快照仍保留。Ubuntu再次排空，原drain恢复，专用CLI2082749已关闭。历史机器显示疑点因缺点击像素保留，本次未复现；物理键盘竞争未开始。

本机/手机竞争检查点：本机先答Alpha、手机先答Beta且本机取消、手机Beta正式入库但host未领取时受控TUI一次Enter抢先Alpha三条实测通过。e21cf3b8原call唯一Alpha/原turn完成，relay及手机handledLocally、Beta claimed0且无dispatch标记，Widget自动清空；控制器全部退出、host三活跃计数0，正常daemon/Herdr不变。物理键盘和候选已领取/派发后的竞争仍未验收，见CONCURRENCY-LOCAL-PHONE.md。
