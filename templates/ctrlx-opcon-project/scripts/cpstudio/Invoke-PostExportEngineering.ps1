[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $false)]
    [Alias('ProjectRoot', 'RepositoryRoot')]
    [string]$EngineeringRoot,

    [Parameter(Mandatory = $false)]
    [string]$OperationRoot,

    [Parameter(Mandatory = $false)]
    [string]$AuditReport,

    [Parameter(Mandatory = $false)]
    [string]$OperationId,

    [Parameter(Mandatory = $false)]
    [string]$EvidencePath,

    [Parameter(Mandatory = $false)]
    [string]$SecondExportAuditReport,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 60000)]
    [int]$LockWaitMilliseconds = 0
)

$ErrorActionPreference = 'Stop'
$workflowRevision = 'ctrlx-opcon-post-export-stage2-v1'
$operationKind = 'ctrlx-opcon-post-export-operation'
$actionKind = 'ctrlx-opcon-runner-request'

function Get-ConfiguredRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigurationPath,
        [Parameter(Mandatory = $true)][string]$FieldName
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
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$ConfiguredPath
    )

    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        return [System.IO.Path]::GetFullPath($ConfiguredPath)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $ConfiguredPath))
}

function Assert-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $false)][switch]$AllowRoot
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($AllowRoot -and $resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedPath
    }
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description is outside the allowed root: $resolvedPath"
    }
    return $resolvedPath
}

function Get-Sha256ForText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-JsonText {
    param([Parameter(Mandatory = $true)][object]$Value)

    return (($Value | ConvertTo-Json -Depth 64) + [Environment]::NewLine)
}

function Get-JsonTextSha256 {
    param([Parameter(Mandatory = $true)][object]$Value)

    return Get-Sha256ForText -Text (Get-JsonText -Value $Value)
}

function Read-JsonDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($resolvedPath)) {
        throw "$Description does not exist: $resolvedPath"
    }
    $bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false, $true
        $raw = $utf8.GetString($bytes)
        if (($raw.Length -gt 0) -and ($raw[0] -eq [char]0xFEFF)) {
            $raw = $raw.Substring(1)
        }
        $payload = $raw | ConvertFrom-Json
    }
    catch {
        throw "$Description is not valid JSON: $resolvedPath. $($_.Exception.Message)"
    }
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $sha256 = ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
    return [pscustomobject]@{
        path    = $resolvedPath
        raw     = $raw
        sha256  = $sha256
        payload = $payload
    }
}

function Assert-JsonArrayProperty {
    param(
        [Parameter(Mandatory = $true)][string]$RawJson,
        [Parameter(Mandatory = $true)][string[]]$PropertyPath,
        [Parameter(Mandatory = $true)][string]$Context
    )

    try {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $rawRoot = $serializer.DeserializeObject($RawJson)
    }
    catch {
        throw "$Context JSON shape could not be validated. $($_.Exception.Message)"
    }
    $rawValue = $rawRoot
    foreach ($propertyName in $PropertyPath) {
        if (($rawValue -isnot [System.Collections.IDictionary]) -or (-not ($rawValue.Keys -contains $propertyName))) {
            throw "$Context is missing $($PropertyPath -join '.')."
        }
        $rawValue = $rawValue[$propertyName]
    }
    $displayPath = $PropertyPath -join '.'
    if ($null -eq $rawValue) {
        throw "$Context $displayPath must be an array, not null."
    }
    if ($rawValue -isnot [System.Array]) {
        throw "$Context $displayPath must be a JSON array."
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $false)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) {
            return $DefaultValue
        }
        $dictionaryValue = $Object[$Name]
        if ($null -eq $dictionaryValue) {
            return $DefaultValue
        }
        return $dictionaryValue
    }
    $property = $Object.PSObject.Properties[$Name]
    if (($null -eq $property) -or ($null -eq $property.Value)) {
        return $DefaultValue
    }
    return $property.Value
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$ExpectedNames,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $actualNames = if ($Object -is [System.Collections.IDictionary]) {
        @($Object.Keys | ForEach-Object { [string]$_ })
    }
    else {
        @($Object.PSObject.Properties.Name)
    }
    foreach ($expectedName in $ExpectedNames) {
        if ($actualNames -notcontains $expectedName) {
            throw "$Context is missing required property '$expectedName'."
        }
    }
    foreach ($actualName in $actualNames) {
        if ($ExpectedNames -notcontains $actualName) {
            throw "$Context contains unsupported property '$actualName'."
        }
    }
}

function Get-RequiredString {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $value = Get-PropertyValue -Object $Object -Name $Name
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "$Context is missing the required '$Name' value."
    }
    return [string]$value
}

function Get-BooleanValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][bool]$DefaultValue = $false,
        [Parameter(Mandatory = $false)][switch]$Required,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $property = if ($null -ne $Object) { $Object.PSObject.Properties[$Name] } else { $null }
    if (($null -eq $property) -or ($null -eq $property.Value)) {
        if ($Required) {
            throw "$Context is missing the required Boolean '$Name'."
        }
        return $DefaultValue
    }
    if ($property.Value -isnot [bool]) {
        throw "$Context '$Name' must be a JSON Boolean."
    }
    return [bool]$property.Value
}

