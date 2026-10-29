# Third-party sources

## CODESYS Persistent MCP

The watcher, script templates and related patches under
`patches/codesys-mcp-persistent-crlf/` and the CODESYS-related assets in
`skills/ctrlx-opcon-engineering/assets/` derive from or adapt
[luke-harriman/Codesys-MCP](https://github.com/luke-harriman/Codesys-MCP).
The maintained compatibility target is `codesys-mcp-persistent 0.6.3`.

Upstream uses the MIT License. Its copyright and permission notice is preserved
in [LICENSE.codesys-mcp-persistent](LICENSE.codesys-mcp-persistent).
Project-specific changes include ctrlX compatibility, bounded diagnostics,
ownership checks and native state readback; they do not imply upstream or vendor endorsement.

## Vendor engineering and HMI software

CpStudio, OpCon, VisiWin, PLCHandler, CODESYS and ctrlX engineering/runtime
components remain external dependencies subject to their respective terms.
This repository does not grant their licenses or redistribute their assemblies,
compiled PLC libraries, project containers, SDK installers or manuals.
The CpStudio bridge is an experimental version-specific interoperability adapter,
not a vendor-supported external API.
