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
$maximumRequestBytes = 1024 * 1024

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

function ConvertFrom-JsonPreservingStrings {
    param([Parameter(Mandatory = $true)][string]$Json)

    # PowerShell 7.5+ otherwise converts ISO-8601 JSON strings to DateTime and
    # a later string cast loses the UTC designator and fractional precision.
    # Windows PowerShell has no DateKind parameter and preserves these strings.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Json -DateKind String
    }
    return ConvertFrom-Json -InputObject $Json
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

function Test-JsonInt32 {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    return (($Value -is [int]) -or ($Value -is [long])) -and
        ([long]$Value -ge [int]::MinValue) -and
        ([long]$Value -le [int]::MaxValue)
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

    # Catch a byte-for-byte renamed copy even if its textual markers change in
    # a later candidate schema. Known generated artifacts remain recognizable
    # by their original candidate/triage filenames in the reviews directory.
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

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$ExpectedNames,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Object) {
        throw "$Context is missing."
    }
    $actualNames = @($Object.PSObject.Properties.Name)
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
    if (($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [pscustomobject])) {
        $index = 0
        foreach ($item in $Value) {
            Assert-NoSensitiveFields -Value $item -Path ($Path + '[' + $index + ']')
            $index++
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        $propertyPath = $Path + '.' + $property.Name
        if ($property.Name -match '(?i)(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential)') {
            throw "Warning baseline contains a prohibited secret-bearing field: $propertyPath"
        }
        Assert-NoSensitiveFields -Value $property.Value -Path $propertyPath
    }
}

