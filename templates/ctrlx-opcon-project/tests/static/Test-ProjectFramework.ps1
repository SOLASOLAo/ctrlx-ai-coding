[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$failures = New-Object System.Collections.Generic.List[string]

$requiredFiles = @(
    'AGENTS.md',
    'README.md',
    'HANDOVER.md',
    'TODO.md',
    'TEAM_SETUP.md',
    'config/project.yaml',
    'config/quality-gates.yaml',
    'specs/station.yaml',
    'specs/io.yaml',
    'specs/events.yaml',
    'ai/ownership.yaml',
    'ai/hooks.yaml',
    'ai/graphical.yaml',
    'docs/project_structure.md',
    'scripts/cpstudio/post_export_signal.bat',
    'scripts/cpstudio/write_export_request.ps1',
    'scripts/cpstudio/Invoke-PostExportAudit.ps1',
    'scripts/cpstudio/Invoke-PostExportEngineering.ps1',
    'scripts/git/Get-ReadOnlyGitAudit.ps1',
    'tests/cpstudio/Test-PostExportQueue.ps1',
    'tests/cpstudio/Test-PostExportEngineering.ps1'
)

$requiredDirectories = @(
    'specs/units',
    'specs/chains',
    'src/plc/common',
    'src/plc/project/{{STATION_ID}}',
    'catalog/units',
    'catalog/addons',
    'catalog/peripherals',
    'scripts/cpstudio',
    'scripts/plc',
    'scripts/ioe',
    'scripts/git',
    'scripts/setup',
    'tests/static',
    'tests/cpstudio',
    'tests/compile',
    'tests/simulation',
    'data/requests',
    'data/snapshots',
    'data/reports',
    'data/backups'
)

foreach ($relativePath in $requiredFiles) {
    $absolutePath = Join-Path $repositoryRoot ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not [System.IO.File]::Exists($absolutePath)) {
        $failures.Add("Missing required file: $relativePath")
    }
}

foreach ($relativePath in $requiredDirectories) {
    $absolutePath = Join-Path $repositoryRoot ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not [System.IO.Directory]::Exists($absolutePath)) {
        $failures.Add("Missing required directory: $relativePath")
    }
}

$forbiddenExtensions = @('.project', '.projectarchive', '.compiled-library', '.pdf', '.chm', '.zip')
foreach ($file in Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File) {
    $relativePath = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\', '/').Replace('\', '/')
    if ($forbiddenExtensions -contains $file.Extension.ToLowerInvariant()) {
        $failures.Add("Forbidden binary or closed asset in AI repository: $relativePath")
    }

    $content = [System.IO.File]::ReadAllText($file.FullName)
    if ($content -match '\{\{[A-Z0-9_]+\}\}') {
        $failures.Add("Unresolved project-template token: $relativePath")
    }
}

$projectConfigPath = Join-Path $repositoryRoot 'config\project.yaml'
if ([System.IO.File]::Exists($projectConfigPath)) {
    $projectConfig = [System.IO.File]::ReadAllText($projectConfigPath)
    foreach ($key in @('station_root', 'standard_library_root', 'cpstudio_project', 'plc_project', 'io_project', 'bus_config')) {
        $match = [regex]::Match($projectConfig, "(?m)^\s{2}${key}:\s*(.+?)\s*$")
        if (-not $match.Success) {
            $failures.Add("Missing config path key: $key")
            continue
        }

        $value = $match.Groups[1].Value.Trim().Trim("'", '"')
        if (($value -ne 'null') -and [System.IO.Path]::IsPathRooted($value)) {
            $failures.Add("Project path must be relative, not absolute: $key")
        }
        if ($value.Contains('\')) {
            $failures.Add("Project path must use forward slashes: $key")
        }
    }
}

$qualityGatePath = Join-Path $repositoryRoot 'config\quality-gates.yaml'
if ([System.IO.File]::Exists($qualityGatePath)) {
    $qualityGates = [System.IO.File]::ReadAllText($qualityGatePath)
    if (-not $qualityGates.Contains('warning_policy: signature_allowlist')) {
        $failures.Add('Compile warning gate must use signature_allowlist, not a count-only baseline.')
    }
}

$stSourceRoot = Join-Path $repositoryRoot 'src\plc'
if ([System.IO.Directory]::Exists($stSourceRoot)) {
    foreach ($file in Get-ChildItem -LiteralPath $stSourceRoot -Recurse -File -Filter '*.st') {
        $relativePath = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        $text = [System.IO.File]::ReadAllText($file.FullName)

        $setEventPattern = "SetEvent\s*\(\s*[^,]+,\s*[^,]+,\s*'((?:''|[^'])*)'"
        foreach ($match in [regex]::Matches($text, $setEventPattern, [Text.RegularExpressions.RegexOptions]::Singleline)) {
            $additionalInfo = $match.Groups[1].Value.Replace("''", "'")
            if ($additionalInfo.Length -gt 63) {
                $failures.Add("OpCon SetEvent AdditionalInfo exceeds STRING(63): ${relativePath} ($($additionalInfo.Length) characters)")
            }
        }

        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            $line = $lines[$lineIndex]
            $lineNumber = $lineIndex + 1
            $trimmedLine = $line.TrimStart()
            if ($trimmedLine.StartsWith('//') -or $trimmedLine.StartsWith('(*') -or $trimmedLine.StartsWith('*')) {
                continue
            }

            if ($line -match '^\s*(AND|OR)\b') {
                $failures.Add("PLC ST logical operator must end the previous line: ${relativePath}:${lineNumber}")
            }
            if (($line -match '^\s*(IF|ELSIF)\s+') -and ($line -notmatch '^\s*(IF|ELSIF)\s+\(\s')) {
                $failures.Add("PLC ST condition must start with a spaced parenthesis: ${relativePath}:${lineNumber}")
            }
        }
    }
}

$postExportRoot = Join-Path $repositoryRoot 'scripts\cpstudio'
if ([System.IO.Directory]::Exists($postExportRoot)) {
    foreach ($file in Get-ChildItem -LiteralPath $postExportRoot -Recurse -File |
        Where-Object { $_.Extension.ToLowerInvariant() -in @('.ps1', '.bat', '.cmd', '.py') }) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($forbiddenText in @('ctrlX-PLC-Engineering.exe', 'codesys-mcp-persistent', 'download_to_device')) {
            if ($text.Contains($forbiddenText)) {
                $relativePath = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\', '/').Replace('\', '/')
                $failures.Add("Post-export hook contains forbidden launcher/online text '$forbiddenText': $relativePath")
            }
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output ("Project framework OK: {0} files, {1} directories" -f $requiredFiles.Count, $requiredDirectories.Count)
