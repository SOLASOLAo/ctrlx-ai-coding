<#
.SYNOPSIS
  Pure-offline readiness regression for the ctrlX codesys-persistent patch.

.DESCRIPTION
  Copies only dist/src/package.json into a unique temporary fixture, applies
  this patch there, runs -Check, syntax checks and Python stub regressions, then
  removes the fixture. It never writes to the source npm package and never
  starts Node as a server, MCP, PLE or an engineering project.
#>
[CmdletBinding()]
param(
  [string]$PackageRoot = "",
  [switch]$KeepFixture
)

$ErrorActionPreference = "Stop"
$patchRoot = $PSScriptRoot
$applyScript = Join-Path $patchRoot "apply-crlf-patch.ps1"
if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
  $npmRoot = (& npm root -g).Trim()
  if (-not $?) { throw "npm root -g failed." }
  $PackageRoot = Join-Path $npmRoot "codesys-mcp-persistent"
}
$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
foreach ($relative in @("dist\scripts\watcher.py", "dist\server.js", "src\server.ts")) {
  if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $relative))) {
    throw "Offline source package is incomplete; missing $relative under $PackageRoot"
  }
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $tempRoot ("ctrlx-adapter-readiness-" + [Guid]::NewGuid().ToString("N"))
$fixturePackage = Join-Path $fixtureRoot "codesys-mcp-persistent"

function Remove-VerifiedFixture {
  if ($KeepFixture -or -not (Test-Path -LiteralPath $fixtureRoot)) { return }
  $resolved = [System.IO.Path]::GetFullPath($fixtureRoot)
  $expectedPrefix = $tempRoot + "\ctrlx-adapter-readiness-"
  if (-not $resolved.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove unexpected fixture path: $resolved"
  }
  [System.IO.Directory]::Delete($resolved, $true)
}

