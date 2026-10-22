# Desktop 旧任务身份只读交接

2026-10-15，仅核查先前创建未返回ID的 `P0 Codex Desktop isolated question`。本轮没有创建/恢复/分叉/发消息/取消/归档任何任务，没有启动UI或更改权限。

**结论：原thread ID及当前状态仍未知。不能记为未创建、已完成或已清理；也不能依据CLI/shared daemon成功认定Desktop可用。**

## 精确标题查找范围

- Codex app `list_threads(limit=50)`成功，0条pinned、50条recent；内存按目标标题精确及大小写归一筛选均无匹配。没有不可用host/source报告，也没有分页游标。
- 按负责人要求，另查一页 `list_archived_threads(source=codex, limit=50)`，50条归档记录中精确同名无匹配；存在nextCursor但没有跟随或扩大搜索。
- 未找到匹配身份，所以没有对任何非目标任务调用read_thread；未输出或保存其他任务标题、摘要或正文。未匹配只能说明上述两页没有此标题，不能排除更早记录、标题变化或其他状态。

第一次recent调用指定limit100被参数校验拒绝：`list_threads received invalid arguments: limit: Too big: expected number to be <=50.` 纠正为当前上限50后成功；没有再次遇到先前Desktop创建时的运行时错误，也没有重试创建来复现它。

## 安装元数据边界

只读取Info.plist公开版本，未调用CUA getApp、Finder或启动应用：

| 项目 | 只读结果 |
| --- | --- |
| Claude Desktop | bundle `com.anthropic.claudefordesktop`，版本/构建1.12603.1 |
| Codex主App | 标准Applications目录未找到匹配主bundle，本轮没有取得主App版本；不能据此称未安装 |
| Codex Computer Use辅助程序 | `com.openai.sky.CUAService`，26.1005.1001425 / 1001425；这是已运行helper的bundle，不能当Codex Desktop主App版本 |

Code tab是否可用、原生hook实际加载与返回均未验证；没有把Claude Chat/Cowork作为Code tab。没有读取账户/登录凭据或应用秘密配置，也没有因只读工具成功而继续泛查。

脱敏证据：evidence/desktop-readonly/handoff.json。后续若要消除未知，需要原任务ID、可定位到目标的更早记录或人工确认身份；在此之前不得盲目重复创建或当作清理完成。本轮无进程/任务需要清理，源码及STATUS未改。
