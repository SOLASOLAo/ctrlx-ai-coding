# codesys-mcp-persistent ctrlX 兼容补丁

> 适用:`codesys-mcp-persistent` v0.6.3(npm 全局包)
> 目标 IDE:ctrlX PLC Engineering(PLE-V-0206.x,profile `ctrlX PLC 2.6.8`)及其他 OEM CODESYS 品牌 IDE
> 首次应用:2026-08-12 · connector I/O 扩展:2026-08-18 · 编译消息/会话接管扩展:2026-08-20 · no-save Build 门禁:2026-08-23 · Broker ownership/fresh-build contract:2026-08-27

> **当前门禁（2026-08-28）**：本机 adapter 已应用；全局 `-Check`、隔离 readiness 与
> Station010 真实 PLE 离线技术通道均通过。这只证明 ownership、fresh Build、typed
> warning 与 semantic snapshot 技术通道；正式 baseline/P1.2 仍未验收。当前 warning
> candidate 含 `PLE_WARNING_OUTPUT_TRUNCATED`，不得批准为正式 baseline。
>
> fresh-build contract v2 不接受推断结果：两个预期消息类别必须全部成功清空并回读为空，
> 应用对象必须实际执行一次 `build()`（不接受 `generate_code()` 代替），两个类别
> 必须全部读取成功，且 Build 类别必须返回以 `Compile complete` 或 `Build complete`
> 开头的明确数字摘要。包含通用 `0 errors / 0 warnings` 的其他文本（内部标记为
> `Other summary`）只供诊断，不能认证 fresh。上述事实任一缺失时，
> `fresh` 与 `patchPreflightVerified` 都不会被认证为 `true`。0 errors / 0 warnings
> 的空集合可直接标记 `typedRecordsVerified=true`；仅在 fresh、0 errors、非零
> warnings 时，adapter 才额外读取固定的 Build 与 Additional code checks 两个类别，
> 每类只调用一次 `get_message_objects(category, Warning)`。两个调用返回的 warning
> 对象总数必须精确等于数字摘要，且每条通过 severity、空值、敏感字段及 UTF-8
> 大小门禁，才输出 `{severity:"warning",text}` records。数量不符、API 异常、含敏感
> 内容或超限时保留有界脱敏 `diagnosticRows` 并令 `typedRecordsVerified=false`；不猜测
> severity，也不会退回全部类别 × 全部 severity 扫描。
>
> semantic snapshot 是单独的 actual-only 只读工具，不与 `compile_project` 混合。
> Broker 在同一 owned session 完成 Build 后调用它，再把返回事实与 action-bound、
> 已审阅 baseline 比较；工具本身不接收 expected 值，也不返回 acceptance 布尔值。
>
> `clean_compile_project` 是独立、显式选择的语义重建工具，普通
> `compile_project` 仍保持一次 `application.build()` 的快速路径。clean 工具只执行
> 一次 `application.clean()`，随后一次 `application.build()`；不保存工程，也不调用
> 其他重建/代码生成入口。`semanticRebuildVerified` 只证明 clean/build 调用、工程身份、
> 前后 dirty 与数字消息证据均可信，不等于 `errorCount=0`；编译错误仍以可信 summary
> 返回并令 MCP 响应 `isError=true`。warning 文本全集是否完整由独立的
> `warningDetailsComplete` / `typedRecordsVerified` 表示。
>
> 本次新增工具只写入共享补丁源并通过隔离 fixture；按任务边界没有修改全局 npm
> 安装。全局 `-Check` 在正式受控安装前会对 clean 工具显示 `TODO`，对 warning wire
> 对齐升级显示 `UPGR`，不能误报为已经部署。

## 症状 1：CRLF 导致编译工具失败

通过 MCP 调用 `compile_project` / `get_compile_messages` 时,返回:

```
SyntaxError: unexpected token '\r'
```

## 根因

1. ctrlX PLC Engineering 内置 IronPython 2.7 脚本引擎,`exec()` 不容忍 CRLF/混合行尾;
2. MCP 包 `dist/scripts/_message_utils.py` 出厂带 CRLF 行尾;
3. watcher 注入的 helper 代码以 LF 拼接,模板脚本以 CRLF 落盘 → 混合行尾触发语法错误。

## 症状 2：ctrlX I/O 通道无法被 `map_io_channel` 找到

