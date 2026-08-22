# ctrlX AI 项目基线记录(MD 版)

> Persistent MCP + Control plus Studio 混合工作流
> 记录日期:2026-08-11 · 更新:2026-08-22（EtherCAT BMK 与 Symbol 导出闭环实测）· 机器:AGZ1WX-APAC
> 配套 HTML:`ctrlX_AI_project_baseline.html`(同目录)

---

## 0. 分工约定（2026-08-20 更新）

| 角色 | 职责 |
|---|---|
| **用户(人)** | CpStudio 模型：Station/Command/Unit 层级、标准 Unit/AddOn/Peripheral、HMI、Event、StationData、BMK，以及工艺和真机安全决策 |
| **AI(persistent MCP/REST)** | AI 旁车初始化、声明归属的 PLC 应用逻辑、SFC/Symbol/I/O 审计、编译-修复闭环、仿真辅助和证据维护 |

约定要点:
- CpStudio 不是一次性工具；模型、标准对象或 HMI/BMK 变化继续在 CpStudio 完成并重新导出
- AI 可以创建标准化的 AI 旁车目录，但不伪造或直接改写 CpStudio 的闭源模型文件
- CpStudio 导出后先做 Git/指纹/ownership 离线审计，再由唯一 persistent 会话执行受控修复、回读和编译

---

## 1. 总体架构

```
阶段1 CpStudio V5.11(人,持续使用)
   Station/Command/Unit + 标准对象 + HMI/Event/StationData/BMK → 生成/导出
        ↓
阶段2 硬件组态(人)
   ctrlX 默认 IP 网页 → EtherCAT 配置 → ctrlX IO Engineering 组态 IO
        ↓
阶段3 AI + persistent MCP(主力)
   在 .project 内写 SqM/SqS/自动/手动细节; set_pou_code → compile(结构化错误) → 修复 → save
        ↓
阶段4 下载调试(MCP 在线工具)
   set_simulation_mode → connect → download → start/stop → read/write_variable → monitor
```

核心前提(均已实测):
- `.project` 是**加密容器**,不能手改文件,只能经 IDE 脚本引擎(MCP 驱动)修改
- 所需库可由本地托管仓库解析；这只解决 PLC 编译依赖，不改变 CpStudio 对供应商模型的所有权

---

## 2. 已安装软件与版本

