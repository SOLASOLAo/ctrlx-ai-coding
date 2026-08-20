[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $false)]
    [Alias('ProjectRoot', 'RepositoryRoot')]
    [string]$EngineeringRoot,

    [Parameter(Mandatory = $false)]
    [Alias('RequestRoot')]
    [string]$QueueRoot,

    [Parameter(Mandatory = $false)]
    [string]$RequestId,

    [Parameter(Mandatory = $false)]
    [switch]$All,

    [Parameter(Mandatory = $false)]
    [switch]$RecoverProcessing,

    [Parameter(Mandatory = $false)]
    [string]$ReportRoot,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 60000)]
    [int]$LockWaitMilliseconds = 0
)

$ErrorActionPreference = 'Stop'

if ($All -and $RequestId) {
    throw '-All and -RequestId cannot be used together.'
}

function Get-ConfiguredRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigurationPath,

        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    if (-not [System.IO.File]::Exists($ConfigurationPath)) {
        return $null
    }

    $text = [System.IO.File]::ReadAllText($ConfigurationPath)
    $pattern = '(?m)^\s*' + [regex]::Escape($FieldName) + '\s*:\s*(?<value>[^#\r\n]+?)\s*$'
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
}

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$ConfiguredPath
    )

    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        return [System.IO.Path]::GetFullPath($ConfiguredPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $ConfiguredPath))
}

function Write-AtomicUtf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    $replaceBackupPath = $temporaryPath + '.replace.bak'
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false

    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $utf8NoBom)
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($temporaryPath, $Path, $replaceBackupPath)
            [System.IO.File]::Delete($replaceBackupPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        if ([System.IO.File]::Exists($replaceBackupPath)) {
            [System.IO.File]::Delete($replaceBackupPath)
        }
    }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    Write-AtomicUtf8File -Path $Path -Content (($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
}

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if (($null -ne $property) -and ($null -ne $property.Value) -and
            (-not [string]::IsNullOrWhiteSpace([string]$property.Value))) {
            return $property.Value
        }
    }

    return $null
}

function Get-Sha256ForText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-FileFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$DisplayPath
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($resolvedPath)) {
        return [pscustomobject]@{
            path             = $DisplayPath
            exists           = $false
            sizeBytes        = $null
            lastWriteTimeUtc = $null
            sha256           = $null
        }
    }

    $item = Get-Item -LiteralPath $resolvedPath
    return [pscustomobject]@{
        path             = $DisplayPath
        exists           = $true
        sizeBytes        = $item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        sha256           = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash
    }
}

function Get-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return $resolvedPath.Substring($prefix.Length).Replace('\', '/')
}