原始 MCP 工具只遍历设备的 `get_children(False)`。ctrlX/DataLayer EtherCAT 模块的实际通道并不是工程树子节点，而位于：

```text
device.connectors → connector.host_parameters
  → parameter.is_mappable_io → parameter.io_mapping.variable
```

因此 `inspect_device_node` 会显示 `children: []`，原始 `map_io_channel` 随后报 `Channel not found`，尽管 PLC Engineering 的 I/O Mapping 页里确实存在通道。

## 症状 3：PLC 已完成 Build，但 MCP `compile_project` 超时

典型表现是 PLC Engineering 的 Build 窗口已显示完成，MCP 调用却在 300 s 后才报超时；随后 `get_compile_messages` 也可能继续卡住。

根因有两层：

1. 原脚本连续执行 `clean()`、`clean_all()`、`build()` 和 `generate_code()`，对大型 OpCon 工程存在重复编译；
2. 编译结束后，原脚本按“全部消息类别 × Fatal/Error/Warning/Information/Text”反复调用 `get_message_objects(category, severity)`，ctrlX PLE 2.6.8 的该 OEM 接口可能单次阻塞数分钟。

兼容补丁改成一次官方 `ScriptApplication.build()`，并只读取 Build 与 Additional code checks 两类缓存；每类仅调用一次 `System.get_messages(category)`，由 IDE 自身的 Build summary 统计 error/warning。若摘要为 fresh 0-error + 非零 warning，再对同样两个固定类别各做一次 Warning-only 对象读取，以生成 type-verified warning records。若拿不到 Build summary、对象数与摘要不一致或对象不安全，工具失败关闭，不会把未知状态误报成成功。

同一 Build 类别同时出现 `Compile complete` 与尾部 `Build complete` 时，以前者为应用编译结果。后者可能只统计外层生成阶段，不能用它把实际数百条错误误报为少量错误。

## 症状 4：扩展重启后 MCP 接管了错误的 Windows 进程

持久会话目录中的 `ready.signal` 可能在 PLE 已退出后残留。Windows 随后会复用其中的 PID；原启动器只用 signal-0 判断 PID 存活，因此可能把无关进程（实测为 `python.exe`）误认为原 PLE 会话，导致所有 MCP 命令失败，shutdown 还存在结束无关进程的风险。

补丁在接管、健康检查和 shutdown 前校验 PID 对应的可执行文件名必须与配置的 PLE 一致；接管前还用候选 watcher 执行一次有界 `SCRIPT_SUCCESS` 握手。身份错误或 watcher 无响应时跳过旧会话并启动新的 PLE。

## 症状 5：只读 Build 隐式保存 dirty 工程

原始 `compile_project.py` 在工程为 dirty 时会先执行 `primary_project.save()`。
这会把 IDE 迁移或其他未确认编辑写回加密 `.project`，不适合作为离线只读门禁。
补丁移除隐式保存：若工程 dirty、或无法确认 dirty 状态，Build 在调用前失败关闭；
需要写入的 MCP 工具仍由各自受控流程显式保存。

## 症状 6：需要正式 Clean Build，但不能拖慢每次快速检查

日常编译修复闭环只需要 `compile_project` 的单次 Build。发布候选或缓存一致性诊断则
需要一次明确的 Clean + Build，且必须能证明没有暗中执行多次重建。补丁因此新增独立
`clean_compile_project`，而不改变既有工具的默认语义。它对精确活动工程路径和 dirty
状态做前后门禁，清空并回读固定消息类别，然后严格调用一次 `application.clean()` 和
一次 `application.build()`。任何调用、身份、dirty 或数字摘要证据缺失都会令
`semanticRebuildVerified=false`。

Build 类别里的 Information 文本（例如保留字提示）不等于 Warning 对象。普通 Build
与 Clean Build 都只把固定 `Build/Warning`、`Additional code checks/Warning` 查询得到的
type-verified records 当作 warning 文本；不会再用“数量碰巧相同”的 Information 行替代。
2026-08-28 Station010 隔离实测恰好展示了该差异：数字摘要为 4 warnings，固定
`Build/Warning` 返回 4 条 OPC UA DA warning，而 `Build/Information` 返回 41 条（前部
包含 CLASS 等提示）；旧 wire 曾错误截取前 4 条 Information 文本。回归现已固定要求
wire warning 文本与 `summary.records` 使用同一组 typed records。

## 补丁内容

