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

function Test-JsonInt32 {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    return (($Value -is [int]) -or ($Value -is [long])) -and
        ([long]$Value -ge [int]::MinValue) -and
        ([long]$Value -le [int]::MaxValue)
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
        $desktopEdition = (-not $PSVersionTable.ContainsKey('PSEdition')) -or ($PSVersionTable.PSEdition -eq 'Desktop')
        if ($desktopEdition) {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength = [int]::MaxValue
            $serializer.RecursionLimit = 256
            $rawRoot = $serializer.DeserializeObject($RawJson)
        }
        else {
            $rawRoot = $RawJson | ConvertFrom-Json
        }
    }
    catch {
        throw "$Context JSON shape could not be validated. $($_.Exception.Message)"
    }
    $rawValue = $rawRoot
    foreach ($propertyName in $PropertyPath) {
        if ($desktopEdition) {
            if (($rawValue -isnot [System.Collections.IDictionary]) -or (-not ($rawValue.Keys -contains $propertyName))) {
                throw "$Context is missing $($PropertyPath -join '.')."
            }
            $rawValue = $rawValue[$propertyName]
        }
        else {
            if ($null -eq $rawValue) {
                throw "$Context is missing $($PropertyPath -join '.')."
            }
            $property = $rawValue.PSObject.Properties[$propertyName]
            if ($null -eq $property) {
                throw "$Context is missing $($PropertyPath -join '.')."
            }
            $rawValue = $property.Value
        }
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

function Test-ClearlyRedactedSensitiveValue {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

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
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

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

function Assert-NoSensitiveFields {
    param(
        [Parameter(Mandatory = $false)][object]$Value,
        [Parameter(Mandatory = $false)][string]$Path = '$',
        [Parameter(Mandatory = $false)][int]$Depth = 0,
        [Parameter(Mandatory = $false)][AllowNull()][object]$State = $null
    )

    if ($Depth -gt 128) { throw "Sensitive-value scan exceeded its maximum depth at $Path." }
    if ($null -eq $State) {
        $State = [pscustomobject]@{ nodes = [long]0; stringBytes = [long]0 }
    }
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
            throw "Secret-like string value is prohibited at $Path."
        }
        return
    }
    if ($Value -is [ValueType]) { return }
    if (($Value -is [System.Array]) -or ($Value -is [System.Collections.IList])) {
        $index = 0
        foreach ($item in $Value) {
            Assert-NoSensitiveFields -Value $item -Path ($Path + '[' + $index + ']') -Depth ($Depth + 1) -State $State
            $index++
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            $nameBytes = [System.Text.Encoding]::UTF8.GetByteCount($name)
            $State.stringBytes = [long]$State.stringBytes + $nameBytes
            if (($nameBytes -gt 4096) -or ([long]$State.stringBytes -gt (8 * 1024 * 1024))) {
                throw "Sensitive-value scan exceeded its bounded property-name budget at $Path."
            }
            if (Test-StringContainsSecretLikeValue -Text $name) {
                throw "Secret-like content is prohibited in a property name below $Path."
            }
            $child = $Value[$key]
            if (($name -match '^(?i:password|passwd|pwd|secret|client[_-]?secret|api[_-]?key|access[_-]?key|secret[_-]?key|shared[_-]?access[_-]?key|account[_-]?key|access[_-]?token|refresh[_-]?token|auth(?:orization)?[_-]?token|bearer[_-]?token|sas[_-]?token|private[_-]?key|credential|credentials)$') -and
                (-not (Test-ClearlyRedactedSensitiveValue -Value $child))) {
                throw "Runner observation contains a prohibited secret-bearing field: $Path.$name"
            }
            Assert-NoSensitiveFields -Value $child -Path ($Path + '.' + $name) -Depth ($Depth + 1) -State $State
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        $name = [string]$property.Name
        $nameBytes = [System.Text.Encoding]::UTF8.GetByteCount($name)
        $State.stringBytes = [long]$State.stringBytes + $nameBytes
        if (($nameBytes -gt 4096) -or ([long]$State.stringBytes -gt (8 * 1024 * 1024))) {
            throw "Sensitive-value scan exceeded its bounded property-name budget at $Path."
        }
        if (Test-StringContainsSecretLikeValue -Text $name) {
            throw "Secret-like content is prohibited in a property name below $Path."
        }
        if (($name -match '^(?i:password|passwd|pwd|secret|client[_-]?secret|api[_-]?key|access[_-]?key|secret[_-]?key|shared[_-]?access[_-]?key|account[_-]?key|access[_-]?token|refresh[_-]?token|auth(?:orization)?[_-]?token|bearer[_-]?token|sas[_-]?token|private[_-]?key|credential|credentials)$') -and
            (-not (Test-ClearlyRedactedSensitiveValue -Value $property.Value))) {
            throw "Runner observation contains a prohibited secret-bearing field: $Path.$($property.Name)"
        }
        Assert-NoSensitiveFields -Value $property.Value -Path ($Path + '.' + $name) -Depth ($Depth + 1) -State $State
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
    Assert-ExactPropertySet -Object $guardrails -Allowed @(
        'offlineOnly',
        'onlineOperationsAllowed',
        'requireExistingPersistentSession',
        'prohibitPleOrMcpStartByAction',
        'prohibitDirectWatcherIpc',
        'requireExactProjectOpen',
        'actionProjectGateRequired',
        'releaseActionProjectGateBeforeTerminalDelivery',
        'symbolAccessSerialized',
        'actionProjectGateKind'
    ) -Context 'Runner action guardrails'
    if ((-not (Get-RequiredBoolean -Object $guardrails -Name 'offlineOnly' -Context 'Runner action guardrails')) -or
        (Get-RequiredBoolean -Object $guardrails -Name 'onlineOperationsAllowed' -Context 'Runner action guardrails') -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'requireExistingPersistentSession' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'prohibitPleOrMcpStartByAction' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'prohibitDirectWatcherIpc' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'requireExactProjectOpen' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'actionProjectGateRequired' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'releaseActionProjectGateBeforeTerminalDelivery' -Context 'Runner action guardrails')) -or
        (-not (Get-RequiredBoolean -Object $guardrails -Name 'symbolAccessSerialized' -Context 'Runner action guardrails')) -or
        ((Get-RequiredString -Object $guardrails -Name 'actionProjectGateKind' -Context 'Runner action guardrails') -ne 'broker-session-action-serialization')) {
        throw 'Runner action does not contain the required offline/single-session guardrails.'
    }
    $evidenceContract = Get-PropertyValue -Object $Action -Name 'evidenceContract'
    Assert-ExactPropertySet -Object $evidenceContract -Allowed @(
        'schemaVersion',
        'requireActionRequestSha256',
        'requireOfflineOnly',
        'requireActionProjectGateReleased',
        'requireReadbackOnSuccess',
        'requireFreshBuildOnSuccess',
        'terminalFailureMayOmitBuild',
        'warningComparison'
    ) -Context 'Runner action evidenceContract'
    if (([int](Get-PropertyValue -Object $evidenceContract -Name 'schemaVersion' -DefaultValue 0) -ne 1) -or
        (-not (Get-RequiredBoolean -Object $evidenceContract -Name 'requireActionRequestSha256' -Context 'Runner action evidenceContract')) -or
        (-not (Get-RequiredBoolean -Object $evidenceContract -Name 'requireOfflineOnly' -Context 'Runner action evidenceContract')) -or
        (-not (Get-RequiredBoolean -Object $evidenceContract -Name 'requireActionProjectGateReleased' -Context 'Runner action evidenceContract'))) {
        throw 'Runner action does not contain the required evidence contract.'
    }

    return [pscustomobject]@{
        actionKind      = $actionKind
        engineeringRoot = $engineeringRoot
        stationRoot      = $stationRoot
        plcProject       = $plcProject
        profile          = [string]$project.profile
    }
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
        if ([int]$character -lt 0x20) {
            [void]$Builder.Append(('\u{0:x4}' -f [int]$character))
        }
        else {
            [void]$Builder.Append($character)
        }
    }
    [void]$Builder.Append('"')
}

