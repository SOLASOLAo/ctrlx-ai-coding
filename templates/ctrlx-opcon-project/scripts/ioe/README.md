# IO Engineering 辅助

IO 工程只能由 `config/project.yaml` 指定版本的 ctrlX IO Engineering/受控 IPC 处理。脚本必须支持 dry-run、
精确目标和回读；禁止用 PLC Engineering 打开 IO 工程。

## CpStudio I/O designator

每个工位先从自己的完整 ePLAN/CpStudio ASC 建立 `specs/io-designators.csv`，不要复制其他工位的
BMK 或点位。未使用通道的 `IoDesignator` 必须留空，才能保持 `Active=false`。

```powershell
pwsh -File scripts/ioe/Convert-CpStudioEplanIoAscToCsv.ps1 `
  -InputAsc <本工位电气导出的完整.asc> `
  -OutputCsv specs/io-designators.csv -Force

pwsh -File scripts/ioe/New-CpStudioEplanIoAsc.ps1 `
  -InputCsv specs/io-designators.csv `
  -OutputAsc generated/cpstudio-io-designators.asc -Force

pwsh -File scripts/ioe/Test-CpStudioEplanIoExport.ps1 `
  -InputCsv specs/io-designators.csv `
  -BusConfigPath <Station>/PublicConfig/<BusConfig>.yaml
```

外部电气交换统一只接受 ASC，不支持 AML/XML/OHD。ASC intake 严格检查
UTF-16LE-BOM、CRLF、15 列、模块和地址连续顺序、DI/DO 类型以及 `E`/`X` 双语列。
空 `I/O designator` 保持 inactive；与当前设备/地址精确对应且无描述的 CpStudio
`_<normalized-device>_Channel_<address>` 自动名也会清空为 inactive。错设备、错地址或带描述的
相似占位名会被拒绝。inactive 行不得携带描述。已有 active 行缺少中英文时，
脚本会在结果中给出缺失计数；`X` 中没有中文字符（包括复制的英文）也计为缺中文，
随后在 canonical CSV 中补齐。
使用 `-Force` 覆盖已有 CSV 时，模块、地址和 DI/DO 类型集合必须完全一致；部分 ASC 或
拓扑漂移会在写入前拒绝。真正改变拓扑时，先输出到新的 CSV 路径并单独审阅。

Project Pack 配置 `sources.ioDesignators` 后，`Build/Check` 会确定性生成并校验 ASC；Post-export
Stage 1 会只读核对导出的 BusConfig。CpStudio 的 Import、Save、Write designators、Export 和 PLE
Link I/O 仍使用官方工具完成。
