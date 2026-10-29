# WPF 控件库的 OpCon 原生适配目标与接口缺口

维护日期：2026-10-20。结论：**纯 WPF 前端、原生 SmartForms 装载及宿主生命周期已有
独立证据；参数提交和手动按下/释放尚未接通。没有取得匹配版本的完整受支持操作契约。**
这不是 WPF 不兼容的结论，也不是所有版本都没有接口的结论。

## 产品目标

在自研功能库（例如华沿机器人库）中，用 WPF 编写该库的界面、参数框和操作按钮，
作为功能库自身的 HMI 部分接入 CpStudio 生成的 HMI。用户强调的主要目的，是该库的
WPF 界面与现有 OpCon/CpStudio 环境、通讯和原生操作机制兼容。
通用控件与宿主是实现这一目标的支撑。正常使用仍通过配置和绑定设置实例、参数、
手动功能、权限及文字；“实例配置独立于 DLL”属于实现选择，不作为产品目标本身。
兼容性按经过验证的 HMI/驱动/框架组合声明，不以“使用 WPF”推导跨版本兼容。

目标路径：

```text
自研功能库（例如华沿机器人库）的 WPF 界面和按钮
  → CpStudio 对象 HMI View / SmartForms 进程内宿主
  → OpCon 原生操作适配器【当前缺口】
  → 既有 VisiWin 会话 → CoDeSysV3 → PLCHandler → ctrlX PLC
```

权限、OwnerUnit/面板归属、控制令牌、放行、参数校验、按下/释放及心跳仍由原生机制维护；
PLC/Unit 独立提供请求接收、执行、完成/错误反馈。UI 分发返回不能表示 PLC 已执行。
不为 WPF 新建 OPC UA、PLCHandler 会话或机器人连接。
WPF App 承载接口可能涉及独立进程，不能据其存在推断可以直接复用 HMI 内的会话。

## 本轮核验范围

- 本机安装的 CpStudio 5.11 英文帮助及导出类帮助位置；已读 HMI 原生控件、
  SmartControlHost、硬件键映射、Export 脚本等相关主题。
- 匹配 HMI Forms/Shared 5.11.1.52、VisiWin 6.5.5.25、Shopfloor Contract 2.0.1.0
  的公开/保护成员。新增检查 NumEdit、配置/资源适配器、代理提供器、ActionDescription、
  ConditionData、DataConnector、IBelongToUnit；当前固定探针覆盖 34 类。
- 公开的 Bosch/Nexeed 发布说明、开发服务说明和公开搜索；未取得匹配版本的操作 SDK。
  搜索无结果不是不存在的证明，没有访问需要额外权限的内部门户。
- 用户确认目前没有该 SDK/扩展手册。`Std/Hmi_V5_11` 提供运行 DLL，
  构建脚本的 `-HmiSdk` 参数名不能将它变成完整开发 SDK。

本轮匹配依赖只读自 ST60 的 Std；没有修改华沿工程、供应商文件、共享 CpStudio/PLE，
没有启动驱动或联系控制器。

## 已取得的具体接口与边界

| 接口 | 证据 | 尚不能据此实现的部分 |
| --- | --- | --- |
| `Mod_ManualFunctionKey` | 公开配置 ManualFunctionName、UseTokenHandling 等；保护 OnMouseDown/Up 包含原生 SafetyTimer/心跳生命周期 | 没有取得允许外部 WPF 语义调用且覆盖完整原生门禁的文档化按下/释放对 |
| `ButtonBase.PerformClick()` | 检查 CanSelect 后走 OnClick，没有调用 OnMouseDown/Up | 不能当作原生按下/释放等价入口 |
| `Key.StartEdit/StopEdit` | 调用 DigitalItem 编辑事务 | 没有证明覆盖 OpCon 手动功能的心跳/计时器及归属机制 |
| `Mod_VarIn` / `VarIn.StopEdit` | 原生初始化加载 Condition、令牌及 Unit 禁用状态；StopEdit 进入其 NumEdit | 没有取得外部 WPF 草稿开始/验证/提交的完整受支持契约 |
| `VisiWinNET.Forms.Internals.NumEdit` | 公开 StartEdit/IsEditing/StopEdit；后者处理数值、限值和 Item 编辑提交 | 仍是原生控件的内部编辑器类型。通过 Controls 枚举找到它，不等于存在受支持、可独立调用的 OpCon 参数服务 |
| `AuthorizationObject.IsAuthorized`、`IModeHandler` | 授权查询、面板/模式状态和令牌请求等公开成员 | 单个方法无法证明一次参数或手动事务完整保持所有原生约束 |
| `IShopfloorAppV2` / `AppControlElementBase` | WPF FrameworkElement、语言、可见性、初始化和释放 | 视图生命周期不提供上述 PLC 操作事务 |
| `IAppConfigurationAdapter` | 泛型 LoadConfiguration / SaveConfiguration | 配置存储；没有原生手动服务契约 |
| `IAppResourceAdapter` | 文件上传、下载、删除及观察 | 资源接口；不能解释为 PLC 参数写入 |
| `IProxyProviderService` | 泛型 GetClient / GetPooledClient | 还需要实际受支持的服务类型、地址来源、所属会话和语义契约，不能猜一个服务来调用 |
| `ActionDescription.Target` | App 自己提供的 Action 委托及参数字典 | 不是 HMI 提供的通用手动操作服务 |