| 组件 | 版本 | 路径 | 角色 |
|---|---|---|---|
| Control plus Studio (CpStudio) | V5.11 (5.11.0.169);另有 V5.8/V5.5 | `C:\Nexeed\Automation\CSV5_11\Bosch.Nexeed.Automation.CpStudio.exe` | OpCon 模型、标准对象、HMI/Event/StationData/BMK 与一键导出（持续使用） |
| ctrlX WORKS | WRK-V-0206.4 (2.6.4) | `C:\ctrlXWORKS\ctrlXWORKS\WRK_V_0206` | ctrlX 套件容器 |
| ctrlX PLC Engineering | PLE-V-0206.8 (2.6.8);exe 2.3.7.5,CODESYS 3.5.19.70 内核 | `C:\ctrlXWORKS\ctrlXPLCEngineering\PLE_V_0206\StudioPlc\Common\ctrlX-PLC-Engineering.exe` | **PLC 编程 IDE,MCP 驱动对象**;profile = `ctrlX PLC 2.6.8` |
| ctrlX IO Engineering | IOE-V-0206.4 (2.6.4) | `C:\ctrlXWORKS\ctrlXIOEngineering` | IO 硬件组态(EtherCAT) |
| OpCon 工具链 | OES V3.0~V4.11、OpConStudio | `C:\OpCon\` | OpCon 标准工具(参考) |
| 本地服务 | ctrlX PLC Gateway 1.6.3.0、Service Control、UaGateway | Windows 服务 | 虚拟 PLC / OPC UA 网关,保持 Running |

---

## 3. 工程文件解剖(关键路径)

参考样板:TrainingStation(ctrlX V2.6.10 培训包)
`C:\Users\AGZ1WX\Desktop\To_Participants_ctrlX_V2.6.10_CN\TrainingStation\TrainingStationV5.11_CtrlXV2.6.10`

| 文件 | 说明 |
|---|---|
| `Station\Engineering\TrainingStationRunningV5.11_CtrlX.cpsp` | CpStudio 工程索引(4 行 XML,指向数据文件) |
| `Station\Engineering\Engineering_Data.xml` | OpCon 低代码模型(10MB,根元素 `<OpConData xmlns="Bosch.OpCon.Data">`,HandlerTable/LogicTable/ClassTable),纯 XML,生成器源模型 |
| `Station\Plc\TrainingStationRunningV5.11_CtrlX_PLC.project` | **PLC 工程生成物**(1,299,376 B,加密容器) |
| `Station\Plc\TrainingStationRunningV5.11_CtrlX_IO.project` | IO 工程 |
| `Station\Plc\*_PLC.Device.Application.xml` | Symbolconfiguration 导出(纯 XML,可读符号层级) |
| `Std\Objects\` | 低代码对象定义(NxUnit、NxModeHandler、NxExecUnit、NxCmdHandler…) |

**.project 格式特征**:所有 .project/.Backup 共享 15 字节头 `23 89 ED 33 14 BD 93 4B 8D A9 5D 91 08 C5 32 35`,内部无 XML 明文 → 手改不可行;IDE 脚本引擎透明加解密。

**模板目录** `C:\ctrlXWORKS\ctrlXPLCEngineering\PLE_V_0206\Studio\Templates\`:
- `Standard.project` = TrainingStation PLC 工程的拷贝(新建工程默认复制它)→ 自带完整 OpCon 骨架 + 34 个库占位符(SqM_Station_Auto/Manual/Home、SqS_Station_Homing/ChangeOverFile、StationUnit/StationExtension 钩子、Addons、Structs、EtherCAT IO 树)
- `Standard.project.bak-slim`:2026-08-04 的瘦身备份
- `Empty.project`:13KB 空白模板;另有 PLC_Templates / MotionInterface / CheckFunctions 模板组
- ⚠ 骨架模板整理(剥离培训站 IO 树/.Sync)由用户负责,改前必备份

---

## 4. OpCon / ctrlX 库清单

库仓库(CpStudio"导出库"的实际落点):
`C:\ProgramData\Rexroth\PLE-V-0206\0\Studio\Managed Libraries`(1300+ 文件)
**库一旦进入仓库即脱离 CpStudio**,占位符(`#OpconBase` 等)编译时自动解析。

### Robert Bosch GmbH – OpCon Platform Team(OpCon 框架核心)

| 库 | 版本 | 库 | 版本 |
|---|---|---|---|
| **OpconBase**(核心状态机) | 1.0.81.0 | OpconAnalogBase | 1.0.6.0 |
| OpconBaseCommonDef | 1.0.7.0 | OpconEventRecorder | 1.1.2.0 |
| OpconFbpBase | 1.0.10.0 | OpconPartCounter | 1.1.2.0 |
| AtmoBasMoveBase | 2.1.2.0 | | |

### Bosch Group(数据集 / 外设 / 系统依赖)

| 库 | 版本 | 库 | 版本 |
|---|---|---|---|
| OpconDataDefBase | 1.3.3.0 | NxFileSysDep_CXA | 1.0.5.0 |
| OpconDataSetBase | 1.1.2.0 | NxSocketSysDep_CXA | 1.0.7.0 |
| OpconDataSetManagerAddon | 1.3.2.0 | NxOpcuaSysDep_CXA | 1.0.1.0 |
| OpconPublicInterfaceBase | 1.0.2.0 | NxCtrlXSysEventAddon | 1.0.0.0 |
| OpconTcpDDL | 1.2.6.0 | NxCycleTimeAssistAddon | 1.0.3.0 |
| NxBaseSysDep_CXA | 1.0.6.0 | AtmoEcBcEx3xxx | 2.1.12.0 |
| NxFbpEcBase_CXA | 2.0.4.0 | AtmoEcBcEx600x | 2.0.6.0 |

