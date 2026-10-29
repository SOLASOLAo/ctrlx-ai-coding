# ctrlX / CpStudio 库开发范例

维护日期：2026-10-16。三个范例随全局 `ctrlx-opcon-engineering` skill 安装，新项目不需要原 ST60 目录。
这里只包含自有文本源码、模拟工具和操作说明；原生工程、编译库、Std、供应商程序及许可证由接收项目准备。

| 范例 | 适用开发 | 可直接运行的部分 | 原生验证 |
| --- | --- | --- | --- |
| [MachineCommon](machinecommon/README.md) | 逻辑、定时、联锁、恢复 | PLC FB 与 16 项场景源码 | 在隔离 PLE 消费工程导入并运行 |
| [IND360](ind360/README.md) | TCP 通信库、Unit 就绪条件 | Python 模拟端和真实 PowerShell TCP 回归 | Ready 最小消费工程源码；通信闭环另验 |
| [INNTAI](inntai/README.md) | 串口协议、分片、测量结果 | Python 编解码/模拟器回归 | 八项实际 ST 串口字节夹具源码 |

## 开始一个新库

使用本机已经安装的 skill 路径；下面是本工作站的位置。其他电脑按自己的安装位置替换，不同时安装两个同名 skill。

```powershell
$skill = Join-Path $env:USERPROFILE '.codex\skills\ctrlx-opcon-engineering'
python "$skill\scripts\create_library_example.py" --example inntai --destination 'C:\Engineering\NewLibrary' --preview
python "$skill\scripts\create_library_example.py" --example inntai --destination 'C:\Engineering\NewLibrary'
Set-Location 'C:\Engineering\NewLibrary'
```

目标必须为空或不存在。复制命令不调用 CpStudio、PLE、MCP 或设备；接着按选中范例的 README 执行。
将 `inntai` 换成 `machinecommon` 或 `ind360` 可选择另一类范例。

向 Codex 提交任务时可直接说：

> 使用 $ctrlx-opcon-engineering 开发这个库，按最接近的范例准备最小消费工程和对应模拟验证。协议及接口以本项目资料为准。

## 从范例到新设备

先确认公共接口与真实协议，再修改库；原生库编译及独立消费通过后，运行相关场景。
需要 CpStudio 时再补 OOD/OTD/OSD、参数/I/O、生成调用和 HMI，最后在接收工程做 Reload/Export/回读/编译。
纯 PLC 库不必添加 HMI。SDK App/Data Layer/Snap 单独设计，不强套这三个范例。

每个库用自己的 README 记录四项即可：入口和依赖、公共接口、测试命令与覆盖范围、当前版本与未验项。
保留库版本、对象版本、目标 profile 和真正跑过的结果；不把历史通过次数当作新库验收。

Native ST 是原始场景的可搜索快照，部分保留当时排版；适配时遵守接收项目的 ST 规范。
模拟夹具是测试输入，不应生成到生产调用中。PC 测试、原生编译、PLC 仿真与实机验收分别报告。
