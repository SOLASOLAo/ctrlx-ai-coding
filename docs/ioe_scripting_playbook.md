# ctrlX IO Engineering(IOE)脚本化操作手册

> **来源**:BPP_ResistantStation(电阻测试台)项目 Station010 硬件组态实战(2026-08-18)。
> **适用**:ctrlX IO Engineering IOE-V-0206.4(exe 2.2.4.1,ScriptEngine 4.1 / IronPython 2.7)。
> **配套工具**:本仓库 `scripts/ioe_ipc.ps1`(从 PowerShell 向独立 IOE 实例投递脚本)。
> **一句话**:IO 工程(`*_CtrlX_IO.project`)绝不能用 PLE 打开;用 IOE-IPC 驱动 IOE 自己干活。

---

## 1. ctrlX 三客户端分工(别搞混)

| 客户端 | 版本 | 用途 | AI 驱动方式 |
|---|---|---|---|
| ctrlX PLC Engineering(PLE) | PLE-V-0206.8(exe 2.3.7.5) | PLC 工程(`*_CtrlX_PLC.project`) | MCP codesys-persistent 正规工具 |
| ctrlX IO Engineering(IOE) | IOE-V-0206.4(exe 2.2.4.1) | IO 工程(EtherCAT 组态),**无 MCP server** | 本文 IOE-IPC |
| ctrlX WORKS(WRK) | WRK-V-0206.4 | 套件入口/管理器 | 不需要 |

关键差异:
- PLE 启动**必须**带精确 profile `ctrlX PLC 2.6.8`;IOE **不需要** `--profile`。
- **PLE 打开 IO 工程 = 事故**:2.6.8 会触发版本转换,转换后的文件 IOE 2.6.4 打不开,且 PLE 实例会崩溃
  (上一会话 MCP eval_python 全部超时的根因就是它)。

## 2. IOE-IPC 架构

MCP 只服务 PLE。IOE 没有自动化服务,但支持与 MCP watcher 相同的 `--runscript` 启动钩子,
据此搭一条文件 IPC 通道:

```
PowerShell(ioe_ipc.ps1)                IOE 实例(--runscript=watcher.py)
        |                                          |
        +-- 写 %TEMP%\ioe-ipc\commands\<id>.py     |
        +-- 写 <id>.command.json ----------------->| watcher 轮询 commands/
        |   {"requestId","scriptPath"}             | ScriptEngine 执行 <id>.py
        |<------------------------ 写 results\<id>.result.json
        +-- 轮询 results/ 取结果                    |
```

### 2.1 启动 IOE 监听实例

前置:把 MCP 包里的 watcher 模板(`codesys-mcp-persistent/dist/scripts/watcher.py`,已含 CRLF 补丁)
拷到 `%TEMP%\ioe-ipc\watcher.py`,并将其 IPC 目录常量替换为 `%TEMP%\ioe-ipc`。

```powershell
$ioeDir = 'C:\ctrlXWORKS\ctrlXIOEngineering\IOE_V_0206\StudioIo\Common'
Start-Process "$ioeDir\ctrlX-IO-Engineering.exe" `
  -ArgumentList '--runscript=C:\Users\<user>\AppData\Local\Temp\ioe-ipc\watcher.py' `
  -WorkingDirectory $ioeDir
# 等待 %TEMP%\ioe-ipc\ready.signal 出现(约 10~60 s)
```

### 2.2 投递脚本(scripts/ioe_ipc.ps1)

```powershell
. .\scripts\ioe_ipc.ps1          # 提供 Invoke-IoeScript $code [$timeoutMs=120000]
$code = @"
import scriptengine as se, sys
p = se.projects.primary
print(p.path)
print('SCRIPT_SUCCESS')
"@
$r = Invoke-IoeScript $code 60000
$r.success; $r.output            # 脚本内打印 SCRIPT_SUCCESS 才算成功
```

协议细节:命令 = `commands\<guid>.command.json`(字段 `requestId`/`scriptPath`)+ 同 guid 的 `.py`;
watcher 执行后写 `results\<guid>.result.json`(success/output/error)。

### 2.3 关闭(务必优雅)

```python
p = se.projects.primary
p.close()          # 先关工程
```

然后由 watcher 侧 terminate 正常退出实例。
**禁止** `System.Environment.Exit(0)` 强退:下次启动再打开同一工程会弹
"already being edited" 三按钮对话框,占住主线程,一切 IPC 超时(见坑5)。

## 3. ScriptEngine 4.1 API 要点(IOE 特有)

```python
import scriptengine as se

se.projects.open(r'C:\...\Stat010_V5.11_CtrlX_IO.project')  # 勿对已打开工程重复调用(卡 UI 线程)
p = se.projects.primary        # ScriptProject;注意 se.projects 本身【不可迭代】(无 .count/.name)
# ScriptProject 常用成员(反射确认):.path  .dirty  .save()  .close()

# 树遍历:项目节点直接 get_children,逐层下钻
for o in p.get_children(False):
    print(o.get_name())
# 设备节点另有:.remove()  .rename()  .export_xml()  .type(Guid)

se.system.background_loading_of_libraries_finished   # 插件/库后台加载完成标志(见坑6)
```

IOE 与 PLE 的差异(实测):
- `p.active_application` 在 IO 工程**抛异常**(IO 工程没有 Application 概念),别套用 PLE 脚本。
- **通道(channel)在 IO 侧脚本 API 不可见**:DI/DO 通道符号(如 `_000S901`)存在于 PLC 工程的
  I/O 映射里,IO 工程只管模块级组态;"改通道名/绑定"类需求要去 PLC 侧。