try {
  New-Item -ItemType Directory -Path $fixturePackage -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $PackageRoot "dist") -Destination $fixturePackage -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $PackageRoot "src") -Destination $fixturePackage -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $PackageRoot "package.json") -Destination $fixturePackage -Force
  $fixtureScripts = Join-Path $fixturePackage "dist\scripts"

  $applyOutput = @(& $applyScript -PackageScriptsDir $fixtureScripts *>&1 | ForEach-Object { $_.ToString() })
  if (-not $?) { throw "Patch application failed in the isolated fixture.`n$($applyOutput -join "`n")" }
  $checkOutput = @(& $applyScript -PackageScriptsDir $fixtureScripts -Check *>&1 | ForEach-Object { $_.ToString() })
  if (-not $?) { throw "Patch -Check failed in the isolated fixture.`n$($checkOutput -join "`n")" }
  $checkText = $checkOutput -join "`n"
  if ($checkText -match '\[(TODO|UPGR)\]') {
    throw "Patched fixture is not ready; -Check retained TODO/UPGR.`n$checkText"
  }
  foreach ($required in @(
    "bounded compile-message + fixed-category typed warning helper",
    "explicit PLE ownership provenance",
    "PLE ownership status/shutdown guard",
    "fail-closed same-call fresh compile contract",
    "fail-closed fresh compile response passthrough",
    "opt-in clean compile producer",
    "opt-in clean compile MCP tool",
    "read-only recursive I/O + Symbol semantic snapshot tool",
    "read-only semantic mapping snapshot producer"
  )) {
    if (-not $checkText.Contains($required)) {
      throw "-Check omitted required readiness fact: $required"
    }
  }

  # A marked but hand-edited block is not a known upgrade source. Check mode
  # must report TODO rather than silently treating it as upgradeable.
  $canonicalServerText = @{}
  foreach ($relativeServer in @("src\server.ts", "dist\server.js")) {
    $fixtureServer = Join-Path $fixturePackage $relativeServer
    $text = [System.IO.File]::ReadAllText($fixtureServer)
    $canonicalServerText[$relativeServer] = $text
    [System.IO.File]::WriteAllText(
      $fixtureServer,
      $text.Replace("Actual-only, read-only producer.", "Actual only, read-only producer."),
      (New-Object System.Text.UTF8Encoding($false)))
  }
  $unknownUpgradeCheck = @(& $applyScript -PackageScriptsDir $fixtureScripts -Check *>&1 | ForEach-Object { $_.ToString() })
  if (-not $?) { throw "Unknown semantic block -Check failed in the isolated fixture." }
  $unknownUpgradeText = $unknownUpgradeCheck -join "`n"
  if (([regex]::Matches($unknownUpgradeText, '\[TODO\].*semantic snapshot tool')).Count -ne 2 -or
      $unknownUpgradeText -match '\[UPGR\].*semantic snapshot tool') {
    throw "A hand-edited semantic block was not rejected as an unknown upgrade source.`n$unknownUpgradeText"
  }
  foreach ($relativeServer in @("src\server.ts", "dist\server.js")) {
    [System.IO.File]::WriteAllText(
      (Join-Path $fixturePackage $relativeServer),
      $canonicalServerText[$relativeServer],
      (New-Object System.Text.UTF8Encoding($false)))
  }

  # Exercise an in-place upgrade of an already-patched semantic tool.  PLE's
  # REST extension rejects the numeric loopback Host header with HTTP 400, so
  # an older block using 127.0.0.1 must be detected as UPGR and normalized to
  # the canonical localhost authority without reinstalling the npm package.
  foreach ($relativeServer in @("src\server.ts", "dist\server.js")) {
    $fixtureServer = Join-Path $fixturePackage $relativeServer
    $legacySource = [System.IO.File]::ReadAllText($fixtureServer).Replace(
      "http://localhost:9002",
      "http://127.0.0.1:9002")
    [System.IO.File]::WriteAllText(
      $fixtureServer,
      $legacySource,
      (New-Object System.Text.UTF8Encoding($false)))
  }
  $upgradeCheck = @(& $applyScript -PackageScriptsDir $fixtureScripts -Check *>&1 | ForEach-Object { $_.ToString() })
  if (-not $?) { throw "Semantic-tool upgrade -Check failed in the isolated fixture." }
  $upgradeText = $upgradeCheck -join "`n"
  if (([regex]::Matches($upgradeText, '\[UPGR\].*semantic snapshot tool')).Count -ne 2) {
    throw "Semantic-tool localhost upgrade was not detected for both server assets.`n$upgradeText"
  }

  # A runtime syntax failure must be terminating and must roll back every
  # package source file changed by this invocation. Exercise that path while
  # both server assets are deliberately at the exact known upgrade state.
  $serverRelatives = @("src\server.ts", "dist\server.js")
  $cleanScriptRelatives = @("src\scripts\clean_compile_project.py", "dist\scripts\clean_compile_project.py")
  $preFailureHashes = @{}
  $transientBackupPaths = @()
  foreach ($relativeServer in $serverRelatives) {
    $fixtureServer = Join-Path $fixturePackage $relativeServer
    $cleanToolAsset = Join-Path $patchRoot $(if ($relativeServer.EndsWith(".ts")) {
      "clean_compile_project.tool.ts"
    } else {
      "clean_compile_project.tool.js"
    })
    $serverText = [System.IO.File]::ReadAllText($fixtureServer)
    $cleanToolBlock = [System.IO.File]::ReadAllText($cleanToolAsset)
    if (-not $serverText.Contains($cleanToolBlock)) {
      throw "Fixture server did not contain the canonical clean compile block: $relativeServer"
    }
    [System.IO.File]::WriteAllText(
      $fixtureServer,
      $serverText.Replace($cleanToolBlock, ""),
      (New-Object System.Text.UTF8Encoding($false)))
    foreach ($backupSuffix in @("bak_pre_semantic_snapshot_contract", "bak_pre_clean_compile_contract")) {
      $transientBackup = "$fixtureServer.$backupSuffix"
      if ([System.IO.File]::Exists($transientBackup)) { [System.IO.File]::Delete($transientBackup) }
      $transientBackupPaths += $transientBackup
    }
    $preFailureHashes[$relativeServer] = (Get-FileHash -LiteralPath $fixtureServer -Algorithm SHA256).Hash
  }
  foreach ($relativeCleanScript in $cleanScriptRelatives) {
    $fixtureCleanScript = Join-Path $fixturePackage $relativeCleanScript
    if (-not [System.IO.File]::Exists($fixtureCleanScript)) {
      throw "Fixture clean compile producer was unexpectedly absent before rollback setup: $relativeCleanScript"
    }
    [System.IO.File]::Delete($fixtureCleanScript)
  }
  $fakeBin = Join-Path $fixtureRoot "fake-node"
  New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
  [System.IO.File]::WriteAllText(
    (Join-Path $fakeBin "node.cmd"),
    "@echo off`r`nexit /b 23`r`n",
    (New-Object System.Text.ASCIIEncoding))
  $originalPath = $env:PATH
  $failureStdout = Join-Path $fixtureRoot "syntax-failure.stdout.txt"
  $failureStderr = Join-Path $fixtureRoot "syntax-failure.stderr.txt"
  try {
    $env:PATH = $fakeBin + ";" + $originalPath
    $failureProcess = Start-Process `
      -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $applyScript),
        '-PackageScriptsDir', ('"{0}"' -f $fixtureScripts)
      ) `
      -RedirectStandardOutput $failureStdout `
      -RedirectStandardError $failureStderr `
      -WindowStyle Hidden `
      -Wait `
      -PassThru
    $failureExitCode = $failureProcess.ExitCode
    $failureOutput = @()
    if ([System.IO.File]::Exists($failureStdout)) {
      $failureOutput += [System.IO.File]::ReadAllLines($failureStdout)
    }
    if ([System.IO.File]::Exists($failureStderr)) {
      $failureOutput += [System.IO.File]::ReadAllLines($failureStderr)
    }
  } finally {
    $env:PATH = $originalPath
  }
  if ($failureExitCode -eq 0) {
    throw "Patch unexpectedly succeeded after node --check was forced to fail.`n$($failureOutput -join "`n")"
  }
  if (-not (($failureOutput -join "`n").Contains("were restored"))) {
    throw "Patch syntax failure did not report transactional restoration.`n$($failureOutput -join "`n")"
  }
  foreach ($relativeServer in $serverRelatives) {
    $fixtureServer = Join-Path $fixturePackage $relativeServer
    $postFailureHash = (Get-FileHash -LiteralPath $fixtureServer -Algorithm SHA256).Hash
    if ($postFailureHash -ne $preFailureHashes[$relativeServer]) {
      throw "Syntax-check failure left a partially upgraded server asset: $relativeServer"
    }
  }
  foreach ($transientBackup in $transientBackupPaths) {
    if ([System.IO.File]::Exists($transientBackup)) {
      throw "Syntax-check failure retained a backup created by the failed transaction: $transientBackup"
    }
  }
  foreach ($relativeCleanScript in $cleanScriptRelatives) {
    if ([System.IO.File]::Exists((Join-Path $fixturePackage $relativeCleanScript))) {
      throw "Syntax-check failure retained a newly installed clean compile producer: $relativeCleanScript"
    }
  }

  # Missing validators are also a default failure, not an implicit skip. The
  # same fixture must be restored before an explicit skip is accepted.
  $missingRuntimeBin = Join-Path $fixtureRoot "missing-runtime-bin"
  New-Item -ItemType Directory -Path $missingRuntimeBin -Force | Out-Null
  $missingStdout = Join-Path $fixtureRoot "missing-runtime.stdout.txt"
  $missingStderr = Join-Path $fixtureRoot "missing-runtime.stderr.txt"
  try {
    $env:PATH = $missingRuntimeBin
    $missingProcess = Start-Process `
      -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $applyScript),
        '-PackageScriptsDir', ('"{0}"' -f $fixtureScripts)
      ) `
      -RedirectStandardOutput $missingStdout `
      -RedirectStandardError $missingStderr `
      -WindowStyle Hidden `
      -Wait `
      -PassThru
    $missingOutput = @()
    if ([System.IO.File]::Exists($missingStdout)) { $missingOutput += [System.IO.File]::ReadAllLines($missingStdout) }
    if ([System.IO.File]::Exists($missingStderr)) { $missingOutput += [System.IO.File]::ReadAllLines($missingStderr) }
    if ($missingProcess.ExitCode -eq 0 -or
        -not (($missingOutput -join "`n").Contains("python was not found")) -or
        -not (($missingOutput -join "`n").Contains("were restored"))) {
      throw "Missing runtime validator did not fail closed and restore the transaction.`n$($missingOutput -join "`n")"
    }
  }
  finally {
    $env:PATH = $originalPath
  }
  foreach ($relativeServer in $serverRelatives) {
    $fixtureServer = Join-Path $fixturePackage $relativeServer
    if ((Get-FileHash -LiteralPath $fixtureServer -Algorithm SHA256).Hash -ne $preFailureHashes[$relativeServer]) {
      throw "Missing runtime validator left a partially upgraded server asset: $relativeServer"
    }
  }
  foreach ($transientBackup in $transientBackupPaths) {
    if ([System.IO.File]::Exists($transientBackup)) {
      throw "Missing runtime validator retained a backup created by the failed transaction: $transientBackup"
    }
  }
  foreach ($relativeCleanScript in $cleanScriptRelatives) {
    if ([System.IO.File]::Exists((Join-Path $fixturePackage $relativeCleanScript))) {
      throw "Missing runtime validator retained a newly installed clean compile producer: $relativeCleanScript"
    }
  }

  $skipStdout = Join-Path $fixtureRoot "explicit-skip.stdout.txt"
  $skipStderr = Join-Path $fixtureRoot "explicit-skip.stderr.txt"
  try {
    $env:PATH = $missingRuntimeBin
    $skipProcess = Start-Process `
      -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $applyScript),
        '-PackageScriptsDir', ('"{0}"' -f $fixtureScripts),
        '-SkipRuntimeSyntaxCheck'
      ) `
      -RedirectStandardOutput $skipStdout `
      -RedirectStandardError $skipStderr `
      -WindowStyle Hidden `
      -Wait `
      -PassThru
    $skipOutput = @()
    if ([System.IO.File]::Exists($skipStdout)) { $skipOutput += [System.IO.File]::ReadAllLines($skipStdout) }
    if ([System.IO.File]::Exists($skipStderr)) { $skipOutput += [System.IO.File]::ReadAllLines($skipStderr) }
    if ($skipProcess.ExitCode -ne 0 -or
        -not (($skipOutput -join "`n").Contains("skipped by explicit request"))) {
      throw "Explicit runtime syntax-check skip was not honored.`n$($skipOutput -join "`n")"
    }
  }
  finally {
    $env:PATH = $originalPath
  }

  $upgradeOutput = @(& $applyScript -PackageScriptsDir $fixtureScripts *>&1 | ForEach-Object { $_.ToString() })
  if (-not $?) { throw "Semantic-tool upgrade failed in the isolated fixture.`n$($upgradeOutput -join "`n")" }
  $checkOutput = @(& $applyScript -PackageScriptsDir $fixtureScripts -Check *>&1 | ForEach-Object { $_.ToString() })
  $checkText = $checkOutput -join "`n"
  if ($checkText -match '\[(TODO|UPGR)\]') {
    throw "Semantic-tool upgrade did not converge to a ready fixture.`n$checkText"
  }
  foreach ($relativeServer in @("src\server.ts", "dist\server.js")) {
    $fixtureServerText = [System.IO.File]::ReadAllText((Join-Path $fixturePackage $relativeServer))
    if (-not $fixtureServerText.Contains("http://localhost:9002") -or
        $fixtureServerText.Contains("http://127.0.0.1:9002")) {
      throw "Semantic-tool upgrade retained the rejected numeric loopback authority: $relativeServer"
    }
  }

  & python (Join-Path $patchRoot "test-fast-compile-message.py") `
    (Join-Path $fixtureScripts "_message_utils.py") `
    (Join-Path $fixtureScripts "compile_project.py")
  if (-not $?) { throw "Fresh compile regression failed." }
  & python (Join-Path $patchRoot "test-clean-compile-project.py") `
    (Join-Path $fixtureScripts "clean_compile_project.py")
  if (-not $?) { throw "Clean compile producer regression failed." }
  & node (Join-Path $patchRoot "test-clean-compile-tool.js")
  if (-not $?) { throw "Clean compile MCP response regression failed." }
  & python (Join-Path $patchRoot "test-semantic-snapshot.py") `
    (Join-Path $fixtureScripts "get_ctrlx_semantic_snapshot.py")
  if (-not $?) { throw "Semantic snapshot regression failed." }
  & node (Join-Path $patchRoot "test-semantic-tool.js")
  if (-not $?) { throw "Semantic tool compact/canonical/size regression failed." }
  & node --check (Join-Path $fixturePackage "dist\server.js")
  if (-not $?) { throw "Patched dist/server.js syntax check failed." }
  $typescriptModule = Join-Path $PackageRoot "node_modules\typescript\lib\typescript.js"
  if (Test-Path -LiteralPath $typescriptModule) {
    foreach ($typescriptAssetName in @(
      "get_ctrlx_semantic_snapshot.tool.ts",
      "clean_compile_project.tool.ts"
    )) {
      $typescriptAsset = Join-Path $patchRoot $typescriptAssetName
      & node -e @'
const fs = require('fs');
const ts = require(process.argv[1]);
const source = fs.readFileSync(process.argv[2], 'utf8');
const result = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  reportDiagnostics: true,
});
const errors = (result.diagnostics || []).filter((item) => item.category === ts.DiagnosticCategory.Error);
if (errors.length) {
  for (const item of errors) console.error(ts.flattenDiagnosticMessageText(item.messageText, ' '));
  process.exit(1);
}
'@ $typescriptModule $typescriptAsset
      if (-not $?) { throw "TypeScript asset syntax check failed: $typescriptAssetName" }
    }
  }

  $cleanServerSource = [System.IO.File]::ReadAllText((Join-Path $fixturePackage "dist\server.js"))
  $cleanToolStart = $cleanServerSource.IndexOf("s.tool('clean_compile_project'")
  $cleanToolEnd = $cleanServerSource.IndexOf("s.tool('compile_project'", [Math]::Max(0, $cleanToolStart))
  if ($cleanToolStart -lt 0 -or $cleanToolEnd -le $cleanToolStart) {
    throw "Clean compile tool block was not inserted exactly once."
  }
  $cleanToolBlock = $cleanServerSource.Substring($cleanToolStart, $cleanToolEnd - $cleanToolStart)
  foreach ($forbidden in @("clean_all", "generate_code")) {
    if ($cleanToolBlock.Contains($forbidden)) {
      throw "Clean compile MCP block contains forbidden method: $forbidden"
    }
  }
  foreach ($required in @(
    "summary.cleanInvocation === 'application.clean'",
    "summary.buildInvocation === 'application.build'",
    "summary.cleanInvocationCount === 1",
    "summary.buildInvocationCount === 1",
    "summary.semanticRebuildVerified === true",
    "summary.messageEvidenceComplete === true",
    "summary.identityPostflightVerified === true",
    "summary.dirtyPostflightVerified === true",
    "responseSizeValid"
  )) {
    if (-not $cleanToolBlock.Contains($required)) {
      throw "Clean compile MCP block omitted required field: $required"
    }
  }

  $serverSource = [System.IO.File]::ReadAllText((Join-Path $fixturePackage "dist\server.js"))
  $toolStart = $serverSource.IndexOf("s.tool('get_ctrlx_semantic_snapshot'")
  $toolEnd = $serverSource.IndexOf("s.tool('map_io_channel'", [Math]::Max(0, $toolStart))
  if ($toolStart -lt 0 -or $toolEnd -le $toolStart) { throw "Semantic tool block was not inserted exactly once." }
  $toolBlock = $serverSource.Substring($toolStart, $toolEnd - $toolStart)
  foreach ($forbidden in @("expectedVariable", "expectedMapping", "symbolsAccepted", "semanticAccepted", "payload: symbolBefore.payload", "localeCompare")) {
    if ($toolBlock.Contains($forbidden)) { throw "Actual-only semantic tool contains forbidden field: $forbidden" }
  }
  foreach ($required in @(
    "mappingScopes",
    "stableAcrossRead",
    "canonicalFacts",
    "mappingSha256",
    "symbolConfigSha256",
    "snapshotSha256",
    "SEMANTIC_SNAPSHOT_TOO_LARGE",
    "responseByteCount > 480 * 1024",
    "const mappingFinal = await readMappings();",
    "const readBoundedResponseBody =",
    "response.body.getReader"
  )) {
    if (-not $toolBlock.Contains($required)) { throw "Semantic tool omitted required field: $required" }
  }

  Write-Host "[OK ] isolated adapter apply/check/syntax regressions passed"
  Write-Host "[OK ] generic 0/0 rejected; fixed-category Warning-only typed records enforced"
  Write-Host "[OK ] opt-in one-clean plus one-Build semantic rebuild contract passed"
  Write-Host "[OK ] recursive actual-only semantic snapshot contract passed"
  Write-Host "[OK ] final dirty-state race and bounded streaming REST body passed"
  Write-Host "[OK ] syntax-check failure is nonzero and transactionally restores package sources"
  Write-Host "[OK ] missing validators fail closed; only explicit syntax-check skip is accepted"
  Write-Host "[OK ] compact Unicode canonical hashes and 480 KiB response limit passed"
  if ($KeepFixture) { Write-Host "Fixture retained: $fixtureRoot" }
}
finally {
  Remove-VerifiedFixture
}
