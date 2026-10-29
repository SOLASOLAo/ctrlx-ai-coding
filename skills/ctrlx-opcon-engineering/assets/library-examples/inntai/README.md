# INNTAI：串口帧与结果时序范例

适合 RS232 命令、异步结果和独立 Ready 输入的设备库。生产协议保持 RS232；本范例的 TCP 仅承载模拟用的原始字节。

## PC 上直接运行

在复制出来的范例目录执行，Python 3.12 标准库即可：

```powershell
python -m unittest discover -s tests -v
```

测试包含帧校验、各分片边界/粘包、BCC 等于 STX/ETX、负值/非法字段、参数范围和本机模拟器往返。
模拟器使用随机回环端口，测试结束关闭，不读取串口或连接 PLC。

需要交互模拟时另开终端：

```powershell
python scripts/inntai_simulator.py --host 127.0.0.1 --port 4546 --fragment 17 --fault none
```

Ctrl+C 退出，原始字节日志在 `tmp/simulator-wire.json`。`--help` 列出超时、断线、ER1/ER2、校验错误、旧结果、错误通道、NG 等注入选项。
默认的单元测试没有逐项运行全部故障模式；协议变更时应选择相关模式并验证实际 PLC 客户端。

## 文件和协议合同

| 文件 | 用途 |
| --- | --- |
| [inntai_protocol.py](scripts/inntai_protocol.py) | 帧/BCC、78 字节 CS 结果、参数编码 |
| [inntai_simulator.py](scripts/inntai_simulator.py) | 独立本机设备模拟端；WP 参数库与面板当前通道分开 |
| [test_protocol.py](tests/test_protocol.py) | 八项 PC 回归 |
| [PRG_AutoResult.st](plc/PRG_AutoResult.st) | 八项主动结果与 Ready 时序测试 |
| [FB_InntaiWireFixture.st](plc/FB_InntaiWireFixture.st) | 实现原生串口接口的字节夹具 |
| [Read](plc/FB_InntaiWireFixture/Read.st) / [Write](plc/FB_InntaiWireFixture/Write.st) | 最大 17 字节分片、发送计数和模拟回复 |

串口历史配置：9600、8N1、无握手；CS 结果为 78 字节线帧。命令帧使用 STX、ASCII 负载、ETX、XOR BCC，不能按一帧一次 Read 假设处理。
WP 收到 OK 表示参数下发已确认，不自动 RP 回读，也不假定已切换面板当前通道。
启动 ST 的 ACK、测量完成和新鲜有效结果分别处理；新结果须匹配通道并区别于启动前流水号。控制超时不自动重发 ST。
这些是此设备范例的合同，新设备需重新定义。

## 原生 PLC 运行

此原生夹具基线为 **InntaiLeakTest 1.1.1.1 / InntaiLeakTestLib / IN_Inntai**，PLE `ctrlX PLC 2.6.8`。
需要实际库及其合法标准依赖，尤其是夹具继承的 `OC_AtmoEcBcEx600x.EcBcEx600xChan`（Ex600x）。它不运行真实 EL6001 或 EtherCAT 总线。

1. 在独立消费工程引用准确编译库；不要沿用历史文件名猜测当前引用版本。
2. 创建 `FB_InntaiWireFixture` 和 `PRG_AutoResult`。按 `(* BODY *)` 分开声明与实现。
3. 在夹具 FB 下创建 `ClearError`、`Close`、`Flush`、`Open`、`Read`、`Write` 六个方法；每个文件给出完整签名与实现。不要把方法导入成同级 FB。
4. 周期任务调用 `PRG_AutoResult()`，原生 Clean Build。确认实际本机 Simulation、工程身份和 owner 后，完整初始化并运行。
5. 最多等待 30 秒：`Finished=TRUE`、`Failed=FALSE`、`Passed[1..8]` 全 TRUE；同时读取 CompletionAge、CompletionCycles、ErrorDetail、StartCalls/CsCalls。
6. 结束后 STOP/logout，确认实际已离线。重新测试须重新初始化夹具和库状态；不能仅把 Finished 清零而保留上轮队列。

夹具通过真实串口接口传递帧，包含分片和异步延迟；Python 模拟器无需同时运行。
`MeasurementTimeout=T#1MS` 用于证明此基线合同中该兼容字段不限制总测量时间，不能照搬给其他设备。
程序读取 Step/PendingResult 等本库诊断字段，属于该版本的回归夹具；新库改接口时需同步适配。

| 场景 | 预期 |
| --- | --- |
| 1、2 | 有主动新结果时，仍等待真实 Ready 连续达到锁存延时；无提前 Done |
| 3 | 无主动上传时保留两轮 Ready 后主动取结果的路径 |
| 4、5 | 旧流水号不能完成；错误通道报错且结果无效 |
| 6 | Ready 在最终延时内抖动，重新计算完整延时 |
| 7、8 | Ready 未满足或无结果时保持 Busy；取消清除待处理结果 |

更长测量、通信恢复、参数下发和设备其他命令按实际变更另加场景；八项不是整库全覆盖。

## CpStudio 接入

按目标版本设置 SerialChannel、Ready 输入、ResponseTimeout、ResultReadDelay 等离线参数，明确生成的初始化和循环调用。
EL6001 通道/I/O 由匹配 IOE 和目标模型配置，不能换成生产 TCP 接口来让模拟通过。
手动待写参数与自动命令参数分别归属；HMI 区分下发确认、读回参数和实际完成。库布局改变时检查 OOD、模板、Symbol 和迁移要求。

## 来源与验收边界

PC 源来自独立 `INNTAI LeakageTest/scripts`、`tests/test_protocol.py`。
PLC 文件从 ST60 `OfflineTest/ST60-Inntai-AutoResult-20261012/fixture-sources.json` 的最终声明/实现逐对象提取，包含当时生成的夹具增量。
同目录 `native-runtime.json` 历史记录：1.1.1.1、本机 Simulation、8/8、编译 0/0、已停止并注销，无实体操作。
没有复制历史 PLE PID、工程路径、在线 helper 或运行回执，也没有把更新中的 1.1.1.2 当成本范例验收版。
本次整理未重新执行 PLC 仿真；真实 EL6001 电气/PDO 时序及仪器行为始终需要现场验收。
