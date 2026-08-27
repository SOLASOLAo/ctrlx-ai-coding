[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)][string]$EvidencePath,
    [Parameter(Mandatory = $false)][string]$EngineeringRoot = (Join-Path $PSScriptRoot '..\..'),
    [Parameter(Mandatory = $false)][string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$requestedWhatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false

$signatureAlgorithm = 'sha256:v1:normalized-warning-record'
$maximumInputBytes = 2 * 1024 * 1024
$maximumCandidateBytes = 1024 * 1024
$maximumWarningCount = 2048

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $Object) { return $DefaultValue }
    if ($Object -is [System.Collections.IDictionary]) {
        $contains = if ($null -ne $Object.PSObject.Methods['ContainsKey']) {
            [bool]$Object.ContainsKey($Name)
        }
        else {
            [bool]$Object.Contains($Name)
        }
        if (-not $contains) { return $DefaultValue }
        $value = $Object[$Name]
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $DefaultValue }
        $value = $property.Value
    }
    if ($value -is [System.Array]) { Write-Output -NoEnumerate $value }
    else { return $value }
}

function Get-PropertyNames {
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

    if (($null -eq $Object) -or
        (($Object -isnot [System.Collections.IDictionary]) -and ($Object -isnot [pscustomobject]))) {
        throw "$Context must be a JSON object."
    }
    $actual = @(Get-PropertyNames -Object $Object | Sort-Object -Unique)
    $expected = @($Allowed | Sort-Object -Unique)
    if (($actual.Count -ne $expected.Count) -or (($actual -join '|') -ne ($expected -join '|'))) {
        throw "$Context contains unsupported or missing fields. Expected: $($expected -join ', ')."
    }
}

function Get-RequiredObject {
    param([object]$Object, [string]$Name, [string]$Context)

    $value = Get-PropertyValue -Object $Object -Name $Name
    if (($null -eq $value) -or
        (($value -isnot [System.Collections.IDictionary]) -and ($value -isnot [pscustomobject]))) {
        throw "$Context has no JSON object '$Name'."
    }
    return $value
}

function Get-RequiredArray {
    param([object]$Object, [string]$Name, [string]$Context)

    $missing = New-Object object
    $value = Get-PropertyValue -Object $Object -Name $Name -DefaultValue $missing
    if ([object]::ReferenceEquals($missing, $value) -or ($null -eq $value) -or ($value -isnot [System.Array])) {
        throw "$Context '$Name' must be a JSON array (including for a singleton)."
    }
    Write-Output -NoEnumerate ([object[]]$value)
}

function Get-RequiredString {
    param([object]$Object, [string]$Name, [string]$Context, [switch]$AllowEmpty)

    $missing = New-Object object
    $value = Get-PropertyValue -Object $Object -Name $Name -DefaultValue $missing
    if ([object]::ReferenceEquals($missing, $value) -or ($value -isnot [string])) {
        throw "$Context has no string '$Name'."
    }
    $text = [string]$value
    if (((-not $AllowEmpty) -and [string]::IsNullOrWhiteSpace($text)) -or ($text -match '[\x00-\x1F]')) {
        throw "$Context has an empty or unsafe '$Name'."
    }
    return $text
}

function Get-RequiredBoolean {
    param([object]$Object, [string]$Name, [string]$Context)

    $missing = New-Object object
    $value = Get-PropertyValue -Object $Object -Name $Name -DefaultValue $missing
    if ([object]::ReferenceEquals($missing, $value) -or ($value -isnot [bool])) {
        throw "$Context must explicitly provide Boolean '$Name'."
    }
    return [bool]$value
}

function Get-RequiredInt32 {
    param([object]$Object, [string]$Name, [string]$Context, [int]$Minimum = 0)

    $value = Get-PropertyValue -Object $Object -Name $Name
    if ((($value -isnot [int]) -and ($value -isnot [long])) -or
        ([long]$value -lt $Minimum) -or ([long]$value -gt [int]::MaxValue)) {
        throw "$Context '$Name' must be a bounded JSON integer."
    }
    return [int]$value
}

function Assert-HexSha256 {
    param([string]$Value, [string]$Context)

    if ($Value -notmatch '^[A-Fa-f0-9]{64}$') { throw "$Context must be a SHA-256 hex digest." }
}