| 文件 | 修改 |
|---|---|
| `dist/scripts/watcher.py` | 在 BOM 剥离行(`script_code = script_code[1:]`)之后插入 5 行行尾归一化:`script_code.replace(u"\r\n", u"\n").replace(u"\r", u"\n")`(见 `watcher_crlf_normalize.patch`) |
| `dist/scripts/_message_utils.py` | 全文 CRLF → LF |
| `dist/scripts/map_io_channel.py` | 增加 connector mappable-parameter 查找；支持按 `Channel_6.Output` 或零基索引定位；写后强制回读校验；增加 `@batch-json` 事务式批量映射并只保存一次工程 |
| `src/scripts/map_io_channel.py` | 同步源码副本，避免本机重建 `dist` 时丢失补丁 |
| `dist/scripts` + `src/scripts` 的 `_message_utils.py` | 增加有界 Build 消息快照与向后兼容的结构化消息转换；通用数字行可保留为 `Other summary` 诊断，但 fresh-v2 不接受它作为 Build 证明 |
| `dist/scripts` + `src/scripts` 的 `compile_project.py` | 应用工程只执行一次 `build()`；只读两个编译类别；移除 dirty 工程的隐式 save，dirty/未知状态失败关闭 |
| `dist/scripts` + `src/scripts` 的 `get_compile_messages.py` | 使用同一有界缓存读取路径，避免只读消息也阻塞 IDE |
| `dist/launcher.js` + `src/launcher.ts` | 校验持久会话 PID 的 PLE 可执行文件身份，并在接管前探测 watcher；健康检查和 shutdown 同样防 PID 复用 |
| `dist/launcher.js` + `src/launcher.ts`、`dist/server.js` + `src/server.ts` | 输出 `ctrlx-ple-ownership-v1`，区分本 launcher 创建的 `broker` 与接管的 `external`；外部 PLE 禁止 shutdown |
| `dist/scripts` + `src/scripts` 的 `compile_project.py`、`dist/server.js` + `src/server.ts` | 输出 `ctrlx-fresh-compile-v2` 同次 summary；只有类别全清空、真实 `application.build()`、类别全读回、明确 Build 数字摘要均成立时才认证 fresh/patch preflight；0/0 保留 type-verified 空 records；fresh 0-error + warning 仅通过固定两类别 × Warning severity 精确计数后输出 typed records，其余结果保留有界脱敏 diagnostics 并失败关闭 |
| `dist/scripts` + `src/scripts` 的 `clean_compile_project.py`、`dist/server.js` + `src/server.ts` | 注册显式 `clean_compile_project`；严格一次 `application.clean()` + 一次 `application.build()`，复用 fixed-category 清空/有界读取/type-verified warning，前后核验精确工程身份与 dirty；`semanticRebuildVerified` 与编译成功、warning 明细完整性分开表达 |
| `dist/scripts` + `src/scripts` 的 `get_ctrlx_semantic_snapshot.py` | 只读递归遍历 action 指定的工程树 scope root 及其后代对象；读取 connector/device parameter 与树通道的实际 mapping（包括空 binding），固定稳定 identity/order，总记录硬上限 2048；不调用 `save()` |
| `dist/server.js` + `src/server.ts` | 注册 actual-only `get_ctrlx_semantic_snapshot`；官方 PLE REST Symbol Configuration 先做最多 4 次连续双读有界收敛并丢弃结果，再执行三组 Mapping/Symbol 交叉权威读取，mapping 仅比较最终封存的语义投影，末尾追加 Mapping/dirty guard；mapping facts 只返回一份，Symbol payload 不跨 MCP、只返回其 hash/byte count/shape summary；compact 内层响应硬限 480 KiB，为 1 MiB MCP JSON-line 外层转义保留空间；任一读失败、工程 dirty、语义投影/权威 Symbol 前后变化或超限均失败关闭 |

## 一键应用

```powershell
# 先检查(不写盘)
.\apply-crlf-patch.ps1 -Check
# 应用(幂等；每个新契约只创建一次对应的 .bak_pre_* 备份)
.\apply-crlf-patch.ps1
```

脚本会自动从 `npm root -g` 定位包路径;也可 `-PackageScriptsDir <path>` 手动指定。脚本会同时检查/修补 `dist/scripts` 与存在时的 `src/scripts`，重复执行不会重复插入。应用阶段从首个文件写入到 Python/Node 语法校验完成属于同一事务；任何中途异常都会恢复本次运行涉及的全部文件。默认找不到 Python 或 Node 也会失败并回滚。只有调用者明确传入 `-SkipRuntimeSyntaxCheck` 时才允许跳过语法校验，该参数不应用于正常工作站部署。

