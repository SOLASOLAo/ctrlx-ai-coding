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
3. 唯一 persistent MCP 会话执行差异与文本快照；
4. 根据 ownership/hooks/graphical 审计或恢复 AI 增量；
5. 检查 I/O Mapping、BinIo、Symbol Configuration 和 SFC metadata；
6. 完整离线编译、回读、报告并提交。

## 通用与项目专用

公共方法论、初始化器、MCP 和通用 SFC 编译器保持单一事实源；本仓库只保存 {{STATION_ID}} 的配置、规格、
项目源码和薄适配。这样后续设备不会复制出多套难以同步的基础设施。
