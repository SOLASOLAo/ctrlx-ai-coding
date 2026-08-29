# {{DISPLAY_NAME}} 工程目录标准

## 工作区边界

```text
<ProjectRoot>/
├── <StationDirectory>/       CpStudio/PLC/HMI 受控集成工程
├── Std/                      供应商标准对象，只读
└── <AiRepository>/           当前 AI 旁车仓库
```

标准化的是 AI 旁车，不移动或重命名供应商 Station 的 `Engineering/`、`Plc/`、`Hmi/`、
`EventRecorder/`、`PublicConfig/`，也不修改 `Std`。

## 归属边界

| 内容 | 唯一入口 |
|---|---|
| Station/Mode/Command、标准 Unit/AddOn/Peripheral、HMI、Event、StationData、BMK | CpStudio |
| PLC ST、AI-owned FB/DUT、Action/Method、SFC 图形属性 | PLC Engineering MCP/正式 REST |
| EtherCAT 硬件树和 IO 工程 | 匹配版本的 ctrlX IO Engineering/受控 IOE IPC |
| 需求、AI 归属、Catalog、源码、测试和报告 | 当前 Git 仓库 |

## CpStudio 导出闭环

1. 用户在 CpStudio 修改并导出；
2. Post-export hook 原子发布请求；
3. Stage 1 消费者只读生成 Git/指纹/ownership 审计报告；
4. Stage 2 PlanOnly coordinator 建立 operation ledger 和不可变、哈希绑定的 runner action；
5. P1.3b Host 自动发现 activation 后的 immutable `currentAction`；交互用户显式启动的唯一 P1.2b Broker 持有 persistent MCP/PLE 会话，按 ownership/hooks/graphical 审计或恢复 AI 增量，检查 I/O Mapping、BinIo、Symbol Configuration 和 SFC metadata，并回传 evidence；
6. P1.3c Host 复核 terminal result，并在 SHA 绑定及只读锁下把 sealed evidence 交给 release-bound 的纯离线 Stage 2 coordinator 推进 ledger；合法无 evidence 终态保持 `WAITING_FOR_COORDINATOR` 等待人工复核，busy 有界退避，其他 fresh ledger 异常阻断；仅在 evidence 明确要求时由用户执行 Export #2；
7. 绑定新的 Stage 1 报告，用显式 `clean_compile_project` 完成最终 Build，回读并记录完整 warning 签名、更新报告并提交。

Stage 2 coordinator 不启动 PLE、MCP 或 REST。P1.2a client 与 P1.2b interactive Broker 离线基础已实现，使用 Named Pipe v2、current-user registration、durable submit/query 和单 owner 租约。受控 adapter、语义证据 producer 及真实 PLE 离线 acceptance 通过前，生产 action 必须失败关闭。
P1.3a/P1.3b Host 是另一个当前用户后台生命周期：它自动消费 activation 后由权威 ledger
发布的 action，隔离历史已终态工作，并恢复旧 open claim。Agent 不在线时保持
`WAITING_FOR_AGENT`；Broker 始终由交互用户显式启动。Host 不启动 Broker、Node、MCP、PLE，
也不执行在线操作。P1.3c 自动 evidence 摄取和五文件内容寻址 immutable release 已实现；
Scheduled Task action 精确指向 active release exe，description 记录 `releaseId + manifest SHA-256`，
`Install` 负责首装/升级，`Rollback` 负责精确回退。P1.3c 的 production ingestor 6 项 E2E、
durable journal/reconcile、真实强杀恢复、升级回滚、损坏拒绝和 missing-deployment 安全卸载已在
参考工作站通过。显式 lifecycle 校验五文件/self-check；AtLogOn 自身不预检 deps/runtimeconfig。
P1.4a 团队离线包固定包含 `Install.ps1`、canonical wrapper/module、package manifest 与 Host
五文件；接收工位用 PowerShell 7 安装，Host 仍需 .NET 8 runtime，但不需要 Git、源码、SDK
或 build。安装器在任何命令前验证
path/length/SHA-256/contentId；同一 `Install` 用于首装/升级，fresh Install 默认不启动 Host，
升级保留原 running/stopped 状态；另提供精确 `Rollback`、安全 `Uninstall` 与 `Status`。包沿用当前用户默认权限，不设置自定义 ACL；数字签名
延期到商业发行或公司 IT 明确要求。独立 AtLogOn 五文件 prelaunch bootstrap、兼容矩阵和新工作站
验收仍未完成，所以 P1.4 保持开放。

## 通用与项目专用

公共方法论、初始化器、MCP 和通用 SFC 编译器保持单一事实源；本仓库只保存 {{STATION_ID}} 的配置、规格、
项目源码和薄适配。这样后续设备不会复制出多套难以同步的基础设施。
