[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)][string]$ActionPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedActionSha256,
    [Parameter(Mandatory = $true)][string]$ObservationPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$requestedWhatIf = [bool]$WhatIfPreference
# Keep -WhatIf from propagating into read-only cmdlets such as Get-FileHash.
# The final write gate below still honors the caller's request.
$WhatIfPreference = $false

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
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $DefaultValue
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-RequiredString {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $value = [string](Get-PropertyValue -Object $Object -Name $Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Context has no non-empty '$Name'."
    }
    return $value
}

function Get-RequiredBoolean {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $missing = New-Object object
    $value = Get-PropertyValue -Object $Object -Name $Name -DefaultValue $missing
    if ([object]::ReferenceEquals($missing, $value) -or ($value -isnot [bool])) {
        throw "$Context must explicitly provide Boolean '$Name'."
    }
    return [bool]$value
}

function Get-Sha256ForBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-Sha256ForText {
    param([Parameter(Mandatory = $true)][string]$Text)

    return Get-Sha256ForBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text))
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
        $text = $utf8.GetString($bytes)
        if (($text.Length -gt 0) -and ($text[0] -eq [char]0xFEFF)) {
            $text = $text.Substring(1)
        }
        $payload = $text | ConvertFrom-Json
    }
    catch {
        throw "$Description is not valid UTF-8 JSON: $resolvedPath. $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        path    = $resolvedPath
        raw     = $text
        sha256  = Get-Sha256ForBytes -Bytes $bytes
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

function Assert-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if ((-not $candidate.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) -and
        (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Description escaped its configured root: $candidate"
    }
    return $candidate
}

function Assert-NoSensitiveFields {
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
    if (($Value -is [System.Collections.IEnumerable]) -and
        ($Value -isnot [pscustomobject]) -and
        ($Value -isnot [System.Collections.IDictionary])) {
        $index = 0
        foreach ($item in $Value) {
            Assert-NoSensitiveFields -Value $item -Path ($Path + '[' + $index + ']')
            $index++
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            if ($name -match '(?i)(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential)') {
                throw "Runner observation contains a prohibited secret-bearing field: $Path.$name"
            }
            Assert-NoSensitiveFields -Value $Value[$key] -Path ($Path + '.' + $name)
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -match '(?i)(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential)') {
            throw "Runner observation contains a prohibited secret-bearing field: $Path.$($property.Name)"
        }
        Assert-NoSensitiveFields -Value $property.Value -Path ($Path + '.' + $property.Name)
    }
}

function Assert-FileFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $relativePath = Get-RequiredString -Object $Record -Name 'path' -Context "$Kind record"
    $fullPath = Assert-PathInsideRoot -Root $Root -Path (Join-Path $Root $relativePath) -Description "$Kind path"
    $expectedExists = Get-RequiredBoolean -Object $Record -Name 'exists' -Context "$Kind record '$relativePath'"
    $actualExists = [System.IO.File]::Exists($fullPath)
    if ($actualExists -ne $expectedExists) {
        throw "$Kind existence drifted: $relativePath"
    }
    if ($expectedExists) {
        $expectedSha = Get-RequiredString -Object $Record -Name 'sha256' -Context "$Kind record '$relativePath'"
        $actualSha = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        if (-not $actualSha.Equals($expectedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$Kind SHA-256 drifted: $relativePath"
        }
    }
}

function Assert-ActionCurrent {
    param(
        [Parameter(Mandatory = $true)][object]$Action,
        [Parameter(Mandatory = $true)][string]$ActionSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if (-not $ActionSha256.Equals($ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The immutable action file SHA-256 does not match ExpectedActionSha256.'
    }
    if ([int](Get-PropertyValue -Object $Action -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
        throw 'Runner action schemaVersion must be 1.'
    }
    if ((Get-RequiredString -Object $Action -Name 'kind' -Context 'Runner action') -ne 'ctrlx-opcon-runner-request') {
        throw 'Unsupported runner action document kind.'
    }
    if ((Get-RequiredString -Object $Action -Name 'status' -Context 'Runner action') -ne 'WAITING_FOR_RUNNER') {
        throw 'Runner action is not waiting for execution.'
    }
    $actionKind = Get-RequiredString -Object $Action -Name 'actionKind' -Context 'Runner action'
    if (@('inspect_and_build', 'apply_change_set_and_build', 'verify_after_export_2') -notcontains $actionKind) {
        throw "Unsupported runner action kind: $actionKind"
    }

    $project = Get-PropertyValue -Object $Action -Name 'project'
    $engineeringRoot = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $project -Name 'engineeringRoot' -Context 'Runner action project'))
    $stationRoot = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $project -Name 'stationRoot' -Context 'Runner action project'))
    $plcProject = Assert-PathInsideRoot -Root $stationRoot -Path (Get-RequiredString -Object $project -Name 'plcProject' -Context 'Runner action project') -Description 'PLC project'
    if (-not [System.IO.File]::Exists($plcProject)) {
        throw "PLC project does not exist: $plcProject"
    }
    $null = Get-RequiredString -Object $project -Name 'profile' -Context 'Runner action project'

    $source = Get-PropertyValue -Object $Action -Name 'source'
    $auditPath = Assert-PathInsideRoot -Root $engineeringRoot -Path (Get-RequiredString -Object $source -Name 'auditReport' -Context 'Runner action source') -Description 'Stage 1 audit report'
    $auditSha = Get-RequiredString -Object $source -Name 'auditReportSha256' -Context 'Runner action source'
    $actualAuditSha = if ([System.IO.File]::Exists($auditPath)) { (Get-FileHash -LiteralPath $auditPath -Algorithm SHA256).Hash } else { $null }
    if ((-not [System.IO.File]::Exists($auditPath)) -or
        (-not $actualAuditSha.Equals($auditSha, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'The Stage 1 audit report is missing or has drifted.'
    }

    $preconditions = Get-PropertyValue -Object $Action -Name 'preconditions'
    foreach ($manifest in @(Get-PropertyValue -Object $preconditions -Name 'manifests' -DefaultValue @())) {
        Assert-FileFingerprint -Root $engineeringRoot -Record $manifest -Kind 'Ownership manifest'
    }
    $fingerprints = @(Get-PropertyValue -Object $preconditions -Name 'fingerprints' -DefaultValue @())
    $export2Audit = Get-PropertyValue -Object $source -Name 'export2Audit'
    if ($actionKind -eq 'verify_after_export_2') {
        if ($null -eq $export2Audit) {
            throw 'Final verification action has no bound Export #2 audit.'
        }
        $export2Path = Assert-PathInsideRoot -Root $engineeringRoot -Path (Get-RequiredString -Object $export2Audit -Name 'path' -Context 'Export #2 audit reference') -Description 'Export #2 audit report'
        $export2Sha = Get-RequiredString -Object $export2Audit -Name 'sha256' -Context 'Export #2 audit reference'
        if (-not [System.IO.File]::Exists($export2Path)) {
            throw 'The bound Export #2 audit report is missing.'
        }
        $actualExport2Sha = (Get-FileHash -LiteralPath $export2Path -Algorithm SHA256).Hash
        if (-not $actualExport2Sha.Equals($export2Sha, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'The bound Export #2 audit report has drifted.'
        }
        $export2Document = Read-JsonDocument -Path $export2Path -Description 'Export #2 audit report'
        $fingerprints = @(Get-PropertyValue -Object $export2Document.payload -Name 'fingerprints' -DefaultValue @())
    }
    $stationPrefix = $stationRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $plcRelativePath = $plcProject.Substring($stationPrefix.Length).Replace('\', '/')
    $requiredFingerprintPaths = @('Engineering/Engineering_Data.xml')
    if ($actionKind -in @('inspect_and_build', 'verify_after_export_2')) {
        $requiredFingerprintPaths += $plcRelativePath
    }
    foreach ($requiredPath in $requiredFingerprintPaths) {
        $matches = @($fingerprints | Where-Object { ([string]$_.path).Replace('\', '/') -eq $requiredPath })
        if ($matches.Count -ne 1) {
            throw "Runner action/audit does not contain one required Station fingerprint: $requiredPath"
        }
        Assert-FileFingerprint -Root $stationRoot -Record $matches[0] -Kind 'Station fingerprint'
    }

    $guardrails = Get-PropertyValue -Object $Action -Name 'guardrails'
    if ((-not (Get-RequiredBoolean -Object $guardrails -Name 'offlineOnly' -Context 'Runner action guardrails')) -or
        (Get-RequiredBoolean -Object $guardrails -Name 'onlineOperationsAllowed' -Context 'Runner action guardrails') -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'requireExistingPersistentSession' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'prohibitStartPleOrMcp' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'prohibitDirectWatcherIpc' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'requireExactProjectOpen' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'projectLeaseRequired' -Context 'Runner action guardrails'))) {
        throw 'Runner action does not contain the required offline/single-session guardrails.'
    }

    return [pscustomobject]@{
        actionKind      = $actionKind
        engineeringRoot = $engineeringRoot
        stationRoot      = $stationRoot
        plcProject       = $plcProject
        profile          = [string]$project.profile
    }
}

function ConvertTo-NormalizedWarningText {
    param([Parameter(Mandatory = $true)][object]$Record)

    if ($Record -is [string]) {
        $text = ([string]$Record).Trim() -replace '\s+', ' '
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw 'Warning records cannot be empty.'
        }
        return ([ordered]@{
            code       = ''
            source     = ''
            objectPath = ''
            position   = ''
            message    = $text
        } | ConvertTo-Json -Compress)
    }
    $objectPath = [string](Get-PropertyValue -Object $Record -Name 'objectPath')
    if ([string]::IsNullOrWhiteSpace($objectPath)) {
        $objectPath = [string](Get-PropertyValue -Object $Record -Name 'object')
    }
    $position = [string](Get-PropertyValue -Object $Record -Name 'position')
    if ([string]::IsNullOrWhiteSpace($position)) {
        $line = [string](Get-PropertyValue -Object $Record -Name 'line')
        $column = [string](Get-PropertyValue -Object $Record -Name 'column')
        if ((-not [string]::IsNullOrWhiteSpace($line)) -or (-not [string]::IsNullOrWhiteSpace($column))) {
            $position = 'line=' + $line + ';column=' + $column
        }
    }
    $message = [string](Get-PropertyValue -Object $Record -Name 'message')
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = [string](Get-PropertyValue -Object $Record -Name 'description')
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = [string](Get-PropertyValue -Object $Record -Name 'text')
    }
    $canonical = [ordered]@{
        code       = (([string](Get-PropertyValue -Object $Record -Name 'code')).Trim() -replace '\s+', ' ')
        source     = (([string](Get-PropertyValue -Object $Record -Name 'source')).Trim() -replace '\s+', ' ')
        objectPath = ($objectPath.Trim() -replace '\s+', ' ')
        position   = ($position.Trim() -replace '\s+', ' ')
        message    = ($message.Trim() -replace '\s+', ' ')
    }
    if ([string]::IsNullOrWhiteSpace([string]$canonical.code) -and
        [string]::IsNullOrWhiteSpace([string]$canonical.source) -and
        [string]::IsNullOrWhiteSpace([string]$canonical.objectPath) -and
        [string]::IsNullOrWhiteSpace([string]$canonical.position) -and
        [string]::IsNullOrWhiteSpace([string]$canonical.message)) {
        throw 'A structured warning record needs code, source, object, position, or message.'
    }
    return ($canonical | ConvertTo-Json -Compress)
}

function Get-WarningSignatureMultiset {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory = $true)][int]$ExpectedCount
    )

    if ($ExpectedCount -lt 0) {
        throw 'Build warnings count cannot be negative.'
    }
    if ($Records.Count -ne $ExpectedCount) {
        throw "warningRecords count $($Records.Count) does not match Build warnings=$ExpectedCount."
    }
    $counts = @{}
    foreach ($record in $Records) {
        $signature = Get-Sha256ForText -Text (ConvertTo-NormalizedWarningText -Record $record)
        if ($counts.ContainsKey($signature)) {
            $counts[$signature] = [int]$counts[$signature] + 1
        }
        else {
            $counts[$signature] = 1
        }
    }
    $result = @()
    foreach ($signature in @($counts.Keys | Sort-Object)) {
        $result += [ordered]@{
            sha256     = $signature
            occurrences = [int]$counts[$signature]
        }
    }
    return @($result)
}

