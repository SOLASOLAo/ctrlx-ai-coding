# {{DISPLAY_NAME}} 工程目录标准

## 工作区边界

```text
<ProjectRoot>/
├── <StationDirectory>/       CpStudio/PLC/HMI 受控集成工程
├── Std/                      供应商标准对象，只读
└── <AiRepository>/           当前 AI 旁车仓库
    ├── project-pack.json      Project Pack 唯一入口与源索引
    ├── schemas/               Project Pack/流程 JSON Schema
    ├── specs/processes/       审阅后的流程事实源
    ├── generated/             可重建的流程计划，禁止手改
    └── scripts/project/        流程计划 Build/Check 入口
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
4. Runner 用不可变 action 串行执行受控工程：Host 只管理 action 生命周期，
   唯一交互 Broker 才能持有 PLE/MCP 会话，coordinator 只校验证据和工程指纹；
5. 离线 Build、完整 warning 回读和报告通过后提交；只在证据明确要求时由用户
   执行 Export #2。

Runner 默认失败关闭，不会自动执行真机连接、下载、启停、写变量或 FORCE。
Host/Broker 的安装、升级和内部通讯属实现文档，不在目录标准里重复。

## Project Pack 与流程计划

- `project-pack.json`：项目入口，只引用现有项目事实；
- `schemas/`：约束 Project Pack 与 `specs/processes/*.process.json`；
- `specs/processes/`：保存 Chain 接口归属、Step ID/Kind/Comment、中英文提示、
  需求、步骤验收和验收测试；
- `generated/engineering-plan.json`：生成的 SFC 计划、提示、测试和追溯产物，禁止手改；
- `scripts/project/Build-CtrlXOpconProjectPack.ps1`：唯一 Build/Check 入口。

```powershell
pwsh -File scripts/project/Build-CtrlXOpconProjectPack.ps1 `
  -Command Build -EngineeringRoot . -RequireReady -Json

pwsh -File scripts/project/Build-CtrlXOpconProjectPack.ps1 `
  -Command Check -EngineeringRoot . -RequireReady -Json
```

`Build` 校验并确定性重建计划；`Check` 重算并逐字检查计划与源指纹。
Phase 2 只生成工程计划，不自动配置 CpStudio，也不启动或写入 PLE/MCP/REST。

## 通用与项目专用

公共方法论、初始化器、MCP 和流程计划生成器保持单一事实源；本仓库只保存 {{STATION_ID}} 的配置、规格、
项目源码和薄适配。这样后续设备不会复制出多套难以同步的基础设施。
