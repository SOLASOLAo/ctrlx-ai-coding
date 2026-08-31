[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)][string]$EvidencePath,
    [Parameter(Mandatory = $false)][string]$EngineeringRoot = (Join-Path $PSScriptRoot '..\..'),
    [Parameter(Mandatory = $false)][string]$ScopePath = 'config\engineering-semantic-scope.json',
    [Parameter(Mandatory = $false)][string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$requestedWhatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false

$semanticProducer = 'codesys-persistent.get_ctrlx_semantic_snapshot'
$semanticPatchId = 'ctrlx-semantic-snapshot-v1'
$canonicalization = 'ctrlx-semantic-canonical-json-v1'
$maximumInputBytes = 2 * 1024 * 1024
$maximumScopeBytes = 256 * 1024
$maximumBaselineBytes = 1024 * 1024
$maximumCandidateBytes = 1024 * 1024

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
        if ($contains) {
            $value = $Object[$Name]
            if ($value -is [System.Array]) { Write-Output -NoEnumerate $value }
            else { return $value }
            return
        }
        return $DefaultValue
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    $value = $property.Value
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
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $value = Get-PropertyValue -Object $Object -Name $Name
    if (($null -eq $value) -or
        (($value -isnot [System.Collections.IDictionary]) -and ($value -isnot [pscustomobject]))) {
        throw "$Context has no JSON object '$Name'."
    }
    return $value
}

function Get-RequiredArray {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $missing = New-Object object
    $value = Get-PropertyValue -Object $Object -Name $Name -DefaultValue $missing
    if ([object]::ReferenceEquals($missing, $value) -or ($null -eq $value) -or ($value -isnot [System.Array])) {
        throw "$Context '$Name' must be a JSON array (including for a singleton)."
    }
    Write-Output -NoEnumerate ([object[]]$value)
}

function Get-RequiredString {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$AllowEmpty
    )

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

function Get-RequiredInt32 {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context,
        [int]$Minimum = 0
    )

    $value = Get-PropertyValue -Object $Object -Name $Name
    if ((($value -isnot [int]) -and ($value -isnot [long])) -or
        ([long]$value -lt $Minimum) -or ([long]$value -gt [int]::MaxValue)) {
        throw "$Context '$Name' must be a bounded JSON integer."
    }
    return [int]$value
}

function Assert-HexSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Value -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "$Context must be a SHA-256 hex digest."
    }
}

function Assert-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

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
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = Assert-PathInsideRoot -Root $rootPath -Path $Path -Context $Context
    if ($candidate.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $candidate.Substring($rootPath.Length + 1).Replace('\', '/')
}

function Read-JsonDocumentExact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][int]$MaximumBytes
    )

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
        $convertCommand = Get-Command ConvertFrom-Json -ErrorAction Stop
        if (-not $convertCommand.Parameters.ContainsKey('DateKind')) {
            throw 'PowerShell 7.5 or newer with ConvertFrom-Json -DateKind is required.'
        }
        $convertArguments = @{
            InputObject = $text
            DateKind = 'String'
        }
        if ($convertCommand.Parameters.ContainsKey('AsHashtable')) { $convertArguments['AsHashtable'] = $true }
        if ($convertCommand.Parameters.ContainsKey('Depth')) { $convertArguments['Depth'] = 256 }
        $payload = ConvertFrom-Json @convertArguments
    }
    catch {
        throw "$Context is not valid UTF-8 JSON. $($_.Exception.Message)"
    }
    if (($null -eq $payload) -or
        (($payload -isnot [System.Collections.IDictionary]) -and ($payload -isnot [pscustomobject]))) {
        throw "$Context root must be a JSON object."
    }
    return [pscustomobject]@{
        path = $resolved
        bytes = $bytes
        raw = $text
        payload = $payload
    }
}

function Get-Sha256ForBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-Sha256ForText {
    param([Parameter(Mandatory = $true)][string]$Text)

    return Get-Sha256ForBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Add-CanonicalJsonString {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder
    )

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
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory = $true)][int]$Depth
    )

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
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

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
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $false)][string]$Path = '$',
        [Parameter(Mandatory = $false)][int]$Depth = 0,
        [Parameter(Mandatory = $false)][AllowNull()][object]$State = $null
    )

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