function ConvertTo-NormalizedRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawText,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$ActiveEngineeringRoot
    )

    $payload = $RawText | ConvertFrom-Json
    if ($null -eq $payload) {
        throw "Request JSON is empty: $SourcePath"
    }

    $requestIdValue = Get-FirstPropertyValue -Object $payload -Names @('requestId', 'id', 'exportRequestId')
    if (-not $requestIdValue) {
        $requestIdValue = [guid]::NewGuid().ToString()
    }

    $requestedAtValue = Get-FirstPropertyValue -Object $payload -Names @('requestedAtUtc', 'createdAtUtc', 'timestampUtc')
    if (-not $requestedAtValue) {
        $requestedAtValue = (Get-Item -LiteralPath $SourcePath).LastWriteTimeUtc.ToString('o')
    }

    $requestEngineeringRoot = Get-FirstPropertyValue -Object $payload -Names @('engineeringRoot', 'projectRoot', 'repositoryRoot')
    if ($requestEngineeringRoot) {
        $resolvedRequestEngineeringRoot = [System.IO.Path]::GetFullPath([string]$requestEngineeringRoot)
        if (-not $resolvedRequestEngineeringRoot.Equals($ActiveEngineeringRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Request engineering root does not match the active repository: $resolvedRequestEngineeringRoot"
        }
    }

    $stationRootValue = Get-FirstPropertyValue -Object $payload -Names @('stationRoot', 'integrationRoot', 'generatedProjectRoot')
    if (-not $stationRootValue) {
        throw "Request has no stationRoot/integrationRoot field: $SourcePath"
    }
    $resolvedStationRoot = [System.IO.Path]::GetFullPath([string]$stationRootValue)
    if (-not [System.IO.Directory]::Exists($resolvedStationRoot)) {
        throw "Request station root does not exist: $resolvedStationRoot"
    }

    $plcProjectValue = Get-FirstPropertyValue -Object $payload -Names @('plcProject', 'plcProjectPath')
    if ($plcProjectValue) {
        $resolvedPlcProject = [System.IO.Path]::GetFullPath([string]$plcProjectValue)
    }
    else {
        $candidate = Get-ChildItem -LiteralPath (Join-Path $resolvedStationRoot 'Plc') -File -Filter '*_PLC.project' -ErrorAction SilentlyContinue |
            Sort-Object -Property Name |
            Select-Object -First 1
        $resolvedPlcProject = if ($candidate) { $candidate.FullName } else { Join-Path $resolvedStationRoot 'Plc\UNKNOWN_PLC.project' }
    }

    $schemaValue = Get-FirstPropertyValue -Object $payload -Names @('schemaVersion', 'schema_version')
    $sourceValue = Get-FirstPropertyValue -Object $payload -Names @('source', 'trigger')
    $modeValue = Get-FirstPropertyValue -Object $payload -Names @('exportMode', 'mode')

    return [pscustomobject]@{
        schemaVersion        = 2
        originalSchemaVersion = if ($schemaValue) { $schemaValue } else { 1 }
        requestId            = [string]$requestIdValue
        requestedAtUtc       = [string]$requestedAtValue
        source               = if ($sourceValue) { [string]$sourceValue } else { 'CpStudio.PostExport' }
        exportMode           = if ($modeValue) { [string]$modeValue } else { 'unknown' }
        engineeringRoot      = $ActiveEngineeringRoot
        stationRoot          = $resolvedStationRoot
        plcProject           = $resolvedPlcProject
        legacyPayload        = $payload
    }
}

function New-StateRecord {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Request,

        [Parameter(Mandatory = $true)]
        [ValidateSet('processing', 'done', 'failed')]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [hashtable]$AdditionalFields
    )

    $record = [ordered]@{
        schemaVersion         = 2
        originalSchemaVersion = $Request.originalSchemaVersion
        requestId             = $Request.requestId
        requestedAtUtc        = $Request.requestedAtUtc
        source                = $Request.source
        status                = $Status
        exportMode            = $Request.exportMode
        engineeringRoot       = $Request.engineeringRoot
        stationRoot           = $Request.stationRoot
        plcProject            = $Request.plcProject
        queue                 = [ordered]@{
            version = 1
            state   = $Status
        }
    }

    if ($Request.PSObject.Properties['legacyPayload']) {
        $record.legacyPayload = $Request.legacyPayload
    }
    if ($AdditionalFields) {
        foreach ($key in $AdditionalFields.Keys) {
            $record[$key] = $AdditionalFields[$key]
        }
    }

    return $record
}

function Get-RequestIdWithoutClaim {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $payload = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
        return [string](Get-FirstPropertyValue -Object $payload -Names @('requestId', 'id', 'exportRequestId'))
    }
    catch {
        return $null
    }
}

function Get-CandidateRequests {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $false)]
        [string]$SelectedRequestId,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeProcessing
    )

    $candidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $pendingDirectory = Join-Path $Root 'pending'
    if ([System.IO.Directory]::Exists($pendingDirectory)) {
        Get-ChildItem -LiteralPath $pendingDirectory -File -Filter '*.json' | ForEach-Object { $candidates.Add($_) }
    }

    # Compatibility with schema v1 and the old project.yaml export_request field.
    $legacyPath = Join-Path $Root 'export_request.json'
    if ([System.IO.File]::Exists($legacyPath)) {
        $candidates.Add((Get-Item -LiteralPath $legacyPath))
    }

    if ($IncludeProcessing) {
        $processingDirectory = Join-Path $Root 'processing'
        if ([System.IO.Directory]::Exists($processingDirectory)) {
            Get-ChildItem -LiteralPath $processingDirectory -File -Filter '*.json' | ForEach-Object { $candidates.Add($_) }
        }
    }

    $orderedCandidates = @($candidates | Sort-Object -Property LastWriteTimeUtc, Name)
    if ($SelectedRequestId) {
        $orderedCandidates = @($orderedCandidates | Where-Object {
            ($_.Name -like "*$SelectedRequestId*") -or
            ((Get-RequestIdWithoutClaim -Path $_.FullName) -eq $SelectedRequestId)
        })
    }

    return $orderedCandidates
}