function ConvertTo-CanonicalWarningJson {
    param([Parameter(Mandatory = $true)][object]$CanonicalRecord)

    # ctrlx-semantic-canonical-json-v1: object keys are ordinal-sorted and
    # strings retain literal Unicode before UTF-8 SHA-256 hashing.
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('{')
    $names = @('code', 'message', 'objectPath', 'position', 'source')
    for ($index = 0; $index -lt $names.Count; $index++) {
        if ($index -gt 0) { [void]$builder.Append(',') }
        $name = $names[$index]
        Add-CanonicalJsonString -Value $name -Builder $builder
        [void]$builder.Append(':')
        Add-CanonicalJsonString -Value ([string](Get-PropertyValue -Object $CanonicalRecord -Name $name -DefaultValue '')) -Builder $builder
    }
    [void]$builder.Append('}')
    return $builder.ToString()
}

function ConvertTo-NormalizedWarningText {
    param([Parameter(Mandatory = $true)][object]$Record)

    if ($Record -is [string]) {
        $text = ([string]$Record).Trim() -replace '\s+', ' '
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw 'Warning records cannot be empty.'
        }
        return ConvertTo-CanonicalWarningJson -CanonicalRecord ([ordered]@{
            code       = ''
            source     = ''
            objectPath = ''
            position   = ''
            message    = $text
        })
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
    return ConvertTo-CanonicalWarningJson -CanonicalRecord $canonical
}

