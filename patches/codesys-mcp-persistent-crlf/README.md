# codesys-mcp-persistent ctrlX 兼容补丁

> 适用:`codesys-mcp-persistent` v0.6.3(npm 全局包)
> 目标 IDE:ctrlX PLC Engineering(PLE-V-0206.x,profile `ctrlX PLC 2.6.8`)及其他 OEM CODESYS 品牌 IDE
> 首次应用:2026-08-12 · connector I/O 扩展:2026-08-18 · 编译消息扩展:2026-08-20 · 状态:已在本机验证

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

兼容补丁改成一次官方 `ScriptApplication.build()`，并只读取 Build 与 Additional code checks 两类缓存；每类仅调用一次 `System.get_messages(category)`，由 IDE 自身的 Build summary 统计 error/warning。若拿不到 Build summary，工具按错误失败，不会把未知状态误报成成功。

## 补丁内容

| 文件 | 修改 |
|---|---|
| `dist/scripts/watcher.py` | 在 BOM 剥离行(`script_code = script_code[1:]`)之后插入 5 行行尾归一化:`script_code.replace(u"\r\n", u"\n").replace(u"\r", u"\n")`(见 `watcher_crlf_normalize.patch`) |
| `dist/scripts/_message_utils.py` | 全文 CRLF → LF |
| `dist/scripts/map_io_channel.py` | 增加 connector mappable-parameter 查找；支持按 `Channel_6.Output` 或零基索引定位；写后强制回读校验；增加 `@batch-json` 事务式批量映射并只保存一次工程 |
| `src/scripts/map_io_channel.py` | 同步源码副本，避免本机重建 `dist` 时丢失补丁 |
| `dist/scripts` + `src/scripts` 的 `_message_utils.py` | 增加有界 Build 消息快照与向后兼容的结构化消息转换；未知摘要按失败处理 |
| `dist/scripts` + `src/scripts` 的 `compile_project.py` | 应用工程只执行一次 `build()`；只读两个编译类别，不再全类别/严重级别扫描 |
| `dist/scripts` + `src/scripts` 的 `get_compile_messages.py` | 使用同一有界缓存读取路径，避免只读消息也阻塞 IDE |

## 一键应用

```powershell
# 先检查(不写盘)
.\apply-crlf-patch.ps1 -Check
# 应用(幂等;自动备份 watcher.py.bak_orig / _message_utils.py.bak_crlf)
.\apply-crlf-patch.ps1
```

脚本会自动从 `npm root -g` 定位包路径;也可 `-PackageScriptsDir <path>` 手动指定。脚本会同时检查/修补 `dist/scripts` 与存在时的 `src/scripts`，重复执行不会重复插入。

## 验证

```powershell
python -m py_compile "$env:APPDATA\npm\node_modules\codesys-mcp-persistent\dist\scripts\watcher.py"
```

然后通过 MCP 调用 `compile_project`,应返回结构化错误/警告列表而非 SyntaxError。

无需 IDE 的编译消息回归测试：

```powershell
python .\test-fast-compile-message.py `
  "$env:APPDATA\npm\node_modules\codesys-mcp-persistent\dist\scripts\_message_utils.py"
```

2026-08-20 在 Station010 实测：旧路径超过 300 s；补丁后 `compile_project` 约 7.6 s 返回 0 errors / 7 warnings，`get_compile_messages` 约 0.8 s 返回同一缓存。该验证是离线 Build，未连接、下载或运行实体 PLC。

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
| `apply-crlf-patch.ps1` | 一键应用/检查 ctrlX 兼容补丁（CRLF、docstring、connector I/O Mapping、有界编译消息） |
| `test-fast-compile-message.py` | 不启动 IDE 的编译摘要解析/失败关闭回归测试 |

## 附注:docstring 损坏修复

若此前用 PowerShell 手工打过补丁,可能因误判 BOM 吞掉 `watcher.py` 首行 `"""` 的一个引号,
导致 `SyntaxError: unterminated triple-quoted string literal`。`apply-crlf-patch.ps1` 会自动检测并修复。
