# WPF 参数框与手动键最小样例

维护日期：2026-10-20。独立输入原型 `OpCon.WpfOperations` **0.1.0.1**；与上级目录的 WinForms 原生操作槽候选是两个不同的程序集。本目录的参数编辑框、确认/取消按钮、手动键均为 WPF 控件，无 WinForms 控件叠放。

**当前完成 WPF 输入控件和本地输入探针；没有实现可用于 PLC 操作的 OpCon 原生适配器。** 默认页面操作禁用，读值未知。显式使用 `--input-probe` 才开启纯本地输入记录；12.5 是示例值，不来自 PLC。提交后也不会把草稿冒充 PLC 回读。没有 VisiWin 初始化、PLC/机器人连接或 PLE/CpStudio 调用。

接口研究结论及证据见上级 [API-EVIDENCE.md](../API-EVIDENCE.md)。原生 `StartEdit/StopEdit`、`PerformClick`、公开 ModeHandler 方法及 Shopfloor App 承载契约均不能单独证明完整手动操作接口已接通。`OperationPort.cs` 的接口是我们定义的待适配契约，不是供应商已经提供的同名 API。

库复用、原生握手与既有 PLCHandler 会话的目标、最新接口缺口和供应商问题清单见
[NATIVE-ADAPTER.md](NATIVE-ADAPTER.md)。用户确认没有匹配开发 SDK；本轮未找到可直接采用的完整受支持操作服务。
新增 [SmartForms 进程内嵌入样例](hosting/README.md) 及 WinForms 生命周期处理，
原生加载器与24项宿主检查通过。可见输入仍是WPF；外层WinForms只负责承载。
这些检查没有接通原生参数提交、手动按下/释放或PLC反馈。

## 构建与运行

Windows + .NET Framework；程序集声明目标 4.6.2 / x86，本机使用 Framework 4.8 编译与检查。前端不依赖供应商 DLL、Visual Studio、NuGet 或 AI。不修改已安装工程环境。

在本目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1 -Test
..\bin\wpf-operations\OpCon.WpfOperations.Sample.exe
..\bin\wpf-operations\OpCon.WpfOperations.Sample.exe --input-probe
```

第二行显示默认禁用页；第三行显示本地输入探针。两者都不会启动驱动或连接 PLC。输出位于上级目录的 `bin/wpf-operations`，不覆盖旧 `OpCon.WpfIntegration.dll`。运行时需要本 DLL、Sample.exe、Controls.xaml、Demo.xaml 同处一目录；尚无现场部署或正常 Export 集成步骤。

只读核验自己的匹配 SDK：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Inspect-Operations.ps1 -HmiSdk 'C:\YourProject\Std\Hmi_V5_11'
```

该入口只编译/运行元数据工具，不构建或启动 HMI、不实例化原生操作控件。核对 HMI 5.11.1.52、VisiWin 6.5.5.25、Shopfloor Contract 2.0.1.0 及已知调用差异；不匹配就停止。当前检查34类元数据；`HmiSdk`这里只指向外部运行DLL目录，不表示已取得开发SDK。输出的 `completeNativeOperationApiVerified=false` 保留真实缺口，不能把这些检查通过理解为适配器验收。

## 配置与绑定

布局、颜色、字体和控件文字放在 XAML。使用方提供经过原生契约核验的 Operation 对象并绑定；正常更换实例路径、手动功能和参数应由该适配器配置完成，不修改控件库源码。

```xml
<ResourceDictionary Source="Controls.xaml" />
<!-- 页面中的两个可见操作控件均为 WPF；以下是绑定形式，不表示已有原生适配器。 -->
<ops:WpfParameterBox Label="设定位置" Operation="{Binding SetpointOperation}" />
<ops:WpfManualKey Content="按住操作" Operation="{Binding HoldOperation}" />
```

页面声明 `xmlns:ops="clr-namespace:OpCon.WpfIntegration.Operations;assembly=OpCon.WpfOperations"`。资源字典放在页面 Resources/MergedDictionaries 内，两个控件放在页面布局中。`ProbePorts.cs` 只编译进样例和测试程序；它不会进入可复用控件 DLL，不能安装到正式 HMI 作为原生适配器。

## 待适配的公开契约

| 入口 | 输入与含义 | 结果边界 |
| --- | --- | --- |
| `IParameterOperation.State/StateChanged` | 原生上下文、代次、当前新鲜值、范围、单位、可开始/可继续及反馈 | 数值质量坏时 Value=null；上下文/重连/重开后必须使旧输入失效 |
| `BeginEdit(inputId, context)` | 显式开始一次编辑；原生层再次核对权限、令牌、条件与归属 | 不能仅靠 WPF Enabled 当作权限保证 |
| `Submit(inputId, context, value)` | 对同一次编辑显式确认；原生层再次核对类型、限值和原生提交规则 | 分发回执不代表 PLC 接收/应用成功，需独立反馈 |
| `CancelEdit(inputId, context, reason)` | 取消该次未提交编辑 | 不提交旧草稿；不重新解析到另一个实例 |
| `IManualOperation.State/StateChanged` | 原生上下文、代次、可开始/可继续及执行反馈 | 新命令 Busy 与当前按住是否允许继续分别表达 |
| `BeginPress(inputId, context)` | 新的一次按下；原生层保留授权、令牌、放行及原生输入生命周期 | `ForwardedToNative` 只代表交给原生层，不能解释为完成 |
| `EndPress(inputId, context, reason)` | 仅结束原端口、原上下文的同一次输入 | 未知 ID 必须无副作用；不能改用当前选中 Unit；不重放 Begin |