function Assert-BlockedEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$ExpectedEngineeringRoot
    )

    Assert-ExactPropertySet -Object $Evidence -Allowed @(
        'schemaVersion', 'operationId', 'actionId', 'actionKind', 'actionRequestSha256',
        'completedAtUtc', 'project', 'capabilitiesInvoked', 'guardrails', 'result'
    ) -Context 'Runner evidence'
    if ((Get-RequiredInt32 -Object $Evidence -Name 'schemaVersion' -Context 'Runner evidence') -ne 1) {
        throw 'Runner evidence schemaVersion is unsupported.'
    }
    $actionId = Get-RequiredString -Object $Evidence -Name 'actionId' -Context 'Runner evidence'
    if ($actionId -notmatch '^[A-Za-z0-9_.-]{1,160}$') { throw 'Runner evidence actionId is unsafe.' }
    Assert-HexSha256 -Value (Get-RequiredString -Object $Evidence -Name 'actionRequestSha256' -Context 'Runner evidence') -Context 'Runner evidence actionRequestSha256'
    $actionKind = Get-RequiredString -Object $Evidence -Name 'actionKind' -Context 'Runner evidence'
    if ($actionKind -notin @('inspect_and_build', 'verify_after_export_2')) {
        throw 'Only read-only inspection evidence can produce a semantic baseline candidate.'
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
    if (($capabilities.Count -lt 3) -or ($capabilities.Count -gt 4) -or
        (@($capabilities | Where-Object { [string]$_ -eq 'get_codesys_status' }).Count -ne 1) -or
        (@($capabilities | Where-Object { [string]$_ -eq 'clean_compile_project' }).Count -ne 1) -or
        (@($capabilities | Where-Object { [string]$_ -eq 'get_ctrlx_semantic_snapshot' }).Count -ne 1) -or
        (@($capabilities | Where-Object { [string]$_ -eq 'get_ctrlx_semantic_snapshot_retry' }).Count -gt 1) -or
        (@($capabilities | Where-Object { [string]$_ -notin @('get_codesys_status', 'clean_compile_project', 'get_ctrlx_semantic_snapshot', 'get_ctrlx_semantic_snapshot_retry') }).Count -ne 0) -or
        (@($capabilities | Where-Object { [string]$_ -match '(?i)(connect|download|start_stop|write_variable|force|online)' }).Count -ne 0)) {
        throw 'Runner evidence does not prove one offline Build plus one semantic snapshot.'
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
    $reasonCode = Get-RequiredString -Object $result -Name 'reasonCode' -Context 'Runner evidence result'
    if ((Get-RequiredString -Object $result -Name 'status' -Context 'Runner evidence result') -ne 'blocked' -or
        (Get-RequiredString -Object $result -Name 'failureStage' -Context 'Runner evidence result') -ne 'semantic-acceptance' -or
        $reasonCode -notin @('SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED', 'SYMBOL_BASELINE_MISMATCH')) {
        throw 'Only semantic baseline bootstrap or Symbol mismatch BLOCKED evidence can produce this candidate.'
    }
    if ((Get-RequiredBoolean -Object $result -Name 'verificationOk' -Context 'Runner evidence result') -or
        (Get-RequiredBoolean -Object $result -Name 'appliedReadbackOk' -Context 'Runner evidence result')) {
        throw 'BLOCKED semantic bootstrap evidence cannot claim successful verification/readback.'
    }
    foreach ($flag in @('repairRequired', 'requiresSecondExport', 'requiresCpStudioChange')) {
        if (Get-RequiredBoolean -Object $result -Name $flag -Context 'Runner evidence result') {
            throw "Runner evidence result cannot set $flag for baseline review."
        }
    }
    if ((Get-RequiredArray -Object $result -Name 'proposedChanges' -Context 'Runner evidence result').Count -ne 0 -or
        (Get-RequiredArray -Object $result -Name 'appliedChanges' -Context 'Runner evidence result').Count -ne 0) {
        throw 'A semantic baseline candidate cannot be produced from mutation evidence.'
    }
    $nextRoute = Get-RequiredObject -Object $result -Name 'nextRoute' -Context 'Runner evidence result'
    Assert-ExactPropertySet -Object $nextRoute -Allowed @('kind', 'reasonCode', 'automaticExecutionAllowed') -Context 'Runner evidence nextRoute'
    $expectedRoute = if ($reasonCode -eq 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED') {
        'review-engineering-semantic-baseline'
    }
    elseif ($actionKind -eq 'inspect_and_build') { 'cpstudio-export-2-review' }
    else { 'cpstudio-change-review' }
    if ((Get-RequiredString -Object $nextRoute -Name 'kind' -Context 'Runner evidence nextRoute') -ne $expectedRoute -or
        (Get-RequiredString -Object $nextRoute -Name 'reasonCode' -Context 'Runner evidence nextRoute') -ne $reasonCode -or
        (Get-RequiredBoolean -Object $nextRoute -Name 'automaticExecutionAllowed' -Context 'Runner evidence nextRoute')) {
        throw 'Runner evidence does not require a manual semantic baseline review.'
    }

    $build = Get-RequiredObject -Object $result -Name 'build' -Context 'Runner evidence result'
    Assert-ExactPropertySet -Object $build -Allowed @(
        'buildId', 'projectPath', 'profile', 'projectSha256', 'startedAtUtc', 'completedAtUtc',
        'verified', 'errors', 'warnings', 'messageCount', 'typedRecordsVerified',
        'diagnosticRowsComplete', 'warningRecordsSafeForReview', 'warningRecords',
        'diagnosticRows', 'summarySource'
    ) -Context 'Runner evidence blocked Build'
    $buildId = Get-RequiredString -Object $build -Name 'buildId' -Context 'Runner evidence blocked Build'
    if ($buildId -notmatch '\A[0-9A-Fa-f]{32}\z') {
        throw 'Runner evidence blocked Build buildId is invalid.'
    }
    $buildProject = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $build -Name 'projectPath' -Context 'Runner evidence blocked Build'))
    $buildSha = Get-RequiredString -Object $build -Name 'projectSha256' -Context 'Runner evidence blocked Build'
    Assert-HexSha256 -Value $buildSha -Context 'Runner evidence blocked Build projectSha256'
    $currentProjectSha = (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash
    if ((-not $buildProject.Equals($plcProject, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (Get-RequiredString -Object $build -Name 'profile' -Context 'Runner evidence blocked Build') -ne $profile -or
        (-not $buildSha.Equals($currentProjectSha, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not (Get-RequiredBoolean -Object $build -Name 'verified' -Context 'Runner evidence blocked Build')) -or
        (Get-RequiredInt32 -Object $build -Name 'errors' -Context 'Runner evidence blocked Build') -ne 0 -or
        (Get-RequiredString -Object $build -Name 'summarySource' -Context 'Runner evidence blocked Build') -ne 'codesys-persistent.clean_compile_project') {
        throw 'Runner evidence blocked Build does not bind the current zero-error project/profile.'
    }
    $warningCount = Get-RequiredInt32 -Object $build -Name 'warnings' -Context 'Runner evidence blocked Build'
    $messageCount = Get-RequiredInt32 -Object $build -Name 'messageCount' -Context 'Runner evidence blocked Build'
    if (($warningCount -gt 2048) -or ($messageCount -lt $warningCount) -or ($messageCount -gt 2048)) {
        throw 'Runner evidence blocked Build counts exceed their bounded contract.'
    }
    $warningRecords = Get-RequiredArray -Object $build -Name 'warningRecords' -Context 'Runner evidence blocked Build'
    $diagnosticRows = Get-RequiredArray -Object $build -Name 'diagnosticRows' -Context 'Runner evidence blocked Build'
    $typedRecords = Get-RequiredBoolean -Object $build -Name 'typedRecordsVerified' -Context 'Runner evidence blocked Build'
    $warningSafe = Get-RequiredBoolean -Object $build -Name 'warningRecordsSafeForReview' -Context 'Runner evidence blocked Build'
    $diagnosticsComplete = Get-RequiredBoolean -Object $build -Name 'diagnosticRowsComplete' -Context 'Runner evidence blocked Build'
    if (($warningSafe -and (-not $typedRecords)) -or
        ($typedRecords -and $warningSafe -and ($warningRecords.Count -ne $warningCount)) -or
        ((-not $warningSafe) -and ($warningRecords.Count -ne 0)) -or
        ($diagnosticRows.Count -gt $messageCount) -or
        ($diagnosticsComplete -and ($diagnosticRows.Count -ne $messageCount))) {
        throw 'Runner evidence blocked Build warning/diagnostic record flags are inconsistent.'
    }

    $proofs = Get-RequiredObject -Object $result -Name 'semanticProofs' -Context 'Runner evidence result'
    Assert-ExactPropertySet -Object $proofs -Allowed @(
        'contractVersion', 'ownership', 'readback', 'recoverableBaseline', 'warnings',
        'semanticBaseline', 'mapping', 'symbolPostProcessing'
    ) -Context 'Runner semantic proofs'
    if ((Get-RequiredInt32 -Object $proofs -Name 'contractVersion' -Context 'Runner semantic proofs') -ne 1) {
        throw 'Runner semantic proofs contractVersion is unsupported.'
    }
    foreach ($proofName in @('ownership', 'readback', 'recoverableBaseline', 'warnings', 'semanticBaseline', 'mapping', 'symbolPostProcessing')) {
        $proof = Get-RequiredObject -Object $proofs -Name $proofName -Context 'Runner semantic proofs'
        if ((Get-RequiredInt32 -Object $proof -Name 'contractVersion' -Context "Runner semantic proof '$proofName'") -ne 1) {
            throw "Runner semantic proof '$proofName' contractVersion is unsupported."
        }
    }
    $baselineProof = Get-RequiredObject -Object $proofs -Name 'semanticBaseline' -Context 'Runner semantic proofs'
    if ($reasonCode -eq 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED') {
        if ((Get-RequiredBoolean -Object $baselineProof -Name 'verified' -Context 'Runner semantic baseline proof') -or
            (Get-RequiredString -Object $baselineProof -Name 'reasonCode' -Context 'Runner semantic baseline proof') -ne $reasonCode) {
            throw 'Runner evidence is not missing only the reviewed semantic baseline.'
        }
    }
    else {
        foreach ($proofName in @('warnings', 'semanticBaseline', 'mapping')) {
            $proof = Get-RequiredObject -Object $proofs -Name $proofName -Context 'Runner semantic proofs'
            if (-not (Get-RequiredBoolean -Object $proof -Name 'verified' -Context "Runner semantic proof '$proofName'")) {
                throw "Runner semantic proof '$proofName' must remain verified for a Symbol-only refresh."
            }
        }
    }

    return [pscustomobject]@{
        actionId = $actionId
        project = $project
        stationRoot = $stationRoot
        plcProject = $plcProject
        profile = $profile
        result = $result
        reasonCode = $reasonCode
    }
}

function Get-CandidateProof {
    param(
        [Parameter(Mandatory = $true)][object]$Proofs,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$HashField
    )

    $proof = Get-RequiredObject -Object $Proofs -Name $Name -Context 'Runner semantic proofs'
    $allowed = @('producer', 'contractVersion', 'adapterPatchId', 'verified', 'reasonCode', 'candidateCanonicalFacts')
    if ($Name -eq 'mapping') { $allowed += @('actualRecordCount', 'actualMappingSha256') }
    else { $allowed += @('actualSymbolConfigSha256') }
    Assert-ExactPropertySet -Object $proof -Allowed $allowed -Context "Runner semantic proof '$Name'"
    if ((Get-RequiredString -Object $proof -Name 'producer' -Context "Runner semantic proof '$Name'") -ne $semanticProducer -or
        (Get-RequiredInt32 -Object $proof -Name 'contractVersion' -Context "Runner semantic proof '$Name'") -ne 1 -or
        (Get-RequiredString -Object $proof -Name 'adapterPatchId' -Context "Runner semantic proof '$Name'") -ne $semanticPatchId -or
        (Get-RequiredBoolean -Object $proof -Name 'verified' -Context "Runner semantic proof '$Name'") -or
        (Get-RequiredString -Object $proof -Name 'reasonCode' -Context "Runner semantic proof '$Name'") -ne 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED') {
        throw "Runner semantic proof '$Name' is not a frozen bootstrap candidate."
    }
    $expectedHash = Get-RequiredString -Object $proof -Name $HashField -Context "Runner semantic proof '$Name'"
    Assert-HexSha256 -Value $expectedHash -Context "Runner semantic proof '$Name' $HashField"
    $facts = Get-RequiredObject -Object $proof -Name 'candidateCanonicalFacts' -Context "Runner semantic proof '$Name'"
    $actualHash = Get-Sha256ForText -Text (ConvertTo-CanonicalJson -Value $facts)
    if (-not $actualHash.Equals($expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Runner semantic proof '$Name' hash does not match candidateCanonicalFacts."
    }
    return [pscustomobject]@{ facts = $facts; sha256 = $actualHash }
}

function Get-SymbolRefreshFacts {
    param(
        [Parameter(Mandatory = $true)][object]$BaselineDocument,
        [Parameter(Mandatory = $true)][object]$Proofs,
        [Parameter(Mandatory = $true)][string]$ScopeSha256,
        [Parameter(Mandatory = $true)][string]$PlcRelativePath,
        [Parameter(Mandatory = $true)][string]$Profile
    )

    $baseline = $BaselineDocument.payload
    Assert-ExactPropertySet -Object $baseline -Allowed @('schemaVersion', 'kind', 'project', 'scopeSha256', 'canonicalFacts', 'hashes', 'review') -Context 'Reviewed engineering semantic baseline'
    if ((Get-RequiredInt32 -Object $baseline -Name 'schemaVersion' -Context 'Reviewed engineering semantic baseline') -ne 1 -or
        (Get-RequiredString -Object $baseline -Name 'kind' -Context 'Reviewed engineering semantic baseline') -ne 'ctrlx-opcon-engineering-semantic-baseline') {
        throw 'Reviewed engineering semantic baseline identity is unsupported.'
    }
    $project = Get-RequiredObject -Object $baseline -Name 'project' -Context 'Reviewed engineering semantic baseline'
    Assert-ExactPropertySet -Object $project -Allowed @('plcProjectRelativePath', 'profile') -Context 'Reviewed engineering semantic baseline project'
    if ((Get-RequiredString -Object $project -Name 'plcProjectRelativePath' -Context 'Reviewed engineering semantic baseline project').Replace('\', '/') -ne $PlcRelativePath -or
        (Get-RequiredString -Object $project -Name 'profile' -Context 'Reviewed engineering semantic baseline project') -ne $Profile -or
        (-not (Get-RequiredString -Object $baseline -Name 'scopeSha256' -Context 'Reviewed engineering semantic baseline').Equals($ScopeSha256, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Reviewed engineering semantic baseline does not bind this project/profile/scope.'
    }

    $facts = Get-RequiredObject -Object $baseline -Name 'canonicalFacts' -Context 'Reviewed engineering semantic baseline'
    Assert-ExactPropertySet -Object $facts -Allowed @('mapping', 'symbolConfig') -Context 'Reviewed engineering semantic baseline facts'
    $mapping = Get-RequiredObject -Object $facts -Name 'mapping' -Context 'Reviewed engineering semantic baseline facts'
    $oldSymbol = Get-RequiredObject -Object $facts -Name 'symbolConfig' -Context 'Reviewed engineering semantic baseline facts'
    $hashes = Get-RequiredObject -Object $baseline -Name 'hashes' -Context 'Reviewed engineering semantic baseline'
    Assert-ExactPropertySet -Object $hashes -Allowed @('algorithm', 'canonicalization', 'mappingSha256', 'symbolConfigSha256', 'snapshotSha256') -Context 'Reviewed engineering semantic baseline hashes'
    if ((Get-RequiredString -Object $hashes -Name 'algorithm' -Context 'Reviewed engineering semantic baseline hashes') -ne 'SHA-256' -or
        (Get-RequiredString -Object $hashes -Name 'canonicalization' -Context 'Reviewed engineering semantic baseline hashes') -ne $canonicalization) {
        throw 'Reviewed engineering semantic baseline hash contract is unsupported.'
    }
    $computed = [ordered]@{
        mappingSha256 = Get-Sha256ForText -Text (ConvertTo-CanonicalJson -Value $mapping)
        symbolConfigSha256 = Get-Sha256ForText -Text (ConvertTo-CanonicalJson -Value $oldSymbol)
        snapshotSha256 = Get-Sha256ForText -Text (ConvertTo-CanonicalJson -Value $facts)
    }
    foreach ($name in $computed.Keys) {
        if (-not ([string]$computed[$name]).Equals((Get-RequiredString -Object $hashes -Name $name -Context 'Reviewed engineering semantic baseline hashes'), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Reviewed engineering semantic baseline $name is invalid."
        }
    }
    $review = Get-RequiredObject -Object $baseline -Name 'review' -Context 'Reviewed engineering semantic baseline'
    if (-not (Get-RequiredBoolean -Object $review -Name 'confirmedByUser' -Context 'Reviewed engineering semantic baseline review')) {
        throw 'Reviewed engineering semantic baseline is not user-confirmed.'
    }

    $baselineSha = Get-Sha256ForBytes -Bytes $BaselineDocument.bytes
    $baselineProof = Get-RequiredObject -Object $Proofs -Name 'semanticBaseline' -Context 'Runner semantic proofs'
    if ((Get-RequiredString -Object $baselineProof -Name 'producer' -Context 'Runner semantic baseline proof') -ne 'runner.reviewed-semantic-baseline' -or
        (-not (Get-RequiredBoolean -Object $baselineProof -Name 'verified' -Context 'Runner semantic baseline proof')) -or
        (Get-RequiredString -Object $baselineProof -Name 'artifactPath' -Context 'Runner semantic baseline proof').Replace('\', '/') -ne 'config/engineering-semantic-baseline.json' -or
        (-not (Get-RequiredString -Object $baselineProof -Name 'artifactSha256' -Context 'Runner semantic baseline proof').Equals($baselineSha, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not (Get-RequiredString -Object $baselineProof -Name 'scopeSha256' -Context 'Runner semantic baseline proof').Equals($ScopeSha256, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not (Get-RequiredString -Object $baselineProof -Name 'expectedMappingSha256' -Context 'Runner semantic baseline proof').Equals([string]$computed.mappingSha256, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not (Get-RequiredString -Object $baselineProof -Name 'expectedSymbolConfigSha256' -Context 'Runner semantic baseline proof').Equals([string]$computed.symbolConfigSha256, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Runner evidence does not bind the current reviewed semantic baseline.'
    }

    $mappingProof = Get-RequiredObject -Object $Proofs -Name 'mapping' -Context 'Runner semantic proofs'
    if ((Get-RequiredString -Object $mappingProof -Name 'producer' -Context 'Runner mapping proof') -ne $semanticProducer -or
        (Get-RequiredString -Object $mappingProof -Name 'adapterPatchId' -Context 'Runner mapping proof') -ne $semanticPatchId -or
        (-not (Get-RequiredBoolean -Object $mappingProof -Name 'verified' -Context 'Runner mapping proof')) -or
        (Get-RequiredInt32 -Object $mappingProof -Name 'recordCount' -Context 'Runner mapping proof') -ne (Get-RequiredInt32 -Object $mapping -Name 'recordCount' -Context 'Reviewed mapping facts') -or
        (-not (Get-RequiredString -Object $mappingProof -Name 'mappingSha256' -Context 'Runner mapping proof').Equals([string]$computed.mappingSha256, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Runner evidence mapping changed; a Symbol-only refresh is not allowed.'
    }

    $symbolProof = Get-RequiredObject -Object $Proofs -Name 'symbolPostProcessing' -Context 'Runner semantic proofs'
    Assert-ExactPropertySet -Object $symbolProof -Allowed @('producer', 'contractVersion', 'verified', 'reasonCode', 'expectedSymbolConfigSha256', 'actualSymbolConfigSha256', 'actualCanonicalFacts') -Context 'Runner Symbol mismatch proof'
    if ((Get-RequiredString -Object $symbolProof -Name 'producer' -Context 'Runner Symbol mismatch proof') -ne $semanticProducer -or
        (Get-RequiredInt32 -Object $symbolProof -Name 'contractVersion' -Context 'Runner Symbol mismatch proof') -ne 1 -or
        (Get-RequiredBoolean -Object $symbolProof -Name 'verified' -Context 'Runner Symbol mismatch proof') -or
        (Get-RequiredString -Object $symbolProof -Name 'reasonCode' -Context 'Runner Symbol mismatch proof') -ne 'SYMBOL_BASELINE_MISMATCH' -or
        (-not (Get-RequiredString -Object $symbolProof -Name 'expectedSymbolConfigSha256' -Context 'Runner Symbol mismatch proof').Equals([string]$computed.symbolConfigSha256, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Runner evidence is not a Symbol-only mismatch against the current baseline.'
    }
    $newSymbol = Get-RequiredObject -Object $symbolProof -Name 'actualCanonicalFacts' -Context 'Runner Symbol mismatch proof'
    $newSymbolSha = Get-Sha256ForText -Text (ConvertTo-CanonicalJson -Value $newSymbol)
    if (-not $newSymbolSha.Equals((Get-RequiredString -Object $symbolProof -Name 'actualSymbolConfigSha256' -Context 'Runner Symbol mismatch proof'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runner Symbol mismatch actualCanonicalFacts hash is invalid.'
    }

    return [pscustomobject]@{
        mapping = $mapping
        mappingSha256 = [string]$computed.mappingSha256
        symbol = $newSymbol
        symbolSha256 = $newSymbolSha
        previousBaseline = [ordered]@{
            path = 'config/engineering-semantic-baseline.json'
            sha256 = $baselineSha
        }
    }
}

function Assert-ScopeAndFacts {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object]$Mapping,
        [Parameter(Mandatory = $true)][object]$Symbol,
        [Parameter(Mandatory = $true)][string]$PlcRelativePath,
        [Parameter(Mandatory = $true)][string]$Profile
    )

    Assert-ExactPropertySet -Object $Scope -Allowed @('schemaVersion', 'kind', 'project', 'mappingScopes', 'symbolApplicationPath') -Context 'Engineering semantic scope'
    if ((Get-RequiredInt32 -Object $Scope -Name 'schemaVersion' -Context 'Engineering semantic scope') -ne 1 -or
        (Get-RequiredString -Object $Scope -Name 'kind' -Context 'Engineering semantic scope') -ne 'ctrlx-opcon-engineering-semantic-scope') {
        throw 'Engineering semantic scope contract is unsupported.'
    }
    $scopeProject = Get-RequiredObject -Object $Scope -Name 'project' -Context 'Engineering semantic scope'
    Assert-ExactPropertySet -Object $scopeProject -Allowed @('plcProjectRelativePath', 'profile') -Context 'Engineering semantic scope project'
    if ((Get-RequiredString -Object $scopeProject -Name 'plcProjectRelativePath' -Context 'Engineering semantic scope project').Replace('\', '/') -ne $PlcRelativePath -or
        (Get-RequiredString -Object $scopeProject -Name 'profile' -Context 'Engineering semantic scope project') -ne $Profile) {
        throw 'Engineering semantic scope belongs to another project/profile.'
    }
    $configuredScopes = Get-RequiredArray -Object $Scope -Name 'mappingScopes' -Context 'Engineering semantic scope'
    if (($configuredScopes.Count -eq 0) -or ($configuredScopes.Count -gt 64)) { throw 'Engineering semantic scope count is invalid.' }
    $seenDevicePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($configured in $configuredScopes) {
        Assert-ExactPropertySet -Object $configured -Allowed @('devicePath', 'recursive', 'includeAllMappableChannels') -Context 'Engineering semantic mapping scope'
        $devicePath = Get-RequiredString -Object $configured -Name 'devicePath' -Context 'Engineering semantic mapping scope'
        if ((-not (Get-RequiredBoolean -Object $configured -Name 'recursive' -Context 'Engineering semantic mapping scope')) -or
            (-not (Get-RequiredBoolean -Object $configured -Name 'includeAllMappableChannels' -Context 'Engineering semantic mapping scope')) -or
            (-not $seenDevicePaths.Add($devicePath))) {
            throw 'Engineering semantic mapping scopes must be unique recursive all-channel roots.'
        }
    }

    Assert-ExactPropertySet -Object $Mapping -Allowed @('scopeCount', 'explicitTargetCount', 'recordCount', 'recordLimit', 'scopes', 'records') -Context 'Candidate mapping facts'
    $mappingScopes = Get-RequiredArray -Object $Mapping -Name 'scopes' -Context 'Candidate mapping facts'
    $records = Get-RequiredArray -Object $Mapping -Name 'records' -Context 'Candidate mapping facts'
    if ((Get-RequiredInt32 -Object $Mapping -Name 'scopeCount' -Context 'Candidate mapping facts') -ne $mappingScopes.Count -or
        (Get-RequiredInt32 -Object $Mapping -Name 'explicitTargetCount' -Context 'Candidate mapping facts') -ne 0 -or
        (Get-RequiredInt32 -Object $Mapping -Name 'recordCount' -Context 'Candidate mapping facts') -ne $records.Count -or
        (Get-RequiredInt32 -Object $Mapping -Name 'recordLimit' -Context 'Candidate mapping facts') -ne 2048 -or
        $mappingScopes.Count -ne $configuredScopes.Count -or $records.Count -gt 2048) {
        throw 'Candidate mapping counters do not match the controlled scope.'
    }

    for ($index = 0; $index -lt $mappingScopes.Count; $index++) {
        $actualScope = $mappingScopes[$index]
        $configured = $configuredScopes[$index]
        Assert-ExactPropertySet -Object $actualScope -Allowed @('scopeIndex', 'devicePath', 'recursive', 'rootName', 'recordCount') -Context 'Candidate mapping scope'
        if ((Get-RequiredInt32 -Object $actualScope -Name 'scopeIndex' -Context 'Candidate mapping scope') -ne $index -or
            (Get-RequiredString -Object $actualScope -Name 'devicePath' -Context 'Candidate mapping scope') -ne (Get-RequiredString -Object $configured -Name 'devicePath' -Context 'Engineering semantic mapping scope') -or
            (-not (Get-RequiredBoolean -Object $actualScope -Name 'recursive' -Context 'Candidate mapping scope'))) {
            throw 'Candidate mapping scope does not match the current controlled scope.'
        }
        $null = Get-RequiredString -Object $actualScope -Name 'rootName' -Context 'Candidate mapping scope'
        $null = Get-RequiredInt32 -Object $actualScope -Name 'recordCount' -Context 'Candidate mapping scope'
    }

    $recordCounts = @{}
    $previousIdentity = $null
    $previousCanonical = $null
    foreach ($record in $records) {
        if (($record -isnot [System.Collections.IDictionary]) -and ($record -isnot [pscustomobject])) { throw 'Candidate mapping record must be an object.' }
        if ((Get-RequiredString -Object $record -Name 'recordKind' -Context 'Candidate mapping record') -ne 'scope-channel') {
            throw 'Controlled candidate mapping records must come from mappingScopes, not explicit targets.'
        }
        $scopeIndex = Get-RequiredInt32 -Object $record -Name 'scopeIndex' -Context 'Candidate mapping record'
        if ($scopeIndex -ge $mappingScopes.Count) { throw 'Candidate mapping record scopeIndex is out of range.' }
        $identity = Get-RequiredString -Object $record -Name 'channelIdentity' -Context 'Candidate mapping record'
        $null = Get-RequiredString -Object $record -Name 'actualVariable' -Context 'Candidate mapping record' -AllowEmpty
        $canonicalRecord = ConvertTo-CanonicalJson -Value $record
        if (($null -ne $previousIdentity) -and
            (([System.StringComparer]::Ordinal.Compare([string]$previousIdentity, $identity) -gt 0) -or
             (([System.StringComparer]::Ordinal.Compare([string]$previousIdentity, $identity) -eq 0) -and
              ([System.StringComparer]::Ordinal.Compare([string]$previousCanonical, $canonicalRecord) -gt 0)))) {
            throw 'Candidate mapping records are not in canonical ordinal order.'
        }
        $previousIdentity = $identity
        $previousCanonical = $canonicalRecord
        if ($recordCounts.ContainsKey($scopeIndex)) { $recordCounts[$scopeIndex] = [int]$recordCounts[$scopeIndex] + 1 }
        else { $recordCounts[$scopeIndex] = 1 }
    }
    for ($index = 0; $index -lt $mappingScopes.Count; $index++) {
        $count = if ($recordCounts.ContainsKey($index)) { [int]$recordCounts[$index] } else { 0 }
        if ($count -ne (Get-RequiredInt32 -Object $mappingScopes[$index] -Name 'recordCount' -Context 'Candidate mapping scope')) {
            throw 'Candidate mapping scope recordCount is inconsistent with records.'
        }
    }

    Assert-ExactPropertySet -Object $Symbol -Allowed @('applicationPath', 'canonicalPayloadByteCount', 'payloadSha256', 'shapeSummary') -Context 'Candidate Symbol facts'
    if ((Get-RequiredString -Object $Symbol -Name 'applicationPath' -Context 'Candidate Symbol facts') -ne
        (Get-RequiredString -Object $Scope -Name 'symbolApplicationPath' -Context 'Engineering semantic scope')) {
        throw 'Candidate Symbol applicationPath does not match the current controlled scope.'
    }
    $null = Get-RequiredInt32 -Object $Symbol -Name 'canonicalPayloadByteCount' -Context 'Candidate Symbol facts'
    Assert-HexSha256 -Value (Get-RequiredString -Object $Symbol -Name 'payloadSha256' -Context 'Candidate Symbol facts') -Context 'Candidate Symbol payloadSha256'
    $shape = Get-RequiredObject -Object $Symbol -Name 'shapeSummary' -Context 'Candidate Symbol facts'
    Assert-ExactPropertySet -Object $shape -Allowed @('rootKind', 'topLevelKeys', 'objectCount', 'arrayCount', 'scalarCount', 'nodeCount', 'maxDepth') -Context 'Candidate Symbol shape summary'
    $rootKind = Get-RequiredString -Object $shape -Name 'rootKind' -Context 'Candidate Symbol shape summary'
    if ($rootKind -notin @('object', 'array', 'string', 'number', 'boolean', 'null')) { throw 'Candidate Symbol rootKind is unsupported.' }
    $topKeys = Get-RequiredArray -Object $shape -Name 'topLevelKeys' -Context 'Candidate Symbol shape summary'
    $previousKey = $null
    foreach ($keyValue in $topKeys) {
        if ($keyValue -isnot [string]) { throw 'Candidate Symbol topLevelKeys must contain strings.' }
        $key = [string]$keyValue
        if (($null -ne $previousKey) -and ([System.StringComparer]::Ordinal.Compare([string]$previousKey, $key) -ge 0)) {
            throw 'Candidate Symbol topLevelKeys are not unique ordinal strings.'
        }
        $previousKey = $key
    }
    if (($rootKind -ne 'object') -and ($topKeys.Count -ne 0)) { throw 'Only object Symbol payloads may have topLevelKeys.' }
    $objectCount = Get-RequiredInt32 -Object $shape -Name 'objectCount' -Context 'Candidate Symbol shape summary'
    $arrayCount = Get-RequiredInt32 -Object $shape -Name 'arrayCount' -Context 'Candidate Symbol shape summary'
    $scalarCount = Get-RequiredInt32 -Object $shape -Name 'scalarCount' -Context 'Candidate Symbol shape summary'
    $nodeCount = Get-RequiredInt32 -Object $shape -Name 'nodeCount' -Context 'Candidate Symbol shape summary'
    $maxDepth = Get-RequiredInt32 -Object $shape -Name 'maxDepth' -Context 'Candidate Symbol shape summary'
    if (($nodeCount -ne ($objectCount + $arrayCount + $scalarCount)) -or ($nodeCount -eq 0) -or ($maxDepth -gt 128)) {
        throw 'Candidate Symbol shape counters are inconsistent.'
    }
}

function Write-ImmutableCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $text = (ConvertTo-CanonicalJson -Value $Value) + [Environment]::NewLine
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($text)
    if ($bytes.Length -gt $maximumCandidateBytes) { throw 'Semantic baseline candidate exceeds its bounded artifact contract.' }
    $sha = Get-Sha256ForBytes -Bytes $bytes
    if ([System.IO.File]::Exists($Path)) {
        $existing = Get-Sha256ForBytes -Bytes ([System.IO.File]::ReadAllBytes($Path))
        if ($existing -eq $sha) { return [pscustomobject]@{ path = $Path; sha256 = $sha; written = $false } }
        throw "Immutable semantic baseline candidate already exists with different content: $Path"
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
$resolvedScopePath = Assert-PathInsideRoot -Root (Join-Path $resolvedEngineeringRoot 'config') -Path (Join-Path $resolvedEngineeringRoot $ScopePath) -Context 'Engineering semantic scope'
if (-not $resolvedScopePath.Equals((Join-Path $resolvedEngineeringRoot 'config\engineering-semantic-scope.json'), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Only config/engineering-semantic-scope.json is supported.'
}

$evidenceDocument = Read-JsonDocumentExact -Path $resolvedEvidencePath -Context 'Runner evidence input' -MaximumBytes $maximumInputBytes
$scopeDocument = Read-JsonDocumentExact -Path $resolvedScopePath -Context 'Engineering semantic scope' -MaximumBytes $maximumScopeBytes
Assert-NoSecrets -Value $evidenceDocument.payload
Assert-NoSecrets -Value $scopeDocument.payload
$validated = Assert-BlockedEvidence -Evidence $evidenceDocument.payload -ExpectedEngineeringRoot $resolvedEngineeringRoot

$semanticProofs = Get-RequiredObject -Object $validated.result -Name 'semanticProofs' -Context 'Runner evidence result'
$plcRelativePath = Get-RelativePathInsideRoot -Root $validated.stationRoot -Path $validated.plcProject -Context 'Runner evidence PLC project'
$scopeSha = Get-Sha256ForBytes -Bytes $scopeDocument.bytes
$previousBaseline = $null
if ($validated.reasonCode -eq 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED') {
    $mappingProof = Get-CandidateProof -Proofs $semanticProofs -Name 'mapping' -HashField 'actualMappingSha256'
    $symbolProof = Get-CandidateProof -Proofs $semanticProofs -Name 'symbolPostProcessing' -HashField 'actualSymbolConfigSha256'
    $mappingRecordCount = Get-RequiredInt32 -Object (Get-RequiredObject -Object $semanticProofs -Name 'mapping' -Context 'Runner semantic proofs') -Name 'actualRecordCount' -Context 'Runner mapping proof'
    if ($mappingRecordCount -ne (Get-RequiredInt32 -Object $mappingProof.facts -Name 'recordCount' -Context 'Candidate mapping facts')) {
        throw 'Runner mapping proof actualRecordCount does not match candidateCanonicalFacts.'
    }
}
else {
    $baselinePath = Join-Path $resolvedEngineeringRoot 'config\engineering-semantic-baseline.json'
    $baselineDocument = Read-JsonDocumentExact -Path $baselinePath -Context 'Reviewed engineering semantic baseline' -MaximumBytes $maximumBaselineBytes
    Assert-NoSecrets -Value $baselineDocument.payload
    $refresh = Get-SymbolRefreshFacts -BaselineDocument $baselineDocument -Proofs $semanticProofs -ScopeSha256 $scopeSha -PlcRelativePath $plcRelativePath -Profile $validated.profile
    $mappingProof = [pscustomobject]@{ facts = $refresh.mapping; sha256 = $refresh.mappingSha256 }
    $symbolProof = [pscustomobject]@{ facts = $refresh.symbol; sha256 = $refresh.symbolSha256 }
    $previousBaseline = $refresh.previousBaseline
}
Assert-ScopeAndFacts -Scope $scopeDocument.payload -Mapping $mappingProof.facts -Symbol $symbolProof.facts -PlcRelativePath $plcRelativePath -Profile $validated.profile

$canonicalFacts = [ordered]@{
    mapping = $mappingProof.facts
    symbolConfig = $symbolProof.facts
}
$snapshotSha = Get-Sha256ForText -Text (ConvertTo-CanonicalJson -Value $canonicalFacts)
$evidenceRelativePath = Get-RelativePathInsideRoot -Root $resolvedEngineeringRoot -Path $resolvedEvidencePath -Context 'Runner evidence input'
$evidenceSha = Get-Sha256ForBytes -Bytes $evidenceDocument.bytes
$candidate = [ordered]@{
    schemaVersion = 1
    kind = 'ctrlx-opcon-engineering-semantic-baseline-candidate'
    project = [ordered]@{
        plcProjectRelativePath = $plcRelativePath
        profile = $validated.profile
    }
    scopeSha256 = $scopeSha
    canonicalFacts = $canonicalFacts
    hashes = [ordered]@{
        algorithm = 'SHA-256'
        canonicalization = $canonicalization
        mappingSha256 = $mappingProof.sha256
        symbolConfigSha256 = $symbolProof.sha256
        snapshotSha256 = $snapshotSha
    }
    sourceEvidence = [ordered]@{
        path = $evidenceRelativePath
        sha256 = $evidenceSha
        operationId = Get-RequiredString -Object $evidenceDocument.payload -Name 'operationId' -Context 'Runner evidence'
        actionId = $validated.actionId
        actionRequestSha256 = (Get-RequiredString -Object $evidenceDocument.payload -Name 'actionRequestSha256' -Context 'Runner evidence').ToLowerInvariant()
        completedAtUtc = Get-RequiredString -Object $evidenceDocument.payload -Name 'completedAtUtc' -Context 'Runner evidence'
    }
    review = [ordered]@{
        state = 'pending-human-review'
        automaticPromotionAllowed = $false
        requiredUserInputs = @('confirmedByUser')
        targetBaselinePath = 'config/engineering-semantic-baseline.json'
    }
}
if ($null -ne $previousBaseline) { $candidate['previousBaseline'] = $previousBaseline }
Assert-NoSecrets -Value $candidate

$reviewRoot = Join-Path $resolvedEngineeringRoot 'docs\reviews'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $reviewRoot ('engineering-semantic-baseline-candidate-' + $validated.actionId + '.json')
}
$resolvedOutputPath = Assert-PathInsideRoot -Root $reviewRoot -Path $OutputPath -Context 'Semantic baseline candidate output'
if ($requestedWhatIf -or (-not $PSCmdlet.ShouldProcess($resolvedOutputPath, 'Write immutable semantic baseline review candidate'))) {
    [pscustomobject]@{
        status = 'WHATIF'
        path = $resolvedOutputPath
        candidate = $candidate
    }
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