function Get-ObjectPropertyNames {
    param([Parameter(Mandatory = $true)][object]$Object)

    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $actual = @(Get-ObjectPropertyNames -Object $Object | Sort-Object -Unique)
    $expected = @($Allowed | Sort-Object -Unique)
    if (($actual.Count -ne $expected.Count) -or (($actual -join '|') -ne ($expected -join '|'))) {
        throw "$Context contains unsupported or missing fields. Expected: $($expected -join ', ')."
    }
}

function Test-HexSha256 {
    param([Parameter(Mandatory = $false)][string]$Value)

    return ($Value -match '^[A-Fa-f0-9]{64}$')
}

function ConvertTo-ProposedChangeEvidence {
    param([Parameter(Mandatory = $true)][object]$Change)

    $allowed = @('changeId', 'authorization', 'targetPath', 'writeMode', 'hookIds', 'interfaceWrite', 'expectedBefore', 'desired', 'requiresReadback')
    Assert-ExactPropertySet -Object $Change -Allowed $allowed -Context 'Proposed change'
    $changeId = Get-RequiredString -Object $Change -Name 'changeId' -Context 'Proposed change'
    $authorization = Get-RequiredString -Object $Change -Name 'authorization' -Context 'Proposed change'
    $targetPath = Get-RequiredString -Object $Change -Name 'targetPath' -Context 'Proposed change'
    $writeMode = Get-RequiredString -Object $Change -Name 'writeMode' -Context 'Proposed change'
    if (($changeId -notmatch '^[A-Za-z0-9_.-]{1,128}$') -or
        (@('ai_owned', 'mixed_declared_hook') -notcontains $authorization) -or
        (@('full_object', 'implementation', 'semantic_merge') -notcontains $writeMode) -or
        ($targetPath.Length -gt 512) -or ($targetPath -match '[\x00-\x1F]') -or
        (Get-RequiredBoolean -Object $Change -Name 'interfaceWrite' -Context 'Proposed change') -or
        (-not (Get-RequiredBoolean -Object $Change -Name 'requiresReadback' -Context 'Proposed change'))) {
        throw "Proposed change '$changeId' contains unsafe authorization, write mode, target, or interface/readback flags."
    }
    $before = Get-PropertyValue -Object $Change -Name 'expectedBefore'
    $desired = Get-PropertyValue -Object $Change -Name 'desired'
    Assert-ExactPropertySet -Object $before -Allowed @('sha256') -Context "Proposed change '$changeId' expectedBefore"
    Assert-ExactPropertySet -Object $desired -Allowed @('sha256') -Context "Proposed change '$changeId' desired"
    $beforeSha = Get-RequiredString -Object $before -Name 'sha256' -Context "Proposed change '$changeId' expectedBefore"
    $desiredSha = Get-RequiredString -Object $desired -Name 'sha256' -Context "Proposed change '$changeId' desired"
    if ((-not (Test-HexSha256 -Value $beforeSha)) -or (-not (Test-HexSha256 -Value $desiredSha))) {
        throw "Proposed change '$changeId' contains an invalid hash."
    }
    $hookIds = @()
    foreach ($hookId in @(Get-PropertyValue -Object $Change -Name 'hookIds' -DefaultValue @())) {
        $value = [string]$hookId
        if ($value -notmatch '^[A-Za-z0-9_.-]{1,128}$') {
            throw "Proposed change '$changeId' contains an unsafe hook id."
        }
        $hookIds += $value
    }
    return [ordered]@{
        changeId        = $changeId
        authorization   = $authorization
        targetPath      = $targetPath
        writeMode       = $writeMode
        hookIds         = @($hookIds)
        interfaceWrite  = $false
        expectedBefore  = [ordered]@{ sha256 = $beforeSha.ToUpperInvariant() }
        desired         = [ordered]@{ sha256 = $desiredSha.ToUpperInvariant() }
        requiresReadback = $true
    }
}