function Enter-QueueLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60000)]
        [int]$WaitMilliseconds = 0
    )

    [System.IO.Directory]::CreateDirectory($Root) | Out-Null
    $lockPath = Join-Path $Root '.consumer.lock'
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMilliseconds)
    $stream = $null
    while ($null -eq $stream) {
        try {
            $stream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] {
            if (($WaitMilliseconds -eq 0) -or ([DateTime]::UtcNow -ge $deadline)) {
                throw "Another post-export consumer holds the queue lock: $lockPath"
            }
            Start-Sleep -Milliseconds 25
        }
    }

    try {
        $lockRecord = [ordered]@{
            processId   = $PID
            acquiredUtc = [DateTime]::UtcNow.ToString('o')
            queueRoot   = $Root
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((($lockRecord | ConvertTo-Json -Compress) + [Environment]::NewLine))
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        return $stream
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Move-RequestToState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentPath,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $false)]
        [string]$DestinationFileName
    )

    [System.IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
    if (-not $DestinationFileName) {
        $DestinationFileName = [System.IO.Path]::GetFileName($CurrentPath)
    }
    $destination = Join-Path $StateDirectory $DestinationFileName
    if ($CurrentPath.Equals($destination, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $CurrentPath
    }
    if ([System.IO.File]::Exists($destination)) {
        throw "Queue state target already exists: $destination"
    }

    [System.IO.File]::Move($CurrentPath, $destination)
    return $destination
}

function Get-ManifestAudit {
    param([Parameter(Mandatory = $true)][string]$Root)

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in @('ai/ownership.yaml', 'ai/hooks.yaml', 'ai/graphical.yaml')) {
        $absolutePath = Join-Path $Root ($relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        $results.Add((Get-FileFingerprint -Path $absolutePath -DisplayPath $relativePath))
    }
    return $results.ToArray()
}

function Get-StationFingerprints {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StationRoot,

        [Parameter(Mandatory = $true)]
        [string]$PlcProject,

        [Parameter(Mandatory = $true)]
        [object]$GitAudit
    )

    $relativePaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($relativePath in @($GitAudit.changedPaths)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$relativePath)) {
            $null = $relativePaths.Add(([string]$relativePath).Replace('\', '/'))
        }
    }

    foreach ($criticalPath in @(
        (Join-Path $StationRoot 'Engineering\Engineering_Data.xml'),
        $PlcProject
    )) {
        $relativePath = Get-SafeRelativePath -Root $StationRoot -Path $criticalPath
        if ($relativePath) {
            $null = $relativePaths.Add($relativePath)
        }
    }

    foreach ($directoryPattern in @(
        @{ Directory = 'Engineering'; Filter = '*.cpsp' },
        @{ Directory = 'Plc'; Filter = '*_PLC.project' },
        @{ Directory = 'Plc'; Filter = '*_IO.project' }
    )) {
        $directory = Join-Path $StationRoot $directoryPattern.Directory
        if ([System.IO.Directory]::Exists($directory)) {
            Get-ChildItem -LiteralPath $directory -File -Filter $directoryPattern.Filter -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $relativePath = Get-SafeRelativePath -Root $StationRoot -Path $_.FullName
                    if ($relativePath) {
                        $null = $relativePaths.Add($relativePath)
                    }
                }
        }
    }

    $fingerprints = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in @($relativePaths | Sort-Object)) {
        $absolutePath = [System.IO.Path]::GetFullPath((Join-Path $StationRoot $relativePath))
        if ($null -eq (Get-SafeRelativePath -Root $StationRoot -Path $absolutePath)) {
            continue
        }
        $fingerprints.Add((Get-FileFingerprint -Path $absolutePath -DisplayPath $relativePath))
    }

    return $fingerprints.ToArray()
}