### Bosch Rexroth AG(ctrlX 平台库)

全套 `CXA_*`:Datalayer、Motion(Ext/Interface/Printing…)、OpcUaServer/Client/Common/Ext、EthercatMaster、ModbusTCP/RTU、Python、PLCopen、FileAsync、Flatbuffers、LoopControl、RegisterControl、S20 系列、CXAC_Base/Licensing 等。

### TrainingStation 工程的 34 个库占位符

```
#Tc2_System #IecVarAccess #IecSfc #Analyzation #CXA_BASE #CXA_COMMONTYPES #CXA_UTILITIES
#OpconBaseSysDep #AtmoEcBcEx600x #OpconBase #OpconFbpBase #OpconBaseCommonDef #OpconFbpEcBase
#OpconAnalogBase #AtmoEcBcEx3xxx #AtmoBasMoveBase #NxCycleTimeAssistAddon #OpconPartCounter
#NxCtrlXSysEventAddon #OpconSocketSysDep #OpconEventRecorder #OpconDataSetBase #OpconFileSysDep
#OpconTcpDDL #OpconPublicInterfaceBase #OpconDataSetManagerAddon #OpconDataDefBase #OpconOpcuaSysDep
#IoStandard #Standard #3SLicense #BreakpointLogging #CXA_LICENSING #CXA_MODBUSTCP
```

⚠ `lm.add_library("OpconBase")` 按**名字**添加占位符会报 "could not be resolved";新增库用**文件路径**方式,或依赖模板占位符 + 仓库自动解析。

---

## 5. MCP 配置(2026-08-11 生效)

配置文件:`C:\Users\AGZ1WX\.codex\config.toml`(原始备份 `config.toml.bak_20260811`)

```toml
[mcp_servers.codesys-persistent]
command = "codesys-mcp-persistent"
args = ["--codesys-path", "C:\\ctrlXWORKS\\ctrlXPLCEngineering\\PLE_V_0206\\StudioPlc\\Common\\ctrlX-PLC-Engineering.exe", "--codesys-profile", "ctrlX PLC 2.6.8", "--workspace", "C:\\A_Documents\\A_Projects\\A_Software\\PLC_Generate", "--mode", "persistent"]

# --- fallback: old @codesys/mcp-toolkit (headless per-call, slower; kept for emergency) ---
# [mcp_servers.ctrlx-codesys]
# command = "node"
# args = ["C:\\Users\\AGZ1WX\\AppData\\Roaming\\npm\\node_modules\\@codesys\\mcp-toolkit\\dist\\bin.js", "--codesys-path", "…ctrlX-PLC-Engineering.exe", "--codesys-profile", "ctrlX PLC 2.6.8", "--workspace", "C:\\A_Documents\\A_Projects\\A_Software\\PLC_Generate"]
```

### 两个 MCP 包对比

| | codesys-mcp-persistent v0.6.3 ✅当前 | @codesys/mcp-toolkit v1.1.16(回退) |
|---|---|---|
| 作者 | luke-harriman / Codesys-MCP(2026-05 更新) | johannesPettersson80 |
| 架构 | 常驻带 UI 的 IDE + watcher 线程 + %TEMP% 文件 IPC,命令延迟 ~50ms | 每次调用新起无头 IDE,15~100s/次 |
| 规模 | **44 工具 + 3 resource** | 8 工具 + 3 resource |
| 编译反馈 | compile_project 返回结构化结果;get_compile_messages | 只触发 build,不回结果 |
| 读代码 | get_all_pou_code / search_code / find_references(工具级) | 仅 resource 通道 |
| 在线 | connect/download/start_stop/read_write_variable/monitor/simulation | 无 |
| ctrlX headless | ❌ 回退模式无品牌 IDE 退出补丁(60s 超时)→ **必须 `--mode persistent`** | ✅ 内置 ctrlX Environment.Exit 补丁 |