function ConvertTo-AppliedChangeEvidence {
    param([Parameter(Mandatory = $true)][object]$Change)

    $allowed = @('changeId', 'status', 'targetPath', 'expectedBeforeSha256', 'observedBeforeSha256', 'desiredSha256', 'readbackSha256')
    Assert-ExactPropertySet -Object $Change -Allowed $allowed -Context 'Applied change'
    $result = [ordered]@{
        changeId             = Get-RequiredString -Object $Change -Name 'changeId' -Context 'Applied change'
        status               = Get-RequiredString -Object $Change -Name 'status' -Context 'Applied change'
        targetPath           = Get-RequiredString -Object $Change -Name 'targetPath' -Context 'Applied change'
        expectedBeforeSha256 = Get-RequiredString -Object $Change -Name 'expectedBeforeSha256' -Context 'Applied change'
        observedBeforeSha256 = Get-RequiredString -Object $Change -Name 'observedBeforeSha256' -Context 'Applied change'
        desiredSha256        = Get-RequiredString -Object $Change -Name 'desiredSha256' -Context 'Applied change'
        readbackSha256       = Get-RequiredString -Object $Change -Name 'readbackSha256' -Context 'Applied change'
    }
    if (($result.changeId -notmatch '^[A-Za-z0-9_.-]{1,128}$') -or
        ($result.status -ne 'applied') -or ($result.targetPath.Length -gt 512) -or
        ($result.targetPath -match '[\x00-\x1F]')) {
        throw 'Applied change contains an unsafe id, status, or target.'
    }
    foreach ($name in @('expectedBeforeSha256', 'observedBeforeSha256', 'desiredSha256', 'readbackSha256')) {
        if (-not (Test-HexSha256 -Value ([string]$result[$name]))) {
            throw "Applied change '$($result.changeId)' contains an invalid $name."
        }
        $result[$name] = ([string]$result[$name]).ToUpperInvariant()
    }
    return $result
}