function Convert-AuditToMarkdown {
    param([Parameter(Mandatory = $true)][object]$Report)

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.AppendLine("# CpStudio post-export offline audit")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- Request: ``$($Report.request.requestId)``")
    $null = $builder.AppendLine("- Export mode: ``$($Report.request.exportMode)``")
    $null = $builder.AppendLine("- Audited at (UTC): ``$($Report.auditedAtUtc)``")
    $null = $builder.AppendLine("- Result: **$($Report.auditStatus)**")
    $null = $builder.AppendLine("- Station root: ``$($Report.request.stationRoot)``")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("## Safety boundary")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('- Offline/read-only inspection only.')
    $null = $builder.AppendLine('- No engineering IDE or automation bridge was started.')
    $null = $builder.AppendLine('- No PLC, I/O, Engineering_Data or generated project file was written.')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("## Git working tree")
    $null = $builder.AppendLine()
    if ($Report.git.available) {
        $null = $builder.AppendLine("- HEAD: ``$($Report.git.head)``")
        $null = $builder.AppendLine("- Branch: ``$($Report.git.branch)``")
        $null = $builder.AppendLine("- Changed paths: $(@($Report.git.changedPaths).Count)")
        foreach ($line in @($Report.git.status)) {
            $null = $builder.AppendLine("  - ``$($line.Replace('`', ''))``")
        }
    }
    else {
        $null = $builder.AppendLine("- Git audit unavailable: $($Report.git.error)")
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("## Ownership manifests")
    $null = $builder.AppendLine()
    foreach ($manifest in @($Report.manifests)) {
        $state = if ($manifest.exists) { 'present' } else { 'MISSING' }
        $null = $builder.AppendLine("- ``$($manifest.path)``: $state")
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("## Findings")
    $null = $builder.AppendLine()
    if (@($Report.findings).Count -eq 0) {
        $null = $builder.AppendLine('- No offline audit finding.')
    }
    else {
        foreach ($finding in @($Report.findings)) {
            $null = $builder.AppendLine("- **$($finding.severity)** ``$($finding.code)``: $($finding.message)")
        }
    }

    return $builder.ToString()
}

function Write-FailureTrace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProcessingPath,

        [Parameter(Mandatory = $false)]
        [object]$NormalizedRequest,

        [Parameter(Mandatory = $true)]
        [string]$OriginalRaw,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$Failure,

        [Parameter(Mandatory = $true)]
        [string]$FailureReportRoot,

        [Parameter(Mandatory = $true)]
        [string]$FailedDirectory
    )

    $fallbackId = [guid]::NewGuid().ToString()
    $safeRequestId = if ($NormalizedRequest) { [string]$NormalizedRequest.requestId } else { $fallbackId }
    $safeFileId = $safeRequestId -replace '[^A-Za-z0-9_.-]', '_'
    $failureDetails = [ordered]@{
        type       = $Failure.Exception.GetType().FullName
        message    = $Failure.Exception.Message
        stackTrace = $Failure.ScriptStackTrace
    }
    $failedAtUtc = [DateTime]::UtcNow.ToString('o')

    if ($NormalizedRequest) {
        $failedRecord = New-StateRecord -Request $NormalizedRequest -Status 'failed' -AdditionalFields @{
            failedAtUtc          = $failedAtUtc
            originalRequestSha256 = Get-Sha256ForText -Text $OriginalRaw
            failure              = $failureDetails
        }
    }
    else {
        $failedRecord = [ordered]@{
            schemaVersion         = 2
            requestId             = $safeRequestId
            status                = 'failed'
            failedAtUtc           = $failedAtUtc
            originalRequestSha256 = Get-Sha256ForText -Text $OriginalRaw
            originalRequestText   = $OriginalRaw
            queue                 = [ordered]@{ version = 1; state = 'failed' }
            failure               = $failureDetails
        }
    }

    Write-AtomicJson -Path $ProcessingPath -Value $failedRecord
    $failedPath = Move-RequestToState -CurrentPath $ProcessingPath -StateDirectory $FailedDirectory

    [System.IO.Directory]::CreateDirectory($FailureReportRoot) | Out-Null
    $failureReportPath = Join-Path $FailureReportRoot ($safeFileId + '.failed.json')
    $failureReport = [ordered]@{
        schemaVersion = 1
        requestId     = $safeRequestId
        status        = 'failed'
        failedAtUtc   = $failedAtUtc
        requestPath   = $failedPath
        failure       = $failureDetails
    }
    Write-AtomicJson -Path $failureReportPath -Value $failureReport

    return $failedPath
}

