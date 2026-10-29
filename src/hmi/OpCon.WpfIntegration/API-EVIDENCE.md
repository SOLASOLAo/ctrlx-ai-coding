# 版本、帮助与公开入口核验

核验日期：2026-10-20。输入是本机已安装程序集和华沿独立样例导出的 `.vwn`；本次只读检查，没有调用其运行会话。

## 驱动与控件

已核实 HMI Modulo 程序/Forms/Shared 文件版 5.11.1.52，VisiWin Embedded Forms/Systems 6.5.5.25。导出的 `OpCon.HMI.Modulo.vwn` 选择 `ProgID=CoDeSysV3`、PLCHandler 驱动。DLL 名称和 API 中的 OPCQuality 不改变这个驱动事实。

`Mod_ManualFunctionKey → Mod_Button → VisiWinNET.Forms.Key → ButtonBase → ControlBase → WinForms.Control`；它是 WinForms 控件。公开的 `ManualFunctionName`、`Condition`、`UseTokenHandling`、`Authorization`、VWItem/VWItemEnabled/VWItemMonitor 以及 AttachItems/DetachItems 构成配置和原生生命周期入口。VWItem 对象公开可写不表示允许绕过手动控制契约写请求。

`Mod_VarIn` 公开原生 Item、Authorization、Condition、UseTokenHandling 和 StopEdit；编辑、确认、限值及触摸键盘沿用控件。显示可使用 Item.Name/Attach/Detach/Quality/Value；本组件只读取 Value。双语使用 LocalizedText.TextGroup/Text/DisplayText 与 Dispose。

## PerformClick 差异

本机元数据/调用点检查得到：VisiWin `ButtonBase.PerformClick()` 检查 CanSelect 后调用 OnClick；该路径没有调用 OnMouseDown/OnMouseUp。OpCon 的两个鼠标重写继续调用 Mod_Button/VisiWin 的按压、释放处理，并处理原生心跳/计时器附着与恢复。Mod_Button 的初始化还解析原生 OwnerUnit、条件及令牌处理。

因此，调用返回不经过完整的原生按压通路，是此前实验必须纠正的接入差异。**此证据没有证明当时权限、质量、初始化或其他门禁全都满足，也没有建立 WPF 不兼容的结论。**

公开面没有一个经本机帮助证明等价于完整手动按下/释放握手的语义调用对。继承来的 Click/StartEdit、直接写 Item 或调用保护方法不能据此升格成受支持的手动 API。本候选使用可见的原生控件承载真实输入，保留同页原生归属。

`tools/InspectHmiContract.cs` 为本机读取工具：只遍历公开/保护成员的签名及调用点，不获取或设置私有字段，不实例化操作控件。原始结果在忽略的 bin/data 内，不将供应商实现或完整帮助复制进交付包。

## 已阅读的本机官方帮助

入口为安装目录 `Help/Control_plus_Studio_English.chm`，在 HMI Controls / Smart Toolbox Controls 中搜索：

- `Mod_ManualFunctionKey`，topic `62ee4972-b3bd-4bf3-825c-bc80b91f5b89`：手动功能名的原生选择、双语说明、启用/可见绑定与真实控件配置。
- `Mod_VarIn`，topic `e4502cca-4e35-4fab-9e89-b54dc6158e22`：支持的参数数据类型、原生权限/Condition、触摸键盘、确认、限值及 RestoreOnLostFocus。
- `Mod_ApplicationHost`，topic `a0632873-9ae4-4c90-a2f5-36ee25ec7915`：承载已启动的外部程序；没有把它解释为 PLC 操作 API。
- `Running Actions Upstream and Downstream of the Export Using Scripts`，topic `1f0012d7-0b02-4857-b1ef-33300631ccfa`：Engineering / Export 中配置相对 Pre/Post-export `.bat` 或 Python 脚本。候选资源步骤采用该入口，不声称有未经验证的 OOD 文件复制接口。

帮助包含当前运行版本中已变动的属性描述，不能仅凭较新帮助或其他版本 Release Notes 推断本机实现。实际兼容组合仍以文件版和接收工程运行结果为准。

微软文档说明 Click 与输入事件的区别，以及混合 UI 的输入、焦点和 HWND 层叠约束：

- [PerformClick](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.button.performclick?view=netframework-4.8.1)
- [WinForms/WPF 输入互操作](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/windows-forms-and-wpf-interoperability-input-architecture)
- [WindowsFormsHost 布局与层叠](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/layout-considerations-for-the-windowsformshost-element)