function Write-ImmutableJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $text = ($Value | ConvertTo-Json -Depth 64) + [Environment]::NewLine
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $bytes = $utf8.GetBytes($text)
    $sha256 = Get-Sha256ForBytes -Bytes $bytes
    if ([System.IO.File]::Exists($resolvedPath)) {
        $existingSha = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash
        if ($existingSha.Equals($sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ path = $resolvedPath; sha256 = $sha256; written = $false }
        }
        throw "Immutable evidence already exists with different content: $resolvedPath"
    }
    $directory = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if (-not [System.IO.Directory]::Exists($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($resolvedPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllBytes($temporaryPath, $bytes)
        [System.IO.File]::Move($temporaryPath, $resolvedPath)
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
    return [pscustomobject]@{ path = $resolvedPath; sha256 = $sha256; written = $true }
}

$actionDocument = Read-JsonDocument -Path $ActionPath -Description 'Runner action'
$observationDocument = Read-JsonDocument -Path $ObservationPath -Description 'Runner observation'
$action = $actionDocument.payload
$observation = $observationDocument.payload
Assert-NoSensitiveFields -Value $observation
$identity = Assert-ActionCurrent -Action $action -ActionSha256 $actionDocument.sha256 -ExpectedSha256 $ExpectedActionSha256

if ([int](Get-PropertyValue -Object $observation -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
    throw 'Runner observation schemaVersion must be 1.'
}
if ((Get-RequiredString -Object $observation -Name 'operationId' -Context 'Runner observation') -ne [string]$action.operationId) {
    throw 'Runner observation operationId does not match the immutable action.'
}
if ((Get-RequiredString -Object $observation -Name 'actionId' -Context 'Runner observation') -ne [string]$action.actionId) {
    throw 'Runner observation actionId does not match the immutable action.'
}
if ((Get-RequiredString -Object $observation -Name 'actionKind' -Context 'Runner observation') -ne $identity.actionKind) {
    throw 'Runner observation actionKind does not match the immutable action.'
}
$observedActionSha = Get-RequiredString -Object $observation -Name 'actionRequestSha256' -Context 'Runner observation'
if (-not $observedActionSha.Equals($actionDocument.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Runner observation actionRequestSha256 does not match the immutable action.'
}
$status = Get-RequiredString -Object $observation -Name 'status' -Context 'Runner observation'
if (@('succeeded', 'blocked', 'failed') -notcontains $status) {
    throw "Unsupported runner observation status: $status"
}
$completedAtText = Get-RequiredString -Object $observation -Name 'completedAtUtc' -Context 'Runner observation'
$completedAt = [DateTime]::MinValue
if ((-not [DateTime]::TryParse($completedAtText, [ref]$completedAt)) -or
    ($completedAt.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5))) {
    throw 'Runner observation completedAtUtc is invalid or unreasonably far in the future.'
}
$actionCreatedAt = [DateTime]::MinValue
if ((-not [DateTime]::TryParse([string]$action.createdAtUtc, [ref]$actionCreatedAt)) -or
    ($completedAt.ToUniversalTime() -lt $actionCreatedAt.ToUniversalTime())) {
    throw 'Runner observation predates the immutable action.'
}

$capabilityProperty = $observation.PSObject.Properties['capabilitiesInvoked']
if ($null -eq $capabilityProperty) {
    throw 'Runner observation is missing capabilitiesInvoked.'
}
Assert-JsonArrayProperty -RawJson $observationDocument.raw -PropertyPath @('capabilitiesInvoked') -Context 'Runner observation'
$capabilities = @($capabilityProperty.Value)
$prohibitedCapability = '(?i)(connect[_-]?to[_-]?device|download[_-]?to[_-]?device|start[_-]?stop|write[_-]?variable|read[_-]?variable|monitor[_-]?variables|force|set[_-]?simulation|online|launch[_-]?(codesys|ple|mcp)|watcher[_-]?ipc)'
$approvedOfflineCapabilities = @(
    'get_codesys_status',
    'get_all_pou_code',
    'find_references',
    'inspect_device_node',
    'list_project_libraries',
    'search_code',
    'compile_project',
    'get_compile_messages',
    'set_pou_code'
)
foreach ($capability in $capabilities) {
    if (([string]$capability -notmatch '^[A-Za-z0-9_.-]{1,96}$') -or
        ([string]$capability -match $prohibitedCapability)) {
        throw "Runner observation reports a prohibited or invalid capability: $capability"
    }
    if ($approvedOfflineCapabilities -notcontains [string]$capability) {
        throw "Runner observation reports an unapproved offline capability: $capability"
    }
}
if (($identity.actionKind -ne 'apply_change_set_and_build') -and
    (@($capabilities | Where-Object { [string]$_ -eq 'set_pou_code' }).Count -ne 0)) {
    throw 'Inspect and verify actions cannot report project write capabilities.'
}
if ($status -eq 'succeeded') {
    foreach ($requiredCapability in @('get_codesys_status', 'compile_project', 'get_compile_messages')) {
        if (@($capabilities | Where-Object { [string]$_ -eq $requiredCapability }).Count -ne 1) {
            throw "Successful runner observation must report capability '$requiredCapability' exactly once."
        }
    }
    if ($identity.actionKind -eq 'apply_change_set_and_build') {
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
}

$observedGuardrails = Get-PropertyValue -Object $observation -Name 'guardrails'
$onlineOperationsUsed = Get-RequiredBoolean -Object $observedGuardrails -Name 'onlineOperationsUsed' -Context 'Runner observation guardrails'
$secondPleStarted = Get-RequiredBoolean -Object $observedGuardrails -Name 'secondPleStarted' -Context 'Runner observation guardrails'
$projectLeaseAcquired = Get-RequiredBoolean -Object $observedGuardrails -Name 'projectLeaseAcquired' -Context 'Runner observation guardrails'
$projectLeaseReleased = Get-RequiredBoolean -Object $observedGuardrails -Name 'projectLeaseReleased' -Context 'Runner observation guardrails'
$symbolLeaseHeld = Get-RequiredBoolean -Object $observedGuardrails -Name 'symbolLeaseHeld' -Context 'Runner observation guardrails'
$pleOrMcpStarted = Get-RequiredBoolean -Object $observedGuardrails -Name 'pleOrMcpStarted' -Context 'Runner observation guardrails'
$directWatcherIpcUsed = Get-RequiredBoolean -Object $observedGuardrails -Name 'directWatcherIpcUsed' -Context 'Runner observation guardrails'
$leaseScope = Get-RequiredString -Object $observedGuardrails -Name 'projectLeaseScope' -Context 'Runner observation guardrails'
if ($leaseScope -ne 'workflow-local') {
    throw "Unsupported project lease scope: $leaseScope"
}
if ($onlineOperationsUsed -or $secondPleStarted -or (-not $projectLeaseReleased) -or $symbolLeaseHeld -or
    $pleOrMcpStarted -or $directWatcherIpcUsed) {
    throw 'Runner observation violates the offline, single-PLE, or released-lease guardrail.'
}
if (($status -eq 'succeeded') -and (-not $projectLeaseAcquired)) {
    throw 'A successful runner observation must explicitly record an acquired project lease.'
}

$observedResult = Get-PropertyValue -Object $observation -Name 'result'
Assert-JsonArrayProperty -RawJson $observationDocument.raw -PropertyPath @('result', 'proposedChanges') -Context 'Runner observation'
Assert-JsonArrayProperty -RawJson $observationDocument.raw -PropertyPath @('result', 'appliedChanges') -Context 'Runner observation'
$terminalObservation = @('blocked', 'failed') -contains $status
if ($terminalObservation) {
    if ($null -ne $observation.PSObject.Properties['session']) {
        throw 'Blocked/failed runner observation must not contain a session object.'
    }
    foreach ($name in @('build', 'acceptance')) {
        if ($null -ne $observedResult.PSObject.Properties[$name]) {
            throw "Blocked/failed runner observation must not contain result.$name."
        }
    }
}
$repairRequired = Get-RequiredBoolean -Object $observedResult -Name 'repairRequired' -Context 'Runner observation result'
$requiresSecondExport = Get-RequiredBoolean -Object $observedResult -Name 'requiresSecondExport' -Context 'Runner observation result'
$requiresCpStudioChange = Get-RequiredBoolean -Object $observedResult -Name 'requiresCpStudioChange' -Context 'Runner observation result'
if (($repairRequired -and $requiresSecondExport) -or
    ($requiresCpStudioChange -and ($repairRequired -or $requiresSecondExport))) {
    throw 'Runner observation routing flags are mutually exclusive.'
}
if (($status -ne 'succeeded') -and ($repairRequired -or $requiresSecondExport -or $requiresCpStudioChange)) {
    throw 'A blocked or failed runner observation cannot request another workflow route.'
}
if ($repairRequired -and ($identity.actionKind -ne 'inspect_and_build')) {
    throw 'Only inspect_and_build may report repairRequired=true.'
}
if (($identity.actionKind -eq 'verify_after_export_2') -and $requiresSecondExport) {
    throw 'verify_after_export_2 cannot request another Export #2.'
}

$rawProposedChanges = @(Get-PropertyValue -Object $observedResult -Name 'proposedChanges' -DefaultValue @())
$proposedChanges = @()
foreach ($change in $rawProposedChanges) {
    $proposedChanges += ConvertTo-ProposedChangeEvidence -Change $change
}
if ($repairRequired -and ($proposedChanges.Count -eq 0)) {
    throw 'repairRequired=true requires at least one projected proposed change.'
}
if ((-not $repairRequired) -and ($proposedChanges.Count -ne 0)) {
    throw 'proposedChanges must be empty when repairRequired=false.'
}

$rawAppliedChanges = @(Get-PropertyValue -Object $observedResult -Name 'appliedChanges' -DefaultValue @())
$appliedChanges = @()
foreach ($change in $rawAppliedChanges) {
    $appliedChanges += ConvertTo-AppliedChangeEvidence -Change $change
}
$requestedChanges = @(Get-PropertyValue -Object $action -Name 'changeSet' -DefaultValue @())
if ($identity.actionKind -eq 'apply_change_set_and_build') {
    if (($status -eq 'succeeded') -and ($requestedChanges.Count -ne $appliedChanges.Count)) {
        throw 'Applied evidence must contain one result per requested action change.'
    }
    if ($appliedChanges.Count -gt $requestedChanges.Count) {
        throw 'Applied evidence contains more results than the immutable action change set.'
    }
    $seenAppliedIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    foreach ($applied in $appliedChanges) {
        $appliedId = [string]$applied['changeId']
        if (-not $seenAppliedIds.Add($appliedId)) {
            throw "Applied evidence contains duplicate change '$appliedId'."
        }
        $matches = @($requestedChanges | Where-Object { [string]$_.changeId -eq $appliedId })
        if ($matches.Count -ne 1) {
            throw "Applied evidence does not uniquely match requested change '$appliedId'."
        }
        $requested = $matches[0]
        $expectedBefore = Get-RequiredString -Object (Get-PropertyValue -Object $requested -Name 'expectedBefore') -Name 'sha256' -Context "Requested change '$appliedId' expectedBefore"
        $desired = Get-RequiredString -Object (Get-PropertyValue -Object $requested -Name 'desired') -Name 'sha256' -Context "Requested change '$appliedId' desired"
        if (([string]$applied['targetPath'] -ne [string]$requested.targetPath) -or
            (-not ([string]$applied['expectedBeforeSha256']).Equals($expectedBefore, [System.StringComparison]::OrdinalIgnoreCase)) -or
            (-not ([string]$applied['observedBeforeSha256']).Equals($expectedBefore, [System.StringComparison]::OrdinalIgnoreCase)) -or
            (-not ([string]$applied['desiredSha256']).Equals($desired, [System.StringComparison]::OrdinalIgnoreCase)) -or
            (-not ([string]$applied['readbackSha256']).Equals($desired, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Applied evidence hash/readback mismatch for requested change '$appliedId'."
        }
    }
    if (($status -ne 'succeeded') -and ($appliedChanges.Count -ne 0)) {
        if ((@($capabilities | Where-Object { [string]$_ -eq 'set_pou_code' }).Count -lt 1) -or
            (@($capabilities | Where-Object { [string]$_ -match '^(get_all_pou_code|search_code|find_references)$' }).Count -lt 1)) {
            throw 'Terminal apply evidence with applied changes must report write and readback capabilities.'
        }
    }
}
elseif ($appliedChanges.Count -ne 0) {
    throw 'appliedChanges must be empty for a non-apply runner action.'
}

$evidenceResult = [ordered]@{
    status                 = $status
    verificationOk         = Get-RequiredBoolean -Object $observedResult -Name 'verificationOk' -Context 'Runner observation result'
    appliedReadbackOk      = Get-RequiredBoolean -Object $observedResult -Name 'appliedReadbackOk' -Context 'Runner observation result'
    repairRequired         = $repairRequired
    requiresSecondExport   = $requiresSecondExport
    requiresCpStudioChange = $requiresCpStudioChange
    proposedChanges        = @($proposedChanges)
    appliedChanges         = @($appliedChanges)
}
$evidenceSession = $null

if ($status -eq 'succeeded') {
    $session = Get-PropertyValue -Object $observation -Name 'session'
    if ($null -eq $session) {
        throw 'A successful runner observation must contain the reused persistent session identity.'
    }
    $sessionState = Get-RequiredString -Object $session -Name 'state' -Context 'Runner session'
    $sessionMode = Get-RequiredString -Object $session -Name 'mode' -Context 'Runner session'
    $sessionId = Get-RequiredString -Object $session -Name 'sessionId' -Context 'Runner session'
    $sessionPid = [int](Get-PropertyValue -Object $session -Name 'plePid' -DefaultValue 0)
    $sessionProfile = Get-RequiredString -Object $session -Name 'profile' -Context 'Runner session'
    $activeProjectPath = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $session -Name 'activeProjectPath' -Context 'Runner session'))
    $sessionStartedByRunner = Get-RequiredBoolean -Object $session -Name 'startedByRunner' -Context 'Runner session'
    if (($sessionState -ne 'ready') -or ($sessionMode -ne 'persistent') -or
        ($sessionId -notmatch '^[A-Za-z0-9_.-]{1,128}$') -or ($sessionPid -le 0) -or
        ($sessionProfile -ne $identity.profile) -or $sessionStartedByRunner -or
        (-not $activeProjectPath.Equals($identity.plcProject, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Observed persistent session does not match the required ready/profile/project identity.'
    }
    $evidenceSession = [ordered]@{
        state             = $sessionState
        mode              = $sessionMode
        sessionId         = $sessionId
        plePid            = $sessionPid
        profile           = $sessionProfile
        activeProjectPath = $activeProjectPath
        startedByRunner   = $sessionStartedByRunner
    }

    $build = Get-PropertyValue -Object $observedResult -Name 'build'
    if ($null -eq $build) {
        throw 'A successful runner observation must contain fresh Build data.'
    }
    Assert-JsonArrayProperty -RawJson $observationDocument.raw -PropertyPath @('result', 'build', 'warningRecords') -Context 'Runner observation'
    $buildStarted = [DateTime]::MinValue
    $buildCompleted = [DateTime]::MinValue
    if ((-not [DateTime]::TryParse((Get-RequiredString -Object $build -Name 'startedAtUtc' -Context 'Observed Build'), [ref]$buildStarted)) -or
        (-not [DateTime]::TryParse((Get-RequiredString -Object $build -Name 'completedAtUtc' -Context 'Observed Build'), [ref]$buildCompleted)) -or
        ($buildStarted.ToUniversalTime() -lt $actionCreatedAt.ToUniversalTime()) -or
        ($buildCompleted.ToUniversalTime() -lt $buildStarted.ToUniversalTime()) -or
        ($buildCompleted.ToUniversalTime() -gt $completedAt.ToUniversalTime())) {
        throw 'Observed Build timestamps are not fresh for this action.'
    }
    $errors = [int](Get-PropertyValue -Object $build -Name 'errors' -DefaultValue -1)
    $warnings = [int](Get-PropertyValue -Object $build -Name 'warnings' -DefaultValue -1)
    if (($errors -lt 0) -or ($warnings -lt 0)) {
        throw 'Observed Build errors/warnings counts must be non-negative.'
    }
    $observedBuildProject = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $build -Name 'projectPath' -Context 'Observed Build'))
    $observedBuildProfile = Get-RequiredString -Object $build -Name 'profile' -Context 'Observed Build'
    $observedBuildSha = Get-RequiredString -Object $build -Name 'projectSha256' -Context 'Observed Build'
    $currentProjectSha = (Get-FileHash -LiteralPath $identity.plcProject -Algorithm SHA256).Hash
    if ((-not $observedBuildProject.Equals($identity.plcProject, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ($observedBuildProfile -ne $identity.profile) -or
        ($observedBuildSha -notmatch '^[A-Fa-f0-9]{64}$') -or
        (-not $observedBuildSha.Equals($currentProjectSha, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Observed Build project/profile/SHA does not match the action and current PLC project.'
    }
    $buildId = Get-RequiredString -Object $build -Name 'buildId' -Context 'Observed Build'
    $summarySource = Get-RequiredString -Object $build -Name 'summarySource' -Context 'Observed Build'
    if (($buildId -notmatch '^[A-Za-z0-9_.:-]{1,128}$') -or
        ($summarySource -ne 'codesys-persistent.compile_project')) {
        throw 'Observed Build has an unsafe buildId or unsupported summarySource.'
    }
    $warningRecords = @(Get-PropertyValue -Object $build -Name 'warningRecords' -DefaultValue @())
    $warningSignatures = Get-WarningSignatureMultiset -Records $warningRecords -ExpectedCount $warnings
    $evidenceResult.build = [ordered]@{
        buildId           = $buildId
        projectPath       = $observedBuildProject
        profile           = $observedBuildProfile
        projectSha256     = $observedBuildSha.ToUpperInvariant()
        startedAtUtc      = $buildStarted.ToUniversalTime().ToString('o')
        completedAtUtc    = $buildCompleted.ToUniversalTime().ToString('o')
        verified          = Get-RequiredBoolean -Object $build -Name 'verified' -Context 'Observed Build'
        errors            = $errors
        warnings          = $warnings
        signatureComplete = $true
        signatureAlgorithm = 'sha256:v1:normalized-warning-record'
        summarySource     = $summarySource
        warningSignatures = @($warningSignatures)
    }

    $acceptance = Get-PropertyValue -Object $observedResult -Name 'acceptance'
    $evidenceResult.acceptance = [ordered]@{}
    foreach ($name in @('ownershipVerified', 'mappingConsistent', 'readbackVerified', 'recoverableBaselineVerified', 'warningSignaturesReviewed', 'existingSessionReused', 'pleOrMcpStarted', 'directWatcherIpcUsed', 'symbolPostProcessingVerified')) {
        $evidenceResult.acceptance[$name] = Get-RequiredBoolean -Object $acceptance -Name $name -Context 'Runner observation acceptance'
    }
    foreach ($name in @('ownershipVerified', 'mappingConsistent', 'readbackVerified', 'recoverableBaselineVerified', 'warningSignaturesReviewed', 'existingSessionReused')) {
        if (-not [bool]$evidenceResult.acceptance[$name]) {
            throw "Runner observation acceptance did not prove '$name'."
        }
    }
    if ($evidenceResult.acceptance.pleOrMcpStarted -or $evidenceResult.acceptance.directWatcherIpcUsed) {
        throw 'Runner observation reports that it started PLE/MCP or used direct watcher IPC.'
    }
    if ((-not $requiresSecondExport) -and (-not $requiresCpStudioChange) -and
        (-not $evidenceResult.acceptance.symbolPostProcessingVerified)) {
        throw 'Runner observation did not prove Symbol post-processing.'
    }
    if ($requiresSecondExport -and ($errors -ne 0)) {
        throw 'Export #2 cannot be requested until the observed Build has zero errors.'
    }
    if ($identity.actionKind -eq 'apply_change_set_and_build') {
        if ((-not [bool]$evidenceResult.appliedReadbackOk) -or ($errors -ne 0)) {
            throw 'Apply action evidence requires exact readback and a zero-error Build.'
        }
    }
}
else {
    $failureStage = Get-RequiredString -Object $observedResult -Name 'failureStage' -Context 'Runner observation result'
    $reasonCode = Get-RequiredString -Object $observedResult -Name 'reasonCode' -Context 'Runner observation result'
    if (($failureStage -notmatch '^[A-Za-z0-9_.-]{1,64}$') -or
        ($reasonCode -notmatch '^[A-Za-z0-9_.-]{1,96}$')) {
        throw 'Blocked/failed runner stage and reason code must be safe identifiers.'
    }
    $evidenceResult.failureStage = $failureStage
    $evidenceResult.reasonCode = $reasonCode
}

$evidence = [ordered]@{
    schemaVersion       = 1
    operationId         = Get-RequiredString -Object $action -Name 'operationId' -Context 'Runner action'
    actionId            = Get-RequiredString -Object $action -Name 'actionId' -Context 'Runner action'
    actionKind          = $identity.actionKind
    actionRequestSha256 = $actionDocument.sha256
    completedAtUtc      = $completedAt.ToUniversalTime().ToString('o')
    project             = [ordered]@{
        engineeringRoot = $identity.engineeringRoot
        stationRoot     = $identity.stationRoot
        plcProject      = $identity.plcProject
        profile         = $identity.profile
    }
    capabilitiesInvoked = @($capabilities)
    guardrails          = [ordered]@{
        onlineOperationsUsed = $onlineOperationsUsed
        secondPleStarted     = $secondPleStarted
        projectLeaseAcquired = $projectLeaseAcquired
        projectLeaseReleased = $projectLeaseReleased
        projectLeaseScope    = $leaseScope
        symbolLeaseHeld      = $symbolLeaseHeld
        pleOrMcpStarted      = $pleOrMcpStarted
        directWatcherIpcUsed = $directWatcherIpcUsed
    }
    result              = $evidenceResult
}
if ($null -ne $evidenceSession) {
    $evidence.session = $evidenceSession
}
Assert-NoSensitiveFields -Value $evidence

$resolvedOutputPath = Assert-PathInsideRoot -Root (Join-Path $identity.engineeringRoot 'data\runner-evidence') -Path $OutputPath -Description 'Runner evidence output'
if ($requestedWhatIf -or (-not $PSCmdlet.ShouldProcess($resolvedOutputPath, 'Write immutable runner evidence'))) {
    [pscustomobject]@{
        status   = 'WHATIF'
        path     = $resolvedOutputPath
        actionId = $evidence.actionId
        evidence = $evidence
    }
    return
}

$writeResult = Write-ImmutableJson -Path $resolvedOutputPath -Value $evidence
[pscustomobject]@{
    status   = if ($writeResult.written) { 'WRITTEN' } else { 'UNCHANGED' }
    path     = $writeResult.path
    sha256   = $writeResult.sha256
    actionId = $evidence.actionId
}