### persistent 工具清单(44)

- 会话:launch_codesys、shutdown_codesys、get_codesys_status、eval_python(兜底任意 IronPython)
- 工程:open_project、create_project、list_project_templates、save_project、create_project_archive
- 代码编辑:create_pou、set_pou_code、create_property、create_method、create_dut、create_gvl、create_folder、delete_object、rename_object
- 读取/搜索:get_all_pou_code、search_code、find_references、rename_symbol;resource:project-status / project-structure / pou-code
- 编译:compile_project(结构化结果)、get_compile_messages
- 库:add_library、list_project_libraries
- 设备树:add_device、list_device_repository、inspect_device_node、set_device_parameter(实验)、map_io_channel
- 在线:connect_to_device、set_credentials、set_simulation_mode、disconnect_from_device、get_application_state、download_to_device、start_stop_application、read_variable、write_variable、monitor_variables

### 运行机制

- IPC 目录:`%TEMP%\codesys-mcp-persistent\<sessionId>\`(commands/ results/ watcher.py ready.signal terminate.signal)
- watcher 在 IDE 内 `--runscript` 启动,50ms 轮询,命令经 `execute_on_primary_thread` 调度到 UI 线程;互斥串行;默认超时 60s(编译 120s);健康监控 5s/次;重启自动接管存活会话
- IDE 同时开 REST API:`http://localhost:9002`(Swagger: plc-engineering-api-v2.json)——备用通道

---

## 6. 已验证结论(实测 2026-08-06 ~ 08-11)

| # | 测试项 | 结果 |
|---|---|---|
| 1 | MCP 打开 TrainingStation .project 副本(加密容器) | ✅ 脚本引擎透明解密 |
| 2 | create_pou 建 MCP_TestPRG + set_pou_code 写声明与实现 | ✅ 自动保存 |
| 3 | 读回校验(textual_declaration.text / textual_implementation.text) | ✅ 逐字一致 |
| 4 | TrainingStation 副本全工程编译(含 AI 新增 POU) | ✅ **0 errors, 2 warnings**(C373 为生成代码自带) |
| 5 | create_project 新建 AI_Only_Test.project | ✅ 自带 OpCon 骨架 + 34 占位符,编译 0 errors → **PLC 侧可完全绕开 CpStudio** |
| 6 | MCP resource 读回 structure / pou-code | ✅ |
| 7 | add_library 按占位符名字添加 | ❌ "could not be resolved" → 用文件路径 |
| 8 | ctrlX IDE 内脚本返回后后台线程存活(persistent 核心机制) | ✅ 返回后 2s/6s 信号均写出 |
| 9 | se.system.get_messages() / lm.get_libraries() / app.build() | ✅ |
| 10 | headless 模式用于 ctrlX 品牌 IDE | ⚠ 不可用(无退出补丁) |

测试产物:`C:\A_Documents\A_Projects\A_Software\PLC_Generate\TestOes\mcp_test\`
(TS_PLC_TEST.project 含 MCP_TestPRG、AI_Only_Test.project、readback/build/libs/addlibs/struct 脚本、watcher_probe 探针)

---

## 7. 2026-08-12 persistent 上线验证与修复

> 当日完成 codesys-persistent v0.6.3 在 ctrlX IDE 上的完整上线验证,修复 MCP 包 CRLF 缺陷 1 处,明确多实例竞态与 eval_python 两条操作红线。

### 7.1 persistent 正式生效

- `config.toml` 已启用 `[mcp_servers.codesys-persistent]`(v0.6.3,44 工具,`--mode persistent`);旧 `@codesys/mcp-toolkit` 块注释保留为应急回退(配置详情见 §5)
- headless 在 ctrlX 品牌 IDE 不可用(无退出补丁)→ **persistent 为唯一可行路线**;IDE 以可见窗口启动,会话跨调用常驻,Codex 被强杀后下次启动自动接管会话
- Resource server 名:`codesys-persistent`;URI:`codesys://project/{path}/structure`、`.../pou/{pou_path}/code`、`codesys://project/status`