function Test-HexSha256 {
    param([Parameter(Mandatory = $false)][string]$Value)

    return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -match '^[A-Fa-f0-9]{64}$')
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $encoding = New-Object System.Text.UTF8Encoding $false
    try {
        [System.IO.File]::WriteAllText($temporaryPath, (Get-JsonText -Value $Value), $encoding)
        if ([System.IO.File]::Exists($Path)) {
            $backupPath = $temporaryPath + '.bak'
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
            if ([System.IO.File]::Exists($backupPath)) {
                [System.IO.File]::Delete($backupPath)
            }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $encoding = New-Object System.Text.UTF8Encoding $false
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Text, $encoding)
        if ([System.IO.File]::Exists($Path)) {
            $backupPath = $temporaryPath + '.bak'
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
            if ([System.IO.File]::Exists($backupPath)) {
                [System.IO.File]::Delete($backupPath)
            }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Write-ImmutableJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $text = Get-JsonText -Value $Value
    $expectedSha256 = Get-Sha256ForText -Text $text
    if ([System.IO.File]::Exists($Path)) {
        $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if (-not $actualSha256.Equals($expectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Immutable ledger file already exists with different content: $Path"
        }
        return $actualSha256
    }

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $encoding = New-Object System.Text.UTF8Encoding $false
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $text, $encoding)
        [System.IO.File]::Move($temporaryPath, $Path)
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Enter-LedgerLock {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][int]$WaitMilliseconds = 0
    )

    [System.IO.Directory]::CreateDirectory($Root) | Out-Null
    $lockPath = Join-Path $Root '.ledger.lock'
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
                throw "Another Stage2 coordinator holds the workflow-local ledger lock: $lockPath"
            }
            Start-Sleep -Milliseconds 25
        }
    }

    try {
        # The OS handle, not mutable file metadata, is the lock authority. Keep
        # the on-disk marker stable so an idempotent coordinator invocation does
        # not create a false ledger diff.
        if ($stream.Length -eq 0) {
            $record = [ordered]@{
                schemaVersion = 1
                scope         = 'workflow-local'
                operationRoot = $Root
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((($record | ConvertTo-Json -Compress) + [Environment]::NewLine))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        return $stream
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Assert-NoSensitiveEvidence {
    param(
        [Parameter(Mandatory = $false)][object]$Value,
        [Parameter(Mandatory = $false)][string]$Path = '$'
    )

    if ($null -eq $Value) {
        return
    }
    if (($Value -is [string]) -or ($Value -is [ValueType])) {
        return
    }
    if (($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [pscustomobject])) {
        $index = 0
        foreach ($item in $Value) {
            Assert-NoSensitiveEvidence -Value $item -Path ($Path + '[' + $index + ']')
            $index++
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        $propertyPath = $Path + '.' + $property.Name
        if ($property.Name -match '(?i)(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential)') {
            if (($null -ne $property.Value) -and
                (($property.Value -isnot [bool]) -or ([bool]$property.Value))) {
                throw "Runner evidence contains a prohibited secret-bearing field: $propertyPath"
            }
        }
        Assert-NoSensitiveEvidence -Value $property.Value -Path $propertyPath
    }
}

function Get-SafeFailureText {
    param(
        [Parameter(Mandatory = $false)][string]$Stage,
        [Parameter(Mandatory = $false)][string]$Code,
        [Parameter(Mandatory = $true)][ValidateSet('blocked', 'failed')][string]$Status
    )

    $safeStage = if ($Stage -match '^[A-Za-z0-9_.-]{1,64}$') { $Stage } else { 'unspecified' }
    $safeCode = if ($Code -match '^[A-Za-z0-9_.-]{1,96}$') { $Code } else { 'UNSPECIFIED' }
    return "Runner reported $Status at stage '$safeStage' with code '$safeCode'."
}

function Assert-NoOnlineCapabilities {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$RawJson
    )

    $capabilityProperty = $Evidence.PSObject.Properties['capabilitiesInvoked']
    if ($null -eq $capabilityProperty) {
        throw 'Runner evidence is missing the producer capabilitiesInvoked field.'
    }
    Assert-JsonArrayProperty -RawJson $RawJson -PropertyPath @('capabilitiesInvoked') -Context 'Runner evidence'
    $prohibitedPattern = '(?i)(connect[_-]?to[_-]?device|download[_-]?to[_-]?device|start[_-]?stop|write[_-]?variable|read[_-]?variable|monitor[_-]?variables|force|set[_-]?simulation|online|launch[_-]?(codesys|ple|mcp)|watcher[_-]?ipc)'
    $approvedOfflineCapabilities = @(
        'get_codesys_status',
        'get_all_pou_code',
        'find_references',
        'inspect_device_node',
        'list_project_libraries',
        'search_code',
        'open_project',
        'compile_project',
        'get_compile_messages',
        'set_pou_code'
    )
    foreach ($capability in @($capabilityProperty.Value)) {
        if ($null -eq $capability) {
            throw 'Runner evidence contains a null capability identifier.'
        }
        if ([string]$capability -notmatch '^[A-Za-z0-9_.-]{1,96}$') {
            throw "Runner evidence reports an invalid capability identifier: $capability"
        }
        if ([string]$capability -match $prohibitedPattern) {
            throw "Runner evidence reports a prohibited online capability: $capability"
        }
        if ($approvedOfflineCapabilities -notcontains [string]$capability) {
            throw "Runner evidence reports an unapproved offline capability: $capability"
        }
    }
}

function Assert-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $expectedPath = [System.IO.Path]::GetFullPath($Expected).TrimEnd('\', '/')
    $actualPath = [System.IO.Path]::GetFullPath($Actual).TrimEnd('\', '/')
    if (-not $expectedPath.Equals($actualPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description mismatch. Expected '$expectedPath', got '$actualPath'."
    }
}

function Get-RelativePathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolvedPath = Assert-PathInsideRoot -Root $resolvedRoot -Path $Path -Description $Description
    return $resolvedPath.Substring($resolvedRoot.Length + 1).Replace('\', '/')
}

function Assert-FingerprintRecordsCurrent {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $false)][string[]]$RequiredPaths = @(),
        [Parameter(Mandatory = $true)][string]$Context
    )

    $recordMap = @{}
    foreach ($record in @($Records)) {
        $relativePath = (Get-RequiredString -Object $record -Name 'path' -Context $Context).Replace('\', '/')
        if ($recordMap.ContainsKey($relativePath)) {
            throw "$Context contains a duplicate path: $relativePath"
        }
        $absolutePath = [System.IO.Path]::GetFullPath((Join-Path $Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
        $null = Assert-PathInsideRoot -Root $Root -Path $absolutePath -Description $Context
        $reportedExists = Get-BooleanValue -Object $record -Name 'exists' -Required -Context $Context
        $actualExists = [System.IO.File]::Exists($absolutePath)
        if ($reportedExists -ne $actualExists) {
            throw "$Context existence changed: $relativePath"
        }
        if ($actualExists) {
            $reportedSha = [string](Get-PropertyValue -Object $record -Name 'sha256')
            if (-not (Test-HexSha256 -Value $reportedSha)) {
                throw "$Context has no valid SHA-256: $relativePath"
            }
            $actualSha = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash
            if (-not $actualSha.Equals($reportedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "$Context changed after its report was created: $relativePath"
            }
        }
        $recordMap[$relativePath] = $record
    }
    foreach ($requiredPath in @($RequiredPaths)) {
        $normalizedRequired = $requiredPath.Replace('\', '/')
        if ((-not $recordMap.ContainsKey($normalizedRequired)) -or
            (-not (Get-BooleanValue -Object $recordMap[$normalizedRequired] -Name 'exists' -Required -Context $Context))) {
            throw "$Context is missing a required file fingerprint: $normalizedRequired"
        }
    }
}

function Read-AndValidateAuditReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedEngineeringRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedStationRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedPlcProject
    )

    $document = Read-JsonDocument -Path $Path -Description 'Stage1 audit report'
    $report = $document.payload
    if ([int](Get-PropertyValue -Object $report -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
        throw 'Stage1 audit report schemaVersion must be 1.'
    }
    if (-not (Get-BooleanValue -Object $report -Name 'readOnly' -Required -Context 'Stage1 audit report')) {
        throw 'Stage1 audit report must be readOnly=true.'
    }
    $auditStatus = Get-RequiredString -Object $report -Name 'auditStatus' -Context 'Stage1 audit report'
    if (@('clean', 'review') -notcontains $auditStatus) {
        throw "Stage1 auditStatus is not accepted by Stage2: $auditStatus"
    }

    $request = Get-PropertyValue -Object $report -Name 'request'
    if ($null -eq $request) {
        throw 'Stage1 audit report has no request object.'
    }
    $requestId = Get-RequiredString -Object $request -Name 'requestId' -Context 'Stage1 audit request'
    $requestedAtText = Get-RequiredString -Object $request -Name 'requestedAtUtc' -Context 'Stage1 audit request'
    $requestedAt = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($requestedAtText, [ref]$requestedAt)) {
        throw "Stage1 requestedAtUtc is invalid: $requestedAtText"
    }
    if ($requestedAt.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5)) {
        throw 'Stage1 requestedAtUtc is unreasonably far in the future.'
    }
    $auditedAtText = Get-RequiredString -Object $report -Name 'auditedAtUtc' -Context 'Stage1 audit report'
    $auditedAt = [DateTime]::MinValue
    if ((-not [DateTime]::TryParse($auditedAtText, [ref]$auditedAt)) -or
        ($auditedAt.ToUniversalTime() -lt $requestedAt.ToUniversalTime()) -or
        ($auditedAt.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5))) {
        throw 'Stage1 auditedAtUtc is inconsistent with requestedAtUtc or is unreasonably far in the future.'
    }

    Assert-SamePath -Expected $ExpectedEngineeringRoot -Actual (Get-RequiredString -Object $request -Name 'engineeringRoot' -Context 'Stage1 audit request') -Description 'Engineering root'
    Assert-SamePath -Expected $ExpectedStationRoot -Actual (Get-RequiredString -Object $request -Name 'stationRoot' -Context 'Stage1 audit request') -Description 'Station root'
    Assert-SamePath -Expected $ExpectedPlcProject -Actual (Get-RequiredString -Object $request -Name 'plcProject' -Context 'Stage1 audit request') -Description 'PLC project'

    $guardrails = Get-PropertyValue -Object $report -Name 'guardrails'
    if ($null -eq $guardrails) {
        throw 'Stage1 audit report has no guardrails object.'
    }
    foreach ($name in @('engineeringToolsStarted', 'generatedFilesWritten', 'onlineOperationsUsed')) {
        if (Get-BooleanValue -Object $guardrails -Name $name -Required -Context 'Stage1 guardrails') {
            throw "Stage1 guardrail '$name' must be false."
        }
    }

    foreach ($finding in @(Get-PropertyValue -Object $report -Name 'findings' -DefaultValue @())) {
        if ([string](Get-PropertyValue -Object $finding -Name 'severity') -eq 'error') {
            throw "Stage1 audit contains an error finding: $([string](Get-PropertyValue -Object $finding -Name 'code'))"
        }
    }
    $manifestRecords = @(Get-PropertyValue -Object $report -Name 'manifests' -DefaultValue @())
    $requiredManifestPaths = @('ai/ownership.yaml', 'ai/hooks.yaml', 'ai/graphical.yaml')
    $seenManifestPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($manifest in $manifestRecords) {
        if (-not (Get-BooleanValue -Object $manifest -Name 'exists' -Required -Context 'Stage1 manifest fingerprint')) {
            throw "Stage1 manifest is absent: $([string](Get-PropertyValue -Object $manifest -Name 'path'))"
        }
        $manifestPath = Get-RequiredString -Object $manifest -Name 'path' -Context 'Stage1 manifest fingerprint'
        if ($requiredManifestPaths -notcontains $manifestPath) {
            throw "Stage1 audit contains an unexpected ownership manifest: $manifestPath"
        }
        if (-not $seenManifestPaths.Add($manifestPath)) {
            throw "Stage1 audit contains a duplicate ownership manifest: $manifestPath"
        }
        $manifestSha = [string](Get-PropertyValue -Object $manifest -Name 'sha256')
        if (-not (Test-HexSha256 -Value $manifestSha)) {
            throw "Stage1 manifest has no valid SHA-256: $manifestPath"
        }
    }
    foreach ($requiredManifestPath in $requiredManifestPaths) {
        if (-not $seenManifestPaths.Contains($requiredManifestPath)) {
            throw "Stage1 audit is missing the ownership manifest: $requiredManifestPath"
        }
    }
    Assert-FingerprintRecordsCurrent `
        -Root $ExpectedEngineeringRoot `
        -Records $manifestRecords `
        -RequiredPaths $requiredManifestPaths `
        -Context 'Stage1 ownership manifest'

    $fingerprintRecords = @(Get-PropertyValue -Object $report -Name 'fingerprints' -DefaultValue @())
    if ($fingerprintRecords.Count -lt 2) {
        throw 'Stage1 audit must contain critical Station fingerprints.'
    }
    $seenFingerprintPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($fingerprint in $fingerprintRecords) {
        $fingerprintPath = Get-RequiredString -Object $fingerprint -Name 'path' -Context 'Stage1 Station fingerprint'
        if (-not $seenFingerprintPaths.Add($fingerprintPath)) {
            throw "Stage1 audit contains a duplicate Station fingerprint: $fingerprintPath"
        }
        if ((Get-BooleanValue -Object $fingerprint -Name 'exists' -Required -Context 'Stage1 Station fingerprint') -and
            (-not (Test-HexSha256 -Value ([string](Get-PropertyValue -Object $fingerprint -Name 'sha256'))))) {
            throw "Stage1 Station fingerprint has no valid SHA-256: $fingerprintPath"
        }
    }
    $plcRelativePath = Get-RelativePathInsideRoot -Root $ExpectedStationRoot -Path $ExpectedPlcProject -Description 'Configured PLC project'
    Assert-FingerprintRecordsCurrent `
        -Root $ExpectedStationRoot `
        -Records $fingerprintRecords `
        -RequiredPaths @('Engineering/Engineering_Data.xml', $plcRelativePath) `
        -Context 'Stage1 Station fingerprint'

    return [pscustomobject]@{
        document      = $document
        report        = $report
        request       = $request
        requestId     = $requestId
        requestedAtUtc = $requestedAt.ToUniversalTime()
    }
}

function Assert-ManifestSetsEqual {
    param(
        [Parameter(Mandatory = $true)][object[]]$Expected,
        [Parameter(Mandatory = $true)][object[]]$Actual
    )

    $expectedMap = @{}
    foreach ($record in @($Expected)) {
        $expectedMap[[string]$record.path] = [string]$record.sha256
    }
    $actualMap = @{}
    foreach ($record in @($Actual)) {
        $actualMap[[string]$record.path] = [string]$record.sha256
    }
    if ($expectedMap.Count -ne $actualMap.Count) {
        throw 'Ownership manifest set changed between Stage1 reports.'
    }
    foreach ($path in $expectedMap.Keys) {
        if ((-not $actualMap.ContainsKey($path)) -or
            (-not $expectedMap[$path].Equals($actualMap[$path], [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Ownership manifest changed during the Stage2 operation: $path"
        }
    }
}

function Assert-OperationSourcesCurrent {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $false)][switch]$SkipStationFingerprints
    )

    foreach ($source in @($Operation.source.initialAudit, $Operation.source.export2Audit)) {
        if ($null -eq $source) {
            continue
        }
        if (-not [System.IO.File]::Exists([string]$source.path)) {
            throw "A bound Stage1 audit report is missing: $($source.path)"
        }
        $actualSha = (Get-FileHash -LiteralPath ([string]$source.path) -Algorithm SHA256).Hash
        if (-not $actualSha.Equals([string]$source.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "A bound Stage1 audit report changed after it entered the operation: $($source.path)"
        }
    }

    foreach ($manifest in @($Operation.baseline.manifests)) {
        $relativePath = ([string]$manifest.path).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $absolutePath = [System.IO.Path]::GetFullPath((Join-Path ([string]$Operation.identity.engineeringRoot) $relativePath))
        $null = Assert-PathInsideRoot -Root ([string]$Operation.identity.engineeringRoot) -Path $absolutePath -Description 'Ownership manifest'
        if (-not [System.IO.File]::Exists($absolutePath)) {
            throw "Ownership manifest disappeared during the Stage2 operation: $($manifest.path)"
        }
        $actualSha = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash
        if (-not $actualSha.Equals([string]$manifest.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Ownership manifest changed during the Stage2 operation: $($manifest.path)"
        }
    }
    if (-not $SkipStationFingerprints) {
        $fingerprints = @($Operation.baseline.fingerprints)
        if (($Operation.currentAction) -and
            ([string]$Operation.currentAction.kind -eq 'verify_after_export_2') -and
            ($Operation.source.export2Audit)) {
            $export2Report = (Read-JsonDocument -Path ([string]$Operation.source.export2Audit.path) -Description 'Bound Export #2 audit report').payload
            $fingerprints = @($export2Report.fingerprints)
        }
        $plcRelativePath = Get-RelativePathInsideRoot `
            -Root ([string]$Operation.identity.stationRoot) `
            -Path ([string]$Operation.identity.plcProject) `
            -Description 'Operation PLC project'
        $requiredFingerprints = @('Engineering/Engineering_Data.xml')
        if (($Operation.currentAction) -and ([string]$Operation.currentAction.kind -in @('inspect_and_build', 'verify_after_export_2'))) {
            $requiredFingerprints += $plcRelativePath
        }
        $recordsToVerify = @($fingerprints | Where-Object { $requiredFingerprints -contains ([string]$_.path).Replace('\', '/') })
        Assert-FingerprintRecordsCurrent `
            -Root ([string]$Operation.identity.stationRoot) `
            -Records $recordsToVerify `
            -RequiredPaths $requiredFingerprints `
            -Context 'Operation Station fingerprint'
    }
}

function Assert-OperationLedgerIntegrity {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$OperationDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedOperationId,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile,
        [Parameter(Mandatory = $false)][switch]$SkipDerivedArtifacts
    )

    if ([int](Get-PropertyValue -Object $Operation -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
        throw 'Operation schemaVersion must be 1.'
    }
    if ([string]$Operation.kind -ne $operationKind) {
        throw "Operation has an unexpected kind: $OperationDirectory"
    }
    if ([string]$Operation.workflowRevision -ne $workflowRevision) {
        throw "Operation workflow revision is not supported: $($Operation.workflowRevision)"
    }
    if ([string]$Operation.operationId -ne $ExpectedOperationId) {
        throw "Operation record identity does not match its directory: $OperationDirectory"
    }
    if (([int]$Operation.revision -lt 1) -or (-not (Test-HexSha256 -Value ([string]$Operation.idempotency.key)))) {
        throw 'Operation revision or idempotency identity is invalid.'
    }
    if ([string]$Operation.identity.profile -ne $ExpectedProfile) {
        throw 'Operation PLE profile no longer matches config/project.yaml.'
    }
    $allowedStates = @('WAITING_FOR_RUNNER', 'WAITING_FOR_CPSTUDIO', 'WAITING_FOR_EXPORT_2', 'DONE', 'BLOCKED', 'FAILED')
    if ($allowedStates -notcontains [string]$Operation.status) {
        throw "Operation has an unsupported status: $($Operation.status)"
    }
    foreach ($name in @('onlineOperationsUsed', 'coordinatorStartsPleMcp', 'coordinatorCallsRest')) {
        if (Get-BooleanValue -Object $Operation.guardrails -Name $name -Required -Context 'Operation guardrails') {
            throw "Operation guardrail '$name' must remain false."
        }
    }
    if (-not (Get-BooleanValue -Object $Operation.guardrails -Name 'offlineOnly' -Required -Context 'Operation guardrails')) {
        throw 'Operation guardrail offlineOnly must remain true.'
    }
    if ((-not (Get-BooleanValue -Object $Operation.coordination -Name 'projectLeaseReleased' -Required -Context 'Operation coordination')) -or
        (Get-BooleanValue -Object $Operation.coordination -Name 'symbolLeaseHeld' -Required -Context 'Operation coordination')) {
        throw 'Persisted operations must not retain a project or Symbol lease.'
    }

    $expectsAction = ([string]$Operation.status -eq 'WAITING_FOR_RUNNER')
    if ($expectsAction -ne ($null -ne $Operation.currentAction)) {
        throw 'Operation status and currentAction are inconsistent.'
    }
    if ($Operation.currentAction) {
        $allowedActionKinds = @('inspect_and_build', 'apply_change_set_and_build', 'verify_after_export_2')
        $actionSequence = [int]$Operation.currentAction.sequence
        if (($allowedActionKinds -notcontains [string]$Operation.currentAction.kind) -or ($actionSequence -lt 1)) {
            throw 'The current runner action kind or sequence is invalid.'
        }
        $expectedActionId = '{0}-{1:d4}' -f [string]$Operation.operationId, $actionSequence
        if ([string]$Operation.currentAction.actionId -ne $expectedActionId) {
            throw 'The current runner actionId does not match its operation/sequence.'
        }
        $actionPath = Assert-PathInsideRoot -Root (Join-Path $OperationDirectory 'actions') -Path ([string]$Operation.currentAction.path) -Description 'Runner action'
        $expectedActionPath = Join-Path (Join-Path $OperationDirectory 'actions') ('{0:d4}-{1}.json' -f $actionSequence, [string]$Operation.currentAction.kind)
        Assert-SamePath -Expected $expectedActionPath -Actual $actionPath -Description 'Runner action path'
        if (-not [System.IO.File]::Exists($actionPath)) {
            throw 'The current immutable runner action is missing.'
        }
        $actualActionSha = (Get-FileHash -LiteralPath $actionPath -Algorithm SHA256).Hash
        if (-not $actualActionSha.Equals([string]$Operation.currentAction.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'The current immutable runner action hash does not match the operation ledger.'
        }
        $action = (Read-JsonDocument -Path $actionPath -Description 'Runner action').payload
        if (([int]$action.schemaVersion -ne 1) -or
            ([string]$action.kind -ne $actionKind) -or
            ([string]$action.status -ne 'WAITING_FOR_RUNNER') -or
            ([int]$action.sequence -ne $actionSequence) -or
            ([string]$action.createdAtUtc -ne [string]$Operation.currentAction.createdAtUtc) -or
            ([string]$action.operationId -ne [string]$Operation.operationId) -or
            ([string]$action.actionId -ne [string]$Operation.currentAction.actionId) -or
            ([string]$action.actionKind -ne [string]$Operation.currentAction.kind) -or
            ([string]$action.preconditions.idempotencyKey -ne [string]$Operation.idempotency.key)) {
            throw 'The current runner action identity does not match the operation ledger.'
        }
    }

    $seenEvidenceActions = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($evidence in @($Operation.evidence)) {
        if (-not $seenEvidenceActions.Add([string]$evidence.actionId)) {
            throw "Operation contains duplicate evidence for action '$($evidence.actionId)'."
        }
        $evidencePath = Assert-PathInsideRoot -Root (Join-Path $OperationDirectory 'evidence') -Path ([string]$evidence.path) -Description 'Stored runner evidence'
        $evidenceSequence = [int](Get-PropertyValue -Object $evidence -Name 'sequence' -DefaultValue 0)
        if ($evidenceSequence -lt 1) {
            throw 'Stored runner evidence has no valid sequence.'
        }
        $expectedEvidencePath = Join-Path (Join-Path $OperationDirectory 'evidence') ('{0:d4}-{1}.json' -f $evidenceSequence, [string]$evidence.actionKind)
        Assert-SamePath -Expected $expectedEvidencePath -Actual $evidencePath -Description 'Stored runner evidence path'
        if (-not [System.IO.File]::Exists($evidencePath)) {
            throw "Stored runner evidence is missing: $evidencePath"
        }
        $actualEvidenceSha = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
        if ((-not $actualEvidenceSha.Equals([string]$evidence.sha256, [System.StringComparison]::OrdinalIgnoreCase)) -or
            (-not (Test-HexSha256 -Value ([string]$evidence.sourceSha256)))) {
            throw "Stored runner evidence hash is invalid: $evidencePath"
        }
    }

    if (-not $SkipDerivedArtifacts) {
        $sentinelPath = Join-Path $OperationDirectory 'export-window.active.json'
        $expectsSentinel = ([string]$Operation.status -eq 'WAITING_FOR_EXPORT_2')
        if ($expectsSentinel -ne [System.IO.File]::Exists($sentinelPath)) {
            throw 'Operation state and Export #2 sentinel are inconsistent.'
        }
        if ($expectsSentinel) {
            $sentinel = (Read-JsonDocument -Path $sentinelPath -Description 'Export #2 sentinel').payload
            if (([int]$sentinel.schemaVersion -ne 1) -or
                ([string]$sentinel.operationId -ne [string]$Operation.operationId) -or
                (-not (Get-BooleanValue -Object $sentinel -Name 'active' -Required -Context 'Export #2 sentinel')) -or
                ([string]$sentinel.symbolAccessPolicy -ne 'DENY') -or
                (-not (Get-BooleanValue -Object $sentinel -Name 'projectLeaseReleased' -Required -Context 'Export #2 sentinel')) -or
                ([string]$sentinel.createdAtUtc -ne [string]$Operation.export2.waitingSinceUtc)) {
                throw 'Export #2 sentinel identity is invalid.'
            }
        }

        if (@('DONE', 'BLOCKED', 'FAILED') -contains [string]$Operation.status) {
            $finalPath = Join-Path $OperationDirectory 'final.json'
            if (-not [System.IO.File]::Exists($finalPath)) {
                throw 'Terminal operation is missing final.json.'
            }
            $expectedFinalSha = Get-JsonTextSha256 -Value (New-FinalRecord -Operation $Operation)
            $actualFinalSha = (Get-FileHash -LiteralPath $finalPath -Algorithm SHA256).Hash
            if (-not $actualFinalSha.Equals($expectedFinalSha, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Final operation result does not exactly match operation.json.'
            }
        }
    }
    $history = @($Operation.history)
    if (($history.Count -eq 0) -or ([string]$history[$history.Count - 1].to -ne [string]$Operation.status)) {
        throw 'Operation history does not end at the current status.'
    }
}

function Get-OperationIdForRequest {
    param([Parameter(Mandatory = $true)][string]$RequestId)

    $safe = $RequestId -replace '[^A-Za-z0-9_.-]', '_'
    if ($safe.Length -gt 48) {
        $safe = $safe.Substring(0, 48)
    }
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'request'
    }
    $suffix = (Get-Sha256ForText -Text $RequestId).Substring(0, 8).ToLowerInvariant()
    return "cpstudio-stage2-$safe-$suffix"
}

function Get-OperationDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Id
    )

    if (($Id -notmatch '^[A-Za-z0-9_.-]+$') -or ($Id -in @('.', '..'))) {
        throw "Unsafe operationId: $Id"
    }
    $operationDirectory = [System.IO.Path]::GetFullPath((Join-Path $Root $Id))
    return Assert-PathInsideRoot -Root $Root -Path $operationDirectory -Description 'Operation directory'
}

function New-RunnerAction {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][int]$Sequence,
        [Parameter(Mandatory = $true)][ValidateSet('inspect_and_build', 'apply_change_set_and_build', 'verify_after_export_2')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$CreatedAtUtc,
        [Parameter(Mandatory = $false)][object[]]$ChangeSet = @()
    )

    $actionIdValue = '{0}-{1:d4}' -f $Operation.operationId, $Sequence
    $instructions = switch ($Kind) {
        'inspect_and_build' {
            @(
                'Use the already active unique codesys-persistent session; do not start PLE or another MCP server.',
                'Verify the exact profile, project, ownership manifests and baseline hashes before any engineering action.',
                'Run a fresh offline Build, classify I/O, owned/mixed references and Symbol post-processing, and return hash-bound evidence.'
            )
        }
        'apply_change_set_and_build' {
            @(
                'Apply only the included ownership-approved change set through the unique persistent session.',
                'Verify every expected-before hash and read back every target; set_pou_code auto-saves, so do not call save_project redundantly; then run a fresh offline Build.',
                'Do not write CpStudio-owned interfaces or any OES Declaration merge area.'
            )
        }
        'verify_after_export_2' {
            @(
                'Verify that the bound second CpStudio export completed before accessing Symbol Configuration.',
                'Use the existing unique persistent session, run final readback and a fresh offline Build, and return hash-bound evidence.',
                'Do not launch a second PLE and do not perform online operations.'
            )
        }
    }

    return [ordered]@{
        schemaVersion = 1
        kind          = $actionKind
        operationId   = $Operation.operationId
        actionId      = $actionIdValue
        actionKind    = $Kind
        sequence      = $Sequence
        createdAtUtc  = $CreatedAtUtc
        status        = 'WAITING_FOR_RUNNER'
        source        = [ordered]@{
            stage1RequestId   = $Operation.source.initialAudit.requestId
            auditReport       = $Operation.source.initialAudit.path
            auditReportSha256 = $Operation.source.initialAudit.sha256
            export2Audit      = $Operation.source.export2Audit
        }
        project       = [ordered]@{
            engineeringRoot = $Operation.identity.engineeringRoot
            stationRoot     = $Operation.identity.stationRoot
            plcProject      = $Operation.identity.plcProject
            profile         = $Operation.identity.profile
        }
        preconditions = [ordered]@{
            workflowRevision = $Operation.workflowRevision
            idempotencyKey   = $Operation.idempotency.key
            manifests        = $Operation.baseline.manifests
            fingerprints     = $Operation.baseline.fingerprints
        }
        guardrails    = [ordered]@{
            offlineOnly                    = $true
            onlineOperationsAllowed        = $false
            requireExistingPersistentSession = $true
            prohibitStartPleOrMcp           = $true
            prohibitDirectWatcherIpc        = $true
            requireExactProjectOpen         = $true
            projectLeaseRequired            = $true
            releaseLeaseAfterAction          = $true
            symbolAccessSerialized           = $true
            coordinationScope                = 'workflow-local-until-runner-lease'
        }
        changeSet     = @($ChangeSet)
        instructions  = $instructions
        evidenceContract = [ordered]@{
            schemaVersion               = 1
            requireActionRequestSha256  = $true
            requireOfflineOnly          = $true
            requireProjectLeaseReleased = $true
            requireReadbackOnSuccess     = $true
            requireFreshBuildOnSuccess   = $true
            terminalFailureMayOmitBuild  = $true
            warningComparison            = 'signature-multiset-not-count-only'
        }
    }
}

function Write-RunnerAction {
    param(
        [Parameter(Mandatory = $true)][string]$OperationDirectory,
        [Parameter(Mandatory = $true)][object]$Action
    )

    $actionsDirectory = Join-Path $OperationDirectory 'actions'
    $fileName = '{0:d4}-{1}.json' -f [int]$Action.sequence, [string]$Action.actionKind
    $path = Join-Path $actionsDirectory $fileName
    $sha256 = Write-ImmutableJson -Path $path -Value $Action
    return [pscustomobject]@{
        actionId = $Action.actionId
        kind     = $Action.actionKind
        sequence = [int]$Action.sequence
        createdAtUtc = $Action.createdAtUtc
        path     = $path
        sha256   = $sha256
    }
}

function Get-ResultView {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$OperationPath,
        [Parameter(Mandatory = $false)][string]$PreviewStatus
    )

    $currentAction = Get-PropertyValue -Object $Operation -Name 'currentAction'
    $status = if ($PreviewStatus) { $PreviewStatus } else { [string]$Operation.status }
    return [pscustomobject]@{
        operationId          = $Operation.operationId
        status               = $status
        outcome              = $Operation.outcome
        revision             = $Operation.revision
        operationPath        = $OperationPath
        actionRequestPath    = if ($currentAction) { $currentAction.path } else { $null }
        actionRequestSha256  = if ($currentAction) { $currentAction.sha256 } else { $null }
        actionId             = if ($currentAction) { $currentAction.actionId } else { $null }
        actionKind           = if ($currentAction) { $currentAction.kind } else { $null }
        nextUserAction       = switch ([string]$Operation.status) {
            'WAITING_FOR_RUNNER' { 'Run the immutable action with the existing unique persistent Codex session, then submit its evidence JSON.' }
            'WAITING_FOR_EXPORT_2' { 'Run one normal Control plus Studio export, process its Stage1 audit, then bind that new audit report to this operation.' }
            'WAITING_FOR_CPSTUDIO' { 'Correct the CpStudio-owned model/interface in CpStudio and begin a new export operation.' }
            'DONE' { 'No further engineering action is required for this export batch.' }
            'BLOCKED' { 'Review the recorded blocker; do not bypass ownership or offline guardrails.' }
            'FAILED' { 'Review the recorded failure; mutation actions are not replayed automatically.' }
            default { 'Review the operation record.' }
        }
    }
}

function Convert-OperationToMarkdown {
    param([Parameter(Mandatory = $true)][object]$Operation)

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.AppendLine('# CpStudio post-export engineering operation')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- Operation: ``$($Operation.operationId)``")
    $null = $builder.AppendLine("- Status: **$($Operation.status)**")
    $null = $builder.AppendLine("- Outcome: **$($Operation.outcome)**")
    $null = $builder.AppendLine("- Revision: $($Operation.revision)")
    $null = $builder.AppendLine("- PLC project: ``$($Operation.identity.plcProject)``")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Safety boundary')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('- The coordinator does not start PLE, MCP or REST and does not write the Station project.')
    $null = $builder.AppendLine('- Runner actions require the already active unique persistent session and offline-only evidence.')
    $null = $builder.AppendLine('- CpStudio-owned interfaces and OES Declaration merge areas are never emitted as AI writes.')
    $null = $builder.AppendLine('- Warning acceptance is based on reviewed signatures, not a warning count alone.')
    $null = $builder.AppendLine()
    if ($Operation.currentAction) {
        $null = $builder.AppendLine('## Current immutable action')
        $null = $builder.AppendLine()
        $null = $builder.AppendLine("- Kind: ``$($Operation.currentAction.kind)``")
        $null = $builder.AppendLine("- Request: ``$($Operation.currentAction.path)``")
        $null = $builder.AppendLine("- SHA-256: ``$($Operation.currentAction.sha256)``")
        $null = $builder.AppendLine()
    }
    if ($Operation.status -eq 'WAITING_FOR_EXPORT_2') {
        $null = $builder.AppendLine('## User action')
        $null = $builder.AppendLine()
        $null = $builder.AppendLine('Run one normal Control plus Studio export. Do not access Symbol Configuration concurrently. Then run the Stage1 audit and bind its JSON report to this operation.')
        $null = $builder.AppendLine()
    }
    if ($Operation.failure) {
        $null = $builder.AppendLine('## Blocker/failure')
        $null = $builder.AppendLine()
        $null = $builder.AppendLine("- Code: ``$($Operation.failure.code)``")
        $null = $builder.AppendLine("- Message: $($Operation.failure.message)")
        $null = $builder.AppendLine()
    }
    return $builder.ToString()
}

function New-FinalRecord {
    param([Parameter(Mandatory = $true)][object]$Operation)

    return [ordered]@{
        schemaVersion  = 1
        operationId    = $Operation.operationId
        status         = $Operation.status
        outcome        = $Operation.outcome
        completedAtUtc = $Operation.updatedAtUtc
        evidence       = $Operation.evidence
        failure        = $Operation.failure
        guardrails     = $Operation.guardrails
    }
}

function Save-Operation {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$OperationDirectory
    )

    $operationPath = Join-Path $OperationDirectory 'operation.json'
    Write-AtomicJson -Path $operationPath -Value $Operation
    Write-AtomicText -Path (Join-Path $OperationDirectory 'summary.md') -Text (Convert-OperationToMarkdown -Operation $Operation)

    if (@('DONE', 'BLOCKED', 'FAILED') -contains [string]$Operation.status) {
        $final = New-FinalRecord -Operation $Operation
        $null = Write-ImmutableJson -Path (Join-Path $OperationDirectory 'final.json') -Value $final
    }
    return $operationPath
}

function Repair-DerivedOperationArtifacts {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$OperationDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedOperationId,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile
    )

    if ($WhatIfPreference) {
        return
    }
    $allowedStates = @('WAITING_FOR_RUNNER', 'WAITING_FOR_CPSTUDIO', 'WAITING_FOR_EXPORT_2', 'DONE', 'BLOCKED', 'FAILED')
    if (([int](Get-PropertyValue -Object $Operation -Name 'schemaVersion' -DefaultValue 0) -ne 1) -or
        ([string]$Operation.kind -ne $operationKind) -or
        ([string]$Operation.workflowRevision -ne $workflowRevision) -or
        ([string]$Operation.operationId -ne $ExpectedOperationId) -or
        ([string]$Operation.identity.profile -ne $ExpectedProfile) -or
        ($allowedStates -notcontains [string]$Operation.status) -or
        (-not (Get-BooleanValue -Object $Operation.guardrails -Name 'offlineOnly' -Required -Context 'Operation guardrails')) -or
        (Get-BooleanValue -Object $Operation.guardrails -Name 'onlineOperationsUsed' -Required -Context 'Operation guardrails') -or
        (Get-BooleanValue -Object $Operation.guardrails -Name 'coordinatorStartsPleMcp' -Required -Context 'Operation guardrails') -or
        (Get-BooleanValue -Object $Operation.guardrails -Name 'coordinatorCallsRest' -Required -Context 'Operation guardrails')) {
        throw 'Operation core identity is invalid; derived safety artifacts were not changed.'
    }
    $history = @($Operation.history)
    if (($history.Count -eq 0) -or ([string]$history[$history.Count - 1].to -ne [string]$Operation.status)) {
        throw 'Operation history is invalid; derived safety artifacts were not changed.'
    }
    $sentinelPath = Join-Path $OperationDirectory 'export-window.active.json'
    if ([string]$Operation.status -eq 'WAITING_FOR_EXPORT_2') {
        if (-not [System.IO.File]::Exists($sentinelPath)) {
            $sentinel = [ordered]@{
                schemaVersion        = 1
                operationId          = $Operation.operationId
                active               = $true
                createdAtUtc         = $Operation.export2.waitingSinceUtc
                symbolAccessPolicy   = 'DENY'
                projectLeaseReleased = $true
                reason               = 'Waiting for a human Control plus Studio Export #2.'
            }
            $null = Write-ImmutableJson -Path $sentinelPath -Value $sentinel
        }
    }
    elseif ([System.IO.File]::Exists($sentinelPath)) {
        # The sentinel is a derived gate. A durable non-waiting operation is
        # authoritative after a crash between operation save and sentinel cleanup.
        [System.IO.File]::Delete($sentinelPath)
    }

    if (@('DONE', 'BLOCKED', 'FAILED') -contains [string]$Operation.status) {
        $finalPath = Join-Path $OperationDirectory 'final.json'
        if (-not [System.IO.File]::Exists($finalPath)) {
            $final = New-FinalRecord -Operation $Operation
            $null = Write-ImmutableJson -Path $finalPath -Value $final
        }
    }
}

function Add-HistoryEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$AtUtc,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To,
        [Parameter(Mandatory = $false)][string]$ActionIdValue,
        [Parameter(Mandatory = $false)][string]$Detail
    )

    $entry = [ordered]@{
        atUtc    = $AtUtc
        event    = $Event
        from     = $From
        to       = $To
        actionId = $ActionIdValue
        detail   = $Detail
    }
    $Operation.history = @($Operation.history) + @($entry)
}

function Set-OperationStatus {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [Parameter(Mandatory = $true)][string]$AtUtc,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $false)][string]$ActionIdValue,
        [Parameter(Mandatory = $false)][string]$Detail
    )

    $from = [string]$Operation.status
    $Operation.status = $Status
    $Operation.outcome = $Outcome
    $Operation.updatedAtUtc = $AtUtc
    $Operation.revision = [int]$Operation.revision + 1
    Add-HistoryEntry -Operation $Operation -AtUtc $AtUtc -Event $Event -From $from -To $Status -ActionIdValue $ActionIdValue -Detail $Detail
}

function ConvertFrom-InlineYamlList {
    param([Parameter(Mandatory = $false)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    $trimmed = $Value.Trim()
    if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
        $trimmed = $trimmed.Substring(1, $trimmed.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return @()
    }
    return @($trimmed.Split(',') | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })
}

function Get-OwnershipProjection {
    param([Parameter(Mandatory = $true)][string]$Path)

    $records = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*-\s+path:\s*(?<value>.+?)\s*$') {
            if ($null -ne $current) {
                $records.Add([pscustomobject]$current)
            }
            $current = [ordered]@{ path = $Matches['value'].Trim().Trim('"').Trim("'") }
            continue
        }
        if (($null -ne $current) -and
            ($line -match '^\s+(?<key>owner|source|write_mode|hook_ids|interface_owner|interface_write|apply_status):\s*(?<value>.+?)\s*$')) {
            $current[$Matches['key']] = $Matches['value'].Trim().Trim('"').Trim("'")
        }
    }
    if ($null -ne $current) {
        $records.Add([pscustomobject]$current)
    }
    return $records.ToArray()
}

function Get-HookProjection {
    param([Parameter(Mandatory = $true)][string]$Path)

    $records = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*-\s+id:\s*(?<value>.+?)\s*$') {
            if ($null -ne $current) {
                $records.Add([pscustomobject]$current)
            }
            $current = [ordered]@{ id = $Matches['value'].Trim().Trim('"').Trim("'") }
            continue
        }
        if (($null -ne $current) -and ($line -match '^\s+object:\s*(?<value>.+?)\s*$')) {
            $current.object = $Matches['value'].Trim().Trim('"').Trim("'")
        }
    }
    if ($null -ne $current) {
        $records.Add([pscustomobject]$current)
    }
    return $records.ToArray()
}

function Assert-ProposedChangesSafe {
    param(
        [Parameter(Mandatory = $true)][object[]]$Changes,
        [Parameter(Mandatory = $true)][string]$EngineeringRoot
    )

    if (@($Changes).Count -eq 0) {
        throw 'repairRequired=true requires at least one proposedChanges entry.'
    }
    $ownershipPath = Join-Path $EngineeringRoot 'ai\ownership.yaml'
    $hooksPath = Join-Path $EngineeringRoot 'ai\hooks.yaml'
    $ownershipRecords = @(Get-OwnershipProjection -Path $ownershipPath)
    $hookRecords = @(Get-HookProjection -Path $hooksPath)
    $ids = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($change in @($Changes)) {
        $authorization = Get-RequiredString -Object $change -Name 'authorization' -Context 'Proposed change'
        if (@('ai_owned', 'mixed_declared_hook') -notcontains $authorization) {
            throw "Unsafe proposed change authorization: $authorization"
        }
        if (Get-BooleanValue -Object $change -Name 'interfaceWrite' -Required -Context 'Proposed change') {
            throw 'CpStudio-owned POU interfaces and OES Declaration merge areas cannot be written by Stage2.'
        }
        if (-not (Get-BooleanValue -Object $change -Name 'requiresReadback' -Required -Context 'Proposed change')) {
            throw 'Every proposed change must require exact readback.'
        }
        $targetPath = Get-RequiredString -Object $change -Name 'targetPath' -Context 'Proposed change'
        $writeMode = Get-RequiredString -Object $change -Name 'writeMode' -Context 'Proposed change'

        $matchingOwnership = @($ownershipRecords | Where-Object { [string]$_.path -eq $targetPath })
        if ($matchingOwnership.Count -ne 1) {
            throw "Proposed change target is not uniquely declared in ai/ownership.yaml: $targetPath"
        }
        $ownership = $matchingOwnership[0]
        if (([string]$ownership.apply_status).StartsWith('blocked_', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Proposed change target is blocked by ai/ownership.yaml: $targetPath"
        }
        if (([string]$ownership.interface_write).Equals('forbidden', [System.StringComparison]::OrdinalIgnoreCase) -or
            ([string]$ownership.interface_owner).Equals('cpstudio', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Proposed change target contains a CpStudio-owned interface: $targetPath"
        }
        if ([string]$ownership.write_mode -ne $writeMode) {
            throw "Proposed change writeMode does not match ai/ownership.yaml for '$targetPath'."
        }

        if ($authorization -eq 'mixed_declared_hook') {
            if (([string]$ownership.owner -ne 'mixed') -or ($writeMode -ne 'semantic_merge')) {
                throw "Mixed object '$targetPath' must use semantic_merge."
            }
            $requestedHookIds = @(@(Get-PropertyValue -Object $change -Name 'hookIds' -DefaultValue @()) | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            $ownedHookIds = @(ConvertFrom-InlineYamlList -Value ([string]$ownership.hook_ids) | Sort-Object -Unique)
            if ($requestedHookIds.Count -eq 0) {
                throw "Mixed object '$targetPath' has no declared hookIds."
            }
            if (($requestedHookIds.Count -ne $ownedHookIds.Count) -or
                (($requestedHookIds -join '|') -ne ($ownedHookIds -join '|'))) {
                throw "Mixed object '$targetPath' hookIds do not match ai/ownership.yaml."
            }
            foreach ($hookId in $requestedHookIds) {
                $matchingHooks = @($hookRecords | Where-Object { ([string]$_.id -eq $hookId) -and ([string]$_.object -eq $targetPath) })
                if ($matchingHooks.Count -ne 1) {
                    throw "Hook '$hookId' is not uniquely declared for '$targetPath' in ai/hooks.yaml."
                }
            }
        }
        else {
            if (@('ai', 'ai_implementation') -notcontains [string]$ownership.owner) {
                throw "Proposed AI-owned authorization conflicts with ai/ownership.yaml for '$targetPath'."
            }
            if (@('full_object', 'implementation') -notcontains $writeMode) {
                throw "AI-owned object '$targetPath' has unsupported writeMode '$writeMode'."
            }
            if ([string]::IsNullOrWhiteSpace([string]$ownership.source)) {
                throw "AI-owned object '$targetPath' has no canonical source and cannot be emitted as an automatic repair."
            }
        }
        $before = Get-PropertyValue -Object $change -Name 'expectedBefore'
        $desired = Get-PropertyValue -Object $change -Name 'desired'
        if (-not (Test-HexSha256 -Value ([string](Get-PropertyValue -Object $before -Name 'sha256')))) {
            throw "Proposed change '$targetPath' has no valid expected-before SHA-256."
        }
        if (-not (Test-HexSha256 -Value ([string](Get-PropertyValue -Object $desired -Name 'sha256')))) {
            throw "Proposed change '$targetPath' has no valid desired SHA-256."
        }
        if ($authorization -eq 'ai_owned') {
            $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot (([string]$ownership.source).Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
            $null = Assert-PathInsideRoot -Root $EngineeringRoot -Path $sourcePath -Description 'Canonical AI source'
            if (-not [System.IO.File]::Exists($sourcePath)) {
                throw "Canonical AI source is missing for '$targetPath': $($ownership.source)"
            }
            $sourceSha = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
            if (-not $sourceSha.Equals([string](Get-PropertyValue -Object $desired -Name 'sha256'), [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Desired SHA-256 for '$targetPath' does not match its canonical source."
            }
        }
        $changeId = Get-RequiredString -Object $change -Name 'changeId' -Context 'Proposed change'
        if ($changeId -notmatch '^[A-Za-z0-9_.-]{1,128}$') {
            throw "Proposed change has an unsafe changeId: $changeId"
        }
        if (-not $ids.Add($changeId)) {
            throw "Duplicate proposed change id: $changeId"
        }
    }
}

function Assert-AppliedChangesMatchAction {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][bool]$RequireComplete,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Capabilities
    )

    $appliedChanges = @(Get-PropertyValue -Object $Result -Name 'appliedChanges' -DefaultValue @())
    if ([string]$Operation.currentAction.kind -ne 'apply_change_set_and_build') {
        if ($appliedChanges.Count -ne 0) {
            throw 'Non-apply evidence cannot contain appliedChanges.'
        }
        return
    }

    $requestedChanges = @((Read-JsonDocument -Path ([string]$Operation.currentAction.path) -Description 'Runner action').payload.changeSet)
    if ($RequireComplete -and ($requestedChanges.Count -ne $appliedChanges.Count)) {
        throw 'Successful repair evidence must contain one readback result per requested change.'
    }
    if ($appliedChanges.Count -gt $requestedChanges.Count) {
        throw 'Repair evidence contains more applied results than requested changes.'
    }

    $seenAppliedIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    foreach ($applied in $appliedChanges) {
        $changeId = Get-RequiredString -Object $applied -Name 'changeId' -Context 'Applied change'
        if (-not $seenAppliedIds.Add($changeId)) {
            throw "Repair evidence contains duplicate change '$changeId'."
        }
        $matches = @($requestedChanges | Where-Object { [string]$_.changeId -eq $changeId })
        if ($matches.Count -ne 1) {
            throw "Repair evidence does not uniquely identify requested change '$changeId'."
        }
        $requested = $matches[0]
        if ((Get-RequiredString -Object $applied -Name 'status' -Context 'Applied change') -ne 'applied') {
            throw "Repair evidence did not apply change '$changeId'."
        }
        if ((Get-RequiredString -Object $applied -Name 'targetPath' -Context 'Applied change') -ne [string]$requested.targetPath) {
            throw "Repair evidence read back the wrong target for change '$changeId'."
        }
        $expectedBefore = Get-RequiredString -Object $requested.expectedBefore -Name 'sha256' -Context "Requested change '$changeId' expectedBefore"
        $desired = Get-RequiredString -Object $requested.desired -Name 'sha256' -Context "Requested change '$changeId' desired"
        foreach ($name in @('expectedBeforeSha256', 'observedBeforeSha256', 'desiredSha256', 'readbackSha256')) {
            $reportedSha = Get-RequiredString -Object $applied -Name $name -Context "Applied change '$changeId'"
            if (-not (Test-HexSha256 -Value $reportedSha)) {
                throw "Repair evidence contains an invalid $name for change '$changeId'."
            }
        }
        if ((-not ([string]$applied.expectedBeforeSha256).Equals($expectedBefore, [System.StringComparison]::OrdinalIgnoreCase)) -or
            (-not ([string]$applied.observedBeforeSha256).Equals($expectedBefore, [System.StringComparison]::OrdinalIgnoreCase)) -or
            (-not ([string]$applied.desiredSha256).Equals($desired, [System.StringComparison]::OrdinalIgnoreCase)) -or
            (-not ([string]$applied.readbackSha256).Equals($desired, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Repair evidence hash/readback mismatch for change '$changeId'."
        }
    }

    if ((-not $RequireComplete) -and ($appliedChanges.Count -ne 0)) {
        if ((@($Capabilities | Where-Object { [string]$_ -eq 'set_pou_code' }).Count -lt 1) -or
            (@($Capabilities | Where-Object { [string]$_ -match '^(get_all_pou_code|search_code|find_references)$' }).Count -lt 1)) {
            throw 'Terminal repair evidence with applied changes must report write and readback capabilities.'
        }
    }
}

function Read-AndValidateEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Operation
    )

    $producerEvidenceRoot = Join-Path ([string]$Operation.identity.engineeringRoot) 'data\runner-evidence'
    $resolvedEvidencePath = Assert-PathInsideRoot -Root $producerEvidenceRoot -Path $Path -Description 'Producer runner evidence'
    $document = Read-JsonDocument -Path $resolvedEvidencePath -Description 'Runner evidence'
    $evidence = $document.payload
    Assert-NoSensitiveEvidence -Value $evidence
    Assert-NoOnlineCapabilities -Evidence $evidence -RawJson $document.raw
    $capabilities = @((Get-PropertyValue -Object $evidence -Name 'capabilitiesInvoked'))

    if ([int](Get-PropertyValue -Object $evidence -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
        throw 'Runner evidence schemaVersion must be 1.'
    }
    if ((Get-RequiredString -Object $evidence -Name 'operationId' -Context 'Runner evidence') -ne $Operation.operationId) {
        throw 'Runner evidence operationId does not match the operation.'
    }
    $actionIdValue = Get-RequiredString -Object $evidence -Name 'actionId' -Context 'Runner evidence'
    if ($null -eq $Operation.currentAction) {
        throw 'The operation has no pending runner action.'
    }
    if ($actionIdValue -ne $Operation.currentAction.actionId) {
        throw "Runner evidence actionId does not match current action '$($Operation.currentAction.actionId)'."
    }
    if ((Get-RequiredString -Object $evidence -Name 'actionKind' -Context 'Runner evidence') -ne [string]$Operation.currentAction.kind) {
        throw 'Runner evidence actionKind does not match the current action.'
    }
    if (-not [System.IO.File]::Exists([string]$Operation.currentAction.path)) {
        throw 'The immutable runner action file is missing.'
    }
    $currentActionSha = (Get-FileHash -LiteralPath ([string]$Operation.currentAction.path) -Algorithm SHA256).Hash
    if (-not $currentActionSha.Equals([string]$Operation.currentAction.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The immutable runner action file no longer matches the operation ledger.'
    }
    $actionSha = Get-RequiredString -Object $evidence -Name 'actionRequestSha256' -Context 'Runner evidence'
    if (-not $actionSha.Equals([string]$Operation.currentAction.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runner evidence actionRequestSha256 does not match the immutable action request.'
    }

    $evidenceProject = Get-PropertyValue -Object $evidence -Name 'project'
    if ($null -eq $evidenceProject) {
        throw 'Runner evidence has no project identity.'
    }
    Assert-ExactPropertySet -Object $evidenceProject -ExpectedNames @('engineeringRoot', 'stationRoot', 'plcProject', 'profile') -Context 'Runner evidence project'
    Assert-SamePath -Expected $Operation.identity.engineeringRoot -Actual (Get-RequiredString -Object $evidenceProject -Name 'engineeringRoot' -Context 'Runner evidence project') -Description 'Evidence engineering root'
    Assert-SamePath -Expected $Operation.identity.stationRoot -Actual (Get-RequiredString -Object $evidenceProject -Name 'stationRoot' -Context 'Runner evidence project') -Description 'Evidence Station root'
    Assert-SamePath -Expected $Operation.identity.plcProject -Actual (Get-RequiredString -Object $evidenceProject -Name 'plcProject' -Context 'Runner evidence project') -Description 'Evidence PLC project'
    if ((Get-RequiredString -Object $evidenceProject -Name 'profile' -Context 'Runner evidence project') -ne [string]$Operation.identity.profile) {
        throw 'Runner evidence profile does not match the configured PLE profile.'
    }

    $guardrails = Get-PropertyValue -Object $evidence -Name 'guardrails'
    if ($null -eq $guardrails) {
        throw 'Runner evidence has no guardrails object.'
    }
    Assert-ExactPropertySet -Object $guardrails -ExpectedNames @(
        'onlineOperationsUsed',
        'secondPleStarted',
        'projectLeaseAcquired',
        'projectLeaseReleased',
        'projectLeaseScope',
        'symbolLeaseHeld',
        'pleOrMcpStarted',
        'directWatcherIpcUsed'
    ) -Context 'Runner evidence guardrails'
    if (Get-BooleanValue -Object $guardrails -Name 'onlineOperationsUsed' -Required -Context 'Runner evidence guardrails') {
        throw 'Runner evidence reports onlineOperationsUsed=true.'
    }
    if (Get-BooleanValue -Object $guardrails -Name 'secondPleStarted' -Required -Context 'Runner evidence guardrails') {
        throw 'Runner evidence reports that a second PLE was started.'
    }
    $projectLeaseAcquired = Get-BooleanValue -Object $guardrails -Name 'projectLeaseAcquired' -Required -Context 'Runner evidence guardrails'
    if (-not (Get-BooleanValue -Object $guardrails -Name 'projectLeaseReleased' -Required -Context 'Runner evidence guardrails')) {
        throw 'Runner evidence must prove that the project lease was released.'
    }
    if ((Get-RequiredString -Object $guardrails -Name 'projectLeaseScope' -Context 'Runner evidence guardrails') -ne 'workflow-local') {
        throw 'Runner evidence projectLeaseScope must be workflow-local.'
    }
    if (Get-BooleanValue -Object $guardrails -Name 'symbolLeaseHeld' -Required -Context 'Runner evidence guardrails') {
        throw 'Runner evidence still holds the Symbol lease.'
    }
    if (Get-BooleanValue -Object $guardrails -Name 'pleOrMcpStarted' -Required -Context 'Runner evidence guardrails') {
        throw 'Runner evidence reports that PLE or MCP was started by the runner.'
    }
    if (Get-BooleanValue -Object $guardrails -Name 'directWatcherIpcUsed' -Required -Context 'Runner evidence guardrails') {
        throw 'Runner evidence reports direct watcher IPC use.'
    }

    $result = Get-PropertyValue -Object $evidence -Name 'result'
    if ($null -eq $result) {
        throw 'Runner evidence has no result object.'
    }
    $resultStatus = Get-RequiredString -Object $result -Name 'status' -Context 'Runner result'
    if (@('succeeded', 'blocked', 'failed') -notcontains $resultStatus) {
        throw "Unsupported runner result status: $resultStatus"
    }
    $terminalRunnerResult = @('blocked', 'failed') -contains $resultStatus
    Assert-JsonArrayProperty -RawJson $document.raw -PropertyPath @('result', 'proposedChanges') -Context 'Runner evidence'
    Assert-JsonArrayProperty -RawJson $document.raw -PropertyPath @('result', 'appliedChanges') -Context 'Runner evidence'
    $expectedTopLevelProperties = @(
        'schemaVersion',
        'operationId',
        'actionId',
        'actionKind',
        'actionRequestSha256',
        'completedAtUtc',
        'project',
        'capabilitiesInvoked',
        'guardrails',
        'result'
    )
    $expectedResultProperties = @(
        'status',
        'verificationOk',
        'appliedReadbackOk',
        'repairRequired',
        'requiresSecondExport',
        'requiresCpStudioChange',
        'proposedChanges',
        'appliedChanges'
    )
    if ($terminalRunnerResult) {
        $expectedResultProperties += @('failureStage', 'reasonCode')
    }
    else {
        $expectedTopLevelProperties += 'session'
        $expectedResultProperties += @('build', 'acceptance')
    }
    Assert-ExactPropertySet -Object $evidence -ExpectedNames $expectedTopLevelProperties -Context 'Runner evidence'
    Assert-ExactPropertySet -Object $result -ExpectedNames $expectedResultProperties -Context 'Runner result'
    foreach ($name in @('verificationOk', 'appliedReadbackOk', 'repairRequired', 'requiresSecondExport', 'requiresCpStudioChange')) {
        $null = Get-BooleanValue -Object $result -Name $name -Required -Context 'Runner result'
    }
    if ($terminalRunnerResult) {
        if ($null -ne $evidence.PSObject.Properties['session']) {
            throw 'Blocked/failed producer evidence must not contain a session object.'
        }
        foreach ($name in @('build', 'acceptance')) {
            if ($null -ne $result.PSObject.Properties[$name]) {
                throw "Blocked/failed producer evidence must not contain result.$name."
            }
        }
        foreach ($name in @('repairRequired', 'requiresSecondExport', 'requiresCpStudioChange')) {
            if (Get-BooleanValue -Object $result -Name $name -Required -Context 'Runner result') {
                throw "Blocked/failed producer evidence requires result.$name=false."
            }
        }
        $failureStage = Get-RequiredString -Object $result -Name 'failureStage' -Context 'Runner result'
        $reasonCode = Get-RequiredString -Object $result -Name 'reasonCode' -Context 'Runner result'
        if (($failureStage -notmatch '^[A-Za-z0-9_.-]{1,64}$') -or
            ($reasonCode -notmatch '^[A-Za-z0-9_.-]{1,96}$')) {
            throw 'Blocked/failed producer evidence has an unsafe failure stage or reason code.'
        }
        if (@(Get-PropertyValue -Object $result -Name 'proposedChanges' -DefaultValue @()).Count -ne 0) {
            throw 'Blocked/failed producer evidence must not contain proposed changes.'
        }
    }
    Assert-AppliedChangesMatchAction `
        -Result $result `
        -Operation $Operation `
        -RequireComplete ($resultStatus -eq 'succeeded') `
        -Capabilities $capabilities
    if (([string]$Operation.currentAction.kind -ne 'apply_change_set_and_build') -and
        (@($capabilities | Where-Object { [string]$_ -eq 'set_pou_code' }).Count -ne 0)) {
        throw 'Inspect and verify evidence cannot report project write capabilities.'
    }
    if ($resultStatus -eq 'succeeded') {
        if (-not $projectLeaseAcquired) {
            throw 'Successful runner evidence must prove that the workflow-local project lease was acquired.'
        }

        $requiredCapabilities = @('get_codesys_status', 'compile_project', 'get_compile_messages')
        foreach ($requiredCapability in $requiredCapabilities) {
            if (@($capabilities | Where-Object { [string]$_ -eq $requiredCapability }).Count -ne 1) {
                throw "Successful runner evidence must report capability '$requiredCapability' exactly once."
            }
        }
        if ([string]$Operation.currentAction.kind -eq 'apply_change_set_and_build') {
            $writeCapabilities = @($capabilities | Where-Object {
                [string]$_ -eq 'set_pou_code'
            })
            $readbackCapabilities = @($capabilities | Where-Object {
                [string]$_ -match '^(get_all_pou_code|search_code|find_references)$'
            })
            if (($writeCapabilities.Count -lt 1) -or ($readbackCapabilities.Count -lt 1)) {
                throw 'Successful apply evidence must report an approved write capability and an approved readback capability.'
            }
        }

        $session = Get-PropertyValue -Object $evidence -Name 'session'
        if ($null -eq $session) {
            throw 'Successful runner evidence has no producer-validated persistent session identity.'
        }
        Assert-ExactPropertySet -Object $session -ExpectedNames @('state', 'mode', 'sessionId', 'plePid', 'profile', 'activeProjectPath', 'startedByRunner') -Context 'Runner evidence session'

        $successBuild = Get-PropertyValue -Object $result -Name 'build'
        Assert-JsonArrayProperty -RawJson $document.raw -PropertyPath @('result', 'build', 'warningSignatures') -Context 'Runner evidence'
        Assert-ExactPropertySet -Object $successBuild -ExpectedNames @(
            'buildId',
            'projectPath',
            'profile',
            'projectSha256',
            'startedAtUtc',
            'completedAtUtc',
            'verified',
            'errors',
            'warnings',
            'signatureComplete',
            'signatureAlgorithm',
            'summarySource',
            'warningSignatures'
        ) -Context 'Runner evidence build'
        $successAcceptance = Get-PropertyValue -Object $result -Name 'acceptance'
        Assert-ExactPropertySet -Object $successAcceptance -ExpectedNames @(
            'ownershipVerified',
            'mappingConsistent',
            'readbackVerified',
            'recoverableBaselineVerified',
            'warningSignaturesReviewed',
            'existingSessionReused',
            'pleOrMcpStarted',
            'directWatcherIpcUsed',
            'symbolPostProcessingVerified'
        ) -Context 'Runner evidence acceptance'
        if ((Get-RequiredString -Object $session -Name 'state' -Context 'Runner evidence session') -ne 'ready') {
            throw 'Runner evidence session state must be ready.'
        }
        if ((Get-RequiredString -Object $session -Name 'mode' -Context 'Runner evidence session') -ne 'persistent') {
            throw 'Runner evidence session mode must be persistent.'
        }
        $sessionId = Get-RequiredString -Object $session -Name 'sessionId' -Context 'Runner evidence session'
        if ($sessionId -notmatch '^[A-Za-z0-9_.-]{1,128}$') {
            throw 'Runner evidence sessionId is invalid.'
        }
        $sessionPid = 0
        if ((-not [int]::TryParse([string](Get-PropertyValue -Object $session -Name 'plePid'), [ref]$sessionPid)) -or
            ($sessionPid -le 0)) {
            throw 'Runner evidence session plePid must be a positive producer-validated process identifier.'
        }
        if ((Get-RequiredString -Object $session -Name 'profile' -Context 'Runner evidence session') -ne [string]$Operation.identity.profile) {
            throw 'Runner evidence session profile does not match the configured PLE profile.'
        }
        Assert-SamePath `
            -Expected ([string]$Operation.identity.plcProject) `
            -Actual (Get-RequiredString -Object $session -Name 'activeProjectPath' -Context 'Runner evidence session') `
            -Description 'Runner evidence session active project'
        if (Get-BooleanValue -Object $session -Name 'startedByRunner' -Required -Context 'Runner evidence session') {
            throw 'Runner evidence reports that the persistent session was started by the runner.'
        }
    }
    $completedAtText = Get-RequiredString -Object $evidence -Name 'completedAtUtc' -Context 'Runner evidence'
    $completedAt = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($completedAtText, [ref]$completedAt)) {
        throw "Runner completedAtUtc is invalid: $completedAtText"
    }
    $actionCreatedAt = [DateTime]::MinValue
    if ((-not [DateTime]::TryParse([string]$Operation.currentAction.createdAtUtc, [ref]$actionCreatedAt)) -or
        ($completedAt.ToUniversalTime() -lt $actionCreatedAt.ToUniversalTime()) -or
        ($completedAt.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5))) {
        throw 'Runner evidence completedAtUtc is inconsistent with the immutable action request or is unreasonably far in the future.'
    }

    return [pscustomobject]@{
        document       = $document
        evidence       = $evidence
        result         = $result
        resultStatus   = $resultStatus
        actionId       = $actionIdValue
        completedAtUtc = $completedAt.ToUniversalTime().ToString('o')
    }
}

function Assert-BuildEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$EvidenceCompletedAtUtc,
        [Parameter(Mandatory = $false)][switch]$AllowErrors
    )

    $build = Get-PropertyValue -Object $Result -Name 'build'
    if ($null -eq $build) {
        throw 'Runner result has no fresh Build evidence.'
    }
    $buildId = Get-RequiredString -Object $build -Name 'buildId' -Context 'Build evidence'
    if ($buildId -notmatch '^[A-Za-z0-9_.:-]{1,128}$') {
        throw 'Build evidence buildId is invalid.'
    }
    if ((Get-RequiredString -Object $build -Name 'summarySource' -Context 'Build evidence') -ne 'codesys-persistent.compile_project') {
        throw 'Build evidence summarySource must be codesys-persistent.compile_project.'
    }
    Assert-SamePath -Expected ([string]$Operation.identity.plcProject) -Actual (Get-RequiredString -Object $build -Name 'projectPath' -Context 'Build evidence') -Description 'Build PLC project'
    if ((Get-RequiredString -Object $build -Name 'profile' -Context 'Build evidence') -ne [string]$Operation.identity.profile) {
        throw 'Build evidence profile does not match the configured PLE profile.'
    }
    $reportedProjectSha = [string](Get-PropertyValue -Object $build -Name 'projectSha256')
    if (-not (Test-HexSha256 -Value $reportedProjectSha)) {
        throw 'Build evidence has no valid PLC project SHA-256.'
    }
    if (-not [System.IO.File]::Exists([string]$Operation.identity.plcProject)) {
        throw 'The configured PLC project disappeared before Build evidence was accepted.'
    }
    $actualProjectSha = (Get-FileHash -LiteralPath ([string]$Operation.identity.plcProject) -Algorithm SHA256).Hash
    if (-not $actualProjectSha.Equals($reportedProjectSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Build evidence PLC project SHA-256 does not match the current project file.'
    }
    $buildStarted = [DateTime]::MinValue
    $buildCompleted = [DateTime]::MinValue
    $actionCreated = [DateTime]::MinValue
    $evidenceCompleted = [DateTime]::MinValue
    if ((-not [DateTime]::TryParse((Get-RequiredString -Object $build -Name 'startedAtUtc' -Context 'Build evidence'), [ref]$buildStarted)) -or
        (-not [DateTime]::TryParse((Get-RequiredString -Object $build -Name 'completedAtUtc' -Context 'Build evidence'), [ref]$buildCompleted)) -or
        (-not [DateTime]::TryParse([string]$Operation.currentAction.createdAtUtc, [ref]$actionCreated)) -or
        (-not [DateTime]::TryParse($EvidenceCompletedAtUtc, [ref]$evidenceCompleted)) -or
        ($buildStarted.ToUniversalTime() -lt $actionCreated.ToUniversalTime()) -or
        ($buildCompleted.ToUniversalTime() -lt $buildStarted.ToUniversalTime()) -or
        ($buildCompleted.ToUniversalTime() -gt $evidenceCompleted.ToUniversalTime())) {
        throw 'Build evidence is not a fresh Build for the current immutable action.'
    }
    $verified = Get-BooleanValue -Object $build -Name 'verified' -Required -Context 'Build evidence'
    $errors = [int](Get-PropertyValue -Object $build -Name 'errors' -DefaultValue -1)
    $warnings = [int](Get-PropertyValue -Object $build -Name 'warnings' -DefaultValue -1)
    if ($errors -lt 0) {
        throw 'Build evidence has no valid errors count.'
    }
    if ($warnings -lt 0) {
        throw 'Build evidence has no valid warnings count.'
    }
    if ((-not $AllowErrors) -and (($errors -ne 0) -or (-not $verified))) {
        throw "Final Build evidence is not clean: errors=$errors, verified=$verified."
    }
    if (-not (Get-BooleanValue -Object $build -Name 'signatureComplete' -Required -Context 'Build evidence')) {
        throw 'Build evidence must include a complete warning-signature set.'
    }
    if ((Get-RequiredString -Object $build -Name 'signatureAlgorithm' -Context 'Build evidence') -ne 'sha256:v1:normalized-warning-record') {
        throw 'Build warning signatureAlgorithm is unsupported.'
    }
    $signatureOccurrences = 0
    $signatures = @(Get-PropertyValue -Object $build -Name 'warningSignatures' -DefaultValue @())
    $seenSignatureShas = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($signature in $signatures) {
        Assert-ExactPropertySet -Object $signature -ExpectedNames @('sha256', 'occurrences') -Context 'Build warning signature'
        $signatureSha = [string](Get-PropertyValue -Object $signature -Name 'sha256')
        $occurrences = [int](Get-PropertyValue -Object $signature -Name 'occurrences' -DefaultValue 0)
        if (-not (Test-HexSha256 -Value $signatureSha)) {
            throw 'Build warning evidence contains an invalid signature SHA-256.'
        }
        if (-not $seenSignatureShas.Add($signatureSha)) {
            throw 'Build warning evidence contains a duplicate signature SHA-256.'
        }
        if ($occurrences -lt 1) {
            throw 'Build warning signature occurrences must be at least 1.'
        }
        $signatureOccurrences += $occurrences
    }
    if ($signatureOccurrences -ne $warnings) {
        throw "Build warning signature multiset does not match warnings=$warnings."
    }
    return [pscustomobject]@{
        build    = $build
        errors   = $errors
        verified = $verified
    }
}

function Assert-StructuredAcceptance {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][bool]$RequiresSecondExport,
        [Parameter(Mandatory = $true)][bool]$RequiresCpStudioChange
    )

    $acceptance = Get-PropertyValue -Object $Result -Name 'acceptance'
    if ($null -eq $acceptance) {
        throw 'Runner result has no structured acceptance object.'
    }
    foreach ($name in @('ownershipVerified', 'mappingConsistent', 'readbackVerified', 'recoverableBaselineVerified', 'warningSignaturesReviewed', 'existingSessionReused')) {
        if (-not (Get-BooleanValue -Object $acceptance -Name $name -Required -Context 'Runner acceptance')) {
            throw "Runner acceptance did not prove '$name'."
        }
    }
    foreach ($name in @('pleOrMcpStarted', 'directWatcherIpcUsed')) {
        if (Get-BooleanValue -Object $acceptance -Name $name -Required -Context 'Runner acceptance') {
            throw "Runner acceptance reports prohibited behavior '$name'."
        }
    }
    $symbolVerified = Get-BooleanValue -Object $acceptance -Name 'symbolPostProcessingVerified' -Required -Context 'Runner acceptance'
    if ((-not $RequiresSecondExport) -and (-not $RequiresCpStudioChange) -and (-not $symbolVerified)) {
        throw 'Final acceptance did not prove Symbol post-processing.'
    }

}

