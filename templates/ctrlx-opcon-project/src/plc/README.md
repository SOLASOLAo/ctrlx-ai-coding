# PLC 可读源码

- `common/`：不依赖当前 Station、BMK 或项目 Event 的通用 FB/DUT；
- `project/{{STATION_ID}}/`：当前项目完整 AI-owned POU；
- mixed CpStudio 对象不保存整对象副本，只在 `ai/hooks.yaml` 登记最小语义钩子。

源码写入加密工程时必须走 MCP/正式 REST，随后回读并完整离线编译。
