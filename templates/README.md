# templates — AI 协作项目骨架模板

## ctrlX/OpCon 自动化项目（推荐）

新 CpStudio + ctrlX 项目不要手工复制现有 Station010 仓库。使用受控初始化器：

```powershell
.\scripts\New-CtrlXOpconProject.ps1 `
  -ProjectId 'example-cell' `
  -DisplayName 'Example Assembly Cell' `
  -StationId 'Station020' `
  -StationRoot 'C:\Engineering\ExampleCell\Station020' `
  -StandardLibraryRoot 'C:\Engineering\ExampleCell\Std' `
  -CpStudioProject 'Engineering\Stat020.cpsp' `
  -PlcProject 'Plc\Stat020_PLC.project' `
  -IoProject 'Plc\Stat020_IO.project' `
  -BusConfig 'PublicConfig\BusConfig_Stat020.yaml' `
  -OutputPath 'C:\Engineering\ExampleCell\McpCoding' `
  -WhatIf
```

去掉 `-WhatIf` 后才会创建。`OutputPath` 是将要生成的 AI 旁车仓库根目录，必须不存在；脚本绝不覆盖已有目录。
相对的 CpStudio/PLC/IO/BusConfig 参数以 `StationRoot` 为基准。生成后的 `config/project.yaml` 只保存相对于
`OutputPath` 的正斜杠路径，不复制 Station、`Std`、`.project` 或闭源资料。

离线自测：

```powershell
.\tests\Test-New-CtrlXOpconProject.ps1
```

`templates/ctrlx-opcon-project/` 是该初始化器的唯一模板事实源；Codex Skill 只调用初始化器，不维护第二份模板。

## 通用代码项目

> Codex 标准开发框架:任何新代码型项目都从本骨架派生,继承"四文档纪律 + 会话循环"。

## 派生流程

```bash
# Windows
xcopy /E templates\ai-repo-skeleton ..\MyProject
# Linux
cp -r templates/ai-repo-skeleton/. /path/to/MyProject/
```

然后:

1. 把四个文档中所有 `<项目名>` 占位符替换为项目名
2. 按提示填写四个根文档(README/AGENTS/HANDOVER/TODO)
3. 按技术栈展开 `src/`(如 .NET:`src/<App>/`;Python:包目录;C:模块目录)
4. `git init` → 首次提交 → 推 GitHub

## 四文档纪律(模板的灵魂)

| 文件 | 职责 | 何时更新 |
|---|---|---|
| AGENTS.md | AI 进场手册:定位/分工/红线/环境事实 | 红线、环境、分工变化时 |
| README.md | 人类手册:是什么/快速上手 | 功能、接口变化时 |
| HANDOVER.md | 会话交接:上次做到哪 | **每次会话结束前** |
| TODO.md | 任务清单:优先级+验收标准 | 随时勾选,新任务入列 |

## 会话循环(Codex 标准流程)

**进场(新会话前 3 分钟)**

1. 读 `AGENTS.md` —— 红线与分工
2. 读 `HANDOVER.md` —— 上次做到哪
3. 读 `TODO.md` —— 这次做什么

**收场(会话结束前必做)**

1. 更新 `HANDOVER.md`:做了什么/产出/未解决/下次第一步
2. `TODO.md` 勾选已完成,新任务入列
3. 提交并推送(`feat: fix: docs: test: tools: refactor:` 前缀)

## 目录约定

| 目录 | 放什么 |
|---|---|
| docs/ | 人写的技术文档、结论、报告 |
| src/ | 源码 |
| tests/ | 测试脚本/框架 |
| examples/ | 示例程序 |
| tools/ | 辅助脚本 |
| data/ | 机器生成的原始数据(测量/日志);大文件入 .gitignore,结论进 docs/ |

## 已按此模板衍生的项目

- **FreePLCDemo** —— 路线④ PREEMPT_RT + IgH EtherCAT + OpenPLC v4 软 PLC 原型
  (`/media/administrator/D/FreePLC/FreePLCDemo`,2026-08-12)
