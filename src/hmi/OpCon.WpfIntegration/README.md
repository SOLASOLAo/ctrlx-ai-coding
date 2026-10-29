# OpCon WPF Integration

可复用的 WPF 展示与原生操作承载组件，候选版本 **0.1.0.1**。维护源位于本目录；不是华沿正式 HMI 的替换版本。此补丁修正初始化失败时的清理顺序，确保订阅清理异常后仍尝试释放控件占用。

该候选的可见参数框和手动键仍是 WinForms。按用户后续方向，新增独立的[纯 WPF 输入最小样例](operations/README.md)：`OpCon.WpfOperations` 0.1.0.1 提供 WPF 参数框与手动键、待适配契约及本地输入探针。59项输入检查、两个实际样例启动自检和13项只读接口证据核验通过；另有[纯WPF的SmartForms宿主](operations/hosting/README.md)，24项原生加载/宿主检查通过。**原生操作适配器尚未实现，不能用于PLC操作**。它们单独构建，候选包只携带其源码，现有资源同步不部署它们。

用户当前目标是在自研功能库（例如华沿机器人库）中，用WPF编写该库的界面和按钮，
重点是兼容现有OpCon/CpStudio环境及其通讯、操作机制。该库的WPF界面接入CpStudio生成的
HMI，并复用既有CoDeSysV3/PLCHandler会话。这里的控件与宿主开发服务于这个功能库目标。
匹配SDK查找范围、现有入口不足及下一步契约见
[原生适配记录](operations/NATIVE-ADAPTER.md)。外层WinForms仅作为承载边界时，可见操作仍可全部为WPF；
但不能把视图承载通过解释为权限、令牌和PLC握手已接通。

当前完成源码编译、公开契约核验和离线检查。**尚未通过实际 HMI→PLC 运行验收，也未证明正常 CpStudio Export 自动携带本组件资源。** 2026-10-20 用户要求当前只做组件开发、暂不联系工程所有者；共享 PLE/CpStudio 未操作。

本轮 39 项 C# 组件检查及配置/双语资源边界检查通过；包括真实 WPF 布局装载和三个尺寸、原生控件几何占用/释放测试。另有 15 项资源同步文件检查，含真实批处理→Windows PowerShell 执行及带空格路径，验证实际自建文件夹的写入与拒绝行为。几何测试使用普通 WinForms 控件，不伪称已验证 OpCon 手动键运行。

## 使用方式

WPF 负责布局、动画、原生双语文字和只读值。参数编辑使用原有 `Mod_VarIn`，手动操作使用原有 `Mod_ManualFunctionKey`；这些控件继续属于原来的 SmartForms `SmartControl`，保留 `OwnerUnit`、权限、控制令牌、Condition、ManualFunctionName 和标准执行/反馈绑定。

组件通过真实屏幕坐标把原生控件放入 XAML 预留区域。原生控件直接接收鼠标、触摸转入的窗口输入及键盘，不重设父级，不调用假点击。组件只使用现有 VisiWin Item 系统读取显示数据，没有连接配置、写变量、执行命令或重试队列。

正常工程使用配置以下内容，不修改 C# 或重编组件：

1. 在组件所属对象的 SmartForms 页保留原生参数框和手动键，配置原生绑定、权限、条件及多语言文本。
2. 同一页添加 `OpCon.WpfIntegration.WpfViewHost`，配置 `LayoutFile`、`ItemPrefix`、`HeartbeatItem`。
3. 编辑自有 `.xaml` 布局，以 `NativeSlot.ControlName` 引用同页原生控件的 `Name`。以 `NativeValue.Path` 配置相对显示变量，以 `NativeText.Group/Key` 引用 HMI 原生文本。
4. 每个实例使用自己的前缀、原生控件及宿主；实例改变时正常重建该页。库的实现变化才需要重新编译 DLL。

示例为 [IntegrationPage.sfc](examples/IntegrationPage.sfc)、[IntegrationDemo.xaml](examples/IntegrationDemo.xaml) 和原生双语 [Texts.osd](examples/Texts.osd)。页面引用虚拟探针的 `Parameters.Setpoint`、`Status.ScanCount`、`Status.RequestCount`、`Status.LastResult` 及两个标准手动功能 `Pulse/Hold`。这些是待建立的独立探针契约，不是已存在的现场变量。

## 依赖与构建

| 项目 | 本轮核验值 |
| --- | --- |
| CpStudio | 5.11.0.169，供后续生成验证；本轮未操作 |
| HMI / Modulo Forms、Shared | 程序文件 5.11.1.52，程序集 5.11.0.0 |
| VisiWin Embedded Forms、Systems | 文件 6.5.5.25，程序集 6.5.0.0 |
| 导出的驱动配置 | CoDeSysV3 / PLCHandler |
| PLCHandlerDll / Wrapper | 3.5.16.31 / 1.1.0.0 |
| 自有组件 | 声明目标 .NET Framework 4.6.2 / x86 / WPF + WinForms Integration |
| 本机构建环境 | Windows，Framework 4.8.09221，Release 533509；不代表其他运行环境已验收 |

