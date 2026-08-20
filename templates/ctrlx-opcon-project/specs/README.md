# specs — 已确认需求

聊天和会议记录是需求入口，本目录才是供代码生成和审计使用的长期事实源。

- `station.yaml`：Mode/Command Handler、AddOn 和全局运行条件；
- `io.yaml`：BMK、方向、用途、模块/通道与验证状态；
- `events.yaml`：事件符号、设计号、类别、触发和复位；
- `units/`：Unit 实例、精确类型版本、I/O、手动联锁和 Home 条件；
- `chains/`：输入输出、Step/Comment、分支、跳转和取消清理。

不知道的内容写 `status: pending` 或 `verification: pending`，不得猜成已验证事实。