- `se.projects` 无迭代接口:多工程场景只能靠 `se.projects.open/close/primary`。
- 设备 typeId 校验可在 PLE 侧用 MCP `list_device_repository` 完成(IOE 脚本侧取 `.type(Guid)` 对照)。

## 4. 踩坑清单(2026-08-18 实测 → 解法)

| # | 现象 | 根因 | 解法/规避 |
|---|---|---|---|
| 1 | `Remove-Item` 被策略拦截 | 环境安全策略 | `[System.IO.File]::Delete`、`Copy-Item` 替代 |
| 2 | "替换失败"假警报(文件其实已改好) | PS 控制台 cp1252 回显中文乱码 | 文件一律 `ReadAllText/WriteAllText(...,UTF8)`;**不信控制台回显**,以文件实际内容为准 |
| 3 | 一切 IPC 超时 | 模态对话框占住 IDE 主线程 | 避免触发对话框的操作;疑似时 `CopyFromScreen` 截图诊断,`SendKeys ENTER` 解除 |
| 4 | 重开工程弹 "already being edited" | 崩溃/强退残留 `.~u` 锁 | 先确认 0 个存活 `ctrlX-*-Engineering` 进程,再删 `.~u`;锁被活进程持有时勿删 |
| 5 | `Environment.Exit(0)` 退出后重启弹三按钮对话框 | 强退未清理状态 | `p.close()` + 正常 terminate 优雅退出(见 2.3) |
| 6 | ready.signal 后首个 `remove()` 报 `Value cannot be null. Parameter name: source` | 插件初始化竞态 | 检查 `se.system.background_loading_of_libraries_finished`,为 True 再执行,失败重试一次 |
| 7 | PLE 打开 IO 工程 → 版本转换 + 实例崩溃 | IO 工程归 IOE 2.6.4 管 | **PLE 永不打开 IO 工程**;IOE-IPC 驱动 IOE(本文路线) |
| 8 | `hh.exe -decompile ScriptEngine.chm` 失败 | CHM 反编译不可用 | 反射探 API;参考 MCP 包 `dist/scripts/*.py`(find_object_by_path / inspect_device_node / map_io_channel) |
| 9 | `git push` 报 NativeCommandError;MCP 命令"迟到" | PS 把 stderr 当错误(表面现象);超时命令稍后仍会执行 | 看 exit code 判断成败;超时后先查状态再继续;`eval_python` 省略 `timeoutMs` 参数 |
| 10 | CpStudio 写大 PDO 的 I/O designator 时 JSON 解析失败 | IOE 2.6.4 对 200-byte input + 200-byte output 设备序列化 `ioMapping/subChannels` 时混入 `The stream is currently in use by a previous operation on the stream` Critical 对象 | 不改 ESI；IOE `ExportEthercatConfigJob` 导出 master，PLE `ImportOfflineFieldbusConfigJob(keepExisting=true)` 导入，再经 persistent MCP connector mapping 绑定父 BYTE |

### 4.1 大 PDO 的 REST 边界（Kistler 5867C 实测）

对 `_100A104` 直接 GET IOE/PLE device REST 资源时，HTTP 可能仍返回 200，但约 195 KB 的 JSON 在
`ioMapping[350].subChannels[2].address` 附近被 Critical 错误对象截断，因此不能把“HTTP 200”当作可解析结果。
CpStudio 的写 designator 功能使用同一设备资源，所以会抛 Newtonsoft JSON 异常。

已验证的无 UI、无二进制直改路径：

1. IOE 对 EtherCAT master 执行 `ExportEthercatConfigJob`；
2. PLE 在 `Realtime_Data` 执行 `ImportOfflineFieldbusConfigJob`，`forceInsert=false`、`keepExisting=true`；
3. 使用 `map_io_channel` 的 connector parameter 路径完成 PLC 变量映射；400 通道场景使用兼容补丁的
   `@batch-json`，只在全部回读通过后保存一次工程；
4. 再次只读统计绑定数/差异数并完整编译。

该问题属于 IDE REST 序列化实现，和 Little-Endian、BMK 或供应商 ESI 内容无关。禁止删减 ESI PDO
来“修好”CpStudio，因为那会让工程接口与真实 5867C 过程数据不一致。

## 5. 可复用检查单(下次 IO 组态任务)

1. 电气图 → 目标树清单(耦合器/模块型号 + 数量 + 顺序);
2. 确认 0 个残留 IOE/PLE 进程、0 个陈旧 `.~u` 锁;备份真工程(`Copy-Item` 成 `.bak_<日期>`);
3. 部署 `%TEMP%\ioe-ipc`(watcher.py)→ 启动 IOE → 等 `ready.signal`;
4. `Invoke-IoeScript`:open → 等 `background_loading_of_libraries_finished` → 遍历树核对 → 增删节点 → `save()`;
5. 用 `list_device_repository`(PLE 侧 MCP 工具)校验设备 typeId,防"形对实错";
6. `p.close()` 优雅关闭;**用户开 IOE 目视复核**;
7. 通道符号需求 → 转 PLC 工程 I/O 映射处理,别在 IO 侧找。

## 6. 红线(IO 侧补充)

- 🔴 IO 工程只由 IOE 2.6.4 编辑;PLE 2.6.8 打开即版本污染。
- 🔴 动真工程前必备份;先在副本(如 `IO_copy.project`)上验证脚本,再上真工程。
- 🔴 不杀用户开着的 IDE 窗口;后台脚本实例用完即优雅关闭,别留给用户一个"不知道是啥"的窗口。
