# MachineCommon：逻辑与定时库范例

适合按钮、压力监控、设备许可等以周期调用和输入反馈为主的库。此范例选择主气压过滤场景，避免把 ST60 的门锁接线和工站流程带入新项目。

## 文件与依赖

| 文件 | 用途 |
| --- | --- |
| [FB_MainPressureControl.st](plc/FB_MainPressureControl.st) | 自有主气压 FB 源码快照；只移除了注释中的本站点号 |
| [PRG_PressureFilter.st](plc/PRG_PressureFilter.st) | 调用编译库的 16 项周期测试 |

历史环境：PLE profile `ctrlX PLC 2.6.8`，库 `MachineCommon 0.1.1.1`，命名空间 `MachineCommon`。
FB 使用标准 `TON`；在原生库中声明实际标准依赖，不能靠应用已安装库掩盖缺失引用。
测试程序引用 `MachineCommon.FB_MainPressureControl`，需要先构建并安装这个库，或明确改成新库自己的命名空间。

## 开发和原生运行

1. 在独立原生库中定义公共输入：MonitoringEnabled、ControlOn、ValveRelease、两路反馈、监控时间、失压过滤时间；输出明确阀命令、就绪、许可和故障锁存。
2. 使用 typed MCP 创建/更新 FB，把源码中 `DECLARATION` 与 `IMPLEMENTATION` 后的内容分别写入并回读。不要把说明性分隔注释当成对象名称。
3. 对库所有对象执行原生编译检查，核对名称/公司/版本/命名空间；经既有 native component 路径导出并安装编译库。
4. 使用接收环境合法取得的最小原生 Application，在独立目录建立消费工程；明确引用刚安装的版本，创建 `PRG_PressureFilter` 并放入周期任务。
5. 先 Clean Build；运行前确认当前工程、唯一 PLE owner、Simulation 已启用以及虚拟操作范围。使用约 1–5 ms 周期，充分初始化后运行。
6. 最多等待 5 秒，要求 `Finished=TRUE`、`Failed=FALSE`、`Pass[1..16]` 全为 TRUE；读取 `LossElapsed` 和 `CustomLossElapsed`。结束后 STOP/logout，核对实际已离线。

不要用 Python 重写一个压力模型并据此宣布 ST 已通过。此范例的行为验证发生在 PLE 中；本次工具包整理没有重新运行它。

## 场景覆盖

| 断言 | 检查 |
| --- | --- |
| 1、11 | 持续失压分别达到默认 200 ms、自定义 350 ms 后撤销输出；允许约 50 ms 的扫描/采样余量 |
| 2、3 | 短时失压和反复抖动不会累计成故障 |
| 4 | 过滤时间为零时的立即失压处理 |
| 5、10 | 建压超时、关闭后反馈未复位 |
| 6 | 两路互斥反馈同时有效时立即报错 |
| 7、8、9 | ControlOn、应用许可、监控使能撤销时立即关闭输出 |
| 12、13、14 | 不确定反馈、初始未建压、重新建立压力的状态处理 |
| 15、16 | 默认参数和初始未就绪；满足复位条件后清除故障 |

修改任务周期或时间参数时，重新核对窗口和容差，不能放宽断言掩盖行为变化。

## 接成 CpStudio AddOn

按目标环境原生 schema 设置 `.ood` 参数、变量引用、I/O 端口、`Library.osd` 和 `Export/Addon.otd`。
参数显示、原生模板展开、最终消费工程编译分别检查。启用但漏绑的必填项应明确失败。
生成调用负责读取配置输入、调用 FB 和写配置输出；输出及 ControlOn 许可各有一个写入者。
关闭组件时的输出行为须由新组件合同明确规定。单压力开关与双反馈模式应各有测试。

MachineCommon 的按钮和门锁是同类开发方法的扩展，不包含在这两个源文件中。不要复用本站临时门锁常量、反馈极性或联锁设置。

## 来源与验收边界

来源：ST60 的 `McpCoding/src/plc/machinecommon/FB_MainPressureControl.st` 与
`OfflineTest/ST60-PressureFilter-20261005/PressureFilter.st`；历史同目录 `build-and-test.json` 记录库 0.1.1.1 的实际本机 PLE Simulation 16 项通过。
日期：2026-10-05；这里保存的是可复用场景源码，不包含旧 runtime 回执或生产工程。
新库/新版本必须重新编译和运行。物理阀、压力开关及安全功能另行验收；单压力开关低电平不等于安全零压。
