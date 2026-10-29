# 在 SmartForms 中承载纯 WPF 输入控件

这是 `OpCon.WpfOperations.Hosting` 0.1.0.0 的独立视图宿主，依赖
`OpCon.WpfOperations` 0.1.0.1。维护日期：2026-10-20。

**已实现嵌入与输入生命周期，尚未实现 OpCon 操作适配器。**
默认样例无 Operation 绑定，参数读值未知、提交和手动键禁用。
不能用于 PLC 操作，也没有完成 CpStudio 正常 Export 或运行 HMI 验收。

用户当前目标是在自研功能库（例如华沿机器人库）中，用 WPF 编写该库的界面和按钮，
作为库自身的 HMI 部分接入 CpStudio 生成的 HMI，重点是兼容现有 OpCon/CpStudio
环境及其通讯、操作机制。通讯继续复用已有 CoDeSysV3/PLCHandler 会话。
控件复用和配置方式服务于这个功能库目标，实例配置与 DLL 的分离属于实现选择。
本宿主提供所需的进程内边界；没有初始化 VisiWin 或新建 PLC 连接。
可见参数框、确认/取消和手动键都是 WPF，外层 WinForms UserControl 只负责
SmartForms/ElementHost 互操作，不叠放原生操作控件。

## 构建与检查

Windows PowerShell，无需 Visual Studio、NuGet 或 AI：

```powershell
# 只构建自有控件和宿主，不需要厂商依赖
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Host.ps1

# 独立原生加载器 + 本地宿主测试；指定自己的已许可匹配依赖
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Host.ps1 -Test `
  -HmiSdk 'C:\YourProject\Std\Hmi_V5_11' `
  -SfcLoader 'C:\Nexeed\Automation\CSV5_11\OpCon\VisiWinNET.SFCLoader.dll'
```

输出在组件的 `bin/wpf-operations/hosting`。`HmiSdk` 是沿用的参数名：
这里选择的是运行程序集目录，**不表示已取得完整 HMI 开发 SDK**。
构建检查 Shared 5.11.1.52、VisiWin Forms/Systems/SFCLoader 6.5.5.25。
声明目标 Framework 4.6.2/x86；实际在本机 Framework 4.8 检查，其他组合待核验。

测试只启动本目录的自有程序。原生 SFCLoader 在设计上下文加载
[OperationsPage.sfc](OperationsPage.sfc)，读回宿主类型、父级、尺寸及 LayoutFile；
它没有创建原生参数框或手动键，没有启动 HMI/驱动/工程 IDE。
随后独立、屏外、非激活 WinForms 窗口实际承载
[HostedOperations.xaml](HostedOperations.xaml)。测试的配置/事件记录端口仅编入测试 EXE。

## 公开配置与调用

`WpfInputHost.LayoutFile` 是相对 HMI 应用程序目录的自有 XAML 路径，最大 256 KiB；
根为 Grid/UserControl 等 FrameworkElement，不能是 Window。相对 ResourceDictionary
按该 XAML 的位置解析。XAML 必须是经过审核的库资源，它不是不可信输入的沙箱。
加载之后修改布局路径需要重建视图。

`View` 提供已加载的 WPF 根，`InputActive` 表示宿主是否允许本地输入，
`LastError` 提供布局错误。**InputActive 不代表原生权限、控制令牌或 PLC 放行。**
操作许可和反馈仍应由将来核验后的 `IParameterOperation` / `IManualOperation` 提供。
更换实例、参数、功能和文字的最终配置入口属于该适配器，目前没有用配置文件假造它。

控件新增 `CancelInput(reason)`，只取消其持有的输入，不新增权限或发送开始命令。
宿主在 WinForms Deactivate、换父级、隐藏、禁用、关闭和释放时调用它，并关闭独立的
祖先输入门；不会改写调用者给控件设置的 Enabled 或绑定。
恢复只开放输入门，不创建 BeginEdit/BeginPress，不恢复旧草稿。
调用者取消关闭窗口后，宿主在关闭事件处理完成后重新判断可用性。

纯 WPF Window 内原有的 Deactivated 路径继续有效。嵌入时通常
`Window.GetWindow(control)==null`，必须保留本宿主的 WinForms 生命周期转发。
参数框自动获焦点不再开始编辑；点击或明确键盘输入才开始。Enter 的自动重复不再次提交。
真正的触摸、物理键盘、Alt+Tab、DPI 和原生语言切换仍需运行验收。

## 后续在自有工程中的集成位置

这一步是待验收的接入说明，**本轮没有修改任何工程**：

1. 将自有 `OpCon.WpfOperations.dll`、`OpCon.WpfOperations.Hosting.dll` 放在测试 HMI
   的程序集查找位置，将两个 XAML 放在约定的布局目录。
2. 在该工程原有 `OpCon.HMI.Modulo.Gui.config` 的引用列表合并这两个程序集引用；
   保留原有配置。在自有对象的 HMI View 模板中使用 `OperationsPage.sfc` 的宿主。
3. 由后续原生操作适配器配置并绑定实例。缺少适配器时保持禁用；
   不把测试的 ProbePorts 安装成现场适配器。
4. 独立窗口内完成正常 Export、再次 Export、冷重开及运行验证后，才将资源部署纳入库发布。

不能将“SFCLoader 已识别宿主”解释为已验证 CpStudio 工具箱编辑、正常 Export、
原生 OwnerUnit/权限/令牌、PLCHandler 通讯或 PLC 执行反馈。
当前操作接口缺口及可交给供应商的明确问题见 [NATIVE-ADAPTER.md](../NATIVE-ADAPTER.md)。
