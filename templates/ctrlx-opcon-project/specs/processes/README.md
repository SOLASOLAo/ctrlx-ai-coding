# Process specifications

每个 `*.process.json` 是一个 Chain 的唯一流程事实源，并必须通过
`schemas/process.schema.json`。Step 在一处记录 `id`、`kind`、短 Comment、操作、提示、
需求与验收条件；生成器只产出 SFC 计划、双语提示、测试骨架和追溯关系，不写入 PLE/CpStudio。

CpStudio 生成的 Chain 接口只登记为 `interfaceOwner: cpstudio`，不得由生成器补写或改写。