### 7.2 CRLF 缺陷与补丁(重要)

- **症状**:`compile_project` / `get_compile_messages` 报 `SyntaxError: unexpected token '\r'`
- **根因**:MCP 包 `_message_utils.py` 混入 1 处 CRLF;ctrlX IronPython 脚本引擎 `exec()` 不容忍混合行尾(helper 代码以 LF 注入 + 模板脚本为 CRLF)
- **补丁位置**(`C:\Users\AGZ1WX\AppData\Roaming\npm\node_modules\codesys-mcp-persistent\dist\scripts\`):
  1. `watcher.py` 第 162 行后(读入命令脚本之后)插入行尾归一化:`script_code.replace("\r\n","\n").replace("\r","\n")`,注释标记 `ctrlX PATCH (2026-08-12)`;原文件备份为 `watcher.py.bak_orig`
  2. `_message_utils.py` 全文 CRLF→LF(已验证 0 处 CRLF)
- **效果**:compile_project / get_compile_messages 恢复正常,返回结构化编译消息
- ⚠ **npm 升级该包会覆盖补丁**,升级后必须重跑 `patches/codesys-mcp-persistent-crlf/apply-crlf-patch.ps1 -Check` 并应用；该脚本同时维护 §7.7 的 connector I/O Mapping 与 §7.8 的有界编译消息扩展

### 7.3 多实例竞态:IDE 自行退出

- **症状**:早晨 IDE 自行退出(exit code 0),MCP 工具全部超时
- **诊断**:3 个并行 node MCP server 进程(PID 19712/23932/26240)各自启动 IDE,争抢同一 profile `ctrlX PLC 2.6.8`,在约 60s ready 窗口内竞态导致退出
- **规则**:**同一时间只允许一个 Codex 窗口使用本 MCP**;ready 后新 server 会接管既有会话;工具列表偶发闪断(多 server 实例并存所致)重试即可

### 7.4 eval_python 陷阱

- 对已打开工程裸调 `se.projects.open()` 会**卡死 IDE UI 线程**(疑触发模态对话框),阻塞整个命令队列 → 恢复手段仅 `shutdown_codesys`(有 SIGKILL 兜底)+ 重启
- 正确姿势:用 `se.projects.primary` 取当前工程,或直接走正规工具(open_project / set_pou_code / compile_project…)
- `timeoutMs` 参数必须传 number,不能传 string

### 7.5 冒烟结果

- IDE PID 3548(08-12 09:18:57 启动),session `9094d883`,状态 ready;`TS_PLC_TEST.project` 已打开
- compile_project:**0 errors, 35 warnings**(全部为 Loc*/SqC*/SqM* 符号配置引用警告,培训样板工程固有);IDE 构建日志 `Build complete -- 0 errors, 69 warnings : Ready for download`(结构化消息与完整日志统计口径不同,以 errors=0 为准)
- 说明:get_compile_messages 曾出现的 iCounter/bMcpActive 两条 error 系早晨坏会话的陈旧消息(该工具返回上次编译的缓存);POU 代码经 pou-code resource 验证完好,重新编译后缓存已刷新

### 7.6 分工再确认

- 干净的 OpCon 骨架模板现在不由 AI 代做;之后**用户做骨架**(CpStudio 层级/HMI/模板),**AI 负责 PLC 代码细节**(自动/手动、SqM/SqS、工艺逻辑)——与 §0 一致;骨架就绪前 AI 不启动阶段 3

### 7.7 ctrlX connector I/O Mapping 与 Symbol Configuration REST（2026-08-18）

- **复现背景**：CpStudio 修改/停用 I/O BMK 后，`BinIo` 声明会更新，但 PLC 工程可能同时残留 EtherCAT connector mapping、AI-owned/mixed ST 直接引用和 Symbol Configuration 旧选择。典型结果是 `bus_<旧名> is no component of BinIo` 编译错误，以及 `variable is no longer available ... still configured` 警告。
- **ctrlX 通道结构**：DataLayer/EtherCAT 模块的通道不是 `device.get_children(False)` 子节点，而是：

  ```text
  device.connectors → connector.host_parameters
    → parameter.is_mappable_io → parameter.io_mapping.variable
  ```

  因此原版 `map_io_channel` 在 `inspect_device_node` 返回 `children: []` 时无法定位通道。兼容补丁增加按通道名（如 `Channel_6.Output`）或零基索引查找 connector 参数，并在写入后强制回读验证。
- **Symbol Configuration 正式接口**：PLE 2.6.8 自带 REST API，稳定基地址为 `http://localhost:9002/plc/engineering/api/v2`；不要依赖偶尔可用的根路径兼容路由。应用下的接口为：

  ```text
  GET /devices/Device/Plc%20Logic/Application/symbol-config
  PUT /devices/Device/Plc%20Logic/Application/symbol-config?symbolsAction=Select|UnSelect|UpdateAll
  ```

- `GET` 只返回当前编译器可用成员。对响应中可枚举且能唯一核验的目标可以使用 `Select/UnSelect`；对 GET 不可见的 orphan 不得猜测类型、路径或 payload 执行精确 `UnSelect`。`UpdateAll` 也不证明隐藏旧选择已经删除。`GET` 中已选成员的 `accessRights` 可能显示 `Void`，实际持久化权限应以底层 `SelectedTypes`/编译结果复核。
- **验证结果**：Station010 两个独立 CpStudio 导出批次均通过该闭环恢复到 **0 errors / 7 baseline warnings**；第二批仅清除 C1 `Channel_6.Output` 的旧映射与 `_000SK010C1_Channel_6` 符号成员，全程未使用 UI 自动化或 `eval_python` 写工程。
- **2026-08-22 EtherCAT 单通道双向实测**：固定顺序为 `CpStudio Save → Write designators → Export #1 → Link I/O → ownership/mixed ST 引用审计与语义合并 → Build 0 errors → 条件 Export #2 → final Build`。Save、Write designators、Export 和 Link I/O 分属不同层，不能相互替代。Export #1 因 Build error 产生的 OPC UA Method、PersistentVars 和 Symbol 错误通常是下游连锁结果，先消除 `BinIo`、mapping 和代码旧引用。
- **Symbol 并发边界**：CpStudio Export 期间禁止 REST/MCP/UI 并发读取或写入 Symbol Configuration。若出现 `This object is already in use`，先停止并发访问；锁仍存在时只在同一 PLE 进程内 Save → Close → Open，重新 Build 后再 Export，禁止启动第二个 PLE。Build 0 errors 后由 CpStudio 条件二次 Export 协调当前选择；隐藏旧项仍存在时先重开验证，最后才用编辑器 `Remove...`，不裸用 `UnSelectAll`。
- **产品化**：`patches/codesys-mcp-persistent-crlf/apply-crlf-patch.ps1` 已扩展为 ctrlX 兼容补丁入口，同时修补 npm 包 `dist/scripts` 与 `src/scripts` 的 `map_io_channel.py`。脚本幂等，npm 升级后先 `-Check`。

### 7.8 `compile_project` 完成后超时（2026-08-20）

- **症状**：PLE 的 Application Build 已完成，MCP `compile_project` 仍运行到 300 s 超时；只读的 `get_compile_messages` 也可能继续阻塞。
- **根因**：原脚本先执行 `clean()`/`clean_all()`/`build()`/`generate_code()`，再动态遍历全部消息类别，并对每类逐个读取 Fatal/Error/Warning/Information/Text。ctrlX PLE 2.6.8 的 `get_message_objects(category, severity)` 在该组合扫描中会卡住数分钟；PLC 编译本身不是瓶颈。
- **兼容路径**：应用工程只调用一次官方 `ScriptApplication.build()`；编译后只读 Build 与 Additional code checks 两个类别，每类调用一次 `System.get_messages(category)`。error/warning 总数以 IDE 自身的 Build summary 为准；拿不到 summary 时按错误失败关闭，禁止把未知结果当作 0 errors。
- **覆盖范围**：同一补丁同步修改 npm 包 `dist/scripts` 与 `src/scripts` 中的 `_message_utils.py`、`compile_project.py`、`get_compile_messages.py`；`test-fast-compile-message.py` 离线覆盖干净、失败、Application current 与未知摘要四类情况。
- **实测**：Station010 离线 Build 从 MCP 超过 300 s 降到约 **7.6 s**（0 errors / 7 warnings），缓存消息读取约 **0.8 s**；未连接、下载或运行实体 PLC。

---

## 8. 脚本 API 速查(IronPython 2.7,ctrlX 脚本引擎)

```python
import scriptengine as se
import System
proj = se.projects.open(r"C:\...\X.project")   # ScriptProject 无 get_name()
app  = proj.active_application                 # "Application"

# 遍历(动态成员,dir() 看不到;get_child 不存在,用迭代)
for k in app.get_children(False):  k.get_name()

# POU 读写
pou.textual_declaration.text        # 声明文本
pou.textual_implementation.text     # 实现文本
pou.textual_declaration.replace(s)  # 写文本

# 库
lm = [k for k in app.get_children(False) if k.get_name()=="Library Manager"][0]
lm.get_libraries()                  # 34 个 "#占位符"
lm.add_library(...)                 # 按名字加占位符会失败

# 编译（应用工程只做一次官方 Build）
app.build()                         # Build 类别输出 IDE summary
build_category = System.Guid("{97F48D64-A2A3-4856-B640-75C046E37EA9}")
se.system.get_messages(build_category)  # 每个类别一次；不要全类别×严重级别扫描

# 退出(品牌 IDE 不自动退):脚本末尾
System.Environment.Exit(0)
```

手动运行:
```
ctrlX-PLC-Engineering.exe --profile="ctrlX PLC 2.6.8" --noUI --runscript="脚本.py"
```
(工作目录设为 exe 所在目录)

---

## 9. 项目实施路线

- [x] **阶段 0 · 环境基线**(2026-08-11 完成,08-12 persistent 上线验证通过 → 见第 7 章):MCP 切 persistent;库/模板/样板盘点;~~干净骨架模板~~ → 归用户职责,不阻塞
- [ ] **阶段 1 · CpStudio 模型(用户,持续使用)**:层级/标准对象/HMI/Event/StationData/BMK → 生成;检查点 = PLE 打开编译 0 error,符号配置与 HMI 对上
- [ ] **阶段 2 · 硬件与 IO 组态(用户)**:默认 IP 网页 → EtherCAT → ctrlX IO Engineering;IO 符号对接(map_io_channel 可 AI 辅助)
- [ ] **阶段 3 · AI 填充逻辑(主力)**:get_all_pou_code/search_code 读骨架 → 写 SqM_Auto/Manual、SqS、工艺逻辑(参考样板 = TrainingStation 生成代码)→ compile(结构化错误)→ 修复 → save;自定义代码放独立 POU/文件夹并带项目前缀
- [ ] **阶段 4 · 下载调试**:set_simulation_mode 先验证 → 真机 connect/download/start_stop → read/write/monitor;里程碑 create_project_archive
- [ ] **阶段 5 · 迭代**:模型/HMI/BMK 改动回 CpStudio；应用逻辑按 ownership 走 MCP/REST；每次导出进入独立离线审计队列

---

## 10. 规则与红线

- 🔴 `write_variable` 是**强制写值(FORCE)**,不解除一直生效;真机操作前确认安全状态。download/start_stop 对真机有实权
- 🔴 不手改 .project 字节（加密容器）；CpStudio 导出后先 diff/ownership 审计。先确认集成 Git 可恢复精确起点，不能恢复时只建一个内容寻址 checkpoint，不重复保存哈希相同备份
- 🟡 每个 MCP 会话弹出可见 IDE 窗口(设计如此,便于监督);勿在窗口内做与 AI 冲突的手动修改
- 🟡 勿同时打开多个使用 codesys-persistent 的 Codex 窗口(多实例竞态致 IDE 退出,见 §7.3)
- 🟡 Codex 被强杀可能残留 IDE:下次启动自动接管,失败则手动结束(查 %TEMP%\codesys-mcp-persistent 会话目录)
- 🟡 eval_python 可执行任意 IronPython,谨慎使用;**勿对已打开工程裸调 `se.projects.open()`**(卡死 UI 线程,见 §7.4)
- 🟢 版本线:PLE 2.6.8 打开/编译 2.6.10 培训包工程无碍;更新版本生成的工程打开时留意转换提示
- 🟢 恢复约定：优先使用 Git、可读源码和对象级指纹；只有现有事实源不能恢复时才创建单一受控 checkpoint

---

## 10.1 跨项目产品化基线（2026-08-20）

- `scripts/New-CtrlXOpconProject.ps1` 是新 OpCon/ctrlX AI 旁车的唯一初始化入口；先 `-WhatIf`，目标存在即拒绝，不复制 Station、Std、`.project` 或闭源资料
- `templates/ctrlx-opcon-project/` 是模板事实源，生成项目自带静态门禁与可执行 Post-export 离线审计队列
- `skills/ctrlx-opcon-engineering/` 是 Codex 工作流/安全层；Skill 组合流程，项目事实仍来自当前项目的 `config/specs/ai/src/catalog`
- Post-export 使用 `pending → processing → done/failed` 独立请求；hook 本身不得启动 PLE/MCP，消费者必须把 Station/PLC 路径与 `config/project.yaml` 强一致校验
- MCP 继续按 `docs/mcp_productization_roadmap.md` 产品化：受控 fork、跨进程租约、异步 operation、`project_health`、`compile_project_v2`、FORCE 生命周期、`apply_change_set`，再实现正式 Symbol/I/O/SFC 接口

---

## 11. 故障排查 FAQ

| 症状 | 处理 |
|---|---|
| MCP 工具全部超时 | get_codesys_status → launch_codesys;查 %TEMP%\codesys-mcp-persistent\<session>\watcher_error.txt |
| ready.signal 不出现 | profile 名必须精确 `ctrlX PLC 2.6.8`;exe 路径是否变动 |
| 打开工程报版本不兼容 | 工程由更新 PLE 生成 → 先在 IDE 手动打开一次完成转换 |
| 编译报占位符库缺失 | 库不在仓库 → CpStudio 导出一次或 add_library(文件路径) |
| 想回退旧工具链 | config.toml 两个 mcp_servers 块注释对调,重启 Codex |
| 残留 ctrlX-PLC-Engineering 进程 | 按 StartTime 甄别后再杀,别杀用户实例 |
| 编译脚本报 `SyntaxError: unexpected token '\r'` | CRLF 缺陷 → 按 §7.2 打 watcher.py 行尾归一化补丁;注意 npm 升级会覆盖补丁 |
| `map_io_channel` 报 Channel not found，且设备 `children: []` | ctrlX 通道在 connector mappable parameters，不是树子节点 → 重跑兼容补丁并按 `Channel_6.Output` 形式定位，见 §7.7 |
| CpStudio 改 EtherCAT BMK 后出现旧 `bus_*` error 或 Symbol warning | Save → Write designators → Export #1 → Link I/O → 审计 mixed/AI ST 旧引用 → Build 0 errors；仅在后处理失败或目标未选中时再 Export #2 和 final Build，见 §7.7 |
| IDE 自行退出(code 0)且当时开了多个 Codex 窗口 | 多实例争抢 profile,见 §7.3:只保留一个窗口;ready 后新 server 自动接管 |
| eval_python 卡死整个 MCP 队列 | shutdown_codesys 强杀重启;已打开工程用 se.projects.primary,勿裸调 projects.open() |
