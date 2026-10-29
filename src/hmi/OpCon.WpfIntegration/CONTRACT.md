# 公开调用契约

## 宿主配置

`WpfViewHost` 是 WinForms `UserControl`，作为原生 `SmartControl` 的直接子控件；其中的 `ElementHost` 承载 WPF。操作控件与宿主是同级控件，保留原生父级和 `OwnerUnit`。不会把它们移入 WPF `WindowsFormsHost` 后再猜测原生单位归属。

| 属性 | 含义与有效条件 |
| --- | --- |
| `LayoutFile` | 相对 HMI 程序目录的自有 `.xaml`，最大 256 KiB；页面创建前配置，不能跳出该目录 |
| `ItemPrefix` | 当前实例在现有 VisiWin 工程中的前缀；初始化后不可换成另一个实例 |
| `HeartbeatItem` | 相对前缀的 PLC 周期计数/心跳；必须由独立于 HMI 的 PLC 周期持续更新 |
| `HeartbeatTimeoutMs` | 500–30000 ms，默认 2000；仅为显示与输入区域的新鲜度期限，不是 PLC 点动失效期限或安全回路 |
| `IsFresh` | 当前质量良好、观察到本次附着后的心跳变化，且采样/心跳未过期 |
| `ActiveItemCount` | 本宿主持有的显示/心跳 Item 数，最多 64；不代表新增通讯连接数 |
| `LastError` | 工程诊断信息；配置/布局/生命周期错误时显示值转未知，原生输入区域被遮断 |

宿主的配置和界面生命周期在 HMI UI 线程执行。目标页 `OwnerUnit` 变更、原生控件被其他父级接管或同一控件被另一个宿主占用均停止显示接入，不能悄悄沿用旧实例状态。

## XAML 配置

| 附加属性 | 用法 |
| --- | --- |
| `NativeSlot.ControlName` | 在矩形 `FrameworkElement` 上引用原生控件 `Name`；同页唯一，最多 64 |
| `NativeValue.Path` | `TextBlock` 的相对只读 Item 路径；数值不可用时显示 `—`，不把坏质量变成 FALSE 或 0 |
| `NativeValue.Format` | `IFormattable` 格式，例如 `0.0`；错误格式触发宿主诊断 |
| `NativeText.Group/Key` | `TextBlock` 使用原生 `LocalizedText`；读取当前语言，不设置 LCID，不重建原生操作控件 |

布局是受信任的库资源，不是装载任意来源 XAML 的沙箱。原生槽应为可完整显示、不重叠的矩形；不支持旋转、倾斜、被滚动裁切或覆盖在原生键上的 WPF 菜单。WPF/Win32 的层叠限制仍存在。

槽内手动键要求 `GlobalHotKey=False`，键盘通过当前焦点的原生 Tab/Space/Enter 路径操作。全局/硬件快捷键留在原生页面机制中，不能用可视区域遮断来冒充对这类外部输入的完整控制。区域关闭时暂时取消该控件的 Tab 停靠，恢复时还原原值。

## 操作、提交与反馈

- **参数**：操作者直接使用原有 `Mod_VarIn` 的触摸键盘或键盘输入/确认。Authorization、UseTokenHandling、Condition、范围、格式及提交规则由原生控件和 PLC 维护。宿主失活时使用公开 `StopEdit(false)` 取消未确认编辑，再通过正常焦点退出；切换原生语言本身不做该操作。
- **离散/按住型手动**：操作者直接按下/释放原有 `Mod_ManualFunctionKey`。ManualFunctionName、放行、控制令牌、标准执行/监视变量和厂商处理路径保留。适用哪种操作语义由原生手动功能/PLC 约定决定，不能凭控件外观推断。
- **完成**：以新鲜的 PLC/Unit 请求接收、Running、完成/错误及结果计数为准。UI 输入事件、点击返回、画面变色都不是执行成功。
- **权限与令牌**：宿主不设置原生 Enabled、Visible、Authorization、UseTokenHandling 或请求值；交互控件要求保留令牌处理。其区域遮断只能进一步限制可操作性，不会增加原生许可。
- **焦点/松开丢失**：按压时失去捕获会将焦点交还 WPF，使原生 LostFocus 路径处理释放；换页/失活也退出焦点。未调用私有方法、合成按压或直接清 Execute。实际客户端/控制器的有界失效结果必须按运行验收确认。

没有公开 `Execute`、`BeginPress`、`WriteParameter` 或排队重试入口。纯 WPF 按钮的命令转发不属于当前支持面；使用原生操作槽。若以后供应商提供正式语义 API，再独立扩展与验收。

## 断链、重开与释放

显示质量使用既有 Item 的质量值；`OPCQuality` 是这个 VisiWin API 的类型名，并不表示建立了 OPC UA 连接。宿主只附着自己的显示 Item，最多 64，250 ms 刷新；不启动驱动或另连 PLC/机器人。

首次打开、页恢复、断链后及 UI 长时间停顿后先视为未知，需观察到新心跳变化才开放显示/原生槽。没有保存旧 Execute、参数提交、点击或重试队列，恢复自身不发送控制请求。原有已接受动作和结果未知状态仍由 PLC/Unit 的原生契约处理。

关闭时停止计时器，解除自有事件，释放文本和显示订阅，取消布局占用，恢复原生控件原布局；不更改它们的父级、原生绑定或权限。HMI 进程完全挂起时这些清理不能运行，按住型失效期限必须由控制器/设备独立保证。该组件的超时不替代这个机制。