function Add-EvidenceReference {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][object]$ValidatedEvidence,
        [Parameter(Mandatory = $true)][string]$StoredPath,
        [Parameter(Mandatory = $true)][string]$StoredSha256,
        [Parameter(Mandatory = $true)][string]$SourceSha256
    )

    $reference = [ordered]@{
        actionId      = $ValidatedEvidence.actionId
        actionKind    = $Operation.currentAction.kind
        sequence      = [int]$Operation.currentAction.sequence
        path          = $StoredPath
        sha256        = $StoredSha256
        sourceSha256  = $SourceSha256
        completedAtUtc = $ValidatedEvidence.completedAtUtc
        resultStatus  = $ValidatedEvidence.resultStatus
    }
    $Operation.evidence = @($Operation.evidence) + @($reference)
}

function Set-OperationBlocked {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$AtUtc,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$ActionIdValue
    )

    $Operation.currentAction = $null
    $Operation.failure = [ordered]@{ code = $Code; message = $Message; atUtc = $AtUtc }
    $Operation.coordination.projectLeaseReleased = $true
    $Operation.coordination.symbolLeaseHeld = $false
    Set-OperationStatus -Operation $Operation -Status 'BLOCKED' -Outcome 'NEEDS_REVIEW' -AtUtc $AtUtc -Event 'blocked' -ActionIdValue $ActionIdValue -Detail $Message
}