function Invoke-OneRequestAudit {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$Candidate,

        [Parameter(Mandatory = $true)]
        [string]$ActiveEngineeringRoot,

        [Parameter(Mandatory = $true)]
        [string]$ActiveQueueRoot,

        [Parameter(Mandatory = $true)]
        [string]$ActiveReportRoot,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedStationRoot,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedPlcProject
    )

    $processingDirectory = Join-Path $ActiveQueueRoot 'processing'
    $doneDirectory = Join-Path $ActiveQueueRoot 'done'
    $failedDirectory = Join-Path $ActiveQueueRoot 'failed'
    $processingPath = $null
    $normalizedRequest = $null
    $rawText = ''

    try {
        if ($Candidate.DirectoryName.Equals($processingDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
            $processingPath = $Candidate.FullName
        }
        else {
            $claimFileName = $Candidate.Name
            if ($Candidate.Name.Equals('export_request.json', [System.StringComparison]::OrdinalIgnoreCase)) {
                # Repeated schema-v1 requests all use the same source name. Give
                # each claimed request a unique queue name so done/failed history
                # never blocks the next legacy export.
                $claimFileName = 'legacy_{0}_{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N')
            }
            $processingPath = Move-RequestToState `
                -CurrentPath $Candidate.FullName `
                -StateDirectory $processingDirectory `
                -DestinationFileName $claimFileName
        }

        $rawText = [System.IO.File]::ReadAllText($processingPath)
        $normalizedRequest = ConvertTo-NormalizedRequest `
            -RawText $rawText `
            -SourcePath $processingPath `
            -ActiveEngineeringRoot $ActiveEngineeringRoot

        if ($ExpectedStationRoot -and
            (-not $normalizedRequest.stationRoot.Equals($ExpectedStationRoot, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Request station root does not match config/project.yaml: $($normalizedRequest.stationRoot)"
        }
        if ($ExpectedPlcProject -and
            (-not $normalizedRequest.plcProject.Equals($ExpectedPlcProject, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Request PLC project does not match config/project.yaml: $($normalizedRequest.plcProject)"
        }

        $processingRecord = New-StateRecord -Request $normalizedRequest -Status 'processing' -AdditionalFields @{
            processingStartedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-AtomicJson -Path $processingPath -Value $processingRecord

        $gitAuditScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\git\Get-ReadOnlyGitAudit.ps1'))
        $gitAudit = & $gitAuditScript -RepositoryPath $normalizedRequest.stationRoot
        $manifestAudit = Get-ManifestAudit -Root $ActiveEngineeringRoot
        $fingerprints = Get-StationFingerprints `
            -StationRoot $normalizedRequest.stationRoot `
            -PlcProject $normalizedRequest.plcProject `
            -GitAudit $gitAudit

        $findings = New-Object System.Collections.Generic.List[object]
        foreach ($manifest in $manifestAudit) {
            if (-not $manifest.exists) {
                $findings.Add([pscustomobject]@{
                    severity = 'error'
                    code     = 'OWNERSHIP_MANIFEST_MISSING'
                    message  = "Required manifest is missing: $($manifest.path)"
                })
            }
        }
        if (-not $gitAudit.available) {
            $findings.Add([pscustomobject]@{
                severity = 'warning'
                code     = 'GIT_AUDIT_UNAVAILABLE'
                message  = $gitAudit.error
            })
        }
        elseif (@($gitAudit.changedPaths).Count -gt 0) {
            $findings.Add([pscustomobject]@{
                severity = 'info'
                code     = 'GENERATED_CHANGES_PRESENT'
                message  = "$(@($gitAudit.changedPaths).Count) changed path(s) require ownership review."
            })
        }

        $plcRelativePath = Get-SafeRelativePath -Root $normalizedRequest.stationRoot -Path $normalizedRequest.plcProject
        if (-not $plcRelativePath) {
            $findings.Add([pscustomobject]@{
                severity = 'error'
                code     = 'PLC_PROJECT_OUTSIDE_STATION'
                message  = 'The request PLC project is outside stationRoot and was not fingerprinted.'
            })
        }
        elseif (-not [System.IO.File]::Exists($normalizedRequest.plcProject)) {
            $findings.Add([pscustomobject]@{
                severity = 'warning'
                code     = 'PLC_PROJECT_MISSING'
                message  = "PLC project is absent: $plcRelativePath"
            })
        }

        $auditStatus = 'clean'
        if (@($findings | Where-Object { $_.severity -eq 'error' }).Count -gt 0) {
            $auditStatus = 'needs-attention'
        }
        elseif ($findings.Count -gt 0) {
            $auditStatus = 'review'
        }

        $auditedAtUtc = [DateTime]::UtcNow.ToString('o')
        $report = [ordered]@{
            schemaVersion = 1
            auditedAtUtc  = $auditedAtUtc
            auditStatus   = $auditStatus
            readOnly      = $true
            request       = [ordered]@{
                requestId       = $normalizedRequest.requestId
                requestedAtUtc  = $normalizedRequest.requestedAtUtc
                source          = $normalizedRequest.source
                exportMode      = $normalizedRequest.exportMode
                engineeringRoot = $normalizedRequest.engineeringRoot
                stationRoot     = $normalizedRequest.stationRoot
                plcProject      = $normalizedRequest.plcProject
            }
            guardrails    = [ordered]@{
                engineeringToolsStarted = $false
                generatedFilesWritten   = $false
                onlineOperationsUsed    = $false
                gitOptionalLocksDisabled = $true
            }
            git            = $gitAudit
            manifests      = @($manifestAudit)
            fingerprints   = @($fingerprints)
            findings       = $findings.ToArray()
            nextStage      = 'A live Codex session may review this report and explicitly run controlled snapshot, ownership merge, I/O/Symbol audit and offline compile.'
        }

        [System.IO.Directory]::CreateDirectory($ActiveReportRoot) | Out-Null
        $safeRequestId = ([string]$normalizedRequest.requestId) -replace '[^A-Za-z0-9_.-]', '_'
        $jsonReportPath = Join-Path $ActiveReportRoot ($safeRequestId + '.json')
        $markdownReportPath = Join-Path $ActiveReportRoot ($safeRequestId + '.md')
        Write-AtomicJson -Path $jsonReportPath -Value $report
        Write-AtomicUtf8File -Path $markdownReportPath -Content (Convert-AuditToMarkdown -Report $report)

        $doneRecord = New-StateRecord -Request $normalizedRequest -Status 'done' -AdditionalFields @{
            completedAtUtc = $auditedAtUtc
            auditStatus    = $auditStatus
            reports        = [ordered]@{
                json     = $jsonReportPath
                markdown = $markdownReportPath
            }
        }
        Write-AtomicJson -Path $processingPath -Value $doneRecord
        $donePath = Move-RequestToState -CurrentPath $processingPath -StateDirectory $doneDirectory

        return [pscustomobject]@{
            requestId     = $normalizedRequest.requestId
            status        = 'done'
            auditStatus   = $auditStatus
            requestPath   = $donePath
            jsonReport    = $jsonReportPath
            markdownReport = $markdownReportPath
        }
    }
    catch {
        $failure = $_
        if ($processingPath -and [System.IO.File]::Exists($processingPath)) {
            try {
                $null = Write-FailureTrace `
                    -ProcessingPath $processingPath `
                    -NormalizedRequest $normalizedRequest `
                    -OriginalRaw $rawText `
                    -Failure $failure `
                    -FailureReportRoot $ActiveReportRoot `
                    -FailedDirectory $failedDirectory
            }
            catch {
                throw "Post-export audit failed and failure trace could not be finalized. Audit error: $($failure.Exception.Message). Trace error: $($_.Exception.Message)"
            }
        }
        throw $failure
    }
}

$scriptDirectory = Split-Path -Parent $PSCommandPath
if (-not $EngineeringRoot) {
    $EngineeringRoot = Join-Path $scriptDirectory '..\..'
}
$resolvedEngineeringRoot = [System.IO.Path]::GetFullPath($EngineeringRoot)
$configurationPath = Join-Path $resolvedEngineeringRoot 'config\project.yaml'
$expectedStationRoot = $null
$expectedPlcProject = $null
if ([System.IO.File]::Exists($configurationPath)) {
    $configuredStationRoot = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'station_root'
    if ($configuredStationRoot -and ($configuredStationRoot -ne 'null')) {
        $expectedStationRoot = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredStationRoot
    }
    $configuredPlcProject = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'plc_project'
    if ($configuredPlcProject -and ($configuredPlcProject -ne 'null')) {
        $expectedPlcProject = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredPlcProject
    }
}

if (-not $QueueRoot) {
    $configuredRequestPath = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'export_request'
    if ($configuredRequestPath) {
        $legacyRequestPath = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredRequestPath
        $QueueRoot = if ([System.IO.Path]::GetExtension($legacyRequestPath) -eq '.json') {
            [System.IO.Path]::GetDirectoryName($legacyRequestPath)
        }
        else {
            $legacyRequestPath
        }
    }
    else {
        $QueueRoot = Join-Path $resolvedEngineeringRoot 'data\requests'
    }
}
$resolvedQueueRoot = [System.IO.Path]::GetFullPath($QueueRoot)

if (-not $ReportRoot) {
    $ReportRoot = Join-Path $resolvedEngineeringRoot 'data\reports\cpstudio'
}
$resolvedReportRoot = [System.IO.Path]::GetFullPath($ReportRoot)

$expectedDataRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedEngineeringRoot 'data')).TrimEnd('\', '/')
$expectedDataPrefix = $expectedDataRoot + [System.IO.Path]::DirectorySeparatorChar
foreach ($controlledPath in @($resolvedQueueRoot, $resolvedReportRoot)) {
    if (-not $controlledPath.StartsWith($expectedDataPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Post-export state/report path escaped the engineering data root: $controlledPath"
    }
}

if ($WhatIfPreference) {
    # WhatIf is a lock-free preview and never claims a queue item.
    $candidateRequests = @(Get-CandidateRequests `
        -Root $resolvedQueueRoot `
        -SelectedRequestId $RequestId `
        -IncludeProcessing:$RecoverProcessing)
    if ($RequestId -and ($candidateRequests.Count -eq 0)) {
        throw "No pending request matched requestId '$RequestId'."
    }
    if (-not $All) {
        $candidateRequests = @($candidateRequests | Select-Object -First 1)
    }
    Write-Output ([pscustomobject]@{
        status       = 'what-if'
        queueRoot    = $resolvedQueueRoot
        reportRoot   = $resolvedReportRoot
        requestPaths = @($candidateRequests.FullName)
        actions      = @(
            'claim pending request by same-volume move',
            'read Git diff with optional locks disabled',
            'hash changed and critical generated files',
            'check ownership manifest files',
            'write JSON and Markdown reports',
            'move request to done or failed'
        )
    })
    return
}

$queueLock = $null
$results = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[System.Management.Automation.ErrorRecord]
try {
    $queueLock = Enter-QueueLock -Root $resolvedQueueRoot -WaitMilliseconds $LockWaitMilliseconds

    # Enumerate only after the exclusive lock is held. A second consumer can
    # therefore never keep a stale FileInfo for a request completed by the
    # first consumer while it was waiting for the queue.
    $candidateRequests = @(Get-CandidateRequests `
        -Root $resolvedQueueRoot `
        -SelectedRequestId $RequestId `
        -IncludeProcessing:$RecoverProcessing)
    if ($RequestId -and ($candidateRequests.Count -eq 0)) {
        throw "No pending request matched requestId '$RequestId'."
    }
    if ($candidateRequests.Count -eq 0) {
        $results.Add([pscustomobject]@{
            status    = 'idle'
            queueRoot = $resolvedQueueRoot
            message   = 'No pending post-export request.'
        })
    }
    else {
        if (-not $All) {
            $candidateRequests = @($candidateRequests | Select-Object -First 1)
        }
        foreach ($candidate in $candidateRequests) {
            try {
                $result = Invoke-OneRequestAudit `
                    -Candidate $candidate `
                -ActiveEngineeringRoot $resolvedEngineeringRoot `
                -ActiveQueueRoot $resolvedQueueRoot `
                -ActiveReportRoot $resolvedReportRoot `
                -ExpectedStationRoot $expectedStationRoot `
                -ExpectedPlcProject $expectedPlcProject
                $results.Add($result)
            }
            catch {
                $failures.Add($_)
            }
        }
    }
}
finally {
    if ($queueLock) {
        $queueLock.Dispose()
    }
}

foreach ($result in $results) {
    Write-Output $result
}
if ($failures.Count -gt 0) {
    $failureMessages = @($failures | ForEach-Object {
        if ($_.ScriptStackTrace) {
            '{0} [{1}]' -f $_.Exception.Message, $_.ScriptStackTrace
        }
        else {
            $_.Exception.Message
        }
    })
    throw "One or more post-export audits failed:`n$($failureMessages -join [Environment]::NewLine)"
}
