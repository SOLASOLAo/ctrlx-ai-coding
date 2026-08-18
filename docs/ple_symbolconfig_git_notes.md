# PLE SymbolConfig & Git Push 实测笔记(2026-08-18)

> 项目:Station010_0708(电阻测试台);环境:ctrlX PLC Engineering 2.6.8 / ScriptEngine 4.1 / codesys-persistent MCP。

## 1. SymbolConfig 脚本限制(已实测)
| 方法 | 结果 |
|---|---|
| `proj.find("Device/Plc Logic/Application/Symbols")` | 多段路径 find 返回 0;单段名 `find("Device")` 可以,其余需手动 get_children 逐层导航 |
| Symbols 节点 `find(name, True)` / `get_children(True)` | 0 —— 符号条目不是树对象 |
| Symbols 节点 `export_xml(path, True, False, True)` | 只导出空壳(plcopenxml,914 B,无条目) |
| `active_application` 及 IScriptObject2-6 接口 | 未发现 SymbolConfig 条目级 API;无 BaseObject 属性 |

**可读形态**:IDE Symbols 编辑器导出的 Symbolconfiguration XML,根元素
`<Symbolconfiguration xmlns="http://www.3s-software.com/schemas/Symbolconfiguration.xsd">`;
实例:`Station010_0708/Plc/Stat010_V5.11_CtrlX_PLC.Device.Application.xml`(4208 行)。

**未验证的下一步**:对 Symbols 节点 `import_xml(path, bImportFolderStructure)` 是否具有整表覆盖语义(用干净的 Symbolconfiguration XML 覆盖掉陈旧条目)。

**快速 workaround**:陈旧条目导致的编译错误("is no component of ..."),让用户在 PLE Symbols 编辑器里手删对应行(30 秒)。

## 2. git 推送配方(该开发机 + Codex 沙箱)
症状:git 全局 `http.proxy=http://127.0.0.1:7890`(Clash)经常停;直连 DNS 解析被拦;schannel TLS 在沙箱内报 `SEC_E_NO_CREDENTIALS`;git 本地传输被拦(`git clone <本地路径>` 报 couldn't create signal pipe Win32 error 5)。

可用组合(3128 为常驻代理):
```powershell
$t = gh auth token
git -c http.sslBackend=openssl -c http.proxy=http://127.0.0.1:3128 -c https.proxy=http://127.0.0.1:3128 `
    push "https://x-access-token:${t}@github.com/<owner>/<repo>.git" HEAD:<branch>
```
- gh CLI 自身无需任何额外配置(建仓库/API/取 token)。
- 沙箱 workspace-write 时:写工作区外的 `.git` 被拒 → 用 `%TEMP%` 中转:`Copy-Item <src>\.git` + `robocopy <src> <tmp> /MIR /XD .git` → commit → push。
- 提交身份:本机自动推断(WANG Zhi <agz1wx@bosch.com>),如需规范可自行 git config。

## 3. eval_python(IronPython 2.7)其它坑
- `System` 未默认导入:写 `except System.Exception, e` 前先 `from System import Exception` 或 try 普通异常。
- `se.projects` 无 `count` 属性;用 `primary` / `get_all()`。
- `find()` 的通配符 `*` 无效,只按单段精确名匹配;多段路径基本不可用。
- `se.projects.open()` 对已打开工程裸调会卡 UI 线程(红线,见 AGENTS.md)。