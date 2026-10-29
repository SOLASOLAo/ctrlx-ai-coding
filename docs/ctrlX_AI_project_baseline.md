# ctrlX AI 项目基线记录(MD 版)

> Persistent MCP + Control plus Studio 混合工作流
> 记录日期:2026-08-11 · 更新:2026-10-29（现有工具发布基线）· 环境:已验证工程工作站
> 配套 HTML:`ctrlX_AI_project_baseline.html`(同目录)

---

## 发布基线与后续开发（2026-10-29）

本仓库继续维护现有 CpStudio/PLE 工具、兼容补丁、工程 skill、只读 Data Layer 工具与研究样例。
安装版 skill 的原生批量操作、库文档及可执行风格检查规则已回收至维护源。
下列章节保留各次验证的版本、范围及历史时间，不代表当前正在运行的 IDE、设备或部署状态。

新的统一 MCP 在 [ctrlx-engineering-mcp](https://github.com/SOLASOLAo/ctrlx-engineering-mcp)
私有仓库独立研发，初始阶段为方案和开发记录。第一阶段范围是 PLE/CpStudio 离线工程开发及
CORE 只读诊断，IOE/WORKS 分模块扩展；不新增采购，不默认使用 GUI，不抢占共享工程会话。
旧工具的存在和历史测试不代表新 MCP 已实现或获得运行验收。

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
- **只读 Build 门禁（2026-08-23）**：兼容补丁移除了 `compile_project.py` 的 dirty-project 自动 `save()`；若 freshly opened 工程为 dirty、无法读取 dirty 状态，或补丁/包版本门禁不通过，离线检查器在 Build 前失败关闭。检查器只以隔离 TEMP 中本次生成的 summary/messages 作为决策证据，缓存消息仅作附录。
- **Export #2 anchor（2026-08-23）**：离线检查器只接受“fresh、verified、0-error 的 Export #1 Build”与当前带时间戳 request 产生的 anchor，并要求其后出现更新的 CpStudio request。无可关联 request 时回到 Export #1、不创建 anchor。对象占用、次数纠正、Output 确认和 Build 前 Link I/O 可继承同一 anchor；Export #2 一旦进入 Build 即消费，终态或已尝试 Build 的报告不能复活旧 anchor。全局锁覆盖 anchor 读取到报告写入，任何锁获取失败均不落报告。
- **覆盖范围**：同一补丁同步修改 npm 包 `dist/scripts` 与 `src/scripts` 中的 `_message_utils.py`、`compile_project.py`、`get_compile_messages.py`；`test-fast-compile-message.py` 离线覆盖干净、失败、Application current 与未知摘要四类情况。
- **实测**：Station010 离线 Build 从 MCP 超过 300 s 降到约 **7.6 s**（0 errors / 7 warnings），缓存消息读取约 **0.8 s**；未连接、下载或运行实体 PLC。

### 7.9 Controlled Runner 真实 PLE 技术通道（2026-08-28）

- 唯一 interactive Broker 持有 persistent MCP/PLE；immutable action 只允许固定的 status、fresh Build 与 read-only semantic snapshot，不提供 generic 或在线工具面。
- 受控 adapter 返回 same-call `buildId`、固定类别 typed warnings，并递归采集声明 scope 下的 ctrlX connector I/O Mapping 与 Application Symbol Configuration 摘要。PLE REST 必须使用 `localhost`；Symbol payload 若因 IEC 文本未转义而不是合法 JSON，只在 adapter 内做有界规范化/哈希，原始 payload 不跨 MCP。
- Station010 实测 fresh Build 为 **0 errors / 101 条可见 warnings**；其中包含 PLE 的 `>100 warnings` 截断哨兵，所以这不证明完整告警全集。semantic snapshot 为 456 条 mapping facts（438 bound / 18 unbound）。mapping SHA-256 为 `491B719C...A5086`，Symbol SHA-256 为 `3FE32193...E686F`。
- PLC project 与结构哈希在 action 前后完全一致；未修改 PLC/IO/ST，未连接 PLC、下载、启停 runtime、写变量或 FORCE。
- 没有经用户明确确认的 warning/semantic baseline 时，action 必须以 bootstrap `BLOCKED` 结束。Runner 可以生成 deterministic candidate，但不得自动晋升为正式 baseline；正式文件只记录 `confirmedByUser: true`、机器生成的时间/ID 和独立 evidence hash，不采集姓名或工号，并通过新的 immutable action 复验。包含截断哨兵的 warning population 由 Broker、Stage 1、Stage 2 和 evidence sealer 以 `PLE_WARNING_OUTPUT_TRUNCATED` 失败关闭，不能批准为正式 baseline。

---

### 7.10 CpStudio 原生桥接隔离验收（2026-10-07）

按用户授权，CpStudio V5.11.0.169 的实验性进程内适配器已在 ST60 隔离副本通过原生调用。
自有 x86 宿主通过 `AppDomain.ExecuteAssembly` 启动原供应商程序，再由独立 DDP 配置加载
自有桥接；未修改供应商安装文件。固定命令覆盖 Reload definitions、精确 OOD 版本计划、
Apply and reload、Parse、完整模型/工程 Save、Export 和关闭。每次操作检查当前工程身份，
版本计划复用原生依赖校验，拒绝未指定的版本变更；回执超时不自动重放。

Machine Common OOD0.1.2.6→隔离测试0.1.2.7 已完成 Apply/reload、保存及冷重开回读；仅测试
OOD 版本头改变，PLC 库仍0.1.1.1，不构成组件发布。模型343667节点保持，结构比较仅有目标
版本/基引用更新及一项原生保存名称更新。便携脚本随后将测试版本还原0.1.2.6，拒绝不存在的
99.99.99.99，在保存后关闭测试实例。

ST60 隔离验收 `d22cfc20-12d4-4cdf-9cec-fc10347cdbf7` 已完成原生 Parse→Save→Export→PLE
原生编译/保存：0错误/9条既有警告，316源码、158 I/O绑定、939 Symbol权限及保护检查通过。
没有鼠标、UIA、热键输入或实体操作；测试 Post-export 仅为独立观察脚本，不等于正式队列
Stage1/Stage2验收。正式 CpStudio 窗口保持，未对正式工程执行上述写命令。

源码与执行/恢复边界见[原生桥接说明](../skills/ctrlx-opcon-engineering/references/cpstudio-native-automation.md)。
原有入口仍用于隔离副本宿主。2026-10-16 新增可选常驻插件：通过独立加载序列扩展注册，
正常启动原版 CpStudio 后可连接现有实例。ST40 隔离副本已验证自动加载、状态/诊断读取、
进程内 owner 拒绝、释放和正常退出失效；正式窗口未重启。安装前已打开的窗口仍需当前
owner 保存后正常重开一次，不支持热注入。正式工程写入及其他版本仍待对应验收；它不是
供应商支持的外部 SDK。GUI 路线仍保留，原生要求不降级为鼠标操作。

2026-10-11 增加 `Invoke-CpStudioLibraryUpdate.ps1` 单次调用入口：复用现有原生客户端，
按精确 OOID/OOD 版本执行 Reload definitions→Plan→Apply and reload→Parse→完整 Save→Export，
保留六步原生回执；失败或完成未知即停止，不重试/回滚/开第二个 IDE。六项离线流程检查通过，
不接触工程会话。该新组合入口尚未实际原生整链验收；不扩张上述隔离命令验收范围，不接管
stock 窗口，不替代编译库安装、更新前 PLC 增量保存或导出后源码/I/O/Symbol/SFC及消费者编译核对。

新增只读 `diagnostics` 与 Export 成败回执的消息明细：从桥接就绪起订阅原生
`MessageHandler.Changed/OutputChanged`，读取 `Repository` 中的文本、原生级别和来源，
按操作 UUID 区分当次消息，保留最近512条并报告丢弃数；不补读旧输出历史、不调用PLE/REST。
诊断读取成功与上次Export成功分开记录，PLE编译0错误也不能证明Export成功。已完成离线
消息模拟检查与x86宿主/桥接编译。owner新宿主的失败Export
`e143d5f2-ad9f-4160-9e47-27feac217c65` 实际捕获499条操作消息，captureError为0，
其中377条Output错误包括371条REST阻塞错误与6条已有目录/对象冲突；全局丢弃190条。
这证明实际消息收集，不证明Export成功或错误根因。旧宿主缺少命令时客户端在写请求前
拒绝，不热换正在运行的DLL；便携源码现为五文件。

### 7.11 PLE 固定脚本原生入口（2026-10-07）

一键流程的 PLE 阶段已替换 Tools/Scripting GUI 入口，复用现有 persistent MCP 的
`IpcClient`/watcher，再调用原生 ScriptEngine 执行器；不是新建标准 MCP tool、服务或第二个 IDE。
裸 watcher `exec()` 缺少在线API执行上下文，曾出现 `Stack empty`；新入口通过原生执行器解决。
新会话首次打开工程应先原生编译解析库类型namespace，预检不接受未解析的Symbol权限基线。

后续只读IL核对发现原生便利入口创建执行器但未Dispose；原生进度Finish本已有finally。
共享dispatcher改为CreateScriptExecutor取得自有执行器，公开ProgressCallbackFactory设为
None，LoadDrivers/Execute后finally Dispose；不释放借用服务，不清除既存全局状态。
回执增加executorDisposed/cleanupUnknown，缺释放标记时保持锁，不能仅凭阶段结果认领成功。
13项Node离线检查通过。owner受控重启后的隔离PID31720实际preflight/component回执均
complete=true、executorDisposed=true、cleanupUnknown=false，已只读磁盘核对；仅确认
这两阶段的原生执行与释放，改动后build、Export及REST恢复需各自结果。

REST阻塞门禁实际读取Engine.LengthyOperationIsActive，全Done的REST jobs不能排除该门禁。
owner发现语言模型更新的工程句柄-1异常；Continue后脚本读False，新Export仍阻塞失败，
异常与门禁因果/线程上下文未证实。不得写私有flag、关闭REST guard或自动重试；本轮仅修改
共享工具，未操作任何工程会话。

交接后owner报告新Export `e0c89618-953f-44ea-83e0-2347f7b14bbd` complete=true、
nativeExportSuccessful=true、无notifications，随后typed编译0错误/9条既有警告。
这是受控重启与入口修正组合后的结果，不能归因于单一改动；消费者Symbol迁移、完整源码/
硬件保护检查仍由owner继续，尚不认领完整消费者或现场验收。

owner随后反馈finish_consumer通过：316源码、30hooks、158 I/O、旧939 Symbol权限保留/
迁移后942、Clean Build0错误/9警告、Generate Code0错误/10警告，8项SFC保护比较通过。
SFC比较当次使用启动器加载维护模块，暴露read_graphs.py只从engineeringRoot导入依赖的
便携缺口。共享reader改为优先直接加载项目scripts/plc/sfc_graph_key.py，缺失时加载自身
asset相对路径的固定维护文件；已有项目模块出错不回退，比较算法未改。7项离线graph检查
通过，未联系工程REST/PLE；正式离线文件同步及新正式编译仍由owner继续。

ST60隔离副本实际预检、Clean Build、保存通过：0错误/9条既有警告，316源码对象、158条
原生I/O绑定、939项Symbol权限；同一PID保持不变，测试会话随后保存退出。
CpStudio 正式工程整链未重跑；§7.10 的新增隔离原生验收独立于2026-10-05旧GUI整链记录。
复用源模板与会话/失败处理见[PLE原生脚本](../skills/ctrlx-opcon-engineering/references/ple-native-script.md)。

库开发入口另增加 `component` 阶段：唯一现有 owner 提供当前 PID/profile、精确 `.library`
或隔离消费者 `.project`、授权目录和已审查 `scripts/ple/*.py` 的内容指纹。固定原生 wrapper
验证当前工程、离线状态和暂存源码后执行文件，回执包含实际库 title/company/version、脚本
证据及保存状态；不是任意代码字符串工具或 Python 沙箱，不代替版本/导出物/安装/运行验收。
ProjectInfo、编译库导出/安装和已审查批量导入可用此入口；DUT/方法/ST继续优先typed MCP。
本机补丁版 `compile_project` 已识别 `.library` 并调用池对象检查，`clean_compile_project`
仍要求 Application；[池对象检查](https://content.helpme-codesys.com/en/CODESYS%20Development%20System/_cds_cmd_check_all_pool_objects.html)
是语法检查，仍需编译库和最小消费者验证。组件入口通过10项Node传输检查与3项CPython
原生API模拟检查，本次未接触INNTAI/ST60会话；实际原生库验收由现有owner完成。

已发布 PLC 变量和 App 状态的调试另走 [CORE Data Layer 只读入口](../skills/ctrlx-opcon-engineering/references/core-datalayer-readonly.md)
（2026-10-27）：技能自带 Python 标准库脚本，明确目标、复用本机目标配置认证，支持 GET 读取、
浏览、元数据和有时限 SSE；不启动或占用 PLE/CpStudio。ST60 原始脚本已实测认证与真实发布变量
订阅，本次技能收录只做离线验证。未发布变量且共享工程被排除时报告缺口，不自动登录/导出；
没有变量写入、FORCE、启停、机器人恢复或自动重发入口。

### 7.12 PLE broker 生命周期超时与离线诊断（2026-10-08）

INNTAI owner报告1.0.3.1编译库本机仿真24/24通过，唯一broker PLE PID28864/session
`4d9e4f34-c369-4e0c-bbba-4ded0c314e11`，offline component正常确认Dispose。
stop/logout与保存后，Close请求 `7b952e83-629a-4073-bae3-5b3aa1e6376c` 超时且无终态，
后续Open/只读eval未确认处理；之前首次Open超时后曾迟到成功。库和工程已由owner保存，
生命周期请求仍为completion unknown，不能按失败重放或指定某个executor为根因。

只读源码确认watcher先调用execute_on_primary_thread，返回后才WaitOne(120000)；
停在Marshaling不能证明两分钟wait已开始。IPC超时会删命令文件，不能据缺文件认领取消。
只读IL确认ScriptProject.close转交原生IProject.Close并丢弃返回值；ScriptOnline订阅
Executing/Executed来Push/Pop及清理实例，with_executor借用executor、finally清理Python
临时变量。本轮8项离线double检查未发现可归因的Python清理缺口，不证明故障会话原生清理。

共享watcher/兼容补丁增加带请求ID的dispatch、callback entry、marshal return日志，未改
执行、超时或全局flag。隔离adapter apply/check/语法回归及便携diff应用检查通过。
改动仅在源码/skill，未修改安装broker、当前watcher或任何工程会话；诊断日志需未来owner
安排维护及受控启动才生效。原Close终态及具体阻塞点尚未确认。

后续owner报告旧PID28864已通过broker shutdown停止并确认进程不存在；这不补记原Close
成功或失败。新PID18304的隔离ReferenceProject Open请求
`f2be04b5-5a4d-4dc5-b5f2-bee4a2b7340f` 约188秒后产生success=true迟到磁盘回执；
owner以fresh只读native审计确认目标工程/dirty=false，typed编译0错误/4警告及native
preflight1241cf18通过。Computer Use只读观察/激活未发现模态，不能由时间顺序认定激活
导致恢复，也不能把该结果推及旧Close。此处按owner交接事实记录，维护者未操作会话。

同一Reference的原生Apply/Parse/Save已到1.0.3.1，但Export
`0879212b-608d-45a5-b235-c90f5a584462` 明确失败：UpdateSymbolConfig返回JSON Reader
`Invalid property identifier character '{'`，位置types[39].variables[3].attribute/
line11052。owner确认209源码及1条自有SFC未变、dirty=false；不认领Export成功或完整
消费者验收。症状与既往PLE2.6.8 Symbol HTTP响应问题相似，本次根因未证实；owner正在
复用会话内BufferedSymbolResponse，未修改厂家文件、blocking flag或安全设置，效果待验收。

### 7.13 typed stop/logout 与原生库引用读回（2026-10-10）

INNTAI owner反馈1.1.0.1库/隔离消费工程编译均0/0，本机Simulation35/35且无实体操作。
本轮只读磁盘runtime证据与component回执635219e8-7136-4566-941c-a82f7f9f63e5，确认
complete/executorDisposed=true、cleanupUnknown=false；未使用其PLE或ST60持有的会话。
旧stop/disconnect成功回执不能共同证明logout；stop本身也不应被解释为退出登录。
owner用受限Virtual/Simulation辅助脚本，在RUN时stop后logout并断言is_logged_in=False。

源码明确存在两项缺口：disconnect把构造/logout异常当成功；list_project_libraries用
Library Manager树子节点代替get_libraries，空树可能仍有InntaiLeakTest1.1.0.1原生引用。
共享兼容补丁新增三个producer及必要server helper wiring：状态调用复用with_executor，
start/stop按实际目标状态读回确认、已达状态不重复调用，disconnect必须读回False；库引用
用选定Application的原生manager枚举，未知scope/manager或枚举失败不输出假空列表。
三工具仅接受已是primary的预期工程，不隐式open/切换/保存；未知自定义模板拒绝替换。

20项离线double测试、隔离apply/check/语法和既有回归通过，便携server diff及模板一致性
通过；当前npm broker/PLE未修改。修正源码纳入skill，原生新路由及其他平台仍待owner验收。
参数策略依INNTAI用户最新要求：WP收到OK即完成、不自动RP比较，早期同通道WRITE_VERIFIED
要求已被覆盖；这是该组件策略，不推广为所有设备协议规则。

### 7.14 CpStudio Variables / Struct 通用添加（2026-10-16）

新增固定命令 `inspectModel`、`planModelAdditions`、`applyModelAdditions`，由原生桥接及
`Invoke-CpStudioNative.ps1 -ModelRequestFile` 提供。独立 `CpStudioNativeModel.cs` 使用供应商
Data/Components 模型 API 的 AddData、AddStructInst 及结构/数组接口；不修改工程 XML，
不向 PLE 绕过模型补声明，不新增任意脚本/反射、删除、批量改类型或配方值写入接口。

目标使用完整 path/GUID/modelType，类型引用要求精确身份；显式同批声明的结构可按该
声明引用。预览封存在本进程，以 planId 应用；类型、数组边界、同名/大小写冲突、递归
引用或模型状态漂移明确拒绝。同形已有项按 unchanged 处理，重复成功应用核对现状后
不再创建。原有 Types/Variables 声明、身份及可读值在添加前后比较，保存/导出仍分别执行。
支持12种原生基本类型、字符串长度、结构定义/成员/实例及1至3维定长数组；容量最多4096，
数组上下界显式提供。供应商以 -1 标记未使用维度，而不是0；该细节已用实际回读纠正。

在 ST40 冻结检查点的独立副本中验证：24项显式声明及原生传播节点已添加，8739项原有
索引记录保持；17项原生正反向检查通过。两枪 ProgNo 身份/类型/值保持，ScrewCount及
双LREAL坐标结构数组分别为[1..8]、[1..3]。原生Save/关闭/冷重开回读保持，未修改正式ST40。
12项新客户端边界、13项既有resident和7项更新流程离线检查通过。7项延迟变量树/数组
元素读取通过，含两枪末项角度、负下标和二维元素；展开后再加StationData成员保留8887项
旧记录，重复应用新增0项。Export/消费者编译分别记录，不以冷重开替代生成、编译或生产配方运行验收。

接收项目按[模型添加说明](../skills/ctrlx-opcon-engineering/references/cpstudio-model-additions.md)
合并通用模块/命令/客户端/编译输入，保留本地扩展。ST40已有专用编码器命令不能被通用
bridge整文件覆盖；旧/运行中DLL不热换，不接管其CpStudio或唯一PLE。原生Export/编译
须由唯一owner协调窗口后完成，本段不声明已取得该窗口或通过该闭环。

### 7.15 WPF / OpCon 原生操作承载候选（2026-10-20）

新增独立通用研发目标，维护源为
[OpCon.WpfIntegration](../src/hmi/OpCon.WpfIntegration/README.md)。华沿正式三页继续由其
原有对话收敛原生 SmartForms/WinForms，本目标不替换它，也保留§7.14模型添加的Export/编译待办。

本机HMI Modulo文件5.11.1.52、VisiWin6.5.5.25；样例vwn选择CoDeSysV3/PLCHandler。
已读安装帮助的Mod_ManualFunctionKey、Mod_VarIn和Mod_ApplicationHost章节，并核验公开接口。
VisiWin的PerformClick只调用OnClick，不经过OpCon鼠标按下/释放路径；不能用其返回证明请求被接受，
也不能据此判定WPF不兼容。缺少等价公开语义调用对时，保留实际原生控件及其同页OwnerUnit归属。

候选0.1.0.1（初版0.1.0.0）使用ElementHost承载WPF，并以声明槽定位原来的原生键/参数框；权限、令牌、Condition、
ManualFunctionName、执行与反馈留在原生机制。显示通过既有VisiWin Item读取，没有另建PLC连接、
私有字段访问、假点击、直接Execute写入或重试队列。配置、双语、心跳新鲜度、布局占用和释放
已有39项组件离线检查及配置/资源检查；不是实际OpCon HMI、PLC周期或故障恢复验收。

资源携带候选使用官方Post-export脚本入口，附自有OOD Hmi片段、路径配置和资源同步脚本。
15项文件夹检查通过，包含真实批处理→Windows PowerShell、保留GUI配置、重复无改动、
越界/Std/链接及未完成更新拒绝；不修改vwn或PLC，不覆盖原有导出钩子。该文件级结果仍不证明
CpStudio实际触发、正常生成或HMI加载，需在独立窗口继续核验。

当前用户明确只做组件开发、暂不联系华沿所有者。共享PLE/CpStudio未操作；真实触摸/键盘、
手动握手、PLC接收/扫描/Unit状态、断链及松开丢失、多实例、正常Export资源携带都待独立窗口。
源码、公开契约、候选包入口和非AI构建部署说明已提供；正式可用性按该目录运行验收逐项建立。
0.1.0.1修正初始化失败时的清理顺序，订阅清理异常后仍尝试释放原生控件占用；39项离线回归
通过，但未在供应商运行中重现该异常。完整目标逐项核验见组件RUNTIME-VALIDATION.md，不能
用源码、构建或文件级结果关闭真实PLC和Export缺口。

按后续“可见操作控件全部WPF”的方向，新增独立
[WPF输入原型](../src/hmi/OpCon.WpfIntegration/operations/README.md) OpCon.WpfOperations 0.1.0.0。
WPF参数框和手动键、草稿/按下释放生命周期、自有待适配接口及本地输入探针已实现；58项离线输入
检查和两个真实样例启动自检通过，默认无适配器时禁用且读值未知。前端DLL无供应商、WinForms或
PLC通讯依赖；本地探针不进入控件DLL，不更新假PLC回读、不宣称权限或PLC运行验收。
元数据工具扩至27类，13项版本/调用差异核验通过：Key.StartEdit进入DigitalItem编辑，
VarIn.StopEdit进入原生NumEdit；手动鼠标路径另有心跳/计时器；Shopfloor Contract 2.0.1.0有
FrameworkElement、语言和可见性契约。这些仍没有建立受支持的完整操作语义API；原生适配器未实现。
输入检查不等于实体输入/DPI/原生语言或PLC握手验证；华沿工程及共享PLE/CpStudio继续未操作。

同日用户进一步明确：在自研功能库（例如华沿机器人库）中，用WPF编写该库的界面和按钮，
主要为了兼容现有OpCon/CpStudio环境及其通讯、操作机制。库的WPF界面接入CpStudio生成的HMI，
复用既有CoDeSysV3/PLCHandler会话；通用控件和宿主为此服务，实例配置独立于DLL属于实现选择。
用户确认没有额外SDK；本机运行库/安装帮助及公开厂商资料尚未提供
匹配版本的完整参数/手动操作服务。[原生适配记录](../src/hmi/OpCon.WpfIntegration/operations/NATIVE-ADAPTER.md)
列出具体缺口；NumEdit、App配置/资源/代理提供器等扩大到34类元数据检查，13项证据核验仍通过。
不把运行DLL目录称为完整开发SDK，不将保护事件或App委托冒充完整受支持握手。

纯WPF前端0.1.0.1增加CancelInput和焦点恢复不开始编辑，59项输入检查及两个样例启动自检通过。
新增[SmartForms进程内视图宿主](../src/hmi/OpCon.WpfIntegration/operations/hosting/README.md)0.1.0.0：
匹配SFCLoader设计加载、ElementHost真实装载、WinForms失活/隐藏/关闭/释放和实例隔离共24项检查通过。
它仅负责视图和生命周期，没有原生操作适配器。没有PLC提交/请求/周期/Unit反馈证据；
CpStudio工具箱编辑、正常Export和运行HMI仍待验收。本轮依赖只读自ST60 Std，没有改华沿或占用共享IDE。

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
- 2026-08-22 已增加 Stage 2 PlanOnly operation ledger：成功的 Stage 1 报告生成不可变 action，并只接受与 operation/action 哈希绑定的 runner evidence；它本身不启动 PLE、MCP 或 REST
- Stage 2 的纯离线 runner evidence 封装器不执行 PLE/MCP/REST；它复核 action/Stage 1/ownership/关键 Station 指纹、Build 新鲜度、当前 PLC SHA 和 semantic proofs，并以固定算法生成 warning 签名多重集。live engineering action 由显式启动的 interactive Broker 执行，该 Broker 是唯一 persistent MCP/PLE owner。
- P1.1 已提供 OS 排他运行租约；P1.2 client/action 与 Broker session/action serialization 分别提供跨进程和执行期门禁。条件 Export #2 仍只在记录到 Symbol/后处理需求时进入人工同步点。
- current-user Pipe/registration、PID/session/executable/project identity 校验用于防止误连和跨会话混用，但不防御同一 Windows 用户下的恶意进程。P1.4a 的离线包增加内容 manifest 与可重复安装边界，但仍沿用当前用户默认权限、不设置自定义 ACL；数字签名延期到商业发行或公司 IT 明确要求，release-bound Broker identity 仍是后续加固项。evidence 是哈希绑定的审计证据，不是加密签名。
- 完整 warning population、去身份用户确认 baseline 与新 immutable action 已于 2026-08-28 完成复验；P1.3a/b Host 已落地。P1.3c 的自动 result/evidence 摄取、SHA 绑定/只读锁、合法无 evidence 终态人工复核、busy 有界退避和其他 ledger 异常阻断均已实现；production 默认 ingestor 的 6 项 fixture E2E（含真实 workflow ledger 独占锁及零 mutation 复核）已通过。五文件内容寻址 immutable release、durable deployment journal/reconcile、真实断点/强杀恢复、升级与精确 `Rollback`、损坏拒绝、普通失败恢复，以及 `deployment.json` 缺失时基于精确 task pin 的安全卸载也已完成参考工作站验收。P1.3c 技术实现和参考工作站验收至此完成；Host 不启动 Broker/MCP/PLE/Node 或在线操作，该验收不新增真实 PLE、仿真或真机结论。
- Scheduled Task action 精确指向 active release 的 `vcrunner-host.exe`，description 记录 `releaseId + manifest SHA-256`。wrapper 的显式 lifecycle 校验 manifest/五文件 payload，并在启动、切换和安全卸载路径执行 apphost self-check；AtLogOn 任务自身直接执行 action，不会先独立校验 `.deps.json` 或 `.runtimeconfig.json`。参考工作站当前 active 为 `faa27c1d79415996ddcd524833160c57ea23ac63888f17b853487a81b46ab0f1`、previous 为 `ac89b28f9a93a61c10b5bd7731c3b5b83288169a105c62eb4218a30c119f4b51`，Host 为 `WAITING_FOR_ACTION`。
- P1.4a 已提供 `New-CtrlXOpconRunnerHostPackage.ps1`：包固定包含 `Install.ps1`、canonical wrapper/module、`package-manifest.json` 与 Host 五文件 payload；manifest 绑定每个内容文件的 path/length/SHA-256 和整体 `contentId`，安装器在所有命令前验证。接收工位通过 PowerShell 7 对指定 AI 工程根目录安装；framework-dependent Host 仍需 .NET 8 runtime，但不需要 Git、源码、SDK 或本机 build。同一 `Install` 用于首装/升级，并提供精确 `Rollback`、安全 `Uninstall` 和 `Status`。fresh Install 默认不启动 Host，升级保留原 running/stopped 状态；更广的运行前提仍由待完成兼容矩阵约束。
- 独立 AtLogOn 五文件 prelaunch bootstrap 按用户决定延期到商业化或明确需要无人值守登录自启时实施；开发期继续显式启动 Host。兼容矩阵与全新团队工作站验收在有工位时再做。包级校验和显式 lifecycle self-check 仍不能冒充 prelaunch bootstrap；这些部署项不阻塞当前开发，可继续推进项目目录/流程生成以及后续 `project_health`、`compile_project_v2` 等通用能力。

## 10.2 Runner baseline 审阅边界（2026-08-28）

- 真实 PLE 技术通道通过不等于工程 `DONE`；Build 0 errors 也不等于 warning、I/O mapping 或 Symbol 语义已经被批准。
- warning candidate 保存当前 warning signature multiset；semantic candidate 保存 scope 绑定的 mapping facts 与 Symbol 摘要。两者只能进入 `docs/reviews/`，状态必须是 `pending-human-review`。
- `review.reviewBlockers` 含 `PLE_WARNING_OUTPUT_TRUNCATED` 时，当前 warning 集合不完整，禁止建立正式 warning baseline。已确认 100 条来自 PLE 工程 `Compile Options` 的编译器生成上限，而不是 MCP/ScriptEngine 的读取分页。先在隔离工程副本中通过官方 REST 对 `CompileOptionsEditor.maxCompilerWarnings=<no limit>` 完成 GET/PUT/readback/Build/回滚验证，再由新 action 生成新候选；不得手改 `.project`、`.opt`、注册表或插件文件。
- 只有用户明确确认候选结论后，工具才能写入 `confirmedByUser: true`；`reviewId`、`reviewedAtUtc`、evidence 路径与 SHA 均由工具生成，不采集或要求姓名、工号。candidate 仍不得直接重命名为 `config/*-baseline.json`。
- 确认证据必须是 `docs/reviews/` 下单独、简短且脱敏的决定记录；candidate、AI triage、reviews index、目录外文件及其改名/逐字副本均不能作为 evidence。Stage 1/2 对确认文件只做一次有界读取，严格 UTF-8、内容检查和 action-bound SHA 均来自同一 byte snapshot。
- warning baseline、semantic scope 和 semantic baseline 同样按各自上限单次读取，并用同一 bytes 完成 SHA 与 JSON 解析。畸形 Post-export 请求的失败记录不得保存 raw/original payload，只保留 1 MiB 上限内的字节数、SHA-256 和固定安全诊断元数据。
- 正式 baseline 的 project/profile、scope、candidate hashes、review evidence path/SHA 任一变化都使旧 action 失效；必须回到 Stage 1 创建新的 operation/action。
- 本条门禁已于 2026-08-28 满足，P1.2 已正式完成；P1.3a/b 因而可以推进。该规则继续适用于未来 baseline 变更：没有新的用户确认与 immutable action 复验，不得把变化后的基线视为正式可用。

## 10.3 Project Pack 与流程事实源（2026-08-29）

- 新项目由根目录 `project-pack.json` 引用既有 Station/I/O/Event/Unit/Process/HMI/Catalog 与 ownership manifests；不复制第二份字段事实。
- `specs/processes/*.process.json` 是 Chain 流程、双语提示、需求和验收的唯一流程事实源；CpStudio 生成的 POU interface 必须标记 `source: cpstudio`。
- `scripts/project/Build-CtrlXOpconProjectPack.ps1` 只提供 PowerShell 7 `Build/Check`，生成内容寻址的 `generated/engineering-plan.json`；它不启动或写入 CpStudio、PLE/MCP。
- 初始化器先生成 draft plan；补齐流程并显式改为 `ready` 后才可通过 `-RequireReady`。新 action 固定 contentId、Pack/plan hash；Host 与直接 ExecuteAction 共用校验器逐项验证 plan source 的路径、长度和 SHA-256，任一源漂移即在 Broker 前失败关闭。
- 本层刻意不实现通用 SFC 编译器、后台服务或插件；实际图形/接口仍按 ownership 进入 CpStudio/PLE 受控闭环。

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