微软支持互操作不等于供应商已经认证本组件。本轮编译/离线证据不替代 OpCon 运行验收。

## 纯 WPF 操作入口的进一步核验（2026-10-20）

`operations/Inspect-Operations.ps1` 可重复执行当前34类元数据检查和13项版本/调用差异核验。只读取外部运行程序集，不实例化原生控件、不初始化VisiWin驱动、不获取或设置私有实例字段。`HmiSdk`参数名不表示该目录包含完整开发SDK。结果保留 `nativeAdapterImplemented=false`、`completeNativeOperationApiVerified=false` 和 `plcContacted=false`。

| 已核验入口 | 实际边界 | 对纯 WPF 操作的结论 |
| --- | --- | --- |
| `VisiWinNET.Forms.Key.StartEdit/StopEdit` | 分别调用其 DigitalItem 的编辑方法；StopEdit 另做 Invalidate | 不是已证明的 OpCon 手动开始/结束入口，未覆盖该控件鼠标路径的心跳/计时器 |
| `VisiWinNET.Forms.VarIn.StopEdit(bool)` | 最终调用原生 NumEdit.StopEdit | 不能把一个 WPF TextBox 的文本交给它就假定原生参数提交契约成立 |
| `Mod_VarIn.OnEndInit` | 注册原生数据并加载 Condition、TokenHandlingData 和 UnitDisabledData | 参数编辑依赖原生初始化与上下文，通用 Item 写入不足以证明这些门禁得到保留 |
| `Mod_ManualFunctionKey.OnMouseDown/Up` | 保护方法；原生按下/释放另含 SafetyTimer.Suspend/Resume、心跳Item附着/分离 | 找到的是控件输入生命周期；没有取得它作为外部语义调用的供应商支持契约 |
| `AuthorizationObject.IsAuthorized`、`IModeHandler` 的面板/模式/令牌属性及方法 | 可读取或执行相应原生职责 | 单独的授权值、SetTokenRequest 或 Run 不能替代完整手动功能握手 |
| `IShopfloorAppV2.AppViewElement → AppControlElementBase.Control` | Contract文件版/程序集版均2.0.1.0，Control类型为WPF FrameworkElement；另有语言和可见性生命周期 | 存在WPF视图承载契约；其已检查成员没有提供参数编辑/手动按下释放服务，实际工程承载也未运行验证 |

本轮结论是**在已核验程序集、控件及安装帮助范围内，尚未取得受支持的完整操作语义入口**；不宣称已穷尽所有版本、额外SDK或供应商扩展。此前额外六个程序集453个导出类型的公开成员元数据检查，也未找到可直接采用的完整手动服务；这是范围内的查找结果，不能用方法命名搜索证明某种能力绝对不存在。

微软文档将 OnMouseDown 定义为可供派生类覆盖的事件方法，并要求覆盖时调用基类以传递事件；这提供 .NET 继承机制的依据，没有提供 OpCon 对完整操作语义的承诺。[Control.OnMouseDown](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.control.onmousedown?view=windowsdesktop-9.0)。WPF 的捕获丢失还可能来自子控件，需要核对真正的捕获所有者；本轮新控件据此结束自己的输入生命周期。[WPF LostMouseCapture](https://learn.microsoft.com/en-us/dotnet/api/system.windows.uielement.lostmousecapture?view=windowsdesktop-9.0)。

因此新增的 `OpCon.WpfOperations` 只提供 WPF 参数框、手动键及**自有待适配契约**。它没有把接口同名方法冒充供应商已有API，也没有接入原生写入。默认操作禁用；本地探针只记录输入意图，不产生PLC反馈。原生适配下一步所需证据是：匹配SDK/正式扩展契约明确覆盖归属、权限、令牌、条件、编辑事务、心跳/计时器和释放，随后独立虚拟样例取得真实PLC接收与故障恢复证据。用户当前限制下不联系华沿、不使用共享工程会话。

后续扩大了配置/资源/代理提供器、NumEdit及归属类型的核验范围，仍未取得完整操作服务。
用户确认没有额外SDK。本轮读本机其他匹配Std及安装帮助、公开厂商资料；
具体服务边界和所缺契约已写入[原生适配记录](operations/NATIVE-ADAPTER.md)。
独立SFCLoader设计加载和真正ElementHost承载通过，证明自研WPF视图能够进入该承载结构；
没有验证CpStudio工具箱、正常Export、原生手动服务或PLC通讯。