function Assert-PathInsideRoot {
    param([string]$Root, [string]$Path, [string]$Context)

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if ((-not $candidate.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) -and
        (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Context escaped its configured root: $candidate"
    }
    return $candidate
}

function Get-RelativePathInsideRoot {
    param([string]$Root, [string]$Path, [string]$Context)

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = Assert-PathInsideRoot -Root $rootPath -Path $Path -Context $Context
    if ($candidate.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $candidate.Substring($rootPath.Length + 1).Replace('\', '/')
}

function Read-JsonDocumentExact {
    param([string]$Path, [string]$Context, [int]$MaximumBytes)

    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($resolved)) { throw "$Context does not exist: $resolved" }
    $bytes = [System.IO.File]::ReadAllBytes($resolved)
    if (($bytes.Length -eq 0) -or ($bytes.Length -gt $MaximumBytes)) {
        throw "$Context exceeds its bounded JSON contract."
    }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false, $true
        $text = $utf8.GetString($bytes)
        if (($text.Length -gt 0) -and ($text[0] -eq [char]0xFEFF)) { $text = $text.Substring(1) }
        $desktop = (-not $PSVersionTable.ContainsKey('PSEdition')) -or ($PSVersionTable.PSEdition -eq 'Desktop')
        if ($desktop) {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength = $MaximumBytes
            $serializer.RecursionLimit = 256
            $payload = $serializer.DeserializeObject($text)
        }
        else {
            $arguments = @{ InputObject = $text }
            $command = Get-Command ConvertFrom-Json -ErrorAction Stop
            if ($command.Parameters.ContainsKey('AsHashtable')) { $arguments['AsHashtable'] = $true }
            if ($command.Parameters.ContainsKey('Depth')) { $arguments['Depth'] = 256 }
            if ($command.Parameters.ContainsKey('DateKind')) { $arguments['DateKind'] = 'String' }
            $payload = ConvertFrom-Json @arguments
        }
    }
    catch {
        throw "$Context is not valid UTF-8 JSON. $($_.Exception.Message)"
    }
    if (($null -eq $payload) -or
        (($payload -isnot [System.Collections.IDictionary]) -and ($payload -isnot [pscustomobject]))) {
        throw "$Context root must be a JSON object."
    }
    return [pscustomobject]@{ path = $resolved; bytes = $bytes; payload = $payload }
}

function Get-Sha256ForBytes {
    param([byte[]]$Bytes)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-Sha256ForText {
    param([string]$Text)

    return Get-Sha256ForBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Add-CanonicalJsonString {
    param([AllowEmptyString()][string]$Value, [System.Text.StringBuilder]$Builder)

    [void]$Builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        switch ([int]$character) {
            0x08 { [void]$Builder.Append('\b'); continue }
            0x09 { [void]$Builder.Append('\t'); continue }
            0x0A { [void]$Builder.Append('\n'); continue }
            0x0C { [void]$Builder.Append('\f'); continue }
            0x0D { [void]$Builder.Append('\r'); continue }
            0x22 { [void]$Builder.Append('\"'); continue }
            0x5C { [void]$Builder.Append('\\'); continue }
        }
        if ([int]$character -lt 0x20) { [void]$Builder.Append(('\u{0:x4}' -f [int]$character)) }
        else { [void]$Builder.Append($character) }
    }
    [void]$Builder.Append('"')
}

function Add-CanonicalJsonValue {
    param([AllowNull()][object]$Value, [System.Text.StringBuilder]$Builder, [int]$Depth)

    if ($Depth -gt 128) { throw 'Canonical JSON exceeds the maximum depth.' }
    if ($null -eq $Value) { [void]$Builder.Append('null'); return }
    if ($Value -is [string]) { Add-CanonicalJsonString -Value ([string]$Value) -Builder $Builder; return }
    if ($Value -is [bool]) { [void]$Builder.Append($(if ([bool]$Value) { 'true' } else { 'false' })); return }
    if (($Value -is [byte]) -or ($Value -is [sbyte]) -or ($Value -is [int16]) -or
        ($Value -is [uint16]) -or ($Value -is [int]) -or ($Value -is [uint32]) -or
        ($Value -is [long]) -or ($Value -is [uint64])) {
        [void]$Builder.Append([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
        return
    }
    if ($Value -is [System.Array]) {
        [void]$Builder.Append('[')
        for ($index = 0; $index -lt $Value.Count; $index++) {
            if ($index -gt 0) { [void]$Builder.Append(',') }
            Add-CanonicalJsonValue -Value $Value[$index] -Builder $Builder -Depth ($Depth + 1)
        }
        [void]$Builder.Append(']')
        return
    }
    if (($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject])) {
        $names = [string[]]@(Get-PropertyNames -Object $Value)
        [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
        [void]$Builder.Append('{')
        for ($index = 0; $index -lt $names.Count; $index++) {
            if ($index -gt 0) { [void]$Builder.Append(',') }
            Add-CanonicalJsonString -Value $names[$index] -Builder $Builder
            [void]$Builder.Append(':')
            Add-CanonicalJsonValue -Value (Get-PropertyValue -Object $Value -Name $names[$index]) -Builder $Builder -Depth ($Depth + 1)
        }
        [void]$Builder.Append('}')
        return
    }
    throw "Canonical JSON does not support value type '$($Value.GetType().FullName)'."
}

function ConvertTo-CanonicalJson {
    param([AllowNull()][object]$Value)

    $builder = New-Object System.Text.StringBuilder
    Add-CanonicalJsonValue -Value $Value -Builder $builder -Depth 0
    return $builder.ToString()
}

function Test-ClearlyRedactedSensitiveValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $true }
    if ($Value -isnot [string]) { return $false }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $true }
    if (($text.Length -ge 2) -and
        ((($text[0] -eq '"') -and ($text[$text.Length - 1] -eq '"')) -or
         (($text[0] -eq "'") -and ($text[$text.Length - 1] -eq "'")))) {
        $text = $text.Substring(1, $text.Length - 2).Trim()
    }
    return $text -match '^(?i:<\s*(?:redacted|masked|removed|not[-_ ]?set)\s*>|\*{3,}|x{6,}|redacted|masked|removed|not[-_ ]?set|null|none|n/?a|\$\{[A-Za-z_][A-Za-z0-9_]*\}|%[A-Za-z_][A-Za-z0-9_]*%|\$env:[A-Za-z_][A-Za-z0-9_]*)$'
}

function Test-StringContainsSecretLikeValue {
    param([AllowEmptyString()][string]$Text)

    if ($Text -match '(?i)-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----') { return $true }

    $assignmentPattern = '(?i)(?<![A-Za-z0-9_])(?:password|passwd|pwd|secret|client[_-]?secret|api[_-]?key|access[_-]?key(?:[_-]?id)?|secret[_-]?key|shared[_-]?access[_-]?key|shared[_-]?access[_-]?signature|account[_-]?key|access[_-]?token|refresh[_-]?token|auth(?:orization)?[_-]?token|bearer[_-]?token|sas[_-]?token|private[_-]?key|credential(?:s)?|token)\s*[:=]\s*(?<value>"[^"\r\n]{1,4096}"|''[^''\r\n]{1,4096}''|[^\s;,}\]\r\n]{1,4096})'
    foreach ($match in [regex]::Matches($Text, $assignmentPattern)) {
        if (-not (Test-ClearlyRedactedSensitiveValue -Value $match.Groups['value'].Value)) { return $true }
    }

    $connectionUriPattern = '(?i)\b[a-z][a-z0-9+.-]{1,20}://[^/\s:@]{1,256}:(?<value>[^/\s@]{1,4096})@'
    foreach ($match in [regex]::Matches($Text, $connectionUriPattern)) {
        if (-not (Test-ClearlyRedactedSensitiveValue -Value $match.Groups['value'].Value)) { return $true }
    }

    $bearerPattern = '(?i)(?<![A-Za-z0-9_-])Bearer[ \t]+(?<value>[A-Za-z0-9._~+/=%-]{12,8192})(?![A-Za-z0-9._~+/=%-])'
    foreach ($match in [regex]::Matches($Text, $bearerPattern)) {
        $token = $match.Groups['value'].Value
        if (($token.Length -ge 24) -or ($token -match '[0-9._~+/=%-]')) { return $true }
    }
    return $false
}

function Assert-NoSecrets {
    param([AllowNull()][object]$Value, [string]$Path = '$', [int]$Depth = 0, [AllowNull()][object]$State = $null)

    if ($Depth -gt 128) { throw "Sensitive-value scan exceeded its maximum depth at $Path." }
    if ($null -eq $State) { $State = [pscustomobject]@{ nodes = [long]0; stringBytes = [long]0 } }
    $State.nodes = [long]$State.nodes + 1
    if ([long]$State.nodes -gt 200000) { throw 'Sensitive-value scan exceeded its bounded node budget.' }
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        $byteCount = [System.Text.Encoding]::UTF8.GetByteCount([string]$Value)
        $State.stringBytes = [long]$State.stringBytes + $byteCount
        if (($byteCount -gt (64 * 1024)) -or ([long]$State.stringBytes -gt (8 * 1024 * 1024))) {
            throw "Sensitive-value scan exceeded its bounded string budget at $Path."
        }
        if (Test-StringContainsSecretLikeValue -Text ([string]$Value)) {
            throw "Secret-like content is prohibited at $Path."
        }
        return
    }
    if ($Value -is [ValueType]) { return }
    if (($Value -is [System.Array]) -or ($Value -is [System.Collections.IList])) {
        $index = 0
        foreach ($item in $Value) {
            Assert-NoSecrets -Value $item -Path ($Path + '[' + $index + ']') -Depth ($Depth + 1) -State $State
            $index++
        }
        return
    }
    if (($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject])) {
        foreach ($name in @(Get-PropertyNames -Object $Value)) {
            $nameBytes = [System.Text.Encoding]::UTF8.GetByteCount([string]$name)
            $State.stringBytes = [long]$State.stringBytes + $nameBytes
            if (($nameBytes -gt 4096) -or ([long]$State.stringBytes -gt (8 * 1024 * 1024))) {
                throw "Sensitive-value scan exceeded its bounded property-name budget at $Path."
            }
            if (Test-StringContainsSecretLikeValue -Text ([string]$name)) {
                throw "Secret-like content is prohibited in a property name below $Path."
            }
            $child = Get-PropertyValue -Object $Value -Name $name
            if (([string]$name -match '^(?i:password|passwd|pwd|secret|client[_-]?secret|api[_-]?key|access[_-]?key|secret[_-]?key|shared[_-]?access[_-]?key|account[_-]?key|access[_-]?token|refresh[_-]?token|auth(?:orization)?[_-]?token|bearer[_-]?token|sas[_-]?token|private[_-]?key|credential|credentials)$') -and
                (-not (Test-ClearlyRedactedSensitiveValue -Value $child))) {
                throw "Secret-bearing field is prohibited at $Path.$name."
            }
            Assert-NoSecrets -Value $child -Path ($Path + '.' + $name) -Depth ($Depth + 1) -State $State
        }
        return
    }
    throw "Unsupported value type during sensitive-value scan at $Path."
}