工具现在还输出公开 Text setter 的调用点。调用点中 `Control.set_Text` 的声明类型
不能单独确定它的接收对象或完整运行行为；没有据此断言设置 `VarIn.Text` 一定有效或一定无效。
研究工具不调用这些 setter，不读写供应商实例私有字段，也不复制供应商实现。

可重复检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Inspect-Operations.ps1 `
  -HmiSdk 'C:\YourProject\Std\Hmi_V5_11'
```

## 需要补齐的供应商契约

以下是可直接交给 Nexeed/Bosch 技术支持的问题清单；本轮没有发送邮件或消息。

1. 对 HMI 5.11.1.52 / VisiWin Embedded 6.5.5.25，是否提供 HMI 控件扩展或
   Shopfloor App 开发 SDK？请给匹配版本的接口文档和可编译最小示例。
2. 原生参数服务如何绑定 OwnerUnit、现有 Item、Authorization、Condition、令牌、
   数据类型/单位/限值，并开始、验证、确认及取消一次编辑？如何区分 HMI 写入回执与 PLC 应用结果？
3. 原生手动服务如何按 ManualFunctionName 执行按下/释放，保留面板归属、令牌、放行、
   心跳/SafetyTimer、离散/按住语义，并读取 Running/Done/Error 及错误来源？
4. 是否正式支持在 SmartControl 内派生 `Mod_ManualFunctionKey` / `Mod_VarIn`，
   以 WPF 渲染和输入并调用基类保护事件？若支持，请明确焦点、触摸、
   计时器、生命周期和释放条件；仅有 .NET protected 可见性不足以作此承诺。
5. 扩展如何复用 HMI 已初始化的 CoDeSysV3/PLCHandler 会话？App 是否必须使用
   指定的进程模式或宿主服务？重连和页面重建如何使旧输入失效？
6. 给出程序集注册、工具箱/SmartForms 配置、对象库 Export/部署及版本升级兼容规则。

在契约缺失时，已有的可见原生控件承载方案仍是备选：
同页真正的 Mod_VarIn/Mod_ManualFunctionKey 接收操作者输入，WPF负责外围视觉。
它的操作控件仍是 WinForms，**不作为本次“自研 WPF 操作控件已完成”的替代结论**。
没有用隐藏控件假点击、私有字段、直接写 Execute 或重建一套握手来填补缺口。

## 下一阶段完成条件

取得可用契约后，在同一前端端口上实现版本明确的适配器，绑定和文本留在配置中。
随后用独立自有虚拟消费者验证真实 PLC 参数回读与请求次数、Unit 状态和执行错误；
覆盖权限/令牌丢失、释放丢失、换页、HMI 挂起/退出、断线、重连、重开与恢复不重放，
记录 PLC 扫描计数和周期。输入探针、原生加载器和静态检查都不替代这一步。
共享 PLE/CpStudio 和现场设备仍不在本轮允许范围内。

官方材料：

- [Control plus V2.11 发布说明](https://community.bosch-connected-industry.com/nexeed-automation/releasenotes/post/control-plus-v2-11-mUaIvWdjv9OwH9R)：
  HMI V5.11 支持需要 Framework 4.8 的 App；不是完整操作 SDK 的说明。
- [WinForms 与 WPF 输入互操作](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/windows-forms-and-wpf-interoperability-input-architecture)：
  用于宿主/焦点设计，不能替代 OpCon 操作契约。