所有入口和 StateChanged 在所属 UI 线程执行，使用缓存状态，调用耗时有界。适配器必须处理自身异常、断链、原生资源附着和释放，不另建 PLC/机器人连接。控件只借用端口；页面卸载会取消自有输入、退订事件，不 Dispose 别的控件共享的会话。

`OperationContext.Binding` 标识准确实例与功能/参数，`Generation` 是该绑定的会话代次。断链恢复、原生重新初始化或实例切换必须废弃旧代次，先取得新鲜状态。`CanStart` 包含原生新输入许可；`CanContinue` 包含本次已开始输入的继续许可。原生 Busy 禁止新开始时，可以保留允许继续的现有输入；不能把 Busy 一律当成释放条件。

`InputDisposition` 只有拒绝、本地记录、已交原生层和结果未知，没有“PLC 完成”。异常/未知结果会阻断同代次的新输入，不自动重试。按下结果未知时最多尝试一次、原上下文的结束意图，要求原生适配器满足上述未知 ID 无副作用契约；结束本身未知时不再次发送。控制器独立的按住失效机制仍是必要前提，本控件不能替代。

## 当前输入行为

- 参数框：单个 decimal 数值，示例范围 0–100 mm；草稿与读值分离。确认按钮/Enter 提交，取消/Esc/移出焦点/隐藏/卸载/窗口失活取消。解析按 WPF Language 的文化，不接收千位分隔符。整数、LREAL 转换、字符串、枚举和配方等原生类型尚需适配器明确契约。
- 手动键：鼠标左键、单个触摸接点及焦点内 Space/Enter 走成对输入；键盘自动重复不产生第二次开始。离开区域、失去捕获、失焦、隐藏/卸载、窗口失活、许可或上下文失效会结束本次输入。触摸处理抑制其提升的重复鼠标输入；笔输入及全局/硬件快捷键不在此最小样例范围。
- 文字与布局：样式可以配置；参数数值文化随 WPF Language。尚未接入原生 LCID、原生中英文资源及原生触摸键盘，不能把样例文字当作语言切换验收。

0.1.0.1补齐嵌入所需的 `CancelInput(reason)`：宿主只取消该控件已持有的输入，不新增权限。
参数框获得/恢复焦点本身不再开始编辑，必须明确点击或键盘输入；Enter 自动重复不会再次提交。
WinForms 宿主窗口没有 WPF Window，必须使用 hosting 中的生命周期转发，不能只监听 WPF Window.Deactivated。

## 已验证与未验证

本轮 **59 项离线输入检查**通过：输入会话、重复事件、上下文切换、Busy/继续许可区分、异常不重放、草稿取消、实例隔离、焦点恢复不开始编辑和资源释放；另实际装载 WPF 页面、模板、禁用默认态、确认/Esc 的合成 WPF 事件及真实 Hide/Show/Close。Sample.exe 的默认页与本地探针页另有两个真实启动自检，初始输入数均为0。测试窗口不激活且位于屏幕外，不发送 OS 鼠标/键盘输入。另24项宿主检查验证原生SFC加载、ElementHost、相对资源字典、WinForms生命周期、实例隔离及布局拒绝后保持禁用；Enter物理长按、真实Alt+Tab与触摸仍未验收。

这些证据不是物理鼠标/触摸/键盘、实际 DPI 或原生 HMI/PLC 验收。当前原生适配器、真实参数提交、手动握手、权限/令牌验证、PLC 接收计数、扫描周期、Unit 状态、HMI 挂起及恢复不重放仍未验证。不得用本地探针代替 [原生运行验收](../RUNTIME-VALIDATION.md)。

人工可执行的最小检查：

1. 默认运行：参数和手动输入禁用、当前值为未知、没有输入记录。
2. 显式运行 `--input-probe`：改数值确认；记录只出现一次提交意图，当前示例值仍为 12.5。Esc 或换焦点取消草稿，不能产生提交。
3. 鼠标按下/松开手动键、焦点内按住/松开 Space，检查一组开始/结束。拖出、Alt+Tab、关闭窗口应结束本地输入；这些仅验证本地端口，PLC 结果仍为未测量。
4. 用“探针失活/恢复”切换本地可用性；恢复不应产生提交或按下记录。真实触摸和 DPI 必须另在目标自有环境核对。

## 后续原生适配入口的验收条件

需要取得匹配版本的正式 SDK/帮助或供应商明确支持的扩展契约，说明如何在保留 OwnerUnit/面板归属的条件下开始/提交/取消编辑、按下/释放手动功能，以及原生心跳、令牌和完成/错误反馈的生命周期。保护事件方法可继承不等于供应商承诺了语义调用；不以反射私有字段、隐藏控件假点击或直接写 Execute 填补这个缺口。

取得入口后只新增原生适配器，前端绑定形式保持稳定；在独立自有虚拟消费者验证真实 PLC 接收/反馈及故障场景。当前用户限制仍为组件开发，不联系、不修改华沿工程，也不占用共享 PLE/CpStudio。
