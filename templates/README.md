# templates/ai-repo-skeleton — AI 协作项目骨架模板

新建代码型项目时:

1. 复制本目录为项目根:`xcopy /E templates\ai-repo-skeleton ..\MyProject`
2. 重命名占位符 `<项目名>`;按提示填写四个根文档
3. 按技术栈展开 `src/`(如 .NET:`src/<App>/`、`src/<App.Protocol>/`;Python:包目录)
4. `git init` → 首次提交 → 推 GitHub

## 四文档纪律(模板的灵魂)

| 文件 | 何时更新 |
|---|---|
| AGENTS.md | 红线/环境/分工变化时 |
| README.md | 功能/接口变化时 |
| HANDOVER.md | **每次会话结束前** |
| TODO.md | 随时勾选,新任务入列 |

## 已按此模板衍生的项目
- (待补充:hmi-framework、EtherCATSlave 等)