SDK 路径选已获许可的匹配 `Hmi_V5_11` 目录，供应商 DLL 作为外部依赖，不复制进本仓库或候选包。不需要 Visual Studio、NuGet 或 AI。用 Windows PowerShell 执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1 -HmiSdk 'C:\YourProject\Std\Hmi_V5_11' -Inspect -Test
python .\tests\check_package.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ResourceSync.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Package.ps1 -Destination 'C:\YourStaging\OpCon.WpfIntegration-0.1.0.1'
```

`Build.ps1` 使用 Windows 自带 Framework C# 编译器，输出 `bin/OpCon.WpfIntegration.dll`；依赖版本不符时停止，先核验新版本再扩展兼容范围。`-Inspect` 只检查程序集元数据和调用点，不创建原生操作控件、启动驱动或连接 PLC。`-Test` 明确输出 `OFFLINE_ONLY`。

## 候选包安装与生成集成

`Package.ps1` 只写一个新/空的候选目录，包含自有源码、构建/检查工具、示例与运行候选，不包含供应商 DLL，不修改工程、安装目录、Std 或运行 HMI。包中 `Runtime` 的布局文件放在 HMI 程序目录下 `OpCon.WpfIntegration/`，DLL 放在 HMI 程序旁；在该工程正常的 `OpCon.HMI.Modulo.Gui.config` 引用列表注册 `OpCon.WpfIntegration.dll`。参考片段随包提供，只合并到自己的工程配置，不覆盖整个配置文件。

组件库的发布者把 [Hmi.ood.fragment](examples/Hmi.ood.fragment) 的 View/HmiText 合并到自有对象的 Content/Hmi，随对象生成页面、绑定与双语；片段不是一个可单独加载的完整 OOD。DLL/布局/GUI 引用由下面的资源步骤承接。**对象加载、正常 Export 的实际调用和资源保留仍未取得原生证据，不能用文件同步通过代替。** 后续在独立样例中完成对象加载、Parse/Save/Export、两次 Export 后资源/引用保留和冷重开，再确定正式发布包。

## 导出后的资源同步

官方安装帮助的“Running Actions Upstream and Downstream of the Export Using Scripts”支持相对路径的 Pre/Post-export `.bat` 或 Python 脚本。候选提供 [Sync-HmiResources.ps1](Sync-HmiResources.ps1) 和 [批处理入口](examples/post-export-resources.bat)，只同步自有 DLL/XAML、合并自身 GUI 引用并回读；不编辑 vwn、PLC 工程或原生参数值。

库发布者一次性登记这个步骤，使用方以后配置路径和对象/绑定，不重编组件：

1. 在 [hmi-resources.json](examples/hmi-resources.json) 配置 workspaceRoot、hmiRoot、runtimeRoot。workspaceRoot 相对该 JSON，后两项相对 workspaceRoot，也可用绝对路径。目标必须是工作区内已有的自有 HMI 输出，不能是 Std、SDK 或链接目录。
2. 先正常关闭自己的测试 HMI，保持发布源不变。运行下面的 `-WhatIf` 查看范围，再应用；正在运行的目标 HMI会被拒绝，不自动关闭它。
3. 把批处理作为自己工程正常 Post-export 链的一步。保留已有 Post-export；例如在自有链中先 `call` 本资源步骤，失败就退出，再 `call` 原有发布/审计脚本。不要直接覆盖原队列钩子，不启动 HMI、PLE 或另一个 MCP。
4. 原生 View/HmiText 仍由 OOD 导出，本脚本不伪造语言数据库或手动功能。下一次 Export 后应重新同步并核对；字节相同的文件不重写、GUI 引用不重复添加。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-HmiResources.ps1 -ConfigFile .\examples\hmi-resources.json -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-HmiResources.ps1 -ConfigFile .\examples\hmi-resources.json
```

有 `.wpf-resources.claim` 或 GUI 的 `.wpf-resources.tmp` 时停止，不自动重试。先由唯一所有者检查进程、实际文件和 GUI 引用，区分已完成/部分完成/未知，确定恢复方案后再处理自己的残留。同步的失败可能已复制部分文件，不能因超时或异常再次盲目提交。

本轮文件夹测试已经验证该脚本；**CpStudio 触发此步骤、既有钩子串联、完整导出与冷重开仍待独立窗口**。

安装或升级时先正常保存并退出自有测试 HMI，部署同一版本完整包后再打开。禁止热换运行 DLL。本文不授权现场 IPC 安装或实体控制器操作。

公开调用与行为约束见 [CONTRACT.md](CONTRACT.md)，公开帮助及调用差异证据见 [API-EVIDENCE.md](API-EVIDENCE.md)，实际运行验收步骤见 [RUNTIME-VALIDATION.md](RUNTIME-VALIDATION.md)。
