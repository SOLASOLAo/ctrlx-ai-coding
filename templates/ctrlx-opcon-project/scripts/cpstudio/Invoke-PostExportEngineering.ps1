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

function Test-JsonInt32 {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    return (($Value -is [int]) -or ($Value -is [long])) -and
        ([long]$Value -ge [int]::MinValue) -and
        ([long]$Value -le [int]::MaxValue)
}

function Get-JsonText {
    param([Parameter(Mandatory = $true)][object]$Value)

    return (($Value | ConvertTo-Json -Depth 64) + [Environment]::NewLine)
}

function Get-JsonTextSha256 {
    param([Parameter(Mandatory = $true)][object]$Value)

    return Get-Sha256ForText -Text (Get-JsonText -Value $Value)
}

function ConvertFrom-JsonPreservingStrings {
    param([Parameter(Mandatory = $true)][string]$Json)

    # PowerShell 7.5+ otherwise converts ISO-8601 JSON strings to DateTime and
    # a later string cast loses the UTC designator and fractional precision.
    $command = Get-Command ConvertFrom-Json -ErrorAction Stop
    if (-not $command.Parameters.ContainsKey('DateKind')) {
        throw 'PowerShell 7.5 or newer with ConvertFrom-Json -DateKind is required.'
    }
    return ConvertFrom-Json -InputObject $Json -DateKind String
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
        $payload = ConvertFrom-JsonPreservingStrings -Json $raw
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

function Get-ProjectPackReference {
    param([Parameter(Mandatory = $true)][string]$ResolvedEngineeringRoot)

    $builderPath = Join-Path $ResolvedEngineeringRoot 'scripts\project\Build-CtrlXOpconProjectPack.ps1'
    $projectPackPath = Join-Path $ResolvedEngineeringRoot 'project-pack.json'
    $engineeringPlanPath = Join-Path $ResolvedEngineeringRoot 'generated\engineering-plan.json'
    foreach ($requiredPath in @($builderPath, $projectPackPath, $engineeringPlanPath)) {
        if (-not [System.IO.File]::Exists($requiredPath)) {
            throw "Project Pack action precondition is missing: $requiredPath"
        }
    }

    $checkOutput = @(& $builderPath -Command Check -EngineeringRoot $ResolvedEngineeringRoot -RequireReady -Json)
    if ($checkOutput.Count -ne 1) {
        throw 'Project Pack action precondition did not return exactly one JSON result.'
    }
    try {
        $check = [string]$checkOutput[0] | ConvertFrom-Json
    }
    catch {
        throw "Project Pack action precondition returned invalid JSON: $($_.Exception.Message)"
    }
    if (([string]$check.status -ne 'VALID') -or
        (-not [bool]$check.readyForEngineering) -or
        (-not (Test-HexSha256 -Value ([string]$check.contentId)))) {
        throw 'Project Pack must be VALID, ready, and content-addressed before a Runner action is created.'
    }

    $packDocument = Read-JsonDocument -Path $projectPackPath -Description 'Project Pack'
    $planDocument = Read-JsonDocument -Path $engineeringPlanPath -Description 'Generated engineering plan'
    if (([string]$planDocument.payload.kind -ne 'ctrlx-opcon-engineering-plan') -or
        (-not [bool]$planDocument.payload.readyForEngineering) -or
        ([string]$planDocument.payload.contentId -cne ([string]$check.contentId).ToLowerInvariant()) -or
        ([string]$planDocument.payload.projectPackSha256 -cne ([string]$packDocument.sha256).ToLowerInvariant())) {
        throw 'Generated engineering plan identity does not match the current ready Project Pack.'
    }

    return [ordered]@{
        contentId = ([string]$check.contentId).ToLowerInvariant()
        projectPackPath = 'project-pack.json'
        projectPackSha256 = ([string]$packDocument.sha256).ToLowerInvariant()
        engineeringPlanPath = 'generated/engineering-plan.json'
        engineeringPlanSha256 = ([string]$planDocument.sha256).ToLowerInvariant()
    }
}

function Assert-ProjectPackReferenceCurrent {
    param(
        [Parameter(Mandatory = $true)][object]$Reference,
        [Parameter(Mandatory = $true)][string]$ResolvedEngineeringRoot,
        [Parameter(Mandatory = $true)][string]$Context
    )

    foreach ($name in @('contentId', 'projectPackSha256', 'engineeringPlanSha256')) {
        if (-not (Test-HexSha256 -Value ([string]$Reference.$name))) {
            throw "$Context has an invalid $name."
        }
    }
    if (([string]$Reference.projectPackPath -cne 'project-pack.json') -or
        ([string]$Reference.engineeringPlanPath -cne 'generated/engineering-plan.json')) {
        throw "$Context uses an unsupported Project Pack path."
    }

    $packPath = Assert-PathInsideRoot -Root $ResolvedEngineeringRoot -Path (Join-Path $ResolvedEngineeringRoot 'project-pack.json') -Description "$Context Project Pack"
    $planPath = Assert-PathInsideRoot -Root $ResolvedEngineeringRoot -Path (Join-Path $ResolvedEngineeringRoot 'generated\engineering-plan.json') -Description "$Context engineering plan"
    $pack = Read-JsonDocument -Path $packPath -Description "$Context Project Pack"
    $plan = Read-JsonDocument -Path $planPath -Description "$Context engineering plan"
    if ((-not ([string]$pack.sha256).Equals([string]$Reference.projectPackSha256, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not ([string]$plan.sha256).Equals([string]$Reference.engineeringPlanSha256, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ([string]$plan.payload.kind -ne 'ctrlx-opcon-engineering-plan') -or
        (-not [bool]$plan.payload.readyForEngineering) -or
        (-not ([string]$plan.payload.contentId).Equals([string]$Reference.contentId, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not ([string]$plan.payload.projectPackSha256).Equals([string]$Reference.projectPackSha256, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Context no longer matches its action-creation Project Pack identity."
    }

    $builderPath = Join-Path $ResolvedEngineeringRoot 'scripts\project\Build-CtrlXOpconProjectPack.ps1'
    if (-not [System.IO.File]::Exists($builderPath)) {
        throw "$Context Project Pack builder is missing."
    }
    $checkOutput = @(& $builderPath -Command Check -EngineeringRoot $ResolvedEngineeringRoot -RequireReady -Json)
    if ($checkOutput.Count -ne 1) {
        throw "$Context Project Pack source check returned unexpected output."
    }
    $check = [string]$checkOutput[0] | ConvertFrom-Json
    if (([string]$check.status -ne 'VALID') -or
        (-not [bool]$check.readyForEngineering) -or
        (-not ([string]$check.contentId).Equals([string]$Reference.contentId, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Context Project Pack source facts drifted after action creation."
    }
}

function Assert-JsonArrayProperty {
    param(
        [Parameter(Mandatory = $true)][string]$RawJson,
        [Parameter(Mandatory = $true)][string[]]$PropertyPath,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $displayPath = $PropertyPath -join '.'
    try {
        $rawValue = ConvertFrom-JsonPreservingStrings -Json $RawJson
        foreach ($propertyName in $PropertyPath) {
            if ($null -eq $rawValue) {
                throw "$Context is missing $displayPath."
            }
            $property = $rawValue.PSObject.Properties[$propertyName]
            if ($null -eq $property) {
                throw "$Context is missing $displayPath."
            }
            $rawValue = $property.Value
        }
        if ($rawValue -isnot [System.Array]) {
            throw "$Context $displayPath must be a JSON array, not null or an object."
        }
    }
    catch {
        throw "$Context JSON shape could not be validated. $($_.Exception.Message)"
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
            8 { [void]$Builder.Append('\b'); continue }
            9 { [void]$Builder.Append('\t'); continue }
            10 { [void]$Builder.Append('\n'); continue }
            12 { [void]$Builder.Append('\f'); continue }
            13 { [void]$Builder.Append('\r'); continue }
            34 { [void]$Builder.Append('\"'); continue }
            92 { [void]$Builder.Append('\\'); continue }
        }
        $codeUnit = [int]$character
        if ($codeUnit -lt 0x20) {
            [void]$Builder.Append(('\u{0:x4}' -f $codeUnit))
        }
        else {
            [void]$Builder.Append($character)
        }
    }
    [void]$Builder.Append('"')
}

function Add-CanonicalJsonValue {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][object]$Value,
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder
    )

    if ($null -eq $Value) {
        [void]$Builder.Append('null')
        return
    }
    if ($Value -is [string] -or $Value -is [char]) {
        Add-CanonicalJsonString -Value ([string]$Value) -Builder $Builder
        return
    }
    if ($Value -is [bool]) {
        [void]$Builder.Append($(if ([bool]$Value) { 'true' } else { 'false' }))
        return
    }
    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]) {
        [void]$Builder.Append(([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)))
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $Value.Keys) { $names.Add([string]$key) }
        $names.Sort([System.StringComparer]::Ordinal)
        [void]$Builder.Append('{')
        for ($index = 0; $index -lt $names.Count; $index++) {
            if ($index -gt 0) { [void]$Builder.Append(',') }
            $name = $names[$index]
            Add-CanonicalJsonString -Value $name -Builder $Builder
            [void]$Builder.Append(':')
            Add-CanonicalJsonValue -Value $Value[$name] -Builder $Builder
        }
        [void]$Builder.Append('}')
        return
    }
    if ($Value -is [System.Array] -or
        (($Value -is [System.Collections.IList]) -and ($Value -isnot [string]))) {
        [void]$Builder.Append('[')
        for ($index = 0; $index -lt $Value.Count; $index++) {
            if ($index -gt 0) { [void]$Builder.Append(',') }
            Add-CanonicalJsonValue -Value $Value[$index] -Builder $Builder
        }
        [void]$Builder.Append(']')
        return
    }
    $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property', 'AliasProperty') })
    if ($properties.Count -gt 0) {
        $propertyByName = @{}
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($property in $properties) {
            if ($propertyByName.ContainsKey($property.Name)) {
                throw "Canonical JSON object contains a duplicate property: $($property.Name)"
            }
            $propertyByName[$property.Name] = $property.Value
            $names.Add($property.Name)
        }
        $names.Sort([System.StringComparer]::Ordinal)
        [void]$Builder.Append('{')
        for ($index = 0; $index -lt $names.Count; $index++) {
            if ($index -gt 0) { [void]$Builder.Append(',') }
            $name = $names[$index]
            Add-CanonicalJsonString -Value $name -Builder $Builder
            [void]$Builder.Append(':')
            Add-CanonicalJsonValue -Value $propertyByName[$name] -Builder $Builder
        }
        [void]$Builder.Append('}')
        return
    }
    throw "Canonical JSON contains unsupported value type: $($Value.GetType().FullName)"
}

function Get-CanonicalJsonElementText {
    param([Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][object]$Element)

    $builder = [System.Text.StringBuilder]::new()
    Add-CanonicalJsonValue -Value $Element -Builder $builder
    return $builder.ToString()
}

function Get-CanonicalJsonElementSha256 {
    param([Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][object]$Element)

    return Get-Sha256ForText -Text (Get-CanonicalJsonElementText -Element $Element)
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

function Assert-IndependentHumanReviewEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$AbsolutePath,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $normalizedRelativePath = $RelativePath.Replace('\', '/')
    if (-not $normalizedRelativePath.StartsWith('docs/reviews/', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context must be a separate independent human review artifact under docs/reviews."
    }

    $leafName = [System.IO.Path]::GetFileName($normalizedRelativePath)
    if ([string]::IsNullOrWhiteSpace($leafName) -or
        $leafName.Equals('README.md', [System.StringComparison]::OrdinalIgnoreCase) -or
        ($leafName -match '(?i)(candidate|triage)')) {
        throw "$Context must not point to a baseline candidate, AI triage or reviews index."
    }

    $maximumEvidenceBytes = 256 * 1024
    try {
        $stream = New-Object System.IO.FileStream(
            $AbsolutePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            $buffer = New-Object byte[] ($maximumEvidenceBytes + 1)
            $bytesRead = 0
            while ($bytesRead -lt $buffer.Length) {
                $count = $stream.Read($buffer, $bytesRead, ($buffer.Length - $bytesRead))
                if ($count -eq 0) {
                    break
                }
                $bytesRead += $count
            }
        }
        finally {
            $stream.Dispose()
        }
        if (($bytesRead -lt 1) -or ($bytesRead -gt $maximumEvidenceBytes)) {
            throw "$Context must be a non-empty UTF-8 review artifact no larger than 256 KiB."
        }
        $evidenceBytes = New-Object byte[] $bytesRead
        [System.Array]::Copy($buffer, 0, $evidenceBytes, 0, $bytesRead)
        $strictUtf8 = New-Object System.Text.UTF8Encoding $false, $true
        $evidenceText = $strictUtf8.GetString($evidenceBytes)
    }
    catch {
        if ($_.Exception.Message -like "$Context must be a non-empty*") {
            throw
        }
        throw "$Context must be a valid UTF-8 human review artifact."
    }

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $evidenceSha = ([System.BitConverter]::ToString($algorithm.ComputeHash($evidenceBytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }

    $generatedArtifactPatterns = @(
        '(?i)ctrlx-opcon-(?:warning-signature|engineering-semantic)-baseline-candidate',
        '(?i)"state"\s*:\s*"pending-human-review"',
        '(?i)"automaticPromotionAllowed"\s*:',
        '(?i)"targetBaselinePath"\s*:',
        '(?i)"sourceEvidence"\s*:',
        '(?i)\bAI-generated\s+triage\b',
        '(?i)\b(?:not|neither)\s+independent\s+human\s+evidence\b'
    )
    foreach ($pattern in $generatedArtifactPatterns) {
        if ($evidenceText -match $pattern) {
            throw "$Context is a generated baseline candidate or AI triage, not independent human review evidence."
        }
    }

    $reviewsRoot = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot 'docs\reviews'))
    if ([System.IO.Directory]::Exists($reviewsRoot)) {
        foreach ($knownGeneratedArtifact in Get-ChildItem -LiteralPath $reviewsRoot -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '(?i)(candidate|triage)'
        }) {
            if ((-not $knownGeneratedArtifact.FullName.Equals($AbsolutePath, [System.StringComparison]::OrdinalIgnoreCase)) -and
                ((Get-FileHash -LiteralPath $knownGeneratedArtifact.FullName -Algorithm SHA256).Hash -eq $evidenceSha)) {
                throw "$Context is a renamed copy of a generated baseline candidate or AI triage."
            }
        }
    }

    return $evidenceSha
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
        'clean_compile_project',
        'get_ctrlx_semantic_snapshot'
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

function Assert-SemanticProofSet {
    param(
        [Parameter(Mandatory = $true)][object]$Proofs,
        [Parameter(Mandatory = $true)][bool]$RequireVerified,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $proofNames = @('ownership', 'readback', 'recoverableBaseline', 'warnings', 'semanticBaseline', 'mapping', 'symbolPostProcessing')
    Assert-ExactPropertySet -Object $Proofs -ExpectedNames (@('contractVersion') + $proofNames) -Context $Context
    $contractVersion = Get-PropertyValue -Object $Proofs -Name 'contractVersion'
    if ((-not (Test-JsonInt32 -Value $contractVersion)) -or ([int]$contractVersion -ne 1)) {
        throw "$Context contractVersion must be 1."
    }
    foreach ($proofName in $proofNames) {
        $proof = Get-PropertyValue -Object $Proofs -Name $proofName
        if ($null -eq $proof) {
            throw "$Context is missing '$proofName'."
        }
        $proofVersion = Get-PropertyValue -Object $proof -Name 'contractVersion'
        if ((-not (Test-JsonInt32 -Value $proofVersion)) -or ([int]$proofVersion -ne 1)) {
            throw "$Context '$proofName' contractVersion must be 1."
        }
        $verified = Get-BooleanValue -Object $proof -Name 'verified' -Required -Context "$Context '$proofName'"
        if ($RequireVerified -and (-not $verified)) {
            throw "$Context '$proofName' is not verified."
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

function Assert-WarningBaselineReference {
    param(
        [Parameter(Mandatory = $true)][object]$Reference,
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $true)][string]$StationRoot,
        [Parameter(Mandatory = $true)][string]$PlcProject,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $state = Get-RequiredString -Object $Reference -Name 'state' -Context $Context
    $relativeBaselinePath = (Get-RequiredString -Object $Reference -Name 'path' -Context $Context).Replace('\', '/')
    if ($relativeBaselinePath -ne 'config/warning-signature-baseline.json') {
        throw "$Context must use config/warning-signature-baseline.json."
    }
    $baselinePath = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $relativeBaselinePath))
    $null = Assert-PathInsideRoot -Root $EngineeringRoot -Path $baselinePath -Description $Context

    if ($state -eq 'missing-bootstrap') {
        Assert-ExactPropertySet -Object $Reference -ExpectedNames @('state', 'path') -Context $Context
        if ([System.IO.File]::Exists($baselinePath)) {
            throw "$Context was bound as missing-bootstrap, but the warning baseline now exists. Create a new Stage1 report/action."
        }
        return
    }
    if ($state -ne 'reviewed') {
        throw "$Context has an unsupported state: $state"
    }

    Assert-ExactPropertySet `
        -Object $Reference `
        -ExpectedNames @('state', 'path', 'sha256', 'reviewEvidence') `
        -Context $Context
    $expectedBaselineSha = Get-RequiredString -Object $Reference -Name 'sha256' -Context $Context
    if (-not (Test-HexSha256 -Value $expectedBaselineSha)) {
        throw "$Context has an invalid baseline SHA-256."
    }
    if (-not [System.IO.File]::Exists($baselinePath)) {
        throw "$Context reviewed baseline file is missing: $relativeBaselinePath"
    }
    $baselineDocument = Read-JsonDocument -Path $baselinePath -Description 'Reviewed warning signature baseline'
    if (-not $baselineDocument.sha256.Equals($expectedBaselineSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context reviewed baseline SHA-256 changed."
    }
    $baseline = $baselineDocument.payload
    Assert-NoSensitiveEvidence -Value $baseline -Path '$.warningBaseline'
    Assert-ExactPropertySet `
        -Object $baseline `
        -ExpectedNames @('schemaVersion', 'kind', 'project', 'signatureAlgorithm', 'signatures', 'review') `
        -Context 'Reviewed warning signature baseline'
    if (([int](Get-PropertyValue -Object $baseline -Name 'schemaVersion' -DefaultValue 0) -ne 1) -or
        ((Get-RequiredString -Object $baseline -Name 'kind' -Context 'Reviewed warning signature baseline') -ne 'ctrlx-opcon-warning-signature-baseline') -or
        ((Get-RequiredString -Object $baseline -Name 'signatureAlgorithm' -Context 'Reviewed warning signature baseline') -ne 'sha256:v1:normalized-warning-record')) {
        throw 'Reviewed warning signature baseline identity or signature algorithm is unsupported.'
    }

    $baselineProject = Get-PropertyValue -Object $baseline -Name 'project'
    Assert-ExactPropertySet `
        -Object $baselineProject `
        -ExpectedNames @('plcProjectRelativePath', 'profile') `
        -Context 'Reviewed warning signature baseline project'
    $plcRelativePath = Get-RelativePathInsideRoot -Root $StationRoot -Path $PlcProject -Description 'Configured PLC project'
    if (((Get-RequiredString -Object $baselineProject -Name 'plcProjectRelativePath' -Context 'Reviewed warning signature baseline project').Replace('\', '/') -ne $plcRelativePath) -or
        ((Get-RequiredString -Object $baselineProject -Name 'profile' -Context 'Reviewed warning signature baseline project') -ne $Profile)) {
        throw 'Reviewed warning signature baseline project/profile does not match this operation.'
    }

    Assert-JsonArrayProperty -RawJson $baselineDocument.raw -PropertyPath @('signatures') -Context 'Reviewed warning signature baseline'
    $seenSignatures = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($signature in @(Get-PropertyValue -Object $baseline -Name 'signatures' -DefaultValue @())) {
        Assert-ExactPropertySet -Object $signature -ExpectedNames @('sha256', 'occurrences') -Context 'Reviewed warning baseline signature'
        $signatureSha = Get-RequiredString -Object $signature -Name 'sha256' -Context 'Reviewed warning baseline signature'
        if (-not (Test-HexSha256 -Value $signatureSha)) {
            throw 'Reviewed warning baseline contains an invalid warning signature SHA-256.'
        }
        if ($signatureSha.Equals('B801B38B18AAA422A0A34B3BDB867CD5F038C46AD5135A73E432AF0C58C86D9B', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Reviewed warning baseline contains the PLE warning-output truncation sentinel and cannot represent a complete warning population.'
        }
        if (-not $seenSignatures.Add($signatureSha)) {
            throw "Reviewed warning baseline contains a duplicate warning signature: $signatureSha"
        }
        $occurrencesValue = Get-PropertyValue -Object $signature -Name 'occurrences'
        if (($occurrencesValue -isnot [int]) -and ($occurrencesValue -isnot [long])) {
            throw 'Reviewed warning baseline signature occurrences must be an integer.'
        }
        if ([long]$occurrencesValue -lt 1) {
            throw 'Reviewed warning baseline signature occurrences must be at least 1.'
        }
    }

    $review = Get-PropertyValue -Object $baseline -Name 'review'
    Assert-ExactPropertySet `
        -Object $review `
        -ExpectedNames @('reviewId', 'confirmedByUser', 'reviewedAtUtc', 'evidencePath', 'evidenceSha256') `
        -Context 'Reviewed warning signature baseline review'
    foreach ($requiredReviewString in @('reviewId', 'reviewedAtUtc', 'evidencePath', 'evidenceSha256')) {
        $null = Get-RequiredString -Object $review -Name $requiredReviewString -Context 'Reviewed warning signature baseline review'
    }
    $confirmedByUser = Get-PropertyValue -Object $review -Name 'confirmedByUser'
    if (($confirmedByUser -isnot [bool]) -or (-not [bool]$confirmedByUser)) {
        throw 'Reviewed warning signature baseline confirmedByUser must be the Boolean value true.'
    }
    $reviewedAt = [DateTime]::MinValue
    if ((-not [DateTime]::TryParse([string]$review.reviewedAtUtc, [ref]$reviewedAt)) -or
        ($reviewedAt.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5))) {
        throw 'Reviewed warning signature baseline reviewedAtUtc is invalid or unreasonably far in the future.'
    }

    $reviewReference = Get-PropertyValue -Object $Reference -Name 'reviewEvidence'
    Assert-ExactPropertySet -Object $reviewReference -ExpectedNames @('path', 'sha256') -Context "$Context reviewEvidence"
    $evidenceRelativePath = (Get-RequiredString -Object $reviewReference -Name 'path' -Context "$Context reviewEvidence").Replace('\', '/')
    $expectedEvidenceSha = Get-RequiredString -Object $reviewReference -Name 'sha256' -Context "$Context reviewEvidence"
    if ([System.IO.Path]::IsPathRooted($evidenceRelativePath) -or (-not (Test-HexSha256 -Value $expectedEvidenceSha))) {
        throw "$Context reviewEvidence path or SHA-256 is invalid."
    }
    $evidencePath = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $evidenceRelativePath))
    $safeEvidenceRelativePath = Get-RelativePathInsideRoot -Root $EngineeringRoot -Path $evidencePath -Description "$Context reviewEvidence"
    if (($safeEvidenceRelativePath -ne $evidenceRelativePath) -or ($safeEvidenceRelativePath -eq $relativeBaselinePath)) {
        throw "$Context reviewEvidence path escapes EngineeringRoot, is not normalized, or points to the baseline itself."
    }
    if (-not [System.IO.File]::Exists($evidencePath)) {
        throw "$Context review evidence file is missing: $evidenceRelativePath"
    }
    $actualEvidenceSha = Assert-IndependentHumanReviewEvidence `
        -EngineeringRoot $EngineeringRoot `
        -RelativePath $safeEvidenceRelativePath `
        -AbsolutePath $evidencePath `
        -Context "$Context review evidence"
    if (-not $actualEvidenceSha.Equals($expectedEvidenceSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context review evidence SHA-256 changed."
    }
    if ((([string]$review.evidencePath).Replace('\', '/') -ne $evidenceRelativePath) -or
        (-not ([string]$review.evidenceSha256).Equals($expectedEvidenceSha, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Context reviewEvidence does not match the reviewed baseline document."
    }
}

function Assert-WarningBaselineReferencesEqual {
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $expectedSha = Get-JsonTextSha256 -Value $Expected
    $actualSha = Get-JsonTextSha256 -Value $Actual
    if (-not $expectedSha.Equals($actualSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context warning baseline binding changed. Start a new Stage1 operation."
    }
}

function Assert-SemanticScopeReference {
    param(
        [Parameter(Mandatory = $true)][object]$Reference,
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $true)][string]$StationRoot,
        [Parameter(Mandatory = $true)][string]$PlcProject,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-ExactPropertySet -Object $Reference -ExpectedNames @('path', 'sha256') -Context $Context
    $relativePath = (Get-RequiredString -Object $Reference -Name 'path' -Context $Context).Replace('\', '/')
    $expectedSha = Get-RequiredString -Object $Reference -Name 'sha256' -Context $Context
    if (($relativePath -ne 'config/engineering-semantic-scope.json') -or
        (-not (Test-HexSha256 -Value $expectedSha))) {
        throw "$Context path/SHA-256 is invalid."
    }
    $path = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $relativePath))
    $null = Assert-PathInsideRoot -Root $EngineeringRoot -Path $path -Description $Context
    $document = Read-JsonDocument -Path $path -Description 'Engineering semantic scope'
    if (-not $document.sha256.Equals($expectedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context SHA-256 changed. Create a new Stage1 report/action."
    }
    $scope = $document.payload
    Assert-NoSensitiveEvidence -Value $scope -Path '$.semanticSnapshotRequest'
    Assert-ExactPropertySet `
        -Object $scope `
        -ExpectedNames @('schemaVersion', 'kind', 'project', 'mappingScopes', 'symbolApplicationPath') `
        -Context 'Engineering semantic scope'
    if ((-not (Test-JsonInt32 -Value $scope.schemaVersion)) -or
        ([int]$scope.schemaVersion -ne 1) -or
        ((Get-RequiredString -Object $scope -Name 'kind' -Context 'Engineering semantic scope') -ne 'ctrlx-opcon-engineering-semantic-scope')) {
        throw 'Engineering semantic scope identity is unsupported.'
    }
    $scopeProject = Get-PropertyValue -Object $scope -Name 'project'
    Assert-ExactPropertySet -Object $scopeProject -ExpectedNames @('plcProjectRelativePath', 'profile') -Context 'Engineering semantic scope project'
    $plcRelativePath = Get-RelativePathInsideRoot -Root $StationRoot -Path $PlcProject -Description 'Configured PLC project'
    if (((Get-RequiredString -Object $scopeProject -Name 'plcProjectRelativePath' -Context 'Engineering semantic scope project').Replace('\', '/') -ne $plcRelativePath) -or
        ((Get-RequiredString -Object $scopeProject -Name 'profile' -Context 'Engineering semantic scope project') -ne $Profile)) {
        throw 'Engineering semantic scope project/profile does not match this operation.'
    }
    Assert-JsonArrayProperty -RawJson $document.raw -PropertyPath @('mappingScopes') -Context 'Engineering semantic scope'
    $mappingScopes = @(Get-PropertyValue -Object $scope -Name 'mappingScopes' -DefaultValue @())
    if (($mappingScopes.Count -lt 1) -or ($mappingScopes.Count -gt 64)) {
        throw 'Engineering semantic scope must contain 1..64 mappingScopes entries.'
    }
    $seenDevicePaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
    foreach ($mappingScope in $mappingScopes) {
        Assert-ExactPropertySet `
            -Object $mappingScope `
            -ExpectedNames @('devicePath', 'recursive', 'includeAllMappableChannels') `
            -Context 'Engineering semantic mapping scope'
        $devicePath = Get-RequiredString -Object $mappingScope -Name 'devicePath' -Context 'Engineering semantic mapping scope'
        if (($devicePath.Length -gt 1024) -or
            ($devicePath -match '[\x00-\x1F]') -or
            (-not $seenDevicePaths.Add($devicePath)) -or
            (-not (Get-BooleanValue -Object $mappingScope -Name 'recursive' -Required -Context 'Engineering semantic mapping scope')) -or
            (-not (Get-BooleanValue -Object $mappingScope -Name 'includeAllMappableChannels' -Required -Context 'Engineering semantic mapping scope'))) {
            throw 'Engineering semantic mapping scope is unsafe, duplicated or not recursive/all-channel.'
        }
    }
    $symbolApplicationPath = Get-RequiredString -Object $scope -Name 'symbolApplicationPath' -Context 'Engineering semantic scope'
    if (($symbolApplicationPath.Length -gt 1024) -or
        ($symbolApplicationPath -match '[\x00-\x1F]') -or
        @($symbolApplicationPath.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -gt 0) {
        throw 'Engineering semantic symbolApplicationPath is unsafe.'
    }
    return $scope
}

function Assert-SemanticBaselineReference {
    param(
        [Parameter(Mandatory = $true)][object]$Reference,
        [Parameter(Mandatory = $true)][object]$ScopeReference,
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $true)][string]$StationRoot,
        [Parameter(Mandatory = $true)][string]$PlcProject,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $state = Get-RequiredString -Object $Reference -Name 'state' -Context $Context
    $relativePath = (Get-RequiredString -Object $Reference -Name 'path' -Context $Context).Replace('\', '/')
    if ($relativePath -ne 'config/engineering-semantic-baseline.json') {
        throw "$Context must use config/engineering-semantic-baseline.json."
    }
    $path = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $relativePath))
    $null = Assert-PathInsideRoot -Root $EngineeringRoot -Path $path -Description $Context
    if ($state -eq 'missing-bootstrap') {
        Assert-ExactPropertySet -Object $Reference -ExpectedNames @('state', 'path') -Context $Context
        if ([System.IO.File]::Exists($path)) {
            throw "$Context was bound as missing-bootstrap, but the baseline now exists. Create a new Stage1 report/action."
        }
        return
    }
    if ($state -ne 'reviewed') {
        throw "$Context has an unsupported state: $state"
    }

    Assert-ExactPropertySet -Object $Reference -ExpectedNames @('state', 'path', 'sha256', 'reviewEvidence') -Context $Context
    $expectedSha = Get-RequiredString -Object $Reference -Name 'sha256' -Context $Context
    if (-not (Test-HexSha256 -Value $expectedSha)) {
        throw "$Context has an invalid SHA-256."
    }
    $document = Read-JsonDocument -Path $path -Description 'Reviewed engineering semantic baseline'
    if (-not $document.sha256.Equals($expectedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context SHA-256 changed."
    }
    $baseline = $document.payload
    Assert-NoSensitiveEvidence -Value $baseline -Path '$.semanticBaseline'
    Assert-ExactPropertySet `
        -Object $baseline `
        -ExpectedNames @('schemaVersion', 'kind', 'project', 'scopeSha256', 'canonicalFacts', 'hashes', 'review') `
        -Context 'Reviewed engineering semantic baseline'
    if ((-not (Test-JsonInt32 -Value $baseline.schemaVersion)) -or
        ([int]$baseline.schemaVersion -ne 1) -or
        ((Get-RequiredString -Object $baseline -Name 'kind' -Context 'Reviewed engineering semantic baseline') -ne 'ctrlx-opcon-engineering-semantic-baseline')) {
        throw 'Reviewed engineering semantic baseline identity is unsupported.'
    }
    $baselineProject = Get-PropertyValue -Object $baseline -Name 'project'
    Assert-ExactPropertySet -Object $baselineProject -ExpectedNames @('plcProjectRelativePath', 'profile') -Context 'Reviewed engineering semantic baseline project'
    $plcRelativePath = Get-RelativePathInsideRoot -Root $StationRoot -Path $PlcProject -Description 'Configured PLC project'
    if (((Get-RequiredString -Object $baselineProject -Name 'plcProjectRelativePath' -Context 'Reviewed engineering semantic baseline project').Replace('\', '/') -ne $plcRelativePath) -or
        ((Get-RequiredString -Object $baselineProject -Name 'profile' -Context 'Reviewed engineering semantic baseline project') -ne $Profile) -or
        (-not (Get-RequiredString -Object $baseline -Name 'scopeSha256' -Context 'Reviewed engineering semantic baseline').Equals([string]$ScopeReference.sha256, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Reviewed engineering semantic baseline project/profile/scope binding does not match this operation.'
    }

    $canonicalFacts = Get-PropertyValue -Object $baseline -Name 'canonicalFacts'
    Assert-ExactPropertySet -Object $canonicalFacts -ExpectedNames @('mapping', 'symbolConfig') -Context 'Reviewed engineering semantic canonical facts'
    $mapping = Get-PropertyValue -Object $canonicalFacts -Name 'mapping'
    Assert-ExactPropertySet `
        -Object $mapping `
        -ExpectedNames @('scopeCount', 'explicitTargetCount', 'recordCount', 'recordLimit', 'scopes', 'records') `
        -Context 'Reviewed engineering semantic canonical mapping'
    Assert-JsonArrayProperty -RawJson $document.raw -PropertyPath @('canonicalFacts', 'mapping', 'scopes') -Context 'Reviewed engineering semantic canonical mapping'
    Assert-JsonArrayProperty -RawJson $document.raw -PropertyPath @('canonicalFacts', 'mapping', 'records') -Context 'Reviewed engineering semantic canonical mapping'
    foreach ($countName in @('scopeCount', 'explicitTargetCount', 'recordCount', 'recordLimit')) {
        $value = Get-PropertyValue -Object $mapping -Name $countName
        if ((-not (Test-JsonInt32 -Value $value)) -or ([int]$value -lt 0)) {
            throw "Reviewed engineering semantic canonical mapping $countName must be a non-negative integer."
        }
    }
    $scope = Assert-SemanticScopeReference `
        -Reference $ScopeReference `
        -EngineeringRoot $EngineeringRoot `
        -StationRoot $StationRoot `
        -PlcProject $PlcProject `
        -Profile $Profile `
        -Context "$Context semanticSnapshotRequest"
    $mappingScopes = @(Get-PropertyValue -Object $mapping -Name 'scopes' -DefaultValue @())
    $mappingRecords = @(Get-PropertyValue -Object $mapping -Name 'records' -DefaultValue @())
    if (([int]$mapping.recordLimit -ne 2048) -or
        ([int]$mapping.scopeCount -ne $mappingScopes.Count) -or
        ([int]$mapping.scopeCount -ne @($scope.mappingScopes).Count) -or
        ([int]$mapping.explicitTargetCount -ne 0) -or
        ([int]$mapping.recordCount -ne $mappingRecords.Count) -or
        ($mappingRecords.Count -gt 2048)) {
        throw 'Reviewed engineering semantic canonical mapping counters do not match the bounded scope/records.'
    }
    $scopeRecordTotal = 0
    for ($index = 0; $index -lt $mappingScopes.Count; $index++) {
        $mappingScope = $mappingScopes[$index]
        Assert-ExactPropertySet -Object $mappingScope -ExpectedNames @('scopeIndex', 'devicePath', 'recursive', 'rootName', 'recordCount') -Context 'Reviewed engineering semantic canonical mapping scope'
        if ((-not (Test-JsonInt32 -Value $mappingScope.scopeIndex)) -or
            ([int]$mappingScope.scopeIndex -ne $index) -or
            (-not (Test-JsonInt32 -Value $mappingScope.recordCount)) -or
            ([int]$mappingScope.recordCount -lt 0) -or
            (-not (Get-BooleanValue -Object $mappingScope -Name 'recursive' -Required -Context 'Reviewed engineering semantic canonical mapping scope')) -or
            ([string]::IsNullOrWhiteSpace([string]$mappingScope.rootName)) -or
            ([string]$mappingScope.devicePath -ne [string]$scope.mappingScopes[$index].devicePath)) {
            throw 'Reviewed engineering semantic canonical mapping scope is invalid.'
        }
        $scopeRecordTotal += [int]$mappingScope.recordCount
    }
    if ($scopeRecordTotal -ne [int]$mapping.recordCount) {
        throw 'Reviewed engineering semantic canonical mapping scope record counts do not equal recordCount.'
    }

    $baseRecordFields = @('recordKind', 'scopeIndex', 'scopeDevicePath', 'relativeDevicePath', 'deviceIndexPath', 'deviceName', 'sourceKind', 'channelIdentity', 'channelName', 'bindingSource', 'actualVariable')
    $connectorFields = @('parameterSetKind', 'connectorIndex', 'parameterIndex', 'parameterId', 'parameterName')
    $previousRecordKey = $null
    for ($index = 0; $index -lt $mappingRecords.Count; $index++) {
        $record = $mappingRecords[$index]
        $sourceKind = [string]$record.sourceKind
        $expectedFields = if ($sourceKind -eq 'connector-parameter') { $baseRecordFields + $connectorFields } else { $baseRecordFields }
        Assert-ExactPropertySet -Object $record -ExpectedNames $expectedFields -Context 'Reviewed engineering semantic canonical mapping record'
        if (([string]$record.recordKind -ne 'scope-channel') -or
            (@('tree-channel', 'connector-parameter') -notcontains $sourceKind) -or
            (-not (Test-JsonInt32 -Value $record.scopeIndex)) -or
            ([int]$record.scopeIndex -lt 0) -or
            ([int]$record.scopeIndex -ge $mappingScopes.Count) -or
            ([string]::IsNullOrWhiteSpace([string]$record.channelIdentity)) -or
            ($record.actualVariable -isnot [string])) {
            throw 'Reviewed engineering semantic canonical mapping record is invalid.'
        }
        $recordKey = [string]$record.channelIdentity + "`n" + (Get-CanonicalJsonElementText -Element $record)
        if (($null -ne $previousRecordKey) -and ([System.StringComparer]::Ordinal.Compare($previousRecordKey, $recordKey) -gt 0)) {
            throw 'Reviewed engineering semantic canonical mapping records are not in canonical order.'
        }
        $previousRecordKey = $recordKey
    }

    $symbol = Get-PropertyValue -Object $canonicalFacts -Name 'symbolConfig'
    Assert-ExactPropertySet -Object $symbol -ExpectedNames @('applicationPath', 'canonicalPayloadByteCount', 'payloadSha256', 'shapeSummary') -Context 'Reviewed engineering semantic canonical Symbol facts'
    $symbolApplicationPath = Get-RequiredString -Object $symbol -Name 'applicationPath' -Context 'Reviewed engineering semantic canonical Symbol facts'
    if (($symbolApplicationPath -ne [string]$scope.symbolApplicationPath) -or
        (-not (Test-JsonInt32 -Value $symbol.canonicalPayloadByteCount)) -or
        ([int]$symbol.canonicalPayloadByteCount -lt 0) -or
        (-not (Test-HexSha256 -Value ([string]$symbol.payloadSha256)))) {
        throw 'Reviewed engineering semantic canonical Symbol facts are invalid.'
    }
    $shape = Get-PropertyValue -Object $symbol -Name 'shapeSummary'
    Assert-ExactPropertySet -Object $shape -ExpectedNames @('rootKind', 'topLevelKeys', 'objectCount', 'arrayCount', 'scalarCount', 'nodeCount', 'maxDepth') -Context 'Reviewed engineering semantic Symbol shape summary'
    Assert-JsonArrayProperty -RawJson $document.raw -PropertyPath @('canonicalFacts', 'symbolConfig', 'shapeSummary', 'topLevelKeys') -Context 'Reviewed engineering semantic Symbol shape summary'
    foreach ($countName in @('objectCount', 'arrayCount', 'scalarCount', 'nodeCount', 'maxDepth')) {
        $value = Get-PropertyValue -Object $shape -Name $countName
        if ((-not (Test-JsonInt32 -Value $value)) -or ([int]$value -lt 0)) {
            throw "Reviewed engineering semantic Symbol shapeSummary.$countName must be a non-negative integer."
        }
    }
    if (([string]::IsNullOrWhiteSpace([string]$shape.rootKind)) -or
        (@($shape.topLevelKeys | Where-Object { $_ -isnot [string] }).Count -gt 0)) {
        throw 'Reviewed engineering semantic Symbol shape summary is invalid.'
    }

    $hashes = Get-PropertyValue -Object $baseline -Name 'hashes'
    Assert-ExactPropertySet -Object $hashes -ExpectedNames @('algorithm', 'canonicalization', 'mappingSha256', 'symbolConfigSha256', 'snapshotSha256') -Context 'Reviewed engineering semantic baseline hashes'
    if (((Get-RequiredString -Object $hashes -Name 'algorithm' -Context 'Reviewed engineering semantic baseline hashes') -ne 'SHA-256') -or
        ((Get-RequiredString -Object $hashes -Name 'canonicalization' -Context 'Reviewed engineering semantic baseline hashes') -ne 'ctrlx-semantic-canonical-json-v1')) {
        throw 'Reviewed engineering semantic baseline hash contract is unsupported.'
    }
    $expectedHashes = @{
        mappingSha256      = Get-CanonicalJsonElementSha256 -Element $mapping
        symbolConfigSha256 = Get-CanonicalJsonElementSha256 -Element $symbol
        snapshotSha256     = Get-CanonicalJsonElementSha256 -Element $canonicalFacts
    }
    foreach ($hashName in $expectedHashes.Keys) {
        $reportedHash = Get-RequiredString -Object $hashes -Name $hashName -Context 'Reviewed engineering semantic baseline hashes'
        if ((-not (Test-HexSha256 -Value $reportedHash)) -or
            (-not $reportedHash.Equals([string]$expectedHashes[$hashName], [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Reviewed engineering semantic baseline $hashName does not match its canonical facts."
        }
    }

    $review = Get-PropertyValue -Object $baseline -Name 'review'
    Assert-ExactPropertySet -Object $review -ExpectedNames @('reviewId', 'confirmedByUser', 'reviewedAtUtc', 'evidencePath', 'evidenceSha256') -Context 'Reviewed engineering semantic baseline review'
    foreach ($name in @('reviewId', 'reviewedAtUtc', 'evidencePath', 'evidenceSha256')) {
        $null = Get-RequiredString -Object $review -Name $name -Context 'Reviewed engineering semantic baseline review'
    }
    $confirmedByUser = Get-PropertyValue -Object $review -Name 'confirmedByUser'
    if (($confirmedByUser -isnot [bool]) -or (-not [bool]$confirmedByUser)) {
        throw 'Reviewed engineering semantic baseline confirmedByUser must be the Boolean value true.'
    }
    $reviewedAt = [DateTime]::MinValue
    if ((-not [DateTime]::TryParse([string]$review.reviewedAtUtc, [ref]$reviewedAt)) -or
        ($reviewedAt.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5))) {
        throw 'Reviewed engineering semantic baseline review timestamp is invalid.'
    }
    $reviewReference = Get-PropertyValue -Object $Reference -Name 'reviewEvidence'
    Assert-ExactPropertySet -Object $reviewReference -ExpectedNames @('path', 'sha256') -Context "$Context reviewEvidence"
    $evidenceRelativePath = (Get-RequiredString -Object $reviewReference -Name 'path' -Context "$Context reviewEvidence").Replace('\', '/')
    $expectedEvidenceSha = Get-RequiredString -Object $reviewReference -Name 'sha256' -Context "$Context reviewEvidence"
    if ([System.IO.Path]::IsPathRooted($evidenceRelativePath) -or (-not (Test-HexSha256 -Value $expectedEvidenceSha))) {
        throw "$Context reviewEvidence path/SHA-256 is invalid."
    }
    $evidencePath = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $evidenceRelativePath))
    $safeEvidenceRelativePath = Get-RelativePathInsideRoot -Root $EngineeringRoot -Path $evidencePath -Description "$Context reviewEvidence"
    if (($safeEvidenceRelativePath -ne $evidenceRelativePath) -or
        ($safeEvidenceRelativePath -in @($relativePath, [string]$ScopeReference.path)) -or
        (-not [System.IO.File]::Exists($evidencePath))) {
        throw "$Context review evidence is missing, unsafe or not independent."
    }
    $actualEvidenceSha = Assert-IndependentHumanReviewEvidence `
        -EngineeringRoot $EngineeringRoot `
        -RelativePath $safeEvidenceRelativePath `
        -AbsolutePath $evidencePath `
        -Context "$Context review evidence"
    if ((-not $actualEvidenceSha.Equals($expectedEvidenceSha, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (([string]$review.evidencePath).Replace('\', '/') -ne $evidenceRelativePath) -or
        (-not ([string]$review.evidenceSha256).Equals($expectedEvidenceSha, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Context review evidence does not match the baseline provenance."
    }
}

function Assert-SemanticReferencesEqual {
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not (Get-JsonTextSha256 -Value $Expected).Equals((Get-JsonTextSha256 -Value $Actual), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context semantic binding changed. Start a new Stage1 operation."
    }
}

function Read-AndValidateAuditReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedEngineeringRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedStationRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedPlcProject,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile
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

    $warningBaseline = Get-PropertyValue -Object $report -Name 'warningBaseline'
    if ($null -eq $warningBaseline) {
        throw 'Stage1 audit report has no warningBaseline object.'
    }
    Assert-WarningBaselineReference `
        -Reference $warningBaseline `
        -EngineeringRoot $ExpectedEngineeringRoot `
        -StationRoot $ExpectedStationRoot `
        -PlcProject $ExpectedPlcProject `
        -Profile $ExpectedProfile `
        -Context 'Stage1 warning baseline'

    $semanticSnapshotRequest = Get-PropertyValue -Object $report -Name 'semanticSnapshotRequest'
    if ($null -eq $semanticSnapshotRequest) {
        throw 'Stage1 audit report has no semanticSnapshotRequest object.'
    }
    $null = Assert-SemanticScopeReference `
        -Reference $semanticSnapshotRequest `
        -EngineeringRoot $ExpectedEngineeringRoot `
        -StationRoot $ExpectedStationRoot `
        -PlcProject $ExpectedPlcProject `
        -Profile $ExpectedProfile `
        -Context 'Stage1 semantic snapshot request'
    $semanticBaseline = Get-PropertyValue -Object $report -Name 'semanticBaseline'
    if ($null -eq $semanticBaseline) {
        throw 'Stage1 audit report has no semanticBaseline object.'
    }
    Assert-SemanticBaselineReference `
        -Reference $semanticBaseline `
        -ScopeReference $semanticSnapshotRequest `
        -EngineeringRoot $ExpectedEngineeringRoot `
        -StationRoot $ExpectedStationRoot `
        -PlcProject $ExpectedPlcProject `
        -Profile $ExpectedProfile `
        -Context 'Stage1 semantic baseline'

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
    Assert-ProjectPackReferenceCurrent `
        -Reference $Operation.baseline.projectPack `
        -ResolvedEngineeringRoot ([string]$Operation.identity.engineeringRoot) `
        -Context 'Operation Project Pack precondition'
    Assert-WarningBaselineReference `
        -Reference $Operation.baseline.warningBaseline `
        -EngineeringRoot ([string]$Operation.identity.engineeringRoot) `
        -StationRoot ([string]$Operation.identity.stationRoot) `
        -PlcProject ([string]$Operation.identity.plcProject) `
        -Profile ([string]$Operation.identity.profile) `
        -Context 'Operation warning baseline'
    $null = Assert-SemanticScopeReference `
        -Reference $Operation.baseline.semanticSnapshotRequest `
        -EngineeringRoot ([string]$Operation.identity.engineeringRoot) `
        -StationRoot ([string]$Operation.identity.stationRoot) `
        -PlcProject ([string]$Operation.identity.plcProject) `
        -Profile ([string]$Operation.identity.profile) `
        -Context 'Operation semantic snapshot request'
    Assert-SemanticBaselineReference `
        -Reference $Operation.baseline.semanticBaseline `
        -ScopeReference $Operation.baseline.semanticSnapshotRequest `
        -EngineeringRoot ([string]$Operation.identity.engineeringRoot) `
        -StationRoot ([string]$Operation.identity.stationRoot) `
        -PlcProject ([string]$Operation.identity.plcProject) `
        -Profile ([string]$Operation.identity.profile) `
        -Context 'Operation semantic baseline'
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
    Assert-WarningBaselineReference `
        -Reference $Operation.baseline.warningBaseline `
        -EngineeringRoot ([string]$Operation.identity.engineeringRoot) `
        -StationRoot ([string]$Operation.identity.stationRoot) `
        -PlcProject ([string]$Operation.identity.plcProject) `
        -Profile ([string]$Operation.identity.profile) `
        -Context 'Operation warning baseline'
    $null = Assert-SemanticScopeReference `
        -Reference $Operation.baseline.semanticSnapshotRequest `
        -EngineeringRoot ([string]$Operation.identity.engineeringRoot) `
        -StationRoot ([string]$Operation.identity.stationRoot) `
        -PlcProject ([string]$Operation.identity.plcProject) `
        -Profile ([string]$Operation.identity.profile) `
        -Context 'Operation semantic snapshot request'
    Assert-SemanticBaselineReference `
        -Reference $Operation.baseline.semanticBaseline `
        -ScopeReference $Operation.baseline.semanticSnapshotRequest `
        -EngineeringRoot ([string]$Operation.identity.engineeringRoot) `
        -StationRoot ([string]$Operation.identity.stationRoot) `
        -PlcProject ([string]$Operation.identity.plcProject) `
        -Profile ([string]$Operation.identity.profile) `
        -Context 'Operation semantic baseline'

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
        Assert-WarningBaselineReferencesEqual `
            -Expected $Operation.baseline.warningBaseline `
            -Actual $action.preconditions.warningBaseline `
            -Context 'Runner action'
        Assert-SemanticReferencesEqual `
            -Expected $Operation.baseline.semanticSnapshotRequest `
            -Actual $action.preconditions.semanticSnapshotRequest `
            -Context 'Runner action semanticSnapshotRequest'
        Assert-SemanticReferencesEqual `
            -Expected $Operation.baseline.semanticBaseline `
            -Actual $action.preconditions.semanticBaseline `
            -Context 'Runner action semanticBaseline'
        foreach ($name in @('contentId', 'projectPackPath', 'projectPackSha256', 'engineeringPlanPath', 'engineeringPlanSha256')) {
            if ([string]$action.preconditions.projectPack.$name -cne [string]$Operation.baseline.projectPack.$name) {
                throw "Runner action Project Pack precondition '$name' does not match the operation ledger."
            }
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
            warningBaseline  = $Operation.baseline.warningBaseline
            semanticSnapshotRequest = $Operation.baseline.semanticSnapshotRequest
            semanticBaseline = $Operation.baseline.semanticBaseline
            projectPack      = $Operation.baseline.projectPack
            fingerprints     = $Operation.baseline.fingerprints
        }
        guardrails    = [ordered]@{
            offlineOnly                    = $true
            onlineOperationsAllowed        = $false
            requireExistingPersistentSession = $true
            prohibitPleOrMcpStartByAction   = $true
            prohibitDirectWatcherIpc        = $true
            requireExactProjectOpen         = $true
            actionProjectGateRequired       = $true
            releaseActionProjectGateBeforeTerminalDelivery = $true
            symbolAccessSerialized           = $true
            actionProjectGateKind            = 'broker-session-action-serialization'
        }
        changeSet     = @($ChangeSet)
        instructions  = $instructions
        evidenceContract = [ordered]@{
            schemaVersion               = 1
            requireActionRequestSha256  = $true
            requireOfflineOnly          = $true
            requireActionProjectGateReleased = $true
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
        # Build the immutable terminal record from the just-persisted ledger.
        # PowerShell 7 rehydrates ISO-8601 strings as DateTime values and then
        # serializes them without insignificant fractional zeros. Deriving from
        # operation.json here makes the first write and every later integrity
        # check use the same representation.
        $persistedOperation = (Read-JsonDocument -Path $operationPath -Description 'Persisted operation ledger').payload
        $final = New-FinalRecord -Operation $persistedOperation
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
        'actionProjectGateAcquired',
        'actionProjectGateReleased',
        'actionProjectGateKind',
        'symbolLeaseHeld',
        'pleOrMcpStartedByAction',
        'directWatcherIpcUsed'
    ) -Context 'Runner evidence guardrails'
    if (Get-BooleanValue -Object $guardrails -Name 'onlineOperationsUsed' -Required -Context 'Runner evidence guardrails') {
        throw 'Runner evidence reports onlineOperationsUsed=true.'
    }
    if (Get-BooleanValue -Object $guardrails -Name 'secondPleStarted' -Required -Context 'Runner evidence guardrails') {
        throw 'Runner evidence reports that a second PLE was started.'
    }
    $actionProjectGateAcquired = Get-BooleanValue -Object $guardrails -Name 'actionProjectGateAcquired' -Required -Context 'Runner evidence guardrails'
    if (-not (Get-BooleanValue -Object $guardrails -Name 'actionProjectGateReleased' -Required -Context 'Runner evidence guardrails')) {
        throw 'Runner evidence must prove that the action project serialization gate was released.'
    }
    $actionProjectGateKind = Get-RequiredString -Object $guardrails -Name 'actionProjectGateKind' -Context 'Runner evidence guardrails'
    if ($actionProjectGateAcquired) {
        if ($actionProjectGateKind -ne 'broker-session-action-serialization') {
            throw 'An acquired runner action project gate must use broker-session-action-serialization.'
        }
    }
    elseif ($actionProjectGateKind -ne 'none') {
        throw 'A non-acquired runner action project gate must use kind=none.'
    }
    if (Get-BooleanValue -Object $guardrails -Name 'symbolLeaseHeld' -Required -Context 'Runner evidence guardrails') {
        throw 'Runner evidence still holds the Symbol lease.'
    }
    if (Get-BooleanValue -Object $guardrails -Name 'pleOrMcpStartedByAction' -Required -Context 'Runner evidence guardrails') {
        throw 'Runner evidence reports that PLE or MCP was started by the action.'
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
        if ($null -ne $result.PSObject.Properties['semanticProofs']) {
            $expectedResultProperties += 'semanticProofs'
        }
        if ($null -ne $result.PSObject.Properties['nextRoute']) {
            $expectedResultProperties += 'nextRoute'
        }
        if ($null -ne $result.PSObject.Properties['build']) {
            if ($resultStatus -ne 'blocked') {
                throw 'Failed producer evidence must not contain result.build.'
            }
            $expectedResultProperties += 'build'
        }
    }
    else {
        $expectedTopLevelProperties += 'session'
        $expectedResultProperties += @('build', 'acceptance', 'semanticProofs')
    }
    Assert-ExactPropertySet -Object $evidence -ExpectedNames $expectedTopLevelProperties -Context 'Runner evidence'
    Assert-ExactPropertySet -Object $result -ExpectedNames $expectedResultProperties -Context 'Runner result'
    foreach ($name in @('verificationOk', 'appliedReadbackOk', 'repairRequired', 'requiresSecondExport', 'requiresCpStudioChange')) {
        $null = Get-BooleanValue -Object $result -Name $name -Required -Context 'Runner result'
    }
    $semanticProofs = Get-PropertyValue -Object $result -Name 'semanticProofs'
    if ((-not $terminalRunnerResult) -and ($null -eq $semanticProofs)) {
        throw 'Successful runner evidence must contain result.semanticProofs.'
    }
    if ($null -ne $semanticProofs) {
        Assert-SemanticProofSet -Proofs $semanticProofs -RequireVerified (-not $terminalRunnerResult) -Context 'Runner semantic proofs'
    }
    $nextRoute = Get-PropertyValue -Object $result -Name 'nextRoute'
    if ($null -ne $nextRoute) {
        if (-not $terminalRunnerResult) {
            throw 'Successful runner evidence cannot contain result.nextRoute.'
        }
        Assert-ExactPropertySet -Object $nextRoute -ExpectedNames @('kind', 'reasonCode', 'automaticExecutionAllowed') -Context 'Runner nextRoute'
        $null = Get-RequiredString -Object $nextRoute -Name 'kind' -Context 'Runner nextRoute'
        $null = Get-RequiredString -Object $nextRoute -Name 'reasonCode' -Context 'Runner nextRoute'
        if (Get-BooleanValue -Object $nextRoute -Name 'automaticExecutionAllowed' -Required -Context 'Runner nextRoute') {
            throw 'Runner nextRoute must require manual review.'
        }
    }
    if ($terminalRunnerResult) {
        if ($null -ne $evidence.PSObject.Properties['session']) {
            throw 'Blocked/failed producer evidence must not contain a session object.'
        }
        if ($null -ne $result.PSObject.Properties['acceptance']) {
            throw 'Blocked/failed producer evidence must not contain result.acceptance.'
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
        if ($null -ne $result.PSObject.Properties['build']) {
            if (($failureStage -ne 'semantic-acceptance') -or
                (-not $actionProjectGateAcquired) -or
                ($null -eq $semanticProofs)) {
                throw 'Only semantic-acceptance BLOCKED evidence may contain a fresh Build.'
            }
            $hasUnverifiedProof = $false
            foreach ($proofName in @('ownership', 'readback', 'recoverableBaseline', 'warnings', 'semanticBaseline', 'mapping', 'symbolPostProcessing')) {
                $proof = Get-PropertyValue -Object $semanticProofs -Name $proofName
                if (-not (Get-BooleanValue -Object $proof -Name 'verified' -Required -Context "Runner semantic proof '$proofName'")) {
                    $hasUnverifiedProof = $true
                }
            }
            if (-not $hasUnverifiedProof) {
                throw 'A BLOCKED fresh Build must retain at least one unverified semantic proof.'
            }
            foreach ($requiredCapability in @('get_codesys_status', 'clean_compile_project')) {
                if (@($capabilities | Where-Object { [string]$_ -eq $requiredCapability }).Count -ne 1) {
                    throw "Blocked fresh Build evidence must report capability '$requiredCapability' exactly once."
                }
            }
            Assert-BlockedBuildEvidence `
                -Result $result `
                -Operation $Operation `
                -EvidenceCompletedAtUtc (Get-RequiredString -Object $evidence -Name 'completedAtUtc' -Context 'Runner evidence') `
                -RawEvidenceJson $document.raw
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
        if (-not $actionProjectGateAcquired) {
            throw 'Successful runner evidence must prove that the Broker action project gate was acquired.'
        }
        if ([string]$Operation.currentAction.kind -eq 'apply_change_set_and_build') {
            throw 'apply_change_set_and_build is not supported by the typed Broker and cannot produce successful evidence.'
        }

        $requiredCapabilities = @('get_codesys_status', 'clean_compile_project', 'get_ctrlx_semantic_snapshot')
        foreach ($requiredCapability in $requiredCapabilities) {
            if (@($capabilities | Where-Object { [string]$_ -eq $requiredCapability }).Count -ne 1) {
                throw "Successful runner evidence must report capability '$requiredCapability' exactly once."
            }
        }

        $session = Get-PropertyValue -Object $evidence -Name 'session'
        if ($null -eq $session) {
            throw 'Successful runner evidence has no producer-validated persistent session identity.'
        }
        Assert-ExactPropertySet -Object $session -ExpectedNames @('state', 'mode', 'sessionId', 'plePid', 'mcpPid', 'profile', 'activeProjectPath', 'pleOwnedByBroker') -Context 'Runner evidence session'

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
            'pleOrMcpStartedByAction',
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
        $sessionMcpPid = 0
        if ((-not [int]::TryParse([string](Get-PropertyValue -Object $session -Name 'mcpPid'), [ref]$sessionMcpPid)) -or
            ($sessionMcpPid -le 0)) {
            throw 'Runner evidence session mcpPid must be a positive producer-validated process identifier.'
        }
        if ((Get-RequiredString -Object $session -Name 'profile' -Context 'Runner evidence session') -ne [string]$Operation.identity.profile) {
            throw 'Runner evidence session profile does not match the configured PLE profile.'
        }
        Assert-SamePath `
            -Expected ([string]$Operation.identity.plcProject) `
            -Actual (Get-RequiredString -Object $session -Name 'activeProjectPath' -Context 'Runner evidence session') `
            -Description 'Runner evidence session active project'
        $null = Get-BooleanValue -Object $session -Name 'pleOwnedByBroker' -Required -Context 'Runner evidence session'
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
        throw ("Runner evidence completedAtUtc is inconsistent with the immutable action request or is unreasonably far in the future: evidence={0:o}; action={1:o}; now={2:o}." -f $completedAt.ToUniversalTime(), $actionCreatedAt.ToUniversalTime(), [DateTime]::UtcNow)
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

function Assert-BlockedBuildEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][object]$Operation,
        [Parameter(Mandatory = $true)][string]$EvidenceCompletedAtUtc,
        [Parameter(Mandatory = $true)][string]$RawEvidenceJson
    )

    $build = Get-PropertyValue -Object $Result -Name 'build'
    Assert-ExactPropertySet -Object $build -ExpectedNames @(
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
    ) -Context 'Blocked fresh Build evidence'
    Assert-JsonArrayProperty -RawJson $RawEvidenceJson -PropertyPath @('result', 'build', 'warningRecords') -Context 'Blocked fresh Build evidence'
    Assert-JsonArrayProperty -RawJson $RawEvidenceJson -PropertyPath @('result', 'build', 'diagnosticRows') -Context 'Blocked fresh Build evidence'

    $buildId = Get-RequiredString -Object $build -Name 'buildId' -Context 'Blocked fresh Build evidence'
    if ($buildId -notmatch '^[A-Za-z0-9_.:-]{1,128}$') {
        throw 'Blocked fresh Build evidence buildId is invalid.'
    }
    Assert-SamePath -Expected ([string]$Operation.identity.plcProject) -Actual (Get-RequiredString -Object $build -Name 'projectPath' -Context 'Blocked fresh Build evidence') -Description 'Blocked Build PLC project'
    if ((Get-RequiredString -Object $build -Name 'profile' -Context 'Blocked fresh Build evidence') -ne [string]$Operation.identity.profile) {
        throw 'Blocked fresh Build profile does not match the immutable action.'
    }
    $reportedProjectSha = Get-RequiredString -Object $build -Name 'projectSha256' -Context 'Blocked fresh Build evidence'
    if ((-not (Test-HexSha256 -Value $reportedProjectSha)) -or
        (-not [System.IO.File]::Exists([string]$Operation.identity.plcProject)) -or
        (-not ((Get-FileHash -LiteralPath ([string]$Operation.identity.plcProject) -Algorithm SHA256).Hash.Equals($reportedProjectSha, [System.StringComparison]::OrdinalIgnoreCase)))) {
        throw 'Blocked fresh Build PLC project SHA-256 does not match the current project.'
    }
    if ((Get-RequiredString -Object $build -Name 'summarySource' -Context 'Blocked fresh Build evidence') -ne 'codesys-persistent.clean_compile_project') {
        throw 'Blocked fresh Build summarySource is unsupported.'
    }

    $buildStarted = [DateTime]::MinValue
    $buildCompleted = [DateTime]::MinValue
    $actionCreated = [DateTime]::MinValue
    $evidenceCompleted = [DateTime]::MinValue
    if ((-not [DateTime]::TryParse((Get-RequiredString -Object $build -Name 'startedAtUtc' -Context 'Blocked fresh Build evidence'), [ref]$buildStarted)) -or
        (-not [DateTime]::TryParse((Get-RequiredString -Object $build -Name 'completedAtUtc' -Context 'Blocked fresh Build evidence'), [ref]$buildCompleted)) -or
        (-not [DateTime]::TryParse([string]$Operation.currentAction.createdAtUtc, [ref]$actionCreated)) -or
        (-not [DateTime]::TryParse($EvidenceCompletedAtUtc, [ref]$evidenceCompleted)) -or
        ($buildStarted.ToUniversalTime() -lt $actionCreated.ToUniversalTime()) -or
        ($buildCompleted.ToUniversalTime() -lt $buildStarted.ToUniversalTime()) -or
        ($buildCompleted.ToUniversalTime() -gt $evidenceCompleted.ToUniversalTime())) {
        throw 'Blocked Build evidence is not fresh for the current immutable action.'
    }

    $errorsValue = Get-PropertyValue -Object $build -Name 'errors'
    $warningsValue = Get-PropertyValue -Object $build -Name 'warnings'
    $messageCountValue = Get-PropertyValue -Object $build -Name 'messageCount'
    if ((-not (Test-JsonInt32 -Value $errorsValue)) -or
        (-not (Test-JsonInt32 -Value $warningsValue)) -or
        (-not (Test-JsonInt32 -Value $messageCountValue)) -or
        ([int]$errorsValue -ne 0) -or
        ([int]$warningsValue -lt 0) -or
        ([int]$warningsValue -gt 2048) -or
        ([int]$messageCountValue -lt [int]$warningsValue) -or
        ([int]$messageCountValue -gt 2048) -or
        (-not (Get-BooleanValue -Object $build -Name 'verified' -Required -Context 'Blocked fresh Build evidence'))) {
        throw 'Blocked fresh Build evidence must be verified, zero-error, and bounded.'
    }
    $warnings = [int]$warningsValue
    $messageCount = [int]$messageCountValue
    $typedRecordsVerified = Get-BooleanValue -Object $build -Name 'typedRecordsVerified' -Required -Context 'Blocked fresh Build evidence'
    $diagnosticRowsComplete = Get-BooleanValue -Object $build -Name 'diagnosticRowsComplete' -Required -Context 'Blocked fresh Build evidence'
    $warningRecordsSafeForReview = Get-BooleanValue -Object $build -Name 'warningRecordsSafeForReview' -Required -Context 'Blocked fresh Build evidence'
    $warningRecords = @(Get-PropertyValue -Object $build -Name 'warningRecords' -DefaultValue @())
    $diagnosticRows = @(Get-PropertyValue -Object $build -Name 'diagnosticRows' -DefaultValue @())
    if (($warningRecordsSafeForReview -and (-not $typedRecordsVerified)) -or
        ($typedRecordsVerified -and $warningRecordsSafeForReview -and ($warningRecords.Count -ne $warnings)) -or
        ((-not $typedRecordsVerified) -and ($warningRecords.Count -ne 0)) -or
        ($typedRecordsVerified -and (-not $warningRecordsSafeForReview) -and ($warningRecords.Count -ne 0)) -or
        ($typedRecordsVerified -and ($messageCount -ne $warnings)) -or
        ($diagnosticRows.Count -gt $messageCount) -or
        ($diagnosticRowsComplete -and ($diagnosticRows.Count -ne $messageCount))) {
        throw 'Blocked fresh Build record arrays do not match their producer flags/counts.'
    }
    foreach ($record in @($warningRecords) + @($diagnosticRows)) {
        if (($record -isnot [string]) -or [string]::IsNullOrWhiteSpace([string]$record) -or
            ([System.Text.Encoding]::UTF8.GetByteCount(([string]$record).Trim()) -gt 4096)) {
            throw 'Blocked fresh Build record arrays contain an invalid row.'
        }
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
    if ((Get-RequiredString -Object $build -Name 'summarySource' -Context 'Build evidence') -ne 'codesys-persistent.clean_compile_project') {
        throw 'Build evidence summarySource must be codesys-persistent.clean_compile_project.'
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
    foreach ($name in @('ownershipVerified', 'mappingConsistent', 'readbackVerified', 'recoverableBaselineVerified', 'existingSessionReused')) {
        if (-not (Get-BooleanValue -Object $acceptance -Name $name -Required -Context 'Runner acceptance')) {
            throw "Runner acceptance did not prove '$name'."
        }
    }
    $warningSignaturesReviewed = Get-BooleanValue -Object $acceptance -Name 'warningSignaturesReviewed' -Required -Context 'Runner acceptance'
    $warningBaselineState = Get-RequiredString -Object $Operation.baseline.warningBaseline -Name 'state' -Context 'Operation warning baseline'
    if ($warningBaselineState -eq 'missing-bootstrap') {
        if ($warningSignaturesReviewed) {
            throw 'Runner acceptance cannot claim reviewed warnings while the immutable action is in missing-bootstrap state.'
        }
    }
    elseif ($warningBaselineState -eq 'reviewed') {
        if (-not $warningSignaturesReviewed) {
            throw 'Runner acceptance did not prove warningSignaturesReviewed against the bound reviewed baseline.'
        }
        $baselinePath = Join-Path ([string]$Operation.identity.engineeringRoot) ([string]$Operation.baseline.warningBaseline.path)
        $baseline = (Read-JsonDocument -Path $baselinePath -Description 'Reviewed warning signature baseline').payload
        $expectedSignatures = @($baseline.signatures | Sort-Object -Property sha256)
        $actualSignatures = @((Get-PropertyValue -Object (Get-PropertyValue -Object $Result -Name 'build') -Name 'warningSignatures' -DefaultValue @()) | Sort-Object -Property sha256)
        if ($expectedSignatures.Count -ne $actualSignatures.Count) {
            throw 'Build warning signatures do not match the reviewed warning baseline.'
        }
        for ($index = 0; $index -lt $expectedSignatures.Count; $index++) {
            if ((-not ([string]$expectedSignatures[$index].sha256).Equals([string]$actualSignatures[$index].sha256, [System.StringComparison]::OrdinalIgnoreCase)) -or
                ([long]$expectedSignatures[$index].occurrences -ne [long]$actualSignatures[$index].occurrences)) {
                throw 'Build warning signatures do not match the reviewed warning baseline.'
            }
        }
    }
    else {
        throw "Operation warning baseline has an unsupported state: $warningBaselineState"
    }
    foreach ($name in @('pleOrMcpStartedByAction', 'directWatcherIpcUsed')) {
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
    $projectPackReference = Get-ProjectPackReference -ResolvedEngineeringRoot $ResolvedEngineeringRoot
    $idempotencyText = $workflowRevision + '|' + $Audit.requestId + '|' + $Audit.document.sha256 + '|' + $ResolvedPlcProject.ToLowerInvariant() + '|' + $Profile + '|' + $projectPackReference.contentId
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
            manifests       = @($Audit.report.manifests)
            projectPack     = $projectPackReference
            warningBaseline = $Audit.report.warningBaseline
            semanticSnapshotRequest = $Audit.report.semanticSnapshotRequest
            semanticBaseline = $Audit.report.semanticBaseline
            fingerprints    = @($Audit.report.fingerprints)
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
        if (([string]$Operation.baseline.warningBaseline.state -eq 'reviewed') -and
            ([string]$Operation.baseline.semanticBaseline.state -eq 'reviewed')) {
            $nextStatus = 'DONE'
            $nextOutcome = 'DONE'
        }
        elseif ([string]$Operation.baseline.warningBaseline.state -ne 'reviewed') {
            $nextStatus = 'BLOCKED'
            $nextOutcome = 'NEEDS_REVIEW'
            $blockCode = 'WARNING_BASELINE_REVIEW_REQUIRED'
            $blockMessage = 'Fresh Build evidence was collected, but no reviewed warning-signature baseline was bound to this immutable action.'
        }
        else {
            $nextStatus = 'BLOCKED'
            $nextOutcome = 'NEEDS_REVIEW'
            $blockCode = 'SEMANTIC_BASELINE_REVIEW_REQUIRED'
            $blockMessage = 'Fresh Build and semantic snapshot evidence were collected, but no reviewed engineering semantic baseline was bound to this immutable action.'
        }
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
    Assert-WarningBaselineReferencesEqual `
        -Expected $Operation.baseline.warningBaseline `
        -Actual $Audit.report.warningBaseline `
        -Context 'Export #2 Stage1 report'
    Assert-SemanticReferencesEqual `
        -Expected $Operation.baseline.semanticSnapshotRequest `
        -Actual $Audit.report.semanticSnapshotRequest `
        -Context 'Export #2 semanticSnapshotRequest'
    Assert-SemanticReferencesEqual `
        -Expected $Operation.baseline.semanticBaseline `
        -Actual $Audit.report.semanticBaseline `
        -Context 'Export #2 semanticBaseline'
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
            -ExpectedPlcProject $resolvedPlcProject `
            -ExpectedProfile $profile
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
            -ExpectedPlcProject $resolvedPlcProject `
            -ExpectedProfile $profile
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
