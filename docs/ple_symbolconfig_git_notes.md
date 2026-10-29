# PLE SymbolConfig & Git Push 实测笔记(2026-08-18)

> 项目:Station010(电阻测试台);环境:ctrlX PLC Engineering 2.6.8 / ScriptEngine 4.1 / codesys-persistent MCP。

## 1. SymbolConfig 接口边界(已实测，2026-08-18 修订)
| 方法 | 结果 |
|---|---|
| `proj.find("Device/Plc Logic/Application/Symbols")` | 多段路径 find 返回 0;单段名 `find("Device")` 可以,其余需手动 get_children 逐层导航 |
| Symbols 节点 `find(name, True)` / `get_children(True)` | 0 —— 符号条目不是树对象 |
| Symbols 节点 `export_xml(path, True, False, True)` | 只导出空壳(plcopenxml,914 B,无条目) |
| 动态扩展方法 `get_only_configured_datatypes()` | 可读取已配置数据类型及成员；节点显示名虽为 Symbol Configuration，内部名实际是 `Symbols` |
| 动态扩展方法 `get_all_datatypes()` | 本工程触发 `An item with the same key has already been added`；这是上层 `ScriptSymbolConfigObject` 包装器缺陷，不是工程数据损坏 |
| 底层 `ISymbolConfigObject.GetAvailableDatatypeSignatures(False)` | 可正常返回全部数据类型并唯一找到 `BinIo`，用于只读审计 |
| PLE REST `symbol-config` GET/PUT | **正式读写入口，已验证 Select/UnSelect 成功并持久化** |

IDE Symbols 编辑器导出的 Symbolconfiguration XML 仍是可读快照，根元素
`<Symbolconfiguration xmlns="http://www.3s-software.com/schemas/Symbolconfiguration.xsd">`;
实例:`Station010/Plc/Stat010_V5.11_CtrlX_PLC.Device.Application.xml`(4208 行)。

正式 REST 基地址必须使用 Swagger 声明值：

```text
http://localhost:9002/plc/engineering/api/v2
```

应用 Symbol Configuration：

```text
GET /devices/Device/Plc%20Logic/Application/symbol-config
PUT /devices/Device/Plc%20Logic/Application/symbol-config?symbolsAction=Select|UnSelect|UpdateAll
```

注意：

- 已失效但仍配置的旧成员不会出现在 GET 的可用成员中，但可以用 `UnSelect` 按“数据类型名 + 旧变量名”精确删除；
- GET 中 `accessRights=Void` 是编译器可用符号视图的字段语义，不代表持久化后的选择权限；最终以底层 `SelectedTypes` 或编译结果复核；
- 不再把 UI 手删或 `import_xml` 整表覆盖作为常规方案。

## 2. Git 发布与网络诊断

发布前核对远程、分支、拟提交范围和凭据扫描结果。只在已授权发布的仓库推送，
不把 PAT 放进 URL、命令输出、脚本或仓库配置；使用已登录的 Git 凭据管理器或 gh credential helper。

本工作站曾出现全局代理端口失效。确认当前可用端口后，只对本次命令覆盖代理，不修改全局设置：

```powershell
git -c http.proxy=http://127.0.0.1:3128 -c https.proxy=http://127.0.0.1:3128 push origin HEAD:<branch>
```

端口是本机历史配置，不是其他工作站的默认值。身份、网络和写入权限问题分别诊断；
不要复制 `.git`、用镜像覆盖工作目录或把凭据嵌入远程地址来绕过失败。

## 3. eval_python(IronPython 2.7)其它坑
- `System` 未默认导入:写 `except System.Exception, e` 前先 `from System import Exception` 或 try 普通异常。
- `se.projects` 无 `count` 属性;用 `primary` / `get_all()`。
- `find()` 的通配符 `*` 无效,只按单段精确名匹配;多段路径基本不可用。
- `se.projects.open()` 对已打开工程裸调会卡 UI 线程(红线,见 AGENTS.md)。