function Test-PleWarningOutputTruncationSentinel {
    param([Parameter(Mandatory = $true)][object]$Record)

    if ($Record -is [string]) {
        $message = [string]$Record
    }
    else {
        $message = [string](Get-PropertyValue -Object $Record -Name 'message')
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = [string](Get-PropertyValue -Object $Record -Name 'description')
        }
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = [string](Get-PropertyValue -Object $Record -Name 'text')
        }
    }

    $normalized = ($message.Trim() -replace '\s+', ' ')
    return $normalized -match '(?i)\AMore than [0-9]+ warnings occurr?ed: Skipping all further warning messages\z'
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
        if (Test-PleWarningOutputTruncationSentinel -Record $record) {
            throw 'PLE warning output is truncated; its sentinel cannot be sealed as a complete warning-signature comparison.'
        }
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

function ConvertTo-BlockedBuildEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Build,
        [Parameter(Mandatory = $true)][string]$RawObservationJson,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][DateTime]$ActionCreatedAt,
        [Parameter(Mandatory = $true)][DateTime]$ObservationCompletedAt
    )

    Assert-ExactPropertySet -Object $Build -Allowed @(
        'buildId',
        'projectPath',
        'profile',
        'projectSha256',
        'startedAtUtc',
        'completedAtUtc',
        'verified',
        'errors',
        'warnings',
        'messageCount',
        'typedRecordsVerified',
        'diagnosticRowsComplete',
        'warningRecordsSafeForReview',
        'warningRecords',
        'diagnosticRows',
        'summarySource'
    ) -Context 'Blocked fresh Build observation'
    Assert-JsonArrayProperty -RawJson $RawObservationJson -PropertyPath @('result', 'build', 'warningRecords') -Context 'Blocked fresh Build observation'
    Assert-JsonArrayProperty -RawJson $RawObservationJson -PropertyPath @('result', 'build', 'diagnosticRows') -Context 'Blocked fresh Build observation'

    $buildStarted = [DateTime]::MinValue
    $buildCompleted = [DateTime]::MinValue
    if ((-not [DateTime]::TryParse((Get-RequiredString -Object $Build -Name 'startedAtUtc' -Context 'Blocked fresh Build'), [ref]$buildStarted)) -or
        (-not [DateTime]::TryParse((Get-RequiredString -Object $Build -Name 'completedAtUtc' -Context 'Blocked fresh Build'), [ref]$buildCompleted)) -or
        ($buildStarted.ToUniversalTime() -lt $ActionCreatedAt.ToUniversalTime()) -or
        ($buildCompleted.ToUniversalTime() -lt $buildStarted.ToUniversalTime()) -or
        ($buildCompleted.ToUniversalTime() -gt $ObservationCompletedAt.ToUniversalTime())) {
        throw 'Blocked Build timestamps are not fresh for the immutable action.'
    }

    $errorsValue = Get-PropertyValue -Object $Build -Name 'errors'
    $warningsValue = Get-PropertyValue -Object $Build -Name 'warnings'
    $messageCountValue = Get-PropertyValue -Object $Build -Name 'messageCount'
    if ((-not (Test-JsonInt32 -Value $errorsValue)) -or
        (-not (Test-JsonInt32 -Value $warningsValue)) -or
        (-not (Test-JsonInt32 -Value $messageCountValue))) {
        throw 'Blocked fresh Build counts must be JSON integers.'
    }
    $errors = [int]$errorsValue
    $warnings = [int]$warningsValue
    $messageCount = [int]$messageCountValue
    if (($errors -ne 0) -or ($warnings -lt 0) -or ($warnings -gt 2048) -or
        ($messageCount -lt $warnings) -or ($messageCount -gt 2048)) {
        throw 'Blocked fresh Build must be a zero-error bounded Build.'
    }
    if (-not (Get-RequiredBoolean -Object $Build -Name 'verified' -Context 'Blocked fresh Build')) {
        throw 'Blocked fresh Build must be producer-verified.'
    }
    $typedRecordsVerified = Get-RequiredBoolean -Object $Build -Name 'typedRecordsVerified' -Context 'Blocked fresh Build'
    $diagnosticRowsComplete = Get-RequiredBoolean -Object $Build -Name 'diagnosticRowsComplete' -Context 'Blocked fresh Build'
    $warningRecordsSafeForReview = Get-RequiredBoolean -Object $Build -Name 'warningRecordsSafeForReview' -Context 'Blocked fresh Build'
    if ($warningRecordsSafeForReview -and (-not $typedRecordsVerified)) {
        throw 'Blocked fresh Build cannot mark untyped warning records safe for review.'
    }
    if ((Get-RequiredString -Object $Build -Name 'summarySource' -Context 'Blocked fresh Build') -ne 'codesys-persistent.compile_project') {
        throw 'Blocked fresh Build summarySource is unsupported.'
    }
    $buildId = Get-RequiredString -Object $Build -Name 'buildId' -Context 'Blocked fresh Build'
    if ($buildId -notmatch '^[A-Za-z0-9_.:-]{1,128}$') {
        throw 'Blocked fresh Build buildId is invalid.'
    }
    $observedProjectPath = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $Build -Name 'projectPath' -Context 'Blocked fresh Build'))
    $observedProfile = Get-RequiredString -Object $Build -Name 'profile' -Context 'Blocked fresh Build'
    $observedProjectSha = Get-RequiredString -Object $Build -Name 'projectSha256' -Context 'Blocked fresh Build'
    $currentProjectSha = (Get-FileHash -LiteralPath ([string]$Identity.plcProject) -Algorithm SHA256).Hash
    if ((-not $observedProjectPath.Equals([string]$Identity.plcProject, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ($observedProfile -ne [string]$Identity.profile) -or
        (-not (Test-HexSha256 -Value $observedProjectSha)) -or
        (-not $observedProjectSha.Equals($currentProjectSha, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Blocked fresh Build project/profile/SHA does not match the immutable action and current PLC project.'
    }

    $warningRecords = @(Get-PropertyValue -Object $Build -Name 'warningRecords' -DefaultValue @())
    if (($typedRecordsVerified -and $warningRecordsSafeForReview -and ($warningRecords.Count -ne $warnings)) -or
        ((-not $typedRecordsVerified) -and ($warningRecords.Count -ne 0)) -or
        ($typedRecordsVerified -and (-not $warningRecordsSafeForReview) -and ($warningRecords.Count -ne 0)) -or
        ($typedRecordsVerified -and ($messageCount -ne $warnings))) {
        throw 'Blocked fresh Build warning record count/safety flags are inconsistent.'
    }
    $validatedWarningRecords = @()
    $warningBytes = 0
    foreach ($record in $warningRecords) {
        if (($record -isnot [string]) -or [string]::IsNullOrWhiteSpace([string]$record)) {
            throw 'Blocked fresh Build warningRecords must contain non-empty strings.'
        }
        $trimmed = ([string]$record).Trim()
        $warningBytes += [System.Text.Encoding]::UTF8.GetByteCount($trimmed)
        if (($warningBytes -gt (256 * 1024)) -or
            ([System.Text.Encoding]::UTF8.GetByteCount($trimmed) -gt 4096)) {
            throw 'Blocked fresh Build warningRecords exceed the bounded review budget.'
        }
        $validatedWarningRecords += $trimmed
    }

    $diagnosticRows = @(Get-PropertyValue -Object $Build -Name 'diagnosticRows' -DefaultValue @())
    if (($diagnosticRows.Count -gt $messageCount) -or
        ($diagnosticRowsComplete -and ($diagnosticRows.Count -ne $messageCount))) {
        throw 'Blocked fresh Build diagnosticRows do not match their completeness flag.'
    }
    $validatedDiagnosticRows = @()
    $diagnosticBytes = 0
    foreach ($row in $diagnosticRows) {
        if (($row -isnot [string]) -or [string]::IsNullOrWhiteSpace([string]$row)) {
            throw 'Blocked fresh Build diagnosticRows must contain non-empty strings.'
        }
        $trimmed = ([string]$row).Trim()
        $diagnosticBytes += [System.Text.Encoding]::UTF8.GetByteCount($trimmed)
        if (($diagnosticBytes -gt (256 * 1024)) -or
            ([System.Text.Encoding]::UTF8.GetByteCount($trimmed) -gt 4096)) {
            throw 'Blocked fresh Build diagnosticRows exceed the bounded review budget.'
        }
        $validatedDiagnosticRows += $trimmed
    }

    return [ordered]@{
        buildId                     = $buildId
        projectPath                 = $observedProjectPath
        profile                     = $observedProfile
        projectSha256               = $observedProjectSha.ToUpperInvariant()
        startedAtUtc                = $buildStarted.ToUniversalTime().ToString('o')
        completedAtUtc              = $buildCompleted.ToUniversalTime().ToString('o')
        verified                    = $true
        errors                      = $errors
        warnings                    = $warnings
        messageCount                = $messageCount
        typedRecordsVerified        = $typedRecordsVerified
        diagnosticRowsComplete      = $diagnosticRowsComplete
        warningRecordsSafeForReview = $warningRecordsSafeForReview
        warningRecords              = @($validatedWarningRecords)
        diagnosticRows              = @($validatedDiagnosticRows)
        summarySource               = 'codesys-persistent.compile_project'
    }
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
    'compile_project',
    'get_ctrlx_semantic_snapshot'
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
if ($status -eq 'succeeded') {
    if ($identity.actionKind -eq 'apply_change_set_and_build') {
        throw 'apply_change_set_and_build is not supported by the typed Broker and cannot produce successful evidence.'
    }
    foreach ($requiredCapability in @('get_codesys_status', 'compile_project', 'get_ctrlx_semantic_snapshot')) {
        if (@($capabilities | Where-Object { [string]$_ -eq $requiredCapability }).Count -ne 1) {
            throw "Successful runner observation must report capability '$requiredCapability' exactly once."
        }
    }
}

$observedGuardrails = Get-PropertyValue -Object $observation -Name 'guardrails'
Assert-ExactPropertySet -Object $observedGuardrails -Allowed @(
    'onlineOperationsUsed',
    'secondPleStarted',
    'actionProjectGateAcquired',
    'actionProjectGateReleased',
    'actionProjectGateKind',
    'symbolLeaseHeld',
    'pleOrMcpStartedByAction',
    'directWatcherIpcUsed'
) -Context 'Runner observation guardrails'
$onlineOperationsUsed = Get-RequiredBoolean -Object $observedGuardrails -Name 'onlineOperationsUsed' -Context 'Runner observation guardrails'
$secondPleStarted = Get-RequiredBoolean -Object $observedGuardrails -Name 'secondPleStarted' -Context 'Runner observation guardrails'
$actionProjectGateAcquired = Get-RequiredBoolean -Object $observedGuardrails -Name 'actionProjectGateAcquired' -Context 'Runner observation guardrails'
$actionProjectGateReleased = Get-RequiredBoolean -Object $observedGuardrails -Name 'actionProjectGateReleased' -Context 'Runner observation guardrails'
$actionProjectGateKind = Get-RequiredString -Object $observedGuardrails -Name 'actionProjectGateKind' -Context 'Runner observation guardrails'
$symbolLeaseHeld = Get-RequiredBoolean -Object $observedGuardrails -Name 'symbolLeaseHeld' -Context 'Runner observation guardrails'
$pleOrMcpStartedByAction = Get-RequiredBoolean -Object $observedGuardrails -Name 'pleOrMcpStartedByAction' -Context 'Runner observation guardrails'
$directWatcherIpcUsed = Get-RequiredBoolean -Object $observedGuardrails -Name 'directWatcherIpcUsed' -Context 'Runner observation guardrails'
if (-not $actionProjectGateReleased) {
    throw 'Runner observation must prove that the action project serialization gate was released.'
}
if ($actionProjectGateAcquired) {
    if ($actionProjectGateKind -ne 'broker-session-action-serialization') {
        throw 'An acquired action project gate must use broker-session-action-serialization.'
    }
}
elseif ($actionProjectGateKind -ne 'none') {
    throw 'A non-acquired action project gate must use kind=none.'
}
if ($onlineOperationsUsed -or $secondPleStarted -or $symbolLeaseHeld -or
    $pleOrMcpStartedByAction -or $directWatcherIpcUsed) {
    throw 'Runner observation violates the offline, single-PLE, or released action-gate guardrail.'
}
if (($status -eq 'succeeded') -and (-not $actionProjectGateAcquired)) {
    throw 'A successful runner observation must explicitly record the Broker action project gate.'
}

$observedResult = Get-PropertyValue -Object $observation -Name 'result'
Assert-JsonArrayProperty -RawJson $observationDocument.raw -PropertyPath @('result', 'proposedChanges') -Context 'Runner observation'
Assert-JsonArrayProperty -RawJson $observationDocument.raw -PropertyPath @('result', 'appliedChanges') -Context 'Runner observation'
$terminalObservation = @('blocked', 'failed') -contains $status
$blockedBuildObservation = $null
if ($terminalObservation) {
    if ($null -ne $observation.PSObject.Properties['session']) {
        throw 'Blocked/failed runner observation must not contain a session object.'
    }
    if ($null -ne $observedResult.PSObject.Properties['acceptance']) {
        throw 'Blocked/failed runner observation must not contain result.acceptance.'
    }
    $terminalBuildProperty = $observedResult.PSObject.Properties['build']
    if ($null -ne $terminalBuildProperty) {
        if ($status -ne 'blocked') {
            throw 'Failed runner observation must not contain result.build.'
        }
        $blockedBuildObservation = $terminalBuildProperty.Value
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
$semanticProofs = Get-PropertyValue -Object $observedResult -Name 'semanticProofs'
if ($status -eq 'succeeded' -and $null -eq $semanticProofs) {
    throw 'A successful runner observation must contain result.semanticProofs.'
}
$hasUnverifiedSemanticProof = $false
if ($null -ne $semanticProofs) {
    $proofNames = @('ownership', 'readback', 'recoverableBaseline', 'warnings', 'semanticBaseline', 'mapping', 'symbolPostProcessing')
    Assert-ExactPropertySet -Object $semanticProofs -Allowed (@('contractVersion') + $proofNames) -Context 'Runner observation semanticProofs'
    $proofContractVersion = Get-PropertyValue -Object $semanticProofs -Name 'contractVersion'
    if ((-not (Test-JsonInt32 -Value $proofContractVersion)) -or ([int]$proofContractVersion -ne 1)) {
        throw 'Runner observation semanticProofs contractVersion must be 1.'
    }
    foreach ($proofName in $proofNames) {
        $proof = Get-PropertyValue -Object $semanticProofs -Name $proofName
        if ($null -eq $proof) {
            throw "Runner observation semanticProofs is missing '$proofName'."
        }
        $proofVersion = Get-PropertyValue -Object $proof -Name 'contractVersion'
        if ((-not (Test-JsonInt32 -Value $proofVersion)) -or ([int]$proofVersion -ne 1)) {
            throw "Runner observation semantic proof '$proofName' contractVersion must be 1."
        }
        $proofVerified = Get-RequiredBoolean -Object $proof -Name 'verified' -Context "Runner observation semantic proof '$proofName'"
        if (($status -eq 'succeeded') -and (-not $proofVerified)) {
            throw "A successful runner observation has incomplete semantic proof '$proofName'."
        }
        if (-not $proofVerified) {
            $hasUnverifiedSemanticProof = $true
        }
    }
    $evidenceResult['semanticProofs'] = $semanticProofs
}
$nextRoute = Get-PropertyValue -Object $observedResult -Name 'nextRoute'
if ($null -ne $nextRoute) {
    if ($status -eq 'succeeded') {
        throw 'A successful runner observation cannot contain result.nextRoute.'
    }
    Assert-ExactPropertySet -Object $nextRoute -Allowed @('kind', 'reasonCode', 'automaticExecutionAllowed') -Context 'Runner observation nextRoute'
    $null = Get-RequiredString -Object $nextRoute -Name 'kind' -Context 'Runner observation nextRoute'
    $null = Get-RequiredString -Object $nextRoute -Name 'reasonCode' -Context 'Runner observation nextRoute'
    if (Get-RequiredBoolean -Object $nextRoute -Name 'automaticExecutionAllowed' -Context 'Runner observation nextRoute') {
        throw 'Runner observation nextRoute must require manual review.'
    }
    $evidenceResult['nextRoute'] = $nextRoute
}
if ($null -ne $blockedBuildObservation) {
    $blockedFailureStage = Get-RequiredString -Object $observedResult -Name 'failureStage' -Context 'Blocked runner observation result'
    if (($blockedFailureStage -ne 'semantic-acceptance') -or
        ($identity.actionKind -notin @('inspect_and_build', 'verify_after_export_2')) -or
        (-not $actionProjectGateAcquired) -or
        ($null -eq $semanticProofs) -or
        (-not $hasUnverifiedSemanticProof)) {
        throw 'Only a semantic-acceptance BLOCKED observation after an acquired action gate may retain fresh Build evidence.'
    }
    foreach ($requiredCapability in @('get_codesys_status', 'compile_project')) {
        if (@($capabilities | Where-Object { [string]$_ -eq $requiredCapability }).Count -ne 1) {
            throw "Blocked fresh Build observation must report capability '$requiredCapability' exactly once."
        }
    }
    if (@($capabilities | Where-Object { [string]$_ -eq 'get_ctrlx_semantic_snapshot' }).Count -gt 1) {
        throw 'Blocked fresh Build observation cannot report duplicate semantic snapshot calls.'
    }
    $evidenceResult['build'] = ConvertTo-BlockedBuildEvidence `
        -Build $blockedBuildObservation `
        -RawObservationJson $observationDocument.raw `
        -Identity $identity `
        -ActionCreatedAt $actionCreatedAt `
        -ObservationCompletedAt $completedAt
}
$evidenceSession = $null

if ($status -eq 'succeeded') {
    $session = Get-PropertyValue -Object $observation -Name 'session'
    if ($null -eq $session) {
        throw 'A successful runner observation must contain the reused persistent session identity.'
    }
    Assert-ExactPropertySet -Object $session -Allowed @('state', 'mode', 'sessionId', 'plePid', 'mcpPid', 'profile', 'activeProjectPath', 'pleOwnedByBroker') -Context 'Runner observation session'
    $sessionState = Get-RequiredString -Object $session -Name 'state' -Context 'Runner session'
    $sessionMode = Get-RequiredString -Object $session -Name 'mode' -Context 'Runner session'
    $sessionId = Get-RequiredString -Object $session -Name 'sessionId' -Context 'Runner session'
    $sessionPid = [int](Get-PropertyValue -Object $session -Name 'plePid' -DefaultValue 0)
    $sessionMcpPid = [int](Get-PropertyValue -Object $session -Name 'mcpPid' -DefaultValue 0)
    $sessionProfile = Get-RequiredString -Object $session -Name 'profile' -Context 'Runner session'
    $activeProjectPath = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $session -Name 'activeProjectPath' -Context 'Runner session'))
    $pleOwnedByBroker = Get-RequiredBoolean -Object $session -Name 'pleOwnedByBroker' -Context 'Runner session'
    if (($sessionState -ne 'ready') -or ($sessionMode -ne 'persistent') -or
        ($sessionId -notmatch '^[A-Za-z0-9_.-]{1,128}$') -or ($sessionPid -le 0) -or ($sessionMcpPid -le 0) -or
        ($sessionProfile -ne $identity.profile) -or
        (-not $activeProjectPath.Equals($identity.plcProject, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Observed persistent session does not match the required ready/profile/project identity.'
    }
    $evidenceSession = [ordered]@{
        state             = $sessionState
        mode              = $sessionMode
        sessionId         = $sessionId
        plePid            = $sessionPid
        mcpPid            = $sessionMcpPid
        profile           = $sessionProfile
        activeProjectPath = $activeProjectPath
        pleOwnedByBroker  = $pleOwnedByBroker
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
    Assert-ExactPropertySet -Object $acceptance -Allowed @(
        'ownershipVerified',
        'mappingConsistent',
        'readbackVerified',
        'recoverableBaselineVerified',
        'warningSignaturesReviewed',
        'existingSessionReused',
        'pleOrMcpStartedByAction',
        'directWatcherIpcUsed',
        'symbolPostProcessingVerified'
    ) -Context 'Runner observation acceptance'
    $evidenceResult.acceptance = [ordered]@{}
    foreach ($name in @('ownershipVerified', 'mappingConsistent', 'readbackVerified', 'recoverableBaselineVerified', 'warningSignaturesReviewed', 'existingSessionReused', 'pleOrMcpStartedByAction', 'directWatcherIpcUsed', 'symbolPostProcessingVerified')) {
        $evidenceResult.acceptance[$name] = Get-RequiredBoolean -Object $acceptance -Name $name -Context 'Runner observation acceptance'
    }
    foreach ($name in @('ownershipVerified', 'mappingConsistent', 'readbackVerified', 'recoverableBaselineVerified', 'warningSignaturesReviewed', 'existingSessionReused')) {
        if (-not [bool]$evidenceResult.acceptance[$name]) {
            throw "Runner observation acceptance did not prove '$name'."
        }
    }
    if ($evidenceResult.acceptance.pleOrMcpStartedByAction -or $evidenceResult.acceptance.directWatcherIpcUsed) {
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
        onlineOperationsUsed      = $onlineOperationsUsed
        secondPleStarted          = $secondPleStarted
        actionProjectGateAcquired = $actionProjectGateAcquired
        actionProjectGateReleased = $actionProjectGateReleased
        actionProjectGateKind     = $actionProjectGateKind
        symbolLeaseHeld           = $symbolLeaseHeld
        pleOrMcpStartedByAction    = $pleOrMcpStartedByAction
        directWatcherIpcUsed      = $directWatcherIpcUsed
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
