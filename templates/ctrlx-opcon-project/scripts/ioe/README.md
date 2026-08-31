# IO Engineering 辅助

IO 工程只能由 `config/project.yaml` 指定版本的 ctrlX IO Engineering/受控 IPC 处理。脚本必须支持 dry-run、
精确目标和回读；禁止用 PLC Engineering 打开 IO 工程。

## CpStudio I/O designator

每个工位先从自己的完整 ePLAN/CpStudio ASC 建立 `specs/io-designators.csv`，不要复制其他工位的
BMK 或点位。未使用通道的 `IoDesignator` 必须留空，才能保持 `Active=false`。

```powershell
pwsh -File scripts/ioe/New-CpStudioEplanIoAsc.ps1 `
  -InputCsv specs/io-designators.csv `
  -OutputAsc generated/cpstudio-io-designators.asc -Force

pwsh -File scripts/ioe/Test-CpStudioEplanIoExport.ps1 `
  -InputCsv specs/io-designators.csv `
  -BusConfigPath <Station>/PublicConfig/<BusConfig>.yaml
```

Project Pack 配置 `sources.ioDesignators` 后，`Build/Check` 会确定性生成并校验 ASC；Post-export
Stage 1 会只读核对导出的 BusConfig。CpStudio 的 Import、Save、Write designators、Export 和 PLE
Link I/O 仍使用官方工具完成。
