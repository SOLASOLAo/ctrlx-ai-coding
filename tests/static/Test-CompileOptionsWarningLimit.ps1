$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\scripts\ple\CompileOptionsWarningLimit.psm1') -Force

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Utf8([object]$Value) { return [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 64 -Compress)) }

$root = Join-Path ([IO.Path]::GetTempPath()) ('ctrlx-compile-options-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$sourceProject = Join-Path ([IO.Path]::GetTempPath()) ('ctrlx-compile-options-source-' + [guid]::NewGuid().ToString('N') + '.project')
try {
    $project = Join-Path $root 'IsolatedCell.project'
    [IO.File]::WriteAllText($project, 'isolated-project-bytes', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::Copy($project, $sourceProject)
    $manifest = Join-Path $root '.ctrlx-isolated-copy.json'
    $manifestValue = [ordered]@{
        schemaVersion = 1; kind = 'ctrlx-ple-isolated-project-copy-v1'
        projectRelativePath = 'IsolatedCell.project'
        projectSha256 = (Get-FileHash $project -Algorithm SHA256).Hash
        sourceProjectPath = $sourceProject
        expectedActiveProjectName = 'IsolatedCell'
        expectedProfileName = 'ctrlX PLC 2.6.8'
    }
    [IO.File]::WriteAllText($manifest, ($manifestValue | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))

    function New-Fixture {
        param(
            [switch]$MutateThenFail, [switch]$RollbackFail, [switch]$DuplicateCompile,
            [string]$ActivePath = $project, [string]$ActiveName = 'IsolatedCell',
            [string]$ProfileName = 'ctrlX PLC 2.6.8', [switch]$UnknownField,
            [switch]$NonemptyReadonly
        )
        $compile = [pscustomobject][ordered]@{
            name='Kompilierungsoptionen'; elementType='CompileOptionsEditor'; id=$null; children=@(); elementProperties=[pscustomobject]@{}
            fixCompilerVersion='3.5.17.0'; settings=[pscustomobject][ordered]@{ allowUniCodeIdentifiers=$true; replaceConstants=$true; enableBreakpointLogging=$true }
            maxCompilerWarnings='100'
        }
        if ($UnknownField) { $compile | Add-Member -NotePropertyName unexpected -NotePropertyValue 'reject-me' }
        if ($NonemptyReadonly) { $compile.children = @('unexpected-child') }
        $state = [pscustomobject]@{
            Compile = $compile
            Puts = New-Object Collections.Generic.List[object]
            MutateThenFail = [bool]$MutateThenFail; RollbackFail = [bool]$RollbackFail; DuplicateCompile = [bool]$DuplicateCompile
            ActivePath = $ActivePath; ActiveName = $ActiveName; ProfileName = $ProfileName
            MetaReads = 0
        }
        $transport = {
            param($Method, $Uri, $Body, $Timeout, $Maximum)
            $path = ([Uri]$Uri).AbsolutePath
            if ($Method -eq 'GET') {
                if ($path.EndsWith('/projects/current')) { $state.MetaReads++; return Utf8 ([pscustomobject][ordered]@{ path=$state.ActivePath; name=$state.ActiveName; profileName=$state.ProfileName; compilerVersion='3.5.17.0' }) }
                if ($path.EndsWith('/pous')) { return Utf8 ([pscustomobject]@{ elementType='PousTopLevel'; children=@('project-settings') }) }
                if ($path.EndsWith('/project-settings')) {
                    $children = @('Compiler warnings','Library development','Page Setup','Security','SFC','Source Download','Static Analysis Light','Users and Groups','Visualization','Visualization Profile','Kompilierungsoptionen')
                    if ($state.DuplicateCompile) { $children += 'Compiler options 2' }
                    return Utf8 ([pscustomobject]@{ name='Projekteinstellungen'; elementType='ProjectSettings'; children=$children })
                }
                if ($path.EndsWith('/Compiler%20options%202')) { return Utf8 $state.Compile }
                if ($path.EndsWith('/Kompilierungsoptionen')) { return Utf8 $state.Compile }
                if ($path.Contains('/project-settings/')) {
                    $unsupported = New-Object InvalidOperationException('HTTP 400 Element can not be handled')
                    $unsupported.Data['PleHttpStatus'] = 400
                    throw $unsupported
                }
            }
            if (($Method -eq 'PUT') -and $path.EndsWith('/Kompilierungsoptionen')) {
                $value = $Body | ConvertFrom-Json
                $state.Puts.Add($value)
                $putFields = @($value.PSObject.Properties.Name | Sort-Object)
                if (($putFields -join ',') -cne ((@('name','elementType','fixCompilerVersion','settings','maxCompilerWarnings') | Sort-Object) -join ',')) { throw 'fixture PUT included forbidden fields' }
                if ($state.RollbackFail -and ([string]$value.maxCompilerWarnings -eq '100')) { throw 'fixture rollback failure' }
                $state.Compile = [pscustomobject][ordered]@{
                    name=$value.name; elementType=$value.elementType; id=$null; children=@(); elementProperties=[pscustomobject]@{}
                    fixCompilerVersion=$value.fixCompilerVersion; settings=$value.settings; maxCompilerWarnings=$value.maxCompilerWarnings
                }
                if ($state.MutateThenFail -and ([string]$value.maxCompilerWarnings -eq '<no limit>')) { throw 'fixture response failure after mutation' }
                return Utf8 $state.Compile
            }
            throw "Unexpected fixture request: $Method $Uri"
        }.GetNewClosure()
        return [pscustomobject]@{ State=$state; Transport=$transport }
    }

    $fixture = New-Fixture
    $result = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $fixture.Transport
    Assert-True (-not $result.retained) 'Default validation must restore the original value.'
    Assert-True $result.inMemoryProjectMutationUsed 'Result hid the in-memory PLE mutation.'
    Assert-True (-not $result.projectContainerSaved) 'Result incorrectly claimed that the project container was saved.'
    Assert-True $result.reopenOrDiscardRequired 'Result did not require close-without-save and reopen/discard.'
    Assert-True ([string]$result.safeNextAction -match 'without saving') 'Result omitted the safe close-without-save action.'
    Assert-True ([string]$fixture.State.Compile.maxCompilerWarnings -eq '100') 'Default validation did not restore.'
    Assert-True ($fixture.State.Puts.Count -eq 2) 'Default validation must issue one mutation and one rollback PUT.'
    Assert-True ($fixture.State.MetaReads -eq 5) 'Identity was not checked at all five default transaction boundaries.'
    Assert-True ([string]$fixture.State.Puts[0].settings.replaceConstants -eq 'True') 'Full compile options object was not preserved.'
    Assert-True (-not $fixture.State.Puts[0].PSObject.Properties['id']) 'PUT payload included read-only id.'
    Assert-True (-not $fixture.State.Puts[0].PSObject.Properties['children']) 'PUT payload included read-only children.'
    Assert-True (-not $fixture.State.Puts[0].PSObject.Properties['elementProperties']) 'PUT payload included read-only elementProperties.'

    $fixture = New-Fixture
    $result = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $fixture.Transport -KeepValidatedValue
    Assert-True $result.retained 'Explicit keep was not reported.'
    Assert-True $result.inMemoryProjectMutationUsed 'Explicit keep hid the in-memory PLE mutation.'
    Assert-True (-not $result.projectContainerSaved) 'Explicit keep incorrectly claimed a saved container.'
    Assert-True $result.reopenOrDiscardRequired 'Explicit keep did not require reopen/discard cleanup.'
    Assert-True ([string]$fixture.State.Compile.maxCompilerWarnings -eq '<no limit>') 'Explicit keep did not retain validated value.'
    Assert-True ($fixture.State.Puts.Count -eq 1) 'Explicit keep unexpectedly rolled back.'
    Assert-True ($fixture.State.MetaReads -eq 3) 'Explicit keep missed an identity boundary.'

    $fixture = New-Fixture -MutateThenFail
    try { $null = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $fixture.Transport; throw 'Expected mutation failure.' }
    catch { Assert-True ($_.Exception.Message -match 'response failure') 'Mutation failure was not surfaced.' }
    Assert-True ([string]$fixture.State.Compile.maxCompilerWarnings -eq '100') 'Failure did not roll back the original value.'

    $fixture = New-Fixture -MutateThenFail -RollbackFail
    try { $null = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $fixture.Transport; throw 'Expected rollback failure.' }
    catch { Assert-True ($_.Exception.Message -match 'Rollback also failed') 'Rollback failure was not made explicit.' }

    $fixture = New-Fixture -DuplicateCompile
    try { $null = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $fixture.Transport; throw 'Expected duplicate discovery failure.' }
    catch { Assert-True ($_.Exception.Message -match 'exactly one CompileOptionsEditor') 'Duplicate type did not fail closed.' }
    Assert-True ($fixture.State.Puts.Count -eq 0) 'Discovery failure performed a PUT.'

    $fixture = New-Fixture
    try { $null = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $fixture.Transport -BaseUri 'http://127.0.0.1:9002/plc/engineering/api/v2'; throw 'Expected localhost gate.' }
    catch { Assert-True ($_.Exception.Message -match 'restricted to') 'Non-localhost authority was accepted.' }
    Assert-True ($fixture.State.Puts.Count -eq 0) 'Authority rejection performed a PUT.'

    $oversizedTransport = { param($Method, $Uri, $Body, $Timeout, $Maximum) return [byte[]](New-Object byte[] ($Maximum + 1)) }
    try { $null = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $oversizedTransport; throw 'Expected response bound failure.' }
    catch { Assert-True ($_.Exception.Message -match 'exceeds 1 MiB') 'Oversized response was not rejected.' }

    $invalidUtf8Transport = { param($Method, $Uri, $Body, $Timeout, $Maximum) return [byte[]](0xC3, 0x28) }
    try { $null = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $invalidUtf8Transport; throw 'Expected UTF-8 failure.' }
    catch { Assert-True ($_.Exception.Message -match 'strict UTF-8 JSON') 'Invalid UTF-8 was not rejected.' }

    foreach ($identityCase in @(
        [pscustomobject]@{ Fixture = (New-Fixture -ActivePath $sourceProject -ActiveName ([IO.Path]::GetFileNameWithoutExtension($sourceProject))); Pattern='path mismatch|Source project is active'; Description='source-active' },
        [pscustomobject]@{ Fixture = (New-Fixture -ActivePath (Join-Path $root 'Other.project')); Pattern='path mismatch'; Description='path mismatch' },
        [pscustomobject]@{ Fixture = (New-Fixture -ProfileName 'ctrlX PLC wrong'); Pattern='profile mismatch'; Description='profile mismatch' }
    )) {
        try { $null = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $identityCase.Fixture.Transport; throw "Expected $($identityCase.Description)." }
        catch { Assert-True ($_.Exception.Message -match $identityCase.Pattern) "$($identityCase.Description) was accepted." }
        Assert-True ($identityCase.Fixture.State.Puts.Count -eq 0) "$($identityCase.Description) performed a PUT."
    }

    foreach ($shapeCase in @(
        [pscustomobject]@{ Fixture=(New-Fixture -UnknownField); Description='unknown response field' },
        [pscustomobject]@{ Fixture=(New-Fixture -NonemptyReadonly); Description='nonempty readonly field' }
    )) {
        try { $null = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $shapeCase.Fixture.Transport; throw "Expected $($shapeCase.Description)." }
        catch { Assert-True ($_.Exception.Message -match 'unknown fields|children must be empty') "$($shapeCase.Description) was accepted." }
        Assert-True ($shapeCase.Fixture.State.Puts.Count -eq 0) "$($shapeCase.Description) performed a PUT."
    }

    $badManifestValue = ($manifestValue | ConvertTo-Json -Compress) | ConvertFrom-Json
    $badManifestValue.expectedActiveProjectName = 'OtherProject'
    [IO.File]::WriteAllText($manifest, ($badManifestValue | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    $fixture = New-Fixture
    try { $null = Invoke-CompileOptionsWarningLimitValidation -ProjectFilePath $project -IsolationRoot $root -IsolationManifestPath $manifest -Transport $fixture.Transport; throw 'Expected identity failure.' }
    catch { Assert-True ($_.Exception.Message -match 'name mismatch') 'Active project name mismatch was accepted.' }
    Assert-True ($fixture.State.Puts.Count -eq 0) 'Identity rejection performed a PUT.'

    Write-Host 'CompileOptions warning-limit isolated REST self-test: OK'
}
finally {
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
    if ([IO.File]::Exists($sourceProject)) { [IO.File]::Delete($sourceProject) }
}