function Set-OperationFailed {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$AtUtc,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$ActionIdValue
    )

    $Operation.currentAction = $null
    $Operation.failure = [ordered]@{ code = $Code; message = $Message; atUtc = $AtUtc }
    $Operation.coordination.projectLeaseReleased = $true
    $Operation.coordination.symbolLeaseHeld = $false
    Set-OperationStatus -Operation $Operation -Status 'FAILED' -Outcome 'FAILED' -AtUtc $AtUtc -Event 'failed' -ActionIdValue $ActionIdValue -Detail $Message
}

function Start-NewOperation {
    param(
        [Parameter(Mandatory = $true)][object]$Audit,
        [Parameter(Mandatory = $true)][string]$ResolvedEngineeringRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedStationRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedPlcProject,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$ResolvedOperationRoot
    )

    $newOperationId = Get-OperationIdForRequest -RequestId $Audit.requestId
    $operationDirectory = Get-OperationDirectory -Root $ResolvedOperationRoot -Id $newOperationId
    $operationPath = Join-Path $operationDirectory 'operation.json'
    $idempotencyText = $workflowRevision + '|' + $Audit.requestId + '|' + $Audit.document.sha256 + '|' + $ResolvedPlcProject.ToLowerInvariant() + '|' + $Profile
    $idempotencyKey = Get-Sha256ForText -Text $idempotencyText

    if ([System.IO.File]::Exists($operationPath)) {
        $existing = (Read-JsonDocument -Path $operationPath -Description 'Stage2 operation').payload
        Assert-SamePath -Expected $ResolvedEngineeringRoot -Actual ([string]$existing.identity.engineeringRoot) -Description 'Operation engineering root'
        Assert-SamePath -Expected $ResolvedStationRoot -Actual ([string]$existing.identity.stationRoot) -Description 'Operation Station root'
        Assert-SamePath -Expected $ResolvedPlcProject -Actual ([string]$existing.identity.plcProject) -Description 'Operation PLC project'
        Assert-OperationLedgerIntegrity `
            -Operation $existing `
            -OperationDirectory $operationDirectory `
            -ExpectedOperationId $newOperationId `
            -ExpectedProfile $Profile `
            -SkipDerivedArtifacts
        Repair-DerivedOperationArtifacts `
            -Operation $existing `
            -OperationDirectory $operationDirectory `
            -ExpectedOperationId $newOperationId `
            -ExpectedProfile $Profile
        Assert-OperationLedgerIntegrity `
            -Operation $existing `
            -OperationDirectory $operationDirectory `
            -ExpectedOperationId $newOperationId `
            -ExpectedProfile $Profile
        Assert-OperationSourcesCurrent -Operation $existing
        if (-not ([string]$existing.idempotency.key).Equals($idempotencyKey, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "INPUT_CHANGED_FOR_EXISTING_OPERATION: Stage1 request '$($Audit.requestId)' no longer matches its existing Stage2 ledger."
        }
        return Get-ResultView -Operation $existing -OperationPath $operationPath
    }

    $createdAtUtc = [string]$Audit.report.auditedAtUtc
    $operation = [ordered]@{
        schemaVersion    = 1
        kind             = $operationKind
        workflowRevision = $workflowRevision
        operationId      = $newOperationId
        revision         = 1
        status           = 'WAITING_FOR_RUNNER'
        outcome          = 'NEEDS_REVIEW'
        createdAtUtc     = $createdAtUtc
        updatedAtUtc     = $createdAtUtc
        idempotency      = [ordered]@{ key = $idempotencyKey; algorithm = 'SHA256' }
        source           = [ordered]@{
            initialAudit = [ordered]@{
                requestId = $Audit.requestId
                path      = $Audit.document.path
                sha256    = $Audit.document.sha256
                requestedAtUtc = $Audit.requestedAtUtc.ToString('o')
            }
            export2Audit = $null
        }
        identity         = [ordered]@{
            engineeringRoot = $ResolvedEngineeringRoot
            stationRoot     = $ResolvedStationRoot
            plcProject      = $ResolvedPlcProject
            profile         = $Profile
        }
        baseline         = [ordered]@{
            manifests    = @($Audit.report.manifests)
            fingerprints = @($Audit.report.fingerprints)
        }
        guardrails       = [ordered]@{
            offlineOnly              = $true
            onlineOperationsUsed     = $false
            coordinatorStartsPleMcp  = $false
            coordinatorCallsRest     = $false
            prohibitCpStudioInterfaceWrites = $true
            warningAcceptance        = 'signature-multiset-not-count-only'
        }
        coordination     = [ordered]@{
            scope                = 'workflow-local'
            projectLeaseReleased = $true
            symbolLeaseHeld      = $false
            exportWindowActive   = $false
        }
        currentAction    = $null
        evidence         = @()
        export2          = [ordered]@{ required = $false; waitingSinceUtc = $null; boundRequestId = $null }
        history          = @(
            [ordered]@{ atUtc = $createdAtUtc; event = 'created'; from = $null; to = 'WAITING_FOR_RUNNER'; actionId = ($newOperationId + '-0001'); detail = 'Stage1 audit accepted.' }
        )
        failure          = $null
    }
    $action = New-RunnerAction -Operation $operation -Sequence 1 -Kind 'inspect_and_build' -CreatedAtUtc $createdAtUtc

    if ($WhatIfPreference) {
        $previewActionSha = Get-JsonTextSha256 -Value $action
        $operation.currentAction = [ordered]@{
            actionId = $action.actionId
            kind = $action.actionKind
        sequence = 1
            createdAtUtc = $createdAtUtc
            path = (Join-Path $operationDirectory 'actions\0001-inspect_and_build.json')
            sha256 = $previewActionSha
        }
        return Get-ResultView -Operation $operation -OperationPath $operationPath -PreviewStatus 'WHATIF'
    }

    [System.IO.Directory]::CreateDirectory($operationDirectory) | Out-Null
    $actionReference = Write-RunnerAction -OperationDirectory $operationDirectory -Action $action
    $operation.currentAction = [ordered]@{
        actionId = $actionReference.actionId
        kind     = $actionReference.kind
        sequence = $actionReference.sequence
        createdAtUtc = $actionReference.createdAtUtc
        path     = $actionReference.path
        sha256   = $actionReference.sha256
    }
    $savedPath = Save-Operation -Operation $operation -OperationDirectory $operationDirectory
    return Get-ResultView -Operation $operation -OperationPath $savedPath
}

function Advance-WithEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$OperationDirectory,
        [Parameter(Mandatory = $true)][string]$OperationPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $incomingDocument = Read-JsonDocument -Path $Path -Description 'Runner evidence'
    foreach ($accepted in @($Operation.evidence)) {
        if ([string]$accepted.actionId -eq [string](Get-PropertyValue -Object $incomingDocument.payload -Name 'actionId')) {
            $acceptedSourceSha = [string](Get-PropertyValue -Object $accepted -Name 'sourceSha256' -DefaultValue $accepted.sha256)
            if ($acceptedSourceSha -eq $incomingDocument.sha256) {
                return Get-ResultView -Operation $Operation -OperationPath $OperationPath
            }
            throw "Immutable evidence for action '$($accepted.actionId)' was already accepted with different content."
        }
    }
    if ([string]$Operation.status -ne 'WAITING_FOR_RUNNER') {
        throw "Operation '$($Operation.operationId)' is not waiting for runner evidence; current status is $($Operation.status)."
    }

    Assert-OperationSourcesCurrent -Operation $Operation
    $validated = Read-AndValidateEvidence -Path $Path -Operation $Operation
    if (-not $validated.document.sha256.Equals($incomingDocument.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runner evidence changed while it was being validated.'
    }
    $result = $validated.result
    $currentActionKind = [string]$Operation.currentAction.kind
    $repairRequired = Get-BooleanValue -Object $result -Name 'repairRequired' -DefaultValue $false -Context 'Runner result'
    $requiresSecondExport = Get-BooleanValue -Object $result -Name 'requiresSecondExport' -DefaultValue $false -Context 'Runner result'
    $requiresCpStudioChange = Get-BooleanValue -Object $result -Name 'requiresCpStudioChange' -DefaultValue $false -Context 'Runner result'
    $verificationOk = Get-BooleanValue -Object $result -Name 'verificationOk' -DefaultValue $false -Context 'Runner result'

    if (($repairRequired -and $requiresSecondExport) -or
        ($requiresCpStudioChange -and ($repairRequired -or $requiresSecondExport))) {
        throw 'Runner result contains mutually exclusive routing flags.'
    }

    $terminalRunnerResult = @('failed', 'blocked') -contains $validated.resultStatus
    if ($terminalRunnerResult -and ($repairRequired -or $requiresSecondExport -or $requiresCpStudioChange)) {
        throw 'A blocked/failed runner result cannot also request another workflow route.'
    }

    $buildEvidence = $null
    if (-not $terminalRunnerResult) {
        $buildEvidence = Assert-BuildEvidence -Result $result -Operation $Operation -EvidenceCompletedAtUtc $validated.completedAtUtc -AllowErrors
        Assert-StructuredAcceptance `
            -Result $result `
            -Operation $Operation `
            -RequiresSecondExport $requiresSecondExport `
            -RequiresCpStudioChange $requiresCpStudioChange
    }
    $proposedChanges = @()
    if ($repairRequired) {
        if ($currentActionKind -ne 'inspect_and_build') {
            throw 'Only inspect_and_build may propose a new repair action.'
        }
        $proposedChanges = @(Get-PropertyValue -Object $result -Name 'proposedChanges' -DefaultValue @())
        try {
            Assert-ProposedChangesSafe -Changes $proposedChanges -EngineeringRoot ([string]$Operation.identity.engineeringRoot)
        }
        catch {
            $ownershipFailure = $_.Exception.Message
            if ($WhatIfPreference) {
                $preview = Get-ResultView -Operation $Operation -OperationPath $OperationPath -PreviewStatus 'WHATIF'
                $preview | Add-Member -NotePropertyName proposedStatus -NotePropertyValue 'BLOCKED'
                $preview | Add-Member -NotePropertyName blocker -NotePropertyValue $ownershipFailure
                return $preview
            }
            $blockedActionId = [string]$Operation.currentAction.actionId
            Set-OperationBlocked `
                -Operation $Operation `
                -AtUtc $validated.completedAtUtc `
                -Code 'OWNERSHIP_APPLY_BLOCKED' `
                -Message $ownershipFailure `
                -ActionIdValue $blockedActionId
            $savedPath = Save-Operation -Operation $Operation -OperationDirectory $OperationDirectory
            return Get-ResultView -Operation $Operation -OperationPath $savedPath
        }
    }
    if ((-not $terminalRunnerResult) -and $requiresSecondExport -and ($buildEvidence.errors -ne 0)) {
        throw 'Export #2 cannot be requested until the offline Build has zero errors.'
    }
    if ((-not $terminalRunnerResult) -and ($currentActionKind -eq 'apply_change_set_and_build')) {
        if (-not (Get-BooleanValue -Object $result -Name 'appliedReadbackOk' -Required -Context 'Repair result')) {
            throw 'Repair evidence did not prove exact readback.'
        }
        if ($buildEvidence.errors -ne 0) {
            throw 'Repair action finished with Build errors.'
        }
    }
    if (($currentActionKind -eq 'verify_after_export_2') -and $requiresSecondExport) {
        throw 'Final verification cannot recursively request another Export #2.'
    }

    $nextStatus = $null
    $nextOutcome = $null
    $nextActionKind = $null
    $blockCode = $null
    $blockMessage = $null
    if ($validated.resultStatus -eq 'failed') {
        $nextStatus = 'FAILED'
        $nextOutcome = 'FAILED'
        $blockCode = 'RUNNER_FAILED'
        $blockMessage = Get-SafeFailureText `
            -Stage ([string](Get-PropertyValue -Object $result -Name 'failureStage' -DefaultValue 'runner')) `
            -Code ([string](Get-PropertyValue -Object $result -Name 'reasonCode' -DefaultValue 'RUNNER_FAILED')) `
            -Status 'failed'
    }
    elseif ($validated.resultStatus -eq 'blocked') {
        $nextStatus = 'BLOCKED'
        $nextOutcome = 'NEEDS_REVIEW'
        $blockCode = 'RUNNER_BLOCKED'
        $blockMessage = Get-SafeFailureText `
            -Stage ([string](Get-PropertyValue -Object $result -Name 'failureStage' -DefaultValue 'runner')) `
            -Code ([string](Get-PropertyValue -Object $result -Name 'reasonCode' -DefaultValue 'RUNNER_BLOCKED')) `
            -Status 'blocked'
    }
    elseif ($requiresCpStudioChange) {
        $nextStatus = 'WAITING_FOR_CPSTUDIO'
        $nextOutcome = 'NEEDS_CPSTUDIO'
    }
    elseif ($repairRequired) {
        $nextStatus = 'WAITING_FOR_RUNNER'
        $nextOutcome = 'NEEDS_REVIEW'
        $nextActionKind = 'apply_change_set_and_build'
    }
    elseif ($requiresSecondExport) {
        $nextStatus = 'WAITING_FOR_EXPORT_2'
        $nextOutcome = 'NEEDS_EXPORT_2'
    }
    elseif (($buildEvidence.errors -eq 0) -and $buildEvidence.verified -and $verificationOk) {
        $nextStatus = 'DONE'
        $nextOutcome = 'DONE'
    }
    else {
        $nextStatus = 'BLOCKED'
        $nextOutcome = 'NEEDS_REVIEW'
        $blockCode = 'ACCEPTANCE_NOT_PROVEN'
        $blockMessage = 'Runner evidence did not prove a clean Build and complete verification.'
    }

    if ($WhatIfPreference) {
        $preview = Get-ResultView -Operation $Operation -OperationPath $OperationPath -PreviewStatus 'WHATIF'
        $preview | Add-Member -NotePropertyName proposedStatus -NotePropertyValue $nextStatus
        $preview | Add-Member -NotePropertyName proposedActionKind -NotePropertyValue $nextActionKind
        return $preview
    }

    $evidenceDirectory = Join-Path $OperationDirectory 'evidence'
    $evidenceFileName = '{0:d4}-{1}.json' -f [int]$Operation.currentAction.sequence, [string]$Operation.currentAction.kind
    $storedEvidencePath = Join-Path $evidenceDirectory $evidenceFileName
    $storedEvidenceSha = Write-ImmutableJson -Path $storedEvidencePath -Value $validated.evidence
    Add-EvidenceReference `
        -Operation $Operation `
        -ValidatedEvidence $validated `
        -StoredPath $storedEvidencePath `
        -StoredSha256 $storedEvidenceSha `
        -SourceSha256 $validated.document.sha256
    $completedActionId = [string]$Operation.currentAction.actionId
    $Operation.currentAction = $null
    $Operation.coordination.projectLeaseReleased = $true
    $Operation.coordination.symbolLeaseHeld = $false

    if ($nextStatus -eq 'FAILED') {
        Set-OperationFailed -Operation $Operation -AtUtc $validated.completedAtUtc -Code $blockCode -Message $blockMessage -ActionIdValue $completedActionId
    }
    elseif ($nextStatus -eq 'BLOCKED') {
        Set-OperationBlocked -Operation $Operation -AtUtc $validated.completedAtUtc -Code $blockCode -Message $blockMessage -ActionIdValue $completedActionId
    }
    elseif ($nextStatus -eq 'WAITING_FOR_RUNNER') {
        $nextSequence = [int]$Operation.evidence.Count + 1
        $nextAction = New-RunnerAction -Operation $Operation -Sequence $nextSequence -Kind $nextActionKind -CreatedAtUtc $validated.completedAtUtc -ChangeSet $proposedChanges
        $nextReference = Write-RunnerAction -OperationDirectory $OperationDirectory -Action $nextAction
        $Operation.currentAction = [ordered]@{
            actionId = $nextReference.actionId
            kind     = $nextReference.kind
            sequence = $nextReference.sequence
            createdAtUtc = $nextReference.createdAtUtc
            path     = $nextReference.path
            sha256   = $nextReference.sha256
        }
        Set-OperationStatus -Operation $Operation -Status $nextStatus -Outcome $nextOutcome -AtUtc $validated.completedAtUtc -Event 'runner_action_planned' -ActionIdValue $completedActionId -Detail $nextActionKind
    }
    elseif ($nextStatus -eq 'WAITING_FOR_EXPORT_2') {
        $Operation.export2.required = $true
        $Operation.export2.waitingSinceUtc = $validated.completedAtUtc
        $Operation.export2.boundRequestId = $null
        $Operation.coordination.exportWindowActive = $true
        $sentinel = [ordered]@{
            schemaVersion       = 1
            operationId         = $Operation.operationId
            active              = $true
            createdAtUtc        = $validated.completedAtUtc
            symbolAccessPolicy  = 'DENY'
            projectLeaseReleased = $true
            reason              = 'Waiting for a human Control plus Studio Export #2.'
        }
        $null = Write-ImmutableJson -Path (Join-Path $OperationDirectory 'export-window.active.json') -Value $sentinel
        Set-OperationStatus -Operation $Operation -Status $nextStatus -Outcome $nextOutcome -AtUtc $validated.completedAtUtc -Event 'waiting_for_export_2' -ActionIdValue $completedActionId -Detail 'Project and Symbol leases released.'
    }
    elseif ($nextStatus -eq 'WAITING_FOR_CPSTUDIO') {
        $Operation.coordination.exportWindowActive = $false
        Set-OperationStatus -Operation $Operation -Status $nextStatus -Outcome $nextOutcome -AtUtc $validated.completedAtUtc -Event 'waiting_for_cpstudio' -ActionIdValue $completedActionId -Detail 'CpStudio owns the required model/interface change.'
    }
    else {
        $Operation.coordination.exportWindowActive = $false
        Set-OperationStatus -Operation $Operation -Status 'DONE' -Outcome 'DONE' -AtUtc $validated.completedAtUtc -Event 'accepted' -ActionIdValue $completedActionId -Detail 'Offline acceptance evidence complete.'
    }

    $savedPath = Save-Operation -Operation $Operation -OperationDirectory $OperationDirectory
    return Get-ResultView -Operation $Operation -OperationPath $savedPath
}

function Bind-SecondExport {
    param(
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$OperationDirectory,
        [Parameter(Mandatory = $true)][string]$OperationPath,
        [Parameter(Mandatory = $true)][object]$Audit
    )

    if ([string]$Operation.status -eq 'WAITING_FOR_RUNNER' -and $Operation.source.export2Audit) {
        if ([string]$Operation.source.export2Audit.sha256 -eq $Audit.document.sha256) {
            $sentinelPath = Join-Path $OperationDirectory 'export-window.active.json'
            if ((-not $WhatIfPreference) -and [System.IO.File]::Exists($sentinelPath)) {
                [System.IO.File]::Delete($sentinelPath)
            }
            return Get-ResultView -Operation $Operation -OperationPath $OperationPath
        }
        throw 'A different second-export audit is already bound to this operation.'
    }
    if ([string]$Operation.status -ne 'WAITING_FOR_EXPORT_2') {
        throw "Operation '$($Operation.operationId)' is not waiting for Export #2; current status is $($Operation.status)."
    }
    Assert-OperationSourcesCurrent -Operation $Operation -SkipStationFingerprints
    Assert-ManifestSetsEqual -Expected @($Operation.baseline.manifests) -Actual @($Audit.report.manifests)
    if ($Audit.requestId -eq $Operation.source.initialAudit.requestId) {
        throw 'Export #2 must have a new Stage1 requestId.'
    }
    $waitingSince = [DateTime]::Parse([string]$Operation.export2.waitingSinceUtc).ToUniversalTime()
    if ($Audit.requestedAtUtc -lt $waitingSince) {
        throw 'Export #2 audit predates the operation waiting window.'
    }

    $createdAtUtc = [string]$Audit.report.auditedAtUtc
    $sequence = [int]$Operation.evidence.Count + 1
    $auditReference = [ordered]@{
        requestId      = $Audit.requestId
        path           = $Audit.document.path
        sha256         = $Audit.document.sha256
        requestedAtUtc = $Audit.requestedAtUtc.ToString('o')
    }
    $Operation.source.export2Audit = $auditReference
    $nextAction = New-RunnerAction -Operation $Operation -Sequence $sequence -Kind 'verify_after_export_2' -CreatedAtUtc $createdAtUtc

    if ($WhatIfPreference) {
        $preview = Get-ResultView -Operation $Operation -OperationPath $OperationPath -PreviewStatus 'WHATIF'
        $preview | Add-Member -NotePropertyName proposedStatus -NotePropertyValue 'WAITING_FOR_RUNNER'
        $preview | Add-Member -NotePropertyName proposedActionKind -NotePropertyValue 'verify_after_export_2'
        return $preview
    }

    $nextReference = Write-RunnerAction -OperationDirectory $OperationDirectory -Action $nextAction
    $Operation.currentAction = [ordered]@{
        actionId = $nextReference.actionId
        kind     = $nextReference.kind
        sequence = $nextReference.sequence
        createdAtUtc = $nextReference.createdAtUtc
        path     = $nextReference.path
        sha256   = $nextReference.sha256
    }
    $Operation.export2.boundRequestId = $Audit.requestId
    $Operation.coordination.exportWindowActive = $false
    Set-OperationStatus -Operation $Operation -Status 'WAITING_FOR_RUNNER' -Outcome 'NEEDS_REVIEW' -AtUtc $createdAtUtc -Event 'export_2_bound' -Detail $Audit.requestId
    $savedPath = Save-Operation -Operation $Operation -OperationDirectory $OperationDirectory
    $sentinelPath = Join-Path $OperationDirectory 'export-window.active.json'
    if ([System.IO.File]::Exists($sentinelPath)) {
        [System.IO.File]::Delete($sentinelPath)
    }
    return Get-ResultView -Operation $Operation -OperationPath $savedPath
}

$specifiedModes = 0
if ($AuditReport) { $specifiedModes++ }
if ($EvidencePath) { $specifiedModes++ }
if ($SecondExportAuditReport) { $specifiedModes++ }
if ($specifiedModes -gt 1) {
    throw '-AuditReport, -EvidencePath and -SecondExportAuditReport are mutually exclusive modes.'
}
if (($EvidencePath -or $SecondExportAuditReport) -and (-not $OperationId)) {
    throw '-EvidencePath and -SecondExportAuditReport require -OperationId.'
}
if ($AuditReport -and $OperationId) {
    throw '-AuditReport computes the deterministic operationId; do not combine it with -OperationId.'
}
if ((-not $AuditReport) -and (-not $OperationId)) {
    throw 'Specify -AuditReport to start, or -OperationId to query/resume an operation.'
}

if (-not $EngineeringRoot) {
    $EngineeringRoot = Join-Path $PSScriptRoot '..\..'
}
$resolvedEngineeringRoot = [System.IO.Path]::GetFullPath($EngineeringRoot)
$configurationPath = Join-Path $resolvedEngineeringRoot 'config\project.yaml'
$configuredStationRoot = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'station_root'
$configuredPlcProject = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'plc_project'
$profile = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'plc_engineering_profile'
if ([string]::IsNullOrWhiteSpace($configuredStationRoot) -or ($configuredStationRoot -eq 'null')) {
    throw 'config/project.yaml must define paths.station_root before Stage2 can run.'
}
if ([string]::IsNullOrWhiteSpace($configuredPlcProject) -or ($configuredPlcProject -eq 'null')) {
    throw 'config/project.yaml must define paths.plc_project before Stage2 can run.'
}
if ([string]::IsNullOrWhiteSpace($profile) -or ($profile -eq 'null')) {
    throw 'config/project.yaml must define tools.plc_engineering_profile before Stage2 can run.'
}
$resolvedStationRoot = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredStationRoot
$resolvedPlcProject = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredPlcProject

if (-not $OperationRoot) {
    $OperationRoot = Join-Path $resolvedEngineeringRoot 'data\operations\cpstudio-stage2'
}
$resolvedOperationRoot = [System.IO.Path]::GetFullPath($OperationRoot)
$null = Assert-PathInsideRoot -Root $resolvedEngineeringRoot -Path $resolvedOperationRoot -Description 'Operation root'

$ledgerLock = $null
try {
    if (-not $WhatIfPreference) {
        $ledgerLock = Enter-LedgerLock -Root $resolvedOperationRoot -WaitMilliseconds $LockWaitMilliseconds
    }

    if ($AuditReport) {
        $resolvedAuditPath = Assert-PathInsideRoot -Root $resolvedEngineeringRoot -Path $AuditReport -Description 'Stage1 audit report'
        $audit = Read-AndValidateAuditReport `
            -Path $resolvedAuditPath `
            -ExpectedEngineeringRoot $resolvedEngineeringRoot `
            -ExpectedStationRoot $resolvedStationRoot `
            -ExpectedPlcProject $resolvedPlcProject
        Start-NewOperation `
            -Audit $audit `
            -ResolvedEngineeringRoot $resolvedEngineeringRoot `
            -ResolvedStationRoot $resolvedStationRoot `
            -ResolvedPlcProject $resolvedPlcProject `
            -Profile $profile `
            -ResolvedOperationRoot $resolvedOperationRoot
        return
    }

    $operationDirectory = Get-OperationDirectory -Root $resolvedOperationRoot -Id $OperationId
    $operationPath = Join-Path $operationDirectory 'operation.json'
    $operationDocument = Read-JsonDocument -Path $operationPath -Description 'Stage2 operation'
    $operation = $operationDocument.payload
    Assert-SamePath -Expected $resolvedEngineeringRoot -Actual ([string]$operation.identity.engineeringRoot) -Description 'Operation engineering root'
    Assert-SamePath -Expected $resolvedStationRoot -Actual ([string]$operation.identity.stationRoot) -Description 'Operation Station root'
    Assert-SamePath -Expected $resolvedPlcProject -Actual ([string]$operation.identity.plcProject) -Description 'Operation PLC project'
    Assert-OperationLedgerIntegrity `
        -Operation $operation `
        -OperationDirectory $operationDirectory `
        -ExpectedOperationId $OperationId `
        -ExpectedProfile $profile `
        -SkipDerivedArtifacts
    Repair-DerivedOperationArtifacts `
        -Operation $operation `
        -OperationDirectory $operationDirectory `
        -ExpectedOperationId $OperationId `
        -ExpectedProfile $profile
    Assert-OperationLedgerIntegrity `
        -Operation $operation `
        -OperationDirectory $operationDirectory `
        -ExpectedOperationId $OperationId `
        -ExpectedProfile $profile
    if ($EvidencePath) {
        $resolvedEvidencePath = Assert-PathInsideRoot -Root $resolvedEngineeringRoot -Path $EvidencePath -Description 'Runner evidence'
        Advance-WithEvidence -Operation $operation -OperationDirectory $operationDirectory -OperationPath $operationPath -Path $resolvedEvidencePath
        return
    }
    if ($SecondExportAuditReport) {
        $resolvedSecondAuditPath = Assert-PathInsideRoot -Root $resolvedEngineeringRoot -Path $SecondExportAuditReport -Description 'Second-export Stage1 audit report'
        $secondAudit = Read-AndValidateAuditReport `
            -Path $resolvedSecondAuditPath `
            -ExpectedEngineeringRoot $resolvedEngineeringRoot `
            -ExpectedStationRoot $resolvedStationRoot `
            -ExpectedPlcProject $resolvedPlcProject
        Bind-SecondExport -Operation $operation -OperationDirectory $operationDirectory -OperationPath $operationPath -Audit $secondAudit
        return
    }

    Get-ResultView -Operation $operation -OperationPath $operationPath
}
finally {
    if ($null -ne $ledgerLock) {
        $ledgerLock.Dispose()
    }
}
