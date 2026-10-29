# IND360：TCP 通信与 Unit 就绪范例

适合命令/应答式 ASCII TCP 库。协议样例是 MT-SICS；新设备的命令、生命周期和数字格式必须按自己的协议重新确定。

## PC 上直接运行

在复制出来的范例根目录执行，依赖 Python 3.12 标准库和 Windows PowerShell 5.1：

```powershell
python tests/simulation/ind360_wire.py
python tests/simulation/test_ind360_diagnostic.py
```

第一条启动临时回环端点并自测 14 项。第二条在随机回环端口运行真实 PowerShell 诊断客户端，覆盖 19 项通信检查及菜单/日志行为。
不需要 PLE、设备或 Python 第三方包。日志生成在本范例 `data/reports/ind360/`。

| 文件 | 用途 |
| --- | --- |
| [ind360_wire.py](tests/simulation/ind360_wire.py) | 14 个设备模拟端点；支持 PLC/COREvirtual 客户端接入 |
| [test_ind360_diagnostic.py](tests/simulation/test_ind360_diagnostic.py) | 实际 PowerShell 收发、只读启动、控制确认和未知结果保护回归 |
| [Test-Ind360.ps1](scripts/diagnostics/Test-Ind360.ps1) | 独立诊断客户端；范例默认地址改为 127.0.0.1 |
| [PRG_Ind360Minimal.st](plc/PRG_Ind360Minimal.st) | OpCon 初始化与 Ready 最小消费程序，不发送命令 |
| [FB_Ind360TestMode.st](plc/FB_Ind360TestMode.st) | 最小模式容器 |
| [OnInitHierarchy](plc/FB_Ind360TestMode.OnInitHierarchy.st) | 属于上述 FB 的方法，挂接 Unit 和 Extension |

## 通信场景与 PLC 闭环

PC 回归覆盖 SI/S/TA/I2/I3/I4/Z/T/TAC、分片 CRLF、负值、明确拒绝、错误应答、未完整回复、超时、超长回复和控制结果未知。
每个请求只发送一次；控制结果未知后保持锁定，读操作仍可用于诊断。

供另一个隔离客户端使用的模拟器：

```powershell
python tests/simulation/ind360_wire.py --serve --host 127.0.0.1 --first-port 4710
```

它提供连续 14 个端口，每个端口的命令和回复由 `COMMANDS`、`REPLIES` 的同索引项决定；并不是单端口完整仪表。
Ctrl+C 退出。COREvirtual 要访问主机模拟器时，明确指定可达的测试网卡地址和虚拟网络；虚拟机内的 127.0.0.1 指向虚拟机自己。

PLC 通信库修改必须再用实际 PLC 客户端连接这些模拟端点，或接入相同接口的字节夹具，检查 Tx/Rx、解析结果、超时、Cancel/Reset 和未知结果不重发。
不要把 PowerShell 的通过结果当成 PLC FB 的通信通过。

## 原生最小消费工程

历史基线是 PLE `ctrlX PLC 2.6.8`、`Ind360Scale 1.0.1.1`、命名空间 `IN_Ind360`；需要接收环境合法安装的 OpCon/Nexeed 依赖。
此包不包含编译库。获得目标库后先核对它的名称/公司/版本及实际 Library Manager 解析；测试新的版本要记录新的身份。

1. 在独立原生 Application 中建立 `FB_Ind360TestMode` 和 `PRG_Ind360Minimal`；使用 `(* BODY *)` 分开声明与实现。
2. 在 FB 下建立 `OnInitHierarchy` 方法，不能把它作为同级 POU。将最小程序加入周期任务。
3. 引用准确库版本及 `OC_OpconBase`、`OC_AtmoIpDataStream` 等实际依赖，执行 Clean Build。
4. 在经确认的本机 Simulation 中运行，要求 `Configured=TRUE`、`Ready=TRUE`、`Finished=TRUE`。
5. 明确记录 `TxCounter=0`。这个程序只验证初始化/Operational/Extension 许可，不发送 SI 或其他命令；通信运行需使用上一节的独立场景。

## CpStudio 生成与现场排障

公开通信 Enable、Channel、ResponseTimeout 和 MaxWeightAge；模板应在 STARTUP/ONLINE_CHANGE 等实际生命周期传入配置。
使用原生 TemplateEngine 展开配置，再检查生成的初始化调用；仅手写给最小工程赋值，不能证明模板已经正确。
更新 OOD 后依次选择正确对象版本、应用保存、Export、回读参数/调用/库引用并编译。

Ready 还受 Unit 状态、故障锁存、未结束命令和配置有效性影响；按命令开关 TCP 时，空闲 Connected=FALSE 可以正常。
现场诊断时先查网络/服务口和原始收发，再查 PLC ReadyDetail/状态/Enable/Tx/Rx。成功的 PC 读重不能证明 PLC 已经就绪。
本目录客户端的现场使用需明确目标；Z/T/TAC 会改变设备状态，不能作为无设备目标的环境检查执行。

## 来源与边界

代码来自 ST60 的 `McpCoding/tests/simulation`、`scripts/diagnostics`、`examples/IND360` 及 `src/plc/ind360/tests`。
便携调整仅为默认回环地址、自测随机端口及模拟端显式 host/端口参数；正式工程原件保持不变。
历史 `OfflineTest/IND360-CpStudio-20261006/generated-ready.json` 中 Ready 为 TRUE，且 `tcpCommandsSent=false`；这是就绪验证，不是 PLC 读重闭环。
新版本原生编译、PLC 通信及实物称重均需分别确认。