function Get-NormalizedWarningRecord {
    param([string]$Value)

    $normalized = ([regex]'\s+').Replace($Value.Trim(), ' ')
    if ([string]::IsNullOrWhiteSpace($normalized)) { throw 'Warning records cannot be empty.' }
    return $normalized
}

function Get-WarningRecordSignature {
    param([string]$Value)

    $canonical = [ordered]@{
        code = ''
        message = Get-NormalizedWarningRecord -Value $Value
        objectPath = ''
        position = ''
        source = ''
    }
    return (Get-Sha256ForText -Text (ConvertTo-CanonicalJson -Value $canonical)).ToUpperInvariant()
}

function Get-ValidatedWarningReview {
    param(
        [object]$Evidence,
        [string]$ExpectedEngineeringRoot
    )

    Assert-ExactPropertySet -Object $Evidence -Allowed @(
        'schemaVersion', 'operationId', 'actionId', 'actionKind', 'actionRequestSha256',
        'completedAtUtc', 'project', 'capabilitiesInvoked', 'guardrails', 'result'
    ) -Context 'Runner evidence'
    if ((Get-RequiredInt32 -Object $Evidence -Name 'schemaVersion' -Context 'Runner evidence') -ne 1) {
        throw 'Runner evidence schemaVersion is unsupported.'
    }
    $operationId = Get-RequiredString -Object $Evidence -Name 'operationId' -Context 'Runner evidence'
    $actionId = Get-RequiredString -Object $Evidence -Name 'actionId' -Context 'Runner evidence'
    if (($operationId -notmatch '^[A-Za-z0-9_.-]{1,160}$') -or ($actionId -notmatch '^[A-Za-z0-9_.-]{1,160}$')) {
        throw 'Runner evidence operationId/actionId is unsafe.'
    }
    $actionRequestSha = Get-RequiredString -Object $Evidence -Name 'actionRequestSha256' -Context 'Runner evidence'
    Assert-HexSha256 -Value $actionRequestSha -Context 'Runner evidence actionRequestSha256'
    if ((Get-RequiredString -Object $Evidence -Name 'actionKind' -Context 'Runner evidence') -notin @('inspect_and_build', 'verify_after_export_2')) {
        throw 'Only read-only inspection evidence can produce a warning baseline candidate.'
    }

    $project = Get-RequiredObject -Object $Evidence -Name 'project' -Context 'Runner evidence'
    Assert-ExactPropertySet -Object $project -Allowed @('engineeringRoot', 'stationRoot', 'plcProject', 'profile') -Context 'Runner evidence project'
    $evidenceEngineeringRoot = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $project -Name 'engineeringRoot' -Context 'Runner evidence project'))
    if (-not $evidenceEngineeringRoot.Equals($ExpectedEngineeringRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runner evidence belongs to another engineering root.'
    }
    $stationRoot = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $project -Name 'stationRoot' -Context 'Runner evidence project'))
    $plcProject = Assert-PathInsideRoot -Root $stationRoot -Path (Get-RequiredString -Object $project -Name 'plcProject' -Context 'Runner evidence project') -Context 'Runner evidence PLC project'
    $profile = Get-RequiredString -Object $project -Name 'profile' -Context 'Runner evidence project'
    if (-not [System.IO.File]::Exists($plcProject)) { throw 'Runner evidence PLC project no longer exists.' }

    $capabilities = Get-RequiredArray -Object $Evidence -Name 'capabilitiesInvoked' -Context 'Runner evidence'
    $allowedCapabilities = @('get_codesys_status', 'compile_project', 'get_ctrlx_semantic_snapshot')
    if (($capabilities.Count -lt 2) -or ($capabilities.Count -gt 3) -or
        (@($capabilities | Where-Object { $_ -isnot [string] -or $allowedCapabilities -notcontains [string]$_ }).Count -ne 0) -or
        (@($capabilities | Where-Object { [string]$_ -eq 'get_codesys_status' }).Count -ne 1) -or
        (@($capabilities | Where-Object { [string]$_ -eq 'compile_project' }).Count -ne 1) -or
        (@($capabilities | Where-Object { [string]$_ -eq 'get_ctrlx_semantic_snapshot' }).Count -gt 1)) {
        throw 'Runner evidence does not prove one approved offline fresh Build.'
    }

    $guardrails = Get-RequiredObject -Object $Evidence -Name 'guardrails' -Context 'Runner evidence'
    Assert-ExactPropertySet -Object $guardrails -Allowed @(
        'onlineOperationsUsed', 'secondPleStarted', 'actionProjectGateAcquired',
        'actionProjectGateReleased', 'actionProjectGateKind', 'symbolLeaseHeld',
        'pleOrMcpStartedByAction', 'directWatcherIpcUsed'
    ) -Context 'Runner evidence guardrails'
    if ((Get-RequiredBoolean -Object $guardrails -Name 'onlineOperationsUsed' -Context 'Runner evidence guardrails') -or
        (Get-RequiredBoolean -Object $guardrails -Name 'secondPleStarted' -Context 'Runner evidence guardrails') -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'actionProjectGateAcquired' -Context 'Runner evidence guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'actionProjectGateReleased' -Context 'Runner evidence guardrails')) -or
        ((Get-RequiredString -Object $guardrails -Name 'actionProjectGateKind' -Context 'Runner evidence guardrails') -ne 'broker-session-action-serialization') -or
        (Get-RequiredBoolean -Object $guardrails -Name 'symbolLeaseHeld' -Context 'Runner evidence guardrails') -or
        (Get-RequiredBoolean -Object $guardrails -Name 'pleOrMcpStartedByAction' -Context 'Runner evidence guardrails') -or
        (Get-RequiredBoolean -Object $guardrails -Name 'directWatcherIpcUsed' -Context 'Runner evidence guardrails')) {
        throw 'Runner evidence violates the offline/single-owner guardrails.'
    }

    $result = Get-RequiredObject -Object $Evidence -Name 'result' -Context 'Runner evidence'
    Assert-ExactPropertySet -Object $result -Allowed @(
        'status', 'verificationOk', 'appliedReadbackOk', 'repairRequired',
        'requiresSecondExport', 'requiresCpStudioChange', 'proposedChanges',
        'appliedChanges', 'semanticProofs', 'nextRoute', 'build', 'failureStage',
        'reasonCode'
    ) -Context 'Runner evidence result'
    if ((Get-RequiredString -Object $result -Name 'status' -Context 'Runner evidence result') -ne 'blocked' -or
        (Get-RequiredString -Object $result -Name 'failureStage' -Context 'Runner evidence result') -ne 'semantic-acceptance') {
        throw 'Only semantic-acceptance BLOCKED evidence can produce a warning baseline candidate.'
    }
    $resultReason = Get-RequiredString -Object $result -Name 'reasonCode' -Context 'Runner evidence result'
    if ($resultReason -notmatch '^[A-Z0-9_]{1,120}$') { throw 'Runner evidence result reasonCode is unsafe.' }
    if ((Get-RequiredBoolean -Object $result -Name 'verificationOk' -Context 'Runner evidence result') -or
        (Get-RequiredBoolean -Object $result -Name 'appliedReadbackOk' -Context 'Runner evidence result')) {
        throw 'BLOCKED evidence cannot claim successful verification/readback.'
    }
    foreach ($flag in @('repairRequired', 'requiresSecondExport', 'requiresCpStudioChange')) {
        if (Get-RequiredBoolean -Object $result -Name $flag -Context 'Runner evidence result') {
            throw "Runner evidence result cannot set $flag for warning review."
        }
    }
    if ((Get-RequiredArray -Object $result -Name 'proposedChanges' -Context 'Runner evidence result').Count -ne 0 -or
        (Get-RequiredArray -Object $result -Name 'appliedChanges' -Context 'Runner evidence result').Count -ne 0) {
        throw 'A warning baseline candidate cannot be produced from mutation evidence.'
    }
    $nextRoute = Get-RequiredObject -Object $result -Name 'nextRoute' -Context 'Runner evidence result'
    Assert-ExactPropertySet -Object $nextRoute -Allowed @('kind', 'reasonCode', 'automaticExecutionAllowed') -Context 'Runner evidence nextRoute'
    if ((Get-RequiredString -Object $nextRoute -Name 'reasonCode' -Context 'Runner evidence nextRoute') -ne $resultReason -or
        (Get-RequiredString -Object $nextRoute -Name 'kind' -Context 'Runner evidence nextRoute') -notin @('review-warning-signature-baseline', 'review-engineering-semantic-baseline') -or
        (Get-RequiredBoolean -Object $nextRoute -Name 'automaticExecutionAllowed' -Context 'Runner evidence nextRoute')) {
        throw 'Runner evidence next route permits automatic execution.'
    }

    $build = Get-RequiredObject -Object $result -Name 'build' -Context 'Runner evidence result'
    Assert-ExactPropertySet -Object $build -Allowed @(
        'buildId', 'projectPath', 'profile', 'projectSha256', 'startedAtUtc', 'completedAtUtc',
        'verified', 'errors', 'warnings', 'messageCount', 'typedRecordsVerified',
        'diagnosticRowsComplete', 'warningRecordsSafeForReview', 'warningRecords',
        'diagnosticRows', 'summarySource'
    ) -Context 'Runner evidence blocked Build'
    $buildId = Get-RequiredString -Object $build -Name 'buildId' -Context 'Runner evidence blocked Build'
    if ($buildId -notmatch '\A[0-9A-Fa-f]{32}\z') { throw 'Runner evidence blocked Build buildId is invalid.' }
    $buildProject = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $build -Name 'projectPath' -Context 'Runner evidence blocked Build'))
    $buildSha = Get-RequiredString -Object $build -Name 'projectSha256' -Context 'Runner evidence blocked Build'
    Assert-HexSha256 -Value $buildSha -Context 'Runner evidence blocked Build projectSha256'
    $currentProjectSha = (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash
    if ((-not $buildProject.Equals($plcProject, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (Get-RequiredString -Object $build -Name 'profile' -Context 'Runner evidence blocked Build') -ne $profile -or
        (-not $buildSha.Equals($currentProjectSha, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not (Get-RequiredBoolean -Object $build -Name 'verified' -Context 'Runner evidence blocked Build')) -or
        (Get-RequiredInt32 -Object $build -Name 'errors' -Context 'Runner evidence blocked Build') -ne 0 -or
        (-not (Get-RequiredBoolean -Object $build -Name 'typedRecordsVerified' -Context 'Runner evidence blocked Build')) -or
        (-not (Get-RequiredBoolean -Object $build -Name 'diagnosticRowsComplete' -Context 'Runner evidence blocked Build')) -or
        (-not (Get-RequiredBoolean -Object $build -Name 'warningRecordsSafeForReview' -Context 'Runner evidence blocked Build')) -or
        (Get-RequiredString -Object $build -Name 'summarySource' -Context 'Runner evidence blocked Build') -ne 'codesys-persistent.compile_project') {
        throw 'Runner evidence does not bind a typed, review-safe, zero-error fresh Build of the current project/profile.'
    }
    $warningCount = Get-RequiredInt32 -Object $build -Name 'warnings' -Context 'Runner evidence blocked Build'
    $messageCount = Get-RequiredInt32 -Object $build -Name 'messageCount' -Context 'Runner evidence blocked Build'
    $warningRecords = Get-RequiredArray -Object $build -Name 'warningRecords' -Context 'Runner evidence blocked Build'
    $diagnosticRows = Get-RequiredArray -Object $build -Name 'diagnosticRows' -Context 'Runner evidence blocked Build'
    if (($warningCount -gt $maximumWarningCount) -or ($messageCount -gt $maximumWarningCount) -or
        ($warningRecords.Count -ne $warningCount) -or ($diagnosticRows.Count -ne $messageCount) -or
        ($messageCount -lt $warningCount) -or
        (@($warningRecords | Where-Object { ($_ -isnot [string]) -or [string]::IsNullOrWhiteSpace([string]$_) }).Count -ne 0)) {
        throw 'Runner evidence Build warning/diagnostic rows are incomplete or exceed their bounded contract.'
    }

    $proofs = Get-RequiredObject -Object $result -Name 'semanticProofs' -Context 'Runner evidence result'
    Assert-ExactPropertySet -Object $proofs -Allowed @(
        'contractVersion', 'ownership', 'readback', 'recoverableBaseline', 'warnings',
        'semanticBaseline', 'mapping', 'symbolPostProcessing'
    ) -Context 'Runner semantic proofs'
    if ((Get-RequiredInt32 -Object $proofs -Name 'contractVersion' -Context 'Runner semantic proofs') -ne 1) {
        throw 'Runner semantic proofs contractVersion is unsupported.'
    }
    $warningProof = Get-RequiredObject -Object $proofs -Name 'warnings' -Context 'Runner semantic proofs'
    Assert-ExactPropertySet -Object $warningProof -Allowed @(
        'producer', 'contractVersion', 'verified', 'signatureAlgorithm',
        'currentMultisetSha256', 'currentSignatures', 'reasonCode'
    ) -Context 'Runner warning proof'
    if ((Get-RequiredString -Object $warningProof -Name 'producer' -Context 'Runner warning proof') -ne 'runner.warning-baseline-comparison' -or
        (Get-RequiredInt32 -Object $warningProof -Name 'contractVersion' -Context 'Runner warning proof') -ne 1 -or
        (Get-RequiredBoolean -Object $warningProof -Name 'verified' -Context 'Runner warning proof') -or
        (Get-RequiredString -Object $warningProof -Name 'signatureAlgorithm' -Context 'Runner warning proof') -ne $signatureAlgorithm -or
        (Get-RequiredString -Object $warningProof -Name 'reasonCode' -Context 'Runner warning proof') -ne 'WARNING_BASELINE_BOOTSTRAP_REQUIRED') {
        throw 'Runner warning proof is not a frozen warning-baseline bootstrap candidate.'
    }
    $expectedMultisetSha = Get-RequiredString -Object $warningProof -Name 'currentMultisetSha256' -Context 'Runner warning proof'
    Assert-HexSha256 -Value $expectedMultisetSha -Context 'Runner warning proof currentMultisetSha256'
    $proofSignatures = Get-RequiredArray -Object $warningProof -Name 'currentSignatures' -Context 'Runner warning proof'

    $recordCounts = @{}
    $recordMessages = @{}
    foreach ($record in $warningRecords) {
        $normalized = Get-NormalizedWarningRecord -Value ([string]$record)
        $sha = Get-WarningRecordSignature -Value $normalized
        if ($recordCounts.ContainsKey($sha)) { $recordCounts[$sha] = [int]$recordCounts[$sha] + 1 }
        else { $recordCounts[$sha] = 1; $recordMessages[$sha] = $normalized }
    }
    $computedSignatures = New-Object System.Collections.Generic.List[object]
    $reviewRecords = New-Object System.Collections.Generic.List[object]
    foreach ($sha in @($recordCounts.Keys | Sort-Object)) {
        $occurrences = [int]$recordCounts[$sha]
        $computedSignatures.Add([ordered]@{ sha256 = $sha; occurrences = $occurrences })
        $reviewRecords.Add([ordered]@{ sha256 = $sha; occurrences = $occurrences; message = [string]$recordMessages[$sha] })
    }
    $validatedProofSignatures = New-Object System.Collections.Generic.List[object]
    $previousSha = $null
    foreach ($signature in $proofSignatures) {
        Assert-ExactPropertySet -Object $signature -Allowed @('sha256', 'occurrences') -Context 'Runner warning signature'
        $sha = (Get-RequiredString -Object $signature -Name 'sha256' -Context 'Runner warning signature').ToUpperInvariant()
        Assert-HexSha256 -Value $sha -Context 'Runner warning signature sha256'
        $occurrences = Get-RequiredInt32 -Object $signature -Name 'occurrences' -Context 'Runner warning signature' -Minimum 1
        if (($null -ne $previousSha) -and ([string]::CompareOrdinal([string]$previousSha, $sha) -ge 0)) {
            throw 'Runner warning signatures are not strictly sorted and unique.'
        }
        $previousSha = $sha
        $validatedProofSignatures.Add([ordered]@{ sha256 = $sha; occurrences = $occurrences })
    }
    $computedJson = ConvertTo-CanonicalJson -Value ([object[]]$computedSignatures.ToArray())
    $proofJson = ConvertTo-CanonicalJson -Value ([object[]]$validatedProofSignatures.ToArray())
    if ($computedJson -ne $proofJson) { throw 'Runner warning signatures do not match the fresh Build warning records.' }
    $actualMultisetSha = (Get-Sha256ForText -Text $proofJson).ToUpperInvariant()
    if (-not $actualMultisetSha.Equals($expectedMultisetSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runner warning multiset hash does not match currentSignatures.'
    }
    $compilerOutputTruncated = @($reviewRecords | Where-Object {
        ([string]$_.message) -match '(?i)\AMore than [0-9]+ warnings occurr?ed: Skipping all further warning messages\z'
    }).Count -gt 0

    return [pscustomobject]@{
        actionId = $actionId
        operationId = $operationId
        actionRequestSha256 = $actionRequestSha.ToLowerInvariant()
        stationRoot = $stationRoot
        plcProject = $plcProject
        profile = $profile
        buildId = $buildId
        warningCount = $warningCount
        messageCount = $messageCount
        signatures = [object[]]$validatedProofSignatures.ToArray()
        reviewRecords = [object[]]$reviewRecords.ToArray()
        multisetSha256 = $actualMultisetSha
        compilerOutputTruncated = $compilerOutputTruncated
    }
}

function Write-ImmutableCandidate {
    param([string]$Path, [object]$Value)

    $text = (ConvertTo-CanonicalJson -Value $Value) + [Environment]::NewLine
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($text)
    if ($bytes.Length -gt $maximumCandidateBytes) { throw 'Warning baseline candidate exceeds its bounded artifact contract.' }
    $sha = Get-Sha256ForBytes -Bytes $bytes
    if ([System.IO.File]::Exists($Path)) {
        $existing = Get-Sha256ForBytes -Bytes ([System.IO.File]::ReadAllBytes($Path))
        if ($existing -eq $sha) { return [pscustomobject]@{ path = $Path; sha256 = $sha; written = $false } }
        throw "Immutable warning baseline candidate already exists with different content: $Path"
    }
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($directory)) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    $temporary = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllBytes($temporary, $bytes)
        [System.IO.File]::Move($temporary, $Path)
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
    return [pscustomobject]@{ path = $Path; sha256 = $sha; written = $true }
}

$resolvedEngineeringRoot = [System.IO.Path]::GetFullPath($EngineeringRoot).TrimEnd('\', '/')
if (-not [System.IO.Directory]::Exists($resolvedEngineeringRoot)) { throw "Engineering root does not exist: $resolvedEngineeringRoot" }
$runnerEvidenceRoot = Join-Path $resolvedEngineeringRoot 'data\runner-evidence'
$resolvedEvidencePath = Assert-PathInsideRoot -Root $runnerEvidenceRoot -Path $EvidencePath -Context 'Runner evidence input'
$evidenceDocument = Read-JsonDocumentExact -Path $resolvedEvidencePath -Context 'Runner evidence input' -MaximumBytes $maximumInputBytes
Assert-NoSecrets -Value $evidenceDocument.payload
$validated = Get-ValidatedWarningReview -Evidence $evidenceDocument.payload -ExpectedEngineeringRoot $resolvedEngineeringRoot

$plcRelativePath = Get-RelativePathInsideRoot -Root $validated.stationRoot -Path $validated.plcProject -Context 'Runner evidence PLC project'
$evidenceRelativePath = Get-RelativePathInsideRoot -Root $resolvedEngineeringRoot -Path $resolvedEvidencePath -Context 'Runner evidence input'
$reviewBlockers = New-Object System.Collections.Generic.List[object]
if ($validated.compilerOutputTruncated) { [void]$reviewBlockers.Add('PLE_WARNING_OUTPUT_TRUNCATED') }
$candidate = [ordered]@{
    schemaVersion = 1
    kind = 'ctrlx-opcon-warning-signature-baseline-candidate'
    project = [ordered]@{
        plcProjectRelativePath = $plcRelativePath
        profile = $validated.profile
    }
    signatureAlgorithm = $signatureAlgorithm
    signatures = $validated.signatures
    currentMultisetSha256 = $validated.multisetSha256
    warningReview = [ordered]@{
        buildId = $validated.buildId
        warningCount = $validated.warningCount
        messageCount = $validated.messageCount
        compilerOutputTruncated = $validated.compilerOutputTruncated
        records = $validated.reviewRecords
    }
    sourceEvidence = [ordered]@{
        path = $evidenceRelativePath
        sha256 = Get-Sha256ForBytes -Bytes $evidenceDocument.bytes
        operationId = $validated.operationId
        actionId = $validated.actionId
        actionRequestSha256 = $validated.actionRequestSha256
        completedAtUtc = Get-RequiredString -Object $evidenceDocument.payload -Name 'completedAtUtc' -Context 'Runner evidence'
    }
    review = [ordered]@{
        state = 'pending-human-review'
        automaticPromotionAllowed = $false
        reviewBlockers = [object[]]$reviewBlockers.ToArray()
        requiredHumanInputs = @('reviewId', 'reviewer', 'reviewedAtUtc', 'independentEvidencePath', 'independentEvidenceSha256')
        targetBaselinePath = 'config/warning-signature-baseline.json'
    }
}
Assert-NoSecrets -Value $candidate

$reviewRoot = Join-Path $resolvedEngineeringRoot 'docs\reviews'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $reviewRoot ('warning-signature-baseline-candidate-' + $validated.actionId + '.json')
}
$resolvedOutputPath = Assert-PathInsideRoot -Root $reviewRoot -Path $OutputPath -Context 'Warning baseline candidate output'
if ($requestedWhatIf -or (-not $PSCmdlet.ShouldProcess($resolvedOutputPath, 'Write immutable warning baseline review candidate'))) {
    [pscustomobject]@{ status = 'WHATIF'; path = $resolvedOutputPath; candidate = $candidate }
    return
}

$writeResult = Write-ImmutableCandidate -Path $resolvedOutputPath -Value $candidate
[pscustomobject]@{
    status = if ($writeResult.written) { 'WRITTEN' } else { 'UNCHANGED' }
    path = $writeResult.path
    sha256 = $writeResult.sha256
    actionId = $validated.actionId
    reviewState = 'pending-human-review'
}