`-Check` 是只读状态报告，不以退出码把 `TODO` 当作成功或失败：`OK` 表示完整
结构契约存在，`TODO` 表示尚未安装，`UPGR` 表示检测到旧版/局部 marker。应用模式
遇到 ownership/semantic 的 `UPGR` 会停止，要求先从相同版本 npm 包或对应备份恢复
该文件，禁止在未知局部状态上继续叠加。Runner readiness 应使用下面的隔离 fixture
测试，而不能只看 `-Check` 命令退出码。

### 回滚

补丁通过 `BackupOnce` 生成且不覆盖已有备份。P1.2b 相关后缀为：

- launcher/server ownership：`.bak_pre_ple_ownership_contract`；
- server/compile fresh-v2：`.bak_pre_fresh_compile_contract`；
- server/既有 semantic script：`.bak_pre_semantic_snapshot_contract`。

回滚前先关闭唯一的 MCP/PLE owner，避免恢复正在加载的文件。最稳妥的全量回滚是
重新安装完全相同的 `codesys-mcp-persistent` 版本，再仅应用仍需保留的旧补丁层。
若按备份做定点回滚，必须按“semantic → fresh-v2 → ownership”的逆序恢复对应
`src`/`dist` 文件；新增加且此前不存在的两份
`src/scripts/get_ctrlx_semantic_snapshot.py`、`dist/scripts/get_ctrlx_semantic_snapshot.py`、
`src/scripts/clean_compile_project.py`、`dist/scripts/clean_compile_project.py`
没有旧内容可恢复，只能在确认精确路径后删除。完成后重新运行 `-Check`，预期被
回滚的项显示 `TODO`，不能把混合的 `OK/UPGR` 状态投入 Runner。

## 验证

```powershell
python -m py_compile "$env:APPDATA\npm\node_modules\codesys-mcp-persistent\dist\scripts\watcher.py"
```

然后通过 MCP 调用 `compile_project`,应返回结构化错误/警告列表而非 SyntaxError。
`-Check` 还必须显示 dist/src 两份 `compile_project.py` 的
`strict no-save compile guard`、`fail-closed same-call fresh compile contract`、recursive semantic snapshot，
以及 launcher/server 的 `PLE ownership` 均为 `[OK]`。
2026-08-23 本机已完成补丁应用、`-Check`、Python/Node 语法和离线 fixture
验证；由于当时仍有既有 PLE/MCP owner 与活动 `.project.~u`，新的独立
checker 生命周期实测按门禁延期，不能把静态验证表述为已完成真实启动/退出验收。

无需 IDE 的编译消息回归测试：

```powershell
python .\test-fast-compile-message.py `
  "$env:APPDATA\npm\node_modules\codesys-mcp-persistent\dist\scripts\_message_utils.py" `
  "$env:APPDATA\npm\node_modules\codesys-mcp-persistent\dist\scripts\compile_project.py"
```

该测试显式覆盖：无关文本里的通用 `0 errors / 0 warnings` 只能保留为
`Other summary` 诊断，不能认证 fresh-v2；0/0 不调用对象 API；error 非零不调用对象
API；fresh 0-error + warning 只调用固定 `Build/Warning` 与
`Additional code checks/Warning` 两次，精确数量可输出 typed records。数量不符、异常、
错误 severity、Unicode、敏感词、单条/总量超限均有独立的失败关闭断言。

Clean Build 的纯离线 producer/handler 回归：

```powershell
python .\test-clean-compile-project.py .\clean_compile_project.py
node .\test-clean-compile-tool.js
```

它们验证一次 clean/一次 build、无隐式 save、无其他重建入口、精确工程身份、前后
dirty、消息类别与 summary 合同。带编译错误的 Clean Build 仍返回可信 numeric summary；
只有 warning 对象精确闭合时 `warningDetailsComplete=true`。warning/diagnostic 单条、
总量和最终 summary 还受 4 KiB/256 KiB、2 KiB/64 KiB、480 KiB 三层 wire 上限约束。

完整的纯离线 adapter readiness 回归（复制到临时 fixture 后应用，不修改全局 npm，
不启动 MCP/PLE/工程）：

```powershell
.\test-adapter-readiness.ps1
```