function Assert-JsonArrayProperty {
    param(
        [Parameter(Mandatory = $true)][string]$RawJson,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$Context
    )

    try {
        if ((-not $PSVersionTable.ContainsKey('PSEdition')) -or ($PSVersionTable.PSEdition -eq 'Desktop')) {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength = [int]::MaxValue
            $serializer.RecursionLimit = 256
            $parsed = $serializer.DeserializeObject($RawJson)
            if (($parsed -isnot [System.Collections.IDictionary]) -or (-not ($parsed.Keys -contains $PropertyName))) {
                throw "$Context is missing '$PropertyName'."
            }
            $rawValue = $parsed[$PropertyName]
        }
        else {
            $parsed = ConvertFrom-JsonPreservingStrings -Json $RawJson
            $property = $parsed.PSObject.Properties[$PropertyName]
            if ($null -eq $property) {
                throw "$Context is missing '$PropertyName'."
            }
            $rawValue = $property.Value
        }
        if ($rawValue -isnot [System.Array]) {
            throw "$Context '$PropertyName' must be a JSON array, not null or an object."
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

function Get-WarningBaselineAudit {
    param(
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $true)][string]$StationRoot,
        [Parameter(Mandatory = $true)][string]$PlcProject,
        [Parameter(Mandatory = $true)][string]$Profile
    )

    $relativeBaselinePath = 'config/warning-signature-baseline.json'
    $baselinePath = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $relativeBaselinePath))
    if (-not [System.IO.File]::Exists($baselinePath)) {
        return [ordered]@{
            state = 'missing-bootstrap'
            path  = $relativeBaselinePath
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($baselinePath)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false, $true
        $raw = $utf8.GetString($bytes)
        if (($raw.Length -gt 0) -and ($raw[0] -eq [char]0xFEFF)) {
            $raw = $raw.Substring(1)
        }
        $baseline = ConvertFrom-JsonPreservingStrings -Json $raw
    }
    catch {
        throw "Warning signature baseline is not valid UTF-8 JSON: $baselinePath. $($_.Exception.Message)"
    }

    Assert-NoSensitiveFields -Value $baseline -Path '$.warningBaseline'
    Assert-ExactPropertySet `
        -Object $baseline `
        -ExpectedNames @('schemaVersion', 'kind', 'project', 'signatureAlgorithm', 'signatures', 'review') `
        -Context 'Warning signature baseline'
    if (([int]$baseline.schemaVersion -ne 1) -or
        ([string]$baseline.kind -ne 'ctrlx-opcon-warning-signature-baseline') -or
        ([string]$baseline.signatureAlgorithm -ne 'sha256:v1:normalized-warning-record')) {
        throw 'Warning signature baseline identity or signature algorithm is unsupported.'
    }

    Assert-ExactPropertySet `
        -Object $baseline.project `
        -ExpectedNames @('plcProjectRelativePath', 'profile') `
        -Context 'Warning signature baseline project'
    $plcRelativePath = Get-SafeRelativePath -Root $StationRoot -Path $PlcProject
    if (-not $plcRelativePath) {
        throw 'Configured PLC project is outside stationRoot; warning baseline cannot be matched.'
    }
    $baselinePlcRelativePath = ([string]$baseline.project.plcProjectRelativePath).Replace('\', '/')
    if (($baselinePlcRelativePath -ne $plcRelativePath.Replace('\', '/')) -or
        ([string]$baseline.project.profile -ne $Profile)) {
        throw 'Warning signature baseline project/profile does not match config/project.yaml.'
    }

    Assert-JsonArrayProperty -RawJson $raw -PropertyName 'signatures' -Context 'Warning signature baseline'
    $seenSignatures = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($signature in @($baseline.signatures)) {
        Assert-ExactPropertySet -Object $signature -ExpectedNames @('sha256', 'occurrences') -Context 'Warning baseline signature'
        $signatureSha = [string]$signature.sha256
        if (-not (Test-HexSha256 -Value $signatureSha)) {
            throw 'Warning baseline signature contains an invalid SHA-256.'
        }
        if ($signatureSha.Equals('B801B38B18AAA422A0A34B3BDB867CD5F038C46AD5135A73E432AF0C58C86D9B', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Warning baseline contains the PLE warning-output truncation sentinel and cannot represent a complete warning population.'
        }
        if (-not $seenSignatures.Add($signatureSha)) {
            throw "Warning signature baseline contains a duplicate signature: $signatureSha"
        }
        if (($signature.occurrences -isnot [int]) -and ($signature.occurrences -isnot [long])) {
            throw 'Warning baseline signature occurrences must be an integer.'
        }
        if ([long]$signature.occurrences -lt 1) {
            throw 'Warning baseline signature occurrences must be at least 1.'
        }
    }

    Assert-ExactPropertySet `
        -Object $baseline.review `
        -ExpectedNames @('reviewId', 'reviewer', 'reviewedAtUtc', 'evidencePath', 'evidenceSha256') `
        -Context 'Warning signature baseline review'
    foreach ($requiredReviewString in @('reviewId', 'reviewer', 'reviewedAtUtc', 'evidencePath', 'evidenceSha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$baseline.review.$requiredReviewString)) {
            throw "Warning signature baseline review is missing '$requiredReviewString'."
        }
    }
    $reviewedAt = [DateTime]::MinValue
    if ((-not [DateTime]::TryParse([string]$baseline.review.reviewedAtUtc, [ref]$reviewedAt)) -or
        ($reviewedAt.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5))) {
        throw 'Warning signature baseline reviewedAtUtc is invalid or unreasonably far in the future.'
    }

    $evidenceRelativePath = ([string]$baseline.review.evidencePath).Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($evidenceRelativePath)) {
        throw 'Warning baseline review evidencePath must be relative to EngineeringRoot.'
    }
    $evidencePath = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $evidenceRelativePath))
    $safeEvidenceRelativePath = Get-SafeRelativePath -Root $EngineeringRoot -Path $evidencePath
    if ((-not $safeEvidenceRelativePath) -or
        ($safeEvidenceRelativePath.Replace('\', '/') -ne $evidenceRelativePath)) {
        throw 'Warning baseline review evidencePath escapes EngineeringRoot or is not normalized.'
    }
    if ($safeEvidenceRelativePath.Replace('\', '/') -eq $relativeBaselinePath) {
        throw 'Warning baseline cannot use itself as review evidence.'
    }
    if (-not [System.IO.File]::Exists($evidencePath)) {
        throw "Warning baseline review evidence does not exist: $safeEvidenceRelativePath"
    }
    $actualEvidenceSha = Assert-IndependentHumanReviewEvidence `
        -EngineeringRoot $EngineeringRoot `
        -RelativePath $safeEvidenceRelativePath `
        -AbsolutePath $evidencePath `
        -Context 'Warning baseline review evidence'
    $expectedEvidenceSha = [string]$baseline.review.evidenceSha256
    if (-not (Test-HexSha256 -Value $expectedEvidenceSha)) {
        throw 'Warning baseline review evidenceSha256 is invalid.'
    }
    if (-not $actualEvidenceSha.Equals($expectedEvidenceSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Warning baseline review evidence SHA-256 does not match its file.'
    }

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $baselineSha = ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
    return [ordered]@{
        state          = 'reviewed'
        path           = $relativeBaselinePath
        sha256         = $baselineSha
        reviewEvidence = [ordered]@{
            path   = $safeEvidenceRelativePath.Replace('\', '/')
            sha256 = $actualEvidenceSha
        }
    }
}

function Get-SemanticScopeAudit {
    param(
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $true)][string]$StationRoot,
        [Parameter(Mandatory = $true)][string]$PlcProject,
        [Parameter(Mandatory = $true)][string]$Profile
    )

    $relativeScopePath = 'config/engineering-semantic-scope.json'
    $scopePath = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $relativeScopePath))
    if (-not [System.IO.File]::Exists($scopePath)) {
        throw "Required engineering semantic scope is missing: $relativeScopePath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($scopePath)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false, $true
        $raw = $utf8.GetString($bytes)
        if (($raw.Length -gt 0) -and ($raw[0] -eq [char]0xFEFF)) {
            $raw = $raw.Substring(1)
        }
        $scope = ConvertFrom-JsonPreservingStrings -Json $raw
    }
    catch {
        throw "Engineering semantic scope is not valid UTF-8 JSON: $scopePath. $($_.Exception.Message)"
    }

    Assert-NoSensitiveFields -Value $scope -Path '$.semanticSnapshotRequest'
    Assert-ExactPropertySet `
        -Object $scope `
        -ExpectedNames @('schemaVersion', 'kind', 'project', 'mappingScopes', 'symbolApplicationPath') `
        -Context 'Engineering semantic scope'
    if ((-not (Test-JsonInt32 -Value $scope.schemaVersion)) -or
        ([int]$scope.schemaVersion -ne 1) -or
        ([string]$scope.kind -ne 'ctrlx-opcon-engineering-semantic-scope')) {
        throw 'Engineering semantic scope identity is unsupported.'
    }

    Assert-ExactPropertySet `
        -Object $scope.project `
        -ExpectedNames @('plcProjectRelativePath', 'profile') `
        -Context 'Engineering semantic scope project'
    $plcRelativePath = Get-SafeRelativePath -Root $StationRoot -Path $PlcProject
    if (-not $plcRelativePath) {
        throw 'Configured PLC project is outside stationRoot; engineering semantic scope cannot be matched.'
    }
    if ((([string]$scope.project.plcProjectRelativePath).Replace('\', '/') -ne $plcRelativePath) -or
        ([string]$scope.project.profile -ne $Profile)) {
        throw 'Engineering semantic scope project/profile does not match config/project.yaml.'
    }

    Assert-JsonArrayProperty -RawJson $raw -PropertyName 'mappingScopes' -Context 'Engineering semantic scope'
    $mappingScopes = @($scope.mappingScopes)
    if (($mappingScopes.Count -lt 1) -or ($mappingScopes.Count -gt 64)) {
        throw 'Engineering semantic scope must contain 1..64 mappingScopes entries.'
    }
    $seenDevicePaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
    foreach ($mappingScope in $mappingScopes) {
        Assert-ExactPropertySet `
            -Object $mappingScope `
            -ExpectedNames @('devicePath', 'recursive', 'includeAllMappableChannels') `
            -Context 'Engineering semantic mapping scope'
        $devicePath = [string]$mappingScope.devicePath
        if ([string]::IsNullOrWhiteSpace($devicePath) -or
            ($devicePath.Length -gt 1024) -or
            ($devicePath -match '[\x00-\x1F]') -or
            (-not $seenDevicePaths.Add($devicePath))) {
            throw 'Engineering semantic mapping devicePath is empty, unsafe, too long or duplicated.'
        }
        if (($mappingScope.recursive -isnot [bool]) -or
            ($mappingScope.includeAllMappableChannels -isnot [bool]) -or
            (-not [bool]$mappingScope.recursive) -or
            (-not [bool]$mappingScope.includeAllMappableChannels)) {
            throw 'Engineering semantic mapping scope must request recursive all-mappable-channel readback.'
        }
    }

    $symbolApplicationPath = [string]$scope.symbolApplicationPath
    if ([string]::IsNullOrWhiteSpace($symbolApplicationPath) -or
        ($symbolApplicationPath.Length -gt 1024) -or
        ($symbolApplicationPath -match '[\x00-\x1F]') -or
        @($symbolApplicationPath.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -gt 0) {
        throw 'Engineering semantic symbolApplicationPath is empty or unsafe.'
    }

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $scopeSha = ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
    return [ordered]@{
        path   = $relativeScopePath
        sha256 = $scopeSha
    }
}

function Get-SemanticBaselineAudit {
    param(
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $true)][string]$StationRoot,
        [Parameter(Mandatory = $true)][string]$PlcProject,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][object]$ScopeAudit
    )

    $relativeBaselinePath = 'config/engineering-semantic-baseline.json'
    $baselinePath = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $relativeBaselinePath))
    if (-not [System.IO.File]::Exists($baselinePath)) {
        return [ordered]@{
            state = 'missing-bootstrap'
            path  = $relativeBaselinePath
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($baselinePath)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false, $true
        $raw = $utf8.GetString($bytes)
        if (($raw.Length -gt 0) -and ($raw[0] -eq [char]0xFEFF)) {
            $raw = $raw.Substring(1)
        }
        $baseline = ConvertFrom-JsonPreservingStrings -Json $raw

        Assert-NoSensitiveFields -Value $baseline -Path '$.semanticBaseline'
        Assert-ExactPropertySet `
            -Object $baseline `
            -ExpectedNames @('schemaVersion', 'kind', 'project', 'scopeSha256', 'canonicalFacts', 'hashes', 'review') `
            -Context 'Engineering semantic baseline'
        if ((-not (Test-JsonInt32 -Value $baseline.schemaVersion)) -or
            ([int]$baseline.schemaVersion -ne 1) -or
            ([string]$baseline.kind -ne 'ctrlx-opcon-engineering-semantic-baseline')) {
            throw 'Engineering semantic baseline identity is unsupported.'
        }

        Assert-ExactPropertySet -Object $baseline.project -ExpectedNames @('plcProjectRelativePath', 'profile') -Context 'Engineering semantic baseline project'
        $plcRelativePath = Get-SafeRelativePath -Root $StationRoot -Path $PlcProject
        if ((-not $plcRelativePath) -or
            (([string]$baseline.project.plcProjectRelativePath).Replace('\', '/') -ne $plcRelativePath) -or
            ([string]$baseline.project.profile -ne $Profile)) {
            throw 'Engineering semantic baseline project/profile does not match config/project.yaml.'
        }
        if ((-not (Test-HexSha256 -Value ([string]$baseline.scopeSha256))) -or
            (-not ([string]$baseline.scopeSha256).Equals([string]$ScopeAudit.sha256, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw 'Engineering semantic baseline does not bind the current semantic scope SHA-256.'
        }

        Assert-ExactPropertySet -Object $baseline.canonicalFacts -ExpectedNames @('mapping', 'symbolConfig') -Context 'Engineering semantic canonical facts'
        $mapping = $baseline.canonicalFacts.mapping
        Assert-ExactPropertySet `
            -Object $mapping `
            -ExpectedNames @('scopeCount', 'explicitTargetCount', 'recordCount', 'recordLimit', 'scopes', 'records') `
            -Context 'Engineering semantic canonical mapping'
        if (($mapping.scopes -isnot [System.Array]) -or
            ($mapping.records -isnot [System.Array])) {
            throw 'Engineering semantic canonical mapping scopes/records must be JSON arrays.'
        }
        foreach ($countName in @('scopeCount', 'explicitTargetCount', 'recordCount', 'recordLimit')) {
            if ((-not (Test-JsonInt32 -Value $mapping.$countName)) -or ([int]$mapping.$countName -lt 0)) {
                throw "Engineering semantic canonical mapping $countName must be a non-negative integer."
            }
        }
        if ([int]$mapping.recordLimit -ne 2048) {
            throw 'Engineering semantic canonical mapping recordLimit must be 2048.'
        }
        $mappingScopes = @($mapping.scopes)
        $mappingRecords = @($mapping.records)
        $scopePath = Join-Path $EngineeringRoot ([string]$ScopeAudit.path)
        $scope = ConvertFrom-JsonPreservingStrings -Json ([System.IO.File]::ReadAllText($scopePath))
        if (([int]$mapping.scopeCount -ne $mappingScopes.Count) -or
            ([int]$mapping.scopeCount -ne @($scope.mappingScopes).Count) -or
            ([int]$mapping.explicitTargetCount -ne 0) -or
            ([int]$mapping.recordCount -ne $mappingRecords.Count) -or
            ($mappingRecords.Count -gt 2048)) {
            throw 'Engineering semantic canonical mapping counters do not match its bounded scope and records.'
        }
        $scopeRecordTotal = 0
        for ($index = 0; $index -lt $mappingScopes.Count; $index++) {
            $mappingScope = $mappingScopes[$index]
            Assert-ExactPropertySet `
                -Object $mappingScope `
                -ExpectedNames @('scopeIndex', 'devicePath', 'recursive', 'rootName', 'recordCount') `
                -Context 'Engineering semantic canonical mapping scope'
            if ((-not (Test-JsonInt32 -Value $mappingScope.scopeIndex)) -or
                ([int]$mappingScope.scopeIndex -ne $index) -or
                (-not (Test-JsonInt32 -Value $mappingScope.recordCount)) -or
                ([int]$mappingScope.recordCount -lt 0) -or
                ($mappingScope.recursive -isnot [bool]) -or
                (-not [bool]$mappingScope.recursive) -or
                ([string]::IsNullOrWhiteSpace([string]$mappingScope.rootName)) -or
                ([string]$mappingScope.devicePath -ne [string]$scope.mappingScopes[$index].devicePath)) {
                throw 'Engineering semantic canonical mapping scope is inconsistent with the reviewed scope request.'
            }
            $scopeRecordTotal += [int]$mappingScope.recordCount
        }
        if ($scopeRecordTotal -ne [int]$mapping.recordCount) {
            throw 'Engineering semantic canonical mapping scope record counts do not equal recordCount.'
        }

        $baseRecordFields = @(
            'recordKind', 'scopeIndex', 'scopeDevicePath', 'relativeDevicePath', 'deviceIndexPath',
            'deviceName', 'sourceKind', 'channelIdentity', 'channelName', 'bindingSource', 'actualVariable'
        )
        $connectorFields = @('parameterSetKind', 'connectorIndex', 'parameterIndex', 'parameterId', 'parameterName')
        $previousRecordKey = $null
        for ($index = 0; $index -lt $mappingRecords.Count; $index++) {
            $record = $mappingRecords[$index]
            $sourceKind = [string]$record.sourceKind
            $expectedFields = if ($sourceKind -eq 'connector-parameter') { $baseRecordFields + $connectorFields } else { $baseRecordFields }
            Assert-ExactPropertySet -Object $record -ExpectedNames $expectedFields -Context 'Engineering semantic canonical mapping record'
            if (([string]$record.recordKind -ne 'scope-channel') -or
                (@('tree-channel', 'connector-parameter') -notcontains $sourceKind) -or
                (-not (Test-JsonInt32 -Value $record.scopeIndex)) -or
                ([int]$record.scopeIndex -lt 0) -or
                ([int]$record.scopeIndex -ge $mappingScopes.Count) -or
                ([string]::IsNullOrWhiteSpace([string]$record.channelIdentity)) -or
                ($record.actualVariable -isnot [string])) {
                throw 'Engineering semantic canonical mapping record is not an actual-only scope-channel fact.'
            }
            $recordKey = [string]$record.channelIdentity + "`n" + (Get-CanonicalJsonElementText -Element $record)
            if (($null -ne $previousRecordKey) -and
                ([System.StringComparer]::Ordinal.Compare($previousRecordKey, $recordKey) -gt 0)) {
                throw 'Engineering semantic canonical mapping records are not in canonical ordinal order.'
            }
            $previousRecordKey = $recordKey
        }

        $symbol = $baseline.canonicalFacts.symbolConfig
        Assert-ExactPropertySet `
            -Object $symbol `
            -ExpectedNames @('applicationPath', 'canonicalPayloadByteCount', 'payloadSha256', 'shapeSummary') `
            -Context 'Engineering semantic canonical Symbol facts'
        if (([string]$symbol.applicationPath -ne [string]$scope.symbolApplicationPath) -or
            (-not (Test-JsonInt32 -Value $symbol.canonicalPayloadByteCount)) -or
            ([int]$symbol.canonicalPayloadByteCount -lt 0) -or
            (-not (Test-HexSha256 -Value ([string]$symbol.payloadSha256)))) {
            throw 'Engineering semantic canonical Symbol facts do not match the requested application path or payload contract.'
        }
        Assert-ExactPropertySet `
            -Object $symbol.shapeSummary `
            -ExpectedNames @('rootKind', 'topLevelKeys', 'objectCount', 'arrayCount', 'scalarCount', 'nodeCount', 'maxDepth') `
            -Context 'Engineering semantic Symbol shape summary'
        if ($symbol.shapeSummary.topLevelKeys -isnot [System.Array]) {
            throw 'Engineering semantic Symbol topLevelKeys must be a JSON array.'
        }
        foreach ($countName in @('objectCount', 'arrayCount', 'scalarCount', 'nodeCount', 'maxDepth')) {
            if ((-not (Test-JsonInt32 -Value $symbol.shapeSummary.$countName)) -or ([int]$symbol.shapeSummary.$countName -lt 0)) {
                throw "Engineering semantic Symbol shapeSummary.$countName must be a non-negative integer."
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$symbol.shapeSummary.rootKind) -or
            @($symbol.shapeSummary.topLevelKeys | Where-Object { $_ -isnot [string] }).Count -gt 0) {
            throw 'Engineering semantic Symbol shape summary contains invalid rootKind/topLevelKeys.'
        }

        Assert-ExactPropertySet `
            -Object $baseline.hashes `
            -ExpectedNames @('algorithm', 'canonicalization', 'mappingSha256', 'symbolConfigSha256', 'snapshotSha256') `
            -Context 'Engineering semantic baseline hashes'
        if (([string]$baseline.hashes.algorithm -ne 'SHA-256') -or
            ([string]$baseline.hashes.canonicalization -ne 'ctrlx-semantic-canonical-json-v1')) {
            throw 'Engineering semantic baseline hash/canonicalization contract is unsupported.'
        }
        $expectedHashes = @{
            mappingSha256      = Get-CanonicalJsonElementSha256 -Element $mapping
            symbolConfigSha256 = Get-CanonicalJsonElementSha256 -Element $symbol
            snapshotSha256     = Get-CanonicalJsonElementSha256 -Element $baseline.canonicalFacts
        }
        foreach ($hashName in $expectedHashes.Keys) {
            $reportedHash = [string]$baseline.hashes.$hashName
            if ((-not (Test-HexSha256 -Value $reportedHash)) -or
                (-not $reportedHash.Equals([string]$expectedHashes[$hashName], [System.StringComparison]::OrdinalIgnoreCase))) {
                throw "Engineering semantic baseline $hashName does not match its canonical facts."
            }
        }

        Assert-ExactPropertySet `
            -Object $baseline.review `
            -ExpectedNames @('reviewId', 'reviewer', 'reviewedAtUtc', 'evidencePath', 'evidenceSha256') `
            -Context 'Engineering semantic baseline review'
        foreach ($requiredReviewString in @('reviewId', 'reviewer', 'reviewedAtUtc', 'evidencePath', 'evidenceSha256')) {
            if ([string]::IsNullOrWhiteSpace([string]$baseline.review.$requiredReviewString)) {
                throw "Engineering semantic baseline review is missing '$requiredReviewString'."
            }
        }
        $reviewedAt = [DateTime]::MinValue
        if ((-not [DateTime]::TryParse([string]$baseline.review.reviewedAtUtc, [ref]$reviewedAt)) -or
            ($reviewedAt.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5))) {
            throw 'Engineering semantic baseline reviewedAtUtc is invalid or unreasonably far in the future.'
        }
        $evidenceRelativePath = ([string]$baseline.review.evidencePath).Replace('\', '/')
        if ([System.IO.Path]::IsPathRooted($evidenceRelativePath)) {
            throw 'Engineering semantic baseline evidencePath must be relative to EngineeringRoot.'
        }
        $evidencePath = [System.IO.Path]::GetFullPath((Join-Path $EngineeringRoot $evidenceRelativePath))
        $safeEvidenceRelativePath = Get-SafeRelativePath -Root $EngineeringRoot -Path $evidencePath
        if ((-not $safeEvidenceRelativePath) -or
            ($safeEvidenceRelativePath -ne $evidenceRelativePath) -or
            ($safeEvidenceRelativePath -in @($relativeBaselinePath, [string]$ScopeAudit.path)) -or
            (-not [System.IO.File]::Exists($evidencePath))) {
            throw 'Engineering semantic baseline review evidence is missing, unsafe or not independent.'
        }
        $actualEvidenceSha = Assert-IndependentHumanReviewEvidence `
            -EngineeringRoot $EngineeringRoot `
            -RelativePath $safeEvidenceRelativePath `
            -AbsolutePath $evidencePath `
            -Context 'Engineering semantic baseline review evidence'
        $expectedEvidenceSha = [string]$baseline.review.evidenceSha256
        if ((-not (Test-HexSha256 -Value $expectedEvidenceSha)) -or
            (-not $actualEvidenceSha.Equals($expectedEvidenceSha, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw 'Engineering semantic baseline review evidence SHA-256 does not match its file.'
        }

        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            $baselineSha = ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
        }
        finally {
            $algorithm.Dispose()
        }
        return [ordered]@{
            state          = 'reviewed'
            path           = $relativeBaselinePath
            sha256         = $baselineSha
            reviewEvidence = [ordered]@{
                path   = $safeEvidenceRelativePath
                sha256 = $actualEvidenceSha
            }
        }
    }
    catch {
        throw "Engineering semantic baseline is invalid: $baselinePath. $($_.Exception.Message)"
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

    $payload = ConvertFrom-JsonPreservingStrings -Json $RawText
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

    if (($Status -ne 'failed') -and $Request.PSObject.Properties['legacyPayload']) {
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
        $payload = ConvertFrom-JsonPreservingStrings -Json ([System.IO.File]::ReadAllText($Path))
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
    $null = $builder.AppendLine("## Reviewed warning baseline")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- State: ``$($Report.warningBaseline.state)``")
    $null = $builder.AppendLine("- Path: ``$($Report.warningBaseline.path)``")
    if ([string]$Report.warningBaseline.state -eq 'reviewed') {
        $null = $builder.AppendLine("- Baseline SHA-256: ``$($Report.warningBaseline.sha256)``")
        $null = $builder.AppendLine("- Review evidence: ``$($Report.warningBaseline.reviewEvidence.path)``")
        $null = $builder.AppendLine("- Review evidence SHA-256: ``$($Report.warningBaseline.reviewEvidence.sha256)``")
    }
    else {
        $null = $builder.AppendLine('- A fresh Build may be collected, but Stage2 cannot reach DONE until a reviewed baseline is present in a new immutable action.')
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Engineering semantic snapshot')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- Required scope: ``$($Report.semanticSnapshotRequest.path)``")
    $null = $builder.AppendLine("- Scope SHA-256: ``$($Report.semanticSnapshotRequest.sha256)``")
    $null = $builder.AppendLine("- Reviewed baseline state: ``$($Report.semanticBaseline.state)``")
    $null = $builder.AppendLine("- Reviewed baseline path: ``$($Report.semanticBaseline.path)``")
    if ([string]$Report.semanticBaseline.state -eq 'reviewed') {
        $null = $builder.AppendLine("- Baseline SHA-256: ``$($Report.semanticBaseline.sha256)``")
        $null = $builder.AppendLine("- Review evidence: ``$($Report.semanticBaseline.reviewEvidence.path)``")
        $null = $builder.AppendLine("- Review evidence SHA-256: ``$($Report.semanticBaseline.reviewEvidence.sha256)``")
    }
    else {
        $null = $builder.AppendLine('- The Runner must still collect a fresh mapping/Symbol snapshot, but Stage2 will block for review instead of reaching DONE.')
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
        [long]$OriginalByteCount,

        [Parameter(Mandatory = $true)]
        [string]$OriginalSha256,

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
    if (($OriginalByteCount -lt 0) -or (-not (Test-HexSha256 -Value $OriginalSha256))) {
        throw 'Original request failure metadata is invalid.'
    }
    $failureDetails = if ($NormalizedRequest) {
        [ordered]@{
            code       = 'AUDIT_REQUEST_FAILED'
            stage      = 'offline-audit'
            type       = $Failure.Exception.GetType().FullName
            message    = $Failure.Exception.Message
            stackTrace = $Failure.ScriptStackTrace
        }
    }
    else {
        # Parser exceptions may quote attacker-controlled fragments. Persist a
        # fixed diagnostic for an untrusted, unnormalized request and retain
        # only exact size/hash metadata for local correlation.
        [ordered]@{
            code       = 'REQUEST_PARSE_OR_NORMALIZATION_FAILED'
            stage      = 'request-normalization'
            type       = $Failure.Exception.GetType().FullName
            message    = 'Post-export request could not be parsed or normalized.'
            stackTrace = $null
        }
    }
    $failedAtUtc = [DateTime]::UtcNow.ToString('o')

    if ($NormalizedRequest) {
        $failedRecord = New-StateRecord -Request $NormalizedRequest -Status 'failed' -AdditionalFields @{
            failedAtUtc          = $failedAtUtc
            originalRequestByteCount = $OriginalByteCount
            originalRequestMaximumBytes = $maximumRequestBytes
            originalRequestSha256 = $OriginalSha256
            failure              = $failureDetails
        }
    }
    else {
        $failedRecord = [ordered]@{
            schemaVersion         = 2
            requestId             = $safeRequestId
            status                = 'failed'
            failedAtUtc           = $failedAtUtc
            originalRequestByteCount = $OriginalByteCount
            originalRequestMaximumBytes = $maximumRequestBytes
            originalRequestSha256 = $OriginalSha256
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
        originalRequestByteCount = $OriginalByteCount
        originalRequestMaximumBytes = $maximumRequestBytes
        originalRequestSha256 = $OriginalSha256
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
        [string]$ExpectedPlcProject,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedProfile
    )

    $processingDirectory = Join-Path $ActiveQueueRoot 'processing'
    $doneDirectory = Join-Path $ActiveQueueRoot 'done'
    $failedDirectory = Join-Path $ActiveQueueRoot 'failed'
    $processingPath = $null
    $normalizedRequest = $null
    $rawText = ''
    $originalRequestByteCount = -1L
    $originalRequestSha256 = $null

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

        $originalRequestItem = Get-Item -LiteralPath $processingPath
        $originalRequestByteCount = [long]$originalRequestItem.Length
        $originalRequestSha256 = (Get-FileHash -LiteralPath $processingPath -Algorithm SHA256).Hash
        if ($originalRequestByteCount -gt $maximumRequestBytes) {
            throw "Post-export request exceeds the $maximumRequestBytes byte input limit."
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
        $warningBaselineAudit = Get-WarningBaselineAudit `
            -EngineeringRoot $ActiveEngineeringRoot `
            -StationRoot $normalizedRequest.stationRoot `
            -PlcProject $normalizedRequest.plcProject `
            -Profile $ExpectedProfile
        $semanticScopeAudit = Get-SemanticScopeAudit `
            -EngineeringRoot $ActiveEngineeringRoot `
            -StationRoot $normalizedRequest.stationRoot `
            -PlcProject $normalizedRequest.plcProject `
            -Profile $ExpectedProfile
        $semanticBaselineAudit = Get-SemanticBaselineAudit `
            -EngineeringRoot $ActiveEngineeringRoot `
            -StationRoot $normalizedRequest.stationRoot `
            -PlcProject $normalizedRequest.plcProject `
            -Profile $ExpectedProfile `
            -ScopeAudit $semanticScopeAudit
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
            warningBaseline = $warningBaselineAudit
            semanticSnapshotRequest = $semanticScopeAudit
            semanticBaseline = $semanticBaselineAudit
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
                    -OriginalByteCount $originalRequestByteCount `
                    -OriginalSha256 $originalRequestSha256 `
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
$expectedProfile = $null
if ([System.IO.File]::Exists($configurationPath)) {
    $configuredStationRoot = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'station_root'
    if ($configuredStationRoot -and ($configuredStationRoot -ne 'null')) {
        $expectedStationRoot = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredStationRoot
    }
    $configuredPlcProject = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'plc_project'
    if ($configuredPlcProject -and ($configuredPlcProject -ne 'null')) {
        $expectedPlcProject = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredPlcProject
    }
    $configuredProfile = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'plc_engineering_profile'
    if ($configuredProfile -and ($configuredProfile -ne 'null')) {
        $expectedProfile = $configuredProfile
    }
}
if ([string]::IsNullOrWhiteSpace($expectedProfile)) {
    throw 'config/project.yaml must define tools.plc_engineering_profile before warning-baseline audit can run.'
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
                 -ExpectedPlcProject $expectedPlcProject `
                 -ExpectedProfile $expectedProfile
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
