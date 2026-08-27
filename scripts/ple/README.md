# Isolated PLE compile-options validation

`Test-IsolatedCompileWarningLimit.ps1` validates the official PLE REST v2
`CompileOptionsEditor.maxCompilerWarnings` mutation on an isolated project
copy. It does not start PLE, connect to a PLC, build, save, or edit project
container bytes.

The caller must first create a separate project copy and a UTF-8 manifest in
the isolation root:

```json
{
  "schemaVersion": 1,
  "kind": "ctrlx-ple-isolated-project-copy-v1",
  "projectRelativePath": "IsolatedCell.project",
  "projectSha256": "UPPERCASE_SHA256_OF_THE_COPY",
  "sourceProjectPath": "C:\\\\Engineering\\\\SourceCell.project",
  "expectedActiveProjectName": "IsolatedCell",
  "expectedProfileName": "ctrlX PLC 2.6.8"
}
```

The source project must exist outside the isolation root and have the same
SHA-256 as the copy. This prevents the integration project itself from being
declared as the isolated target. Open that exact copy in the single externally
owned PLE instance, then run:

```powershell
.\Test-IsolatedCompileWarningLimit.ps1 `
  -ProjectFilePath C:\Temp\ple-isolation\IsolatedCell.project `
  -IsolationRoot C:\Temp\ple-isolation `
  -IsolationManifestPath C:\Temp\ple-isolation\.ctrlx-isolated-copy.json
```

The default transaction reads `/projects/current?option=meta` and requires its
path, project name, and profile to match the manifest. It dynamically discovers
`ProjectSettings` and `CompileOptionsEditor` by `elementType`; explicit HTTP 400
responses for unsupported Project Settings children are skipped, while every
other failure remains fatal. It GETs and validates the exact PLE 2.6.8 response
shape, projects only the five fields accepted by the official PUT contract, changes only
`maxCompilerWarnings`; PUTs and reads it back; and restores the exact original
known projection. Identity is checked initially, before and after PUT, and
before and after rollback. `-KeepValidatedValue` is an explicit isolated-test option for a later
manual experiment. Any failure after a PUT attempts restoration and requires
an exact full-object readback. Do not use `-KeepValidatedValue` on an
integration project.

## Dirty-state consequence

PLE 2.6.8 marks `ScriptProject.dirty=True` after the REST PUT. Restoring
`maxCompilerWarnings` to its original value restores the setting and leaves the
encrypted `.project` bytes unchanged, but it does **not** make the in-memory PLE
project clean again. A successful result therefore always reports:

```text
inMemoryProjectMutationUsed = true
projectContainerSaved = false
reopenOrDiscardRequired = true
```

After either the default restore or `-KeepValidatedValue`, close PLE **without
saving**, then reopen or discard the isolated copy before any other controlled
operation. Do not pass the same open session directly to the existing
`compile_project` adapter: its no-save guard must see the dirty project and fail
closed. A later compile experiment needs a separately designed lifecycle that
does not weaken that guard. The tool never claims that the PLE session is clean
after its transaction.

The REST authority is fixed to
`http://localhost:9002/plc/engineering/api/v2`. Requests and responses are
strict UTF-8 JSON, bounded to 1 MiB, use a bounded timeout, and bypass system
proxies. No endpoint other than GET/PUT under `/pous` is supported.

Pure fake-REST regression (does not start PLE):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  ..\..\tests\static\Test-CompileOptionsWarningLimit.ps1
```