它要求隔离 fixture 应用后的 `-Check` 不含 `TODO`/`UPGR`，随后运行 Node/Python
语法检查、fresh-v2、recursive mapping stub、Unicode canonical/近限、final-dirty、
slow-body/oversize stream 与补丁失败回滚回归。应用模式若 `py_compile` 或
`node --check` 失败会非零退出，并恢复本轮写入的 package source 文件。本机
全局安装当前运行 `apply-crlf-patch.ps1 -Check` 应全部显示 `[OK]`；这证明已安装文件与
受控补丁一致，但不能替代真实工程 action 和 baseline 审阅。

semantic snapshot 请求示例（只给位置，不给 expected 值）：

```json
{
  "projectFilePath": "C:/Engineering/Station/Plc/Station_PLC.project",
  "mappingScopes": [
    {
      "devicePath": "Device/Realtime_Data/ethercat_master_instances_example",
      "recursive": true,
      "includeAllMappableChannels": true
    }
  ],
  "mappingTargets": [],
  "symbolApplicationPath": "Device/Plc Logic/Application"
}
```

成功响应契约为 `ctrlx-semantic-snapshot-v1`，关键事实如下：

- `dirtyStateVerified=true`、`projectDirty=false`、`recordsComplete=true`、
  `stableAcrossRead=true`；Symbol 有界收敛结果全部丢弃，随后执行三组 Mapping/Symbol
  交叉权威读取，最后再执行第四次 Mapping/dirty guard；
- `canonicalFacts.mapping.scopes/records` 是实际只读结果，空 binding 明确表示为
  `actualVariable:""`；
- Symbol payload 在 adapter 内递归 key 排序（数组顺序保留）并以 UTF-8 计算 hash，
  payload 本体不通过 MCP 返回；仅保留 byte count、`payloadSha256` 与 shape summary；
- `canonicalFacts.mapping` 固定包含 `scopeCount`、`explicitTargetCount`、
  `recordCount`、`recordLimit`、`scopes`、`records`；
- actual facts 只在 `canonicalFacts` 出现一次，`sources` 只保留读取来源/HTTP 元数据；
- `hashes` 固定包含 `mappingSha256`、`symbolConfigSha256`、`snapshotSha256`，
  算法为 `SHA-256` / `ctrlx-semantic-canonical-json-v1`。
- Symbol REST 以流式 reader 消费，30 s abort 覆盖 fetch 与完整 body；首字节超过
  8 MiB 即 cancel/fail，不先把超大响应整体缓冲到内存。

这些 hash 只是确定性实际事实，不是通过证明；Runner 必须递归重算 hash，并与
action-bound baseline 的完整 `canonicalFacts + hashes` 比较。失败响应保留相同
contract/producer/patch IDs，并返回 `recordsComplete=false`、
`stableAcrossRead=false`、结构化 `reasonCode/reason`。脚本执行失败和 REST 非 2xx
只返回长度与 SHA-256，错误正文经过脱敏和 4 KiB 上限处理。最终 compact JSON 超过
491520 UTF-8 bytes 时必须返回 `SEMANTIC_SNAPSHOT_TOO_LARGE`，不得截断或放宽限制；对应完整 MCP JSON-RPC 外层消息仍必须小于 1 MiB。

2026-08-20 在 Station010 实测：旧路径超过 300 s；当时仅使用文本缓存的补丁后
`compile_project` 约 7.6 s 返回 0 errors / 7 warnings，`get_compile_messages` 约 0.8 s
返回同一缓存。2026-08-28 真实 PLE action 已验证“两固定类别 × Warning-only”对象
读取并返回 `typedRecordsVerified=true`，但未单独记录两个调用的耗时；结果同时包含
`>100 warnings` 截断哨兵。因此这次 101 条记录不能成为完整 warning baseline，且仍需
在后续 acceptance 中记录真实分调用耗时。若读取异常慢或输出不完整，必须失败关闭，
不得放宽为全扫描。上述验证均为离线 Build，未连接、下载或运行实体 PLC。

同日会话恢复实测：残留 `ready.signal` 指向一个已被 `python.exe` 复用的 PID；补丁拒绝该候选并成功启动、连接新的 ctrlX PLE watcher。`apply-crlf-patch.ps1 -Check` 会同时检查源码和运行时 launcher 标记，应用模式还执行 `node --check dist/launcher.js`。

connector 通道补丁可直接通过正式工具验证：

```text
map_io_channel(
  devicePath="Device/Realtime_Data/.../_000SK010C1",
  channelPath="Channel_6.Output",
  clearBinding=true
)
```

成功结果必须同时给出修改前后的绑定；若回读值与请求不一致，补丁会主动报错而不会静默声称成功。

大 PDO 设备可使用同一个正式 `map_io_channel` 工具的批量扩展。`channelPath` 固定为
`@batch-json`，`variableName` 传 JSON 数组，每项为 `[零基 connector 通道索引, PLC 全局变量]`：

```text
map_io_channel(
  devicePath="Device/Realtime_Data/.../_100A104",
  channelPath="@batch-json",
  variableName='[[0,"Application.Peripherals._100A104._input.Ctrl[0]"], ...]'
)
```

扩展会先验证全部索引、重复项和变量名，再逐项写入并回读；任一项失败会对本批已写项做尽力回滚，
全部成功后只调用一次 `project.save()`。ctrlX 对 400-byte PDO 的内部刷新仍可能超过 MCP 默认 30 s；
遇到超时必须先等待 IDE 恢复并只读核对绑定，不能立即重发同一批命令。

## ⚠ 升级会覆盖补丁

`npm install -g codesys-mcp-persistent@<new>` 会还原上述文件 → **每次升级后必须重跑 `apply-crlf-patch.ps1 -Check`，再执行正式应用**。
若上游修复(行尾归一化进主线),本补丁即可退役。

## 文件清单

| 文件 | 说明 |
|---|---|
| `watcher.py.orig` | 原厂 watcher.py(v0.6.3,未打补丁) |
| `watcher.py.patched` | 打补丁后的完整文件 |
| `watcher_crlf_normalize.patch` | unified diff(仅 5 行插入) |
| `apply-crlf-patch.ps1` | 一键应用/检查 ctrlX 兼容补丁（CRLF、docstring、connector I/O Mapping、有界编译消息、no-save Build、安全会话接管） |
| `test-fast-compile-message.py` | 不启动 IDE 的编译摘要、固定两类别 Warning-only producer 与失败关闭回归；覆盖精确计数、异常、Unicode、敏感/超限记录、0-warning/error-no-query 和通用 0/0 拒绝 |
| `clean_compile_project.py` | IronPython 2.7 显式语义重建 producer；一次 clean + 一次 build，前后 identity/dirty 与同次消息证据 |
| `clean_compile_project.tool.ts/.js` | `clean_compile_project` MCP 注册与 fail-closed 响应合同 canonical 资产 |
| `test-clean-compile-project.py` / `test-clean-compile-tool.js` | 不启动 IDE 的调用次数、禁止入口、identity/dirty、编译错误可信 summary 与 warning 明细分离回归 |
| `get_ctrlx_semantic_snapshot.py` | IronPython 2.7 actual-only mapping scope/target 读取模板；稳定 identity/order，最多 2048 records |
| `get_ctrlx_semantic_snapshot.tool.ts/.js` | MCP 工具的源码/运行时 canonical 插入资产；有界 Symbol 收敛、三组 Mapping/Symbol 交叉权威读取及最终 Mapping/dirty guard，输出 canonical facts + SHA-256 |
| `test-semantic-snapshot.py` | 纯 stub 的递归 scope、connector/tree mapping、空 binding、dirty/缺失 scope 失败关闭回归 |
| `semantic-canonical-vectors.json` | Node/C# 共用 Unicode + shuffled-key canonical UTF-8/hash 向量；C# 序列化必须使用 literal Unicode 并与向量逐字节一致 |
| `test-semantic-tool.js` | 直接执行运行时插入资产的纯离线回归；覆盖 ordinal 排序、Unicode hash、Symbol payload 不外发、交叉权威读取变化/末端竞态、480 KiB 内层上限及 1 MiB 外层消息边界 |
| `test-adapter-readiness.ps1` | 临时隔离 fixture apply → 全 `[OK]` check → 语法、final-dirty race、slow-body/oversize stream、unknown-block 拒绝和 syntax-failure rollback 回归；不写全局 npm、不启动 PLE/MCP |

## 附注:docstring 损坏修复

若此前用 PowerShell 手工打过补丁,可能因误判 BOM 吞掉 `watcher.py` 首行 `"""` 的一个引号,
导致 `SyntaxError: unterminated triple-quoted string literal`。`apply-crlf-patch.ps1` 会自动检测并修复。
