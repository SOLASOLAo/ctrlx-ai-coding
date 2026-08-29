[CmdletBinding()]
param(
    [ValidateSet('Build', 'Check')]
    [string]$Command = 'Build',

    [string]$EngineeringRoot,

    [switch]$RequireReady,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$maximumJsonBytes = 4MB
$maximumSourceBytes = 16MB
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or newer is required to build a ctrlX OpCon Project Pack.'
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Read-BoundedBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int64]$MaximumBytes,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point: $Path"
    }
    if ($item.Length -gt $MaximumBytes) {
        throw "$Description exceeds the $MaximumBytes byte limit: $Path"
    }
    return [System.IO.File]::ReadAllBytes($item.FullName)
}

function Read-StrictUtf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int64]$MaximumBytes,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $bytes = Read-BoundedBytes -Path $Path -MaximumBytes $MaximumBytes -Description $Description
    try {
        return $utf8Strict.GetString($bytes)
    }
    catch {
        throw "$Description is not strict UTF-8: $Path"
    }
}

function Read-JsonDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SchemaPath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $raw = Read-StrictUtf8Text -Path $Path -MaximumBytes $maximumJsonBytes -Description $Description
    $schemaErrors = @()
    $isValid = Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    if (-not $isValid) {
        $detail = @($schemaErrors | ForEach-Object { $_.ToString() }) -join '; '
        throw "$Description does not match its schema: $detail"
    }
    try {
        return ($raw | ConvertFrom-Json -Depth 64)
    }
    catch {
        throw "$Description is not valid JSON: $($_.Exception.Message)"
    }
}

function Assert-RootDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (-not [System.IO.Directory]::Exists($fullPath)) {
        throw "EngineeringRoot does not exist: $fullPath"
    }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "EngineeringRoot must not be a reparse point: $fullPath"
    }
    return $fullPath
}

function Resolve-ProjectFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\')) {
        throw "$Description must use a non-empty root-relative path with '/' separators: '$RelativePath'"
    }
    $segments = @($RelativePath.Split('/'))
    if (($segments.Count -eq 0) -or @($segments | Where-Object { ($_ -eq '') -or ($_ -eq '.') -or ($_ -eq '..') }).Count -gt 0) {
        throw "$Description contains an empty, current-directory or parent-directory segment: '$RelativePath'"
    }

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    $rootPrefix = $Root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description escapes EngineeringRoot: '$RelativePath'"
    }

    $current = $Root
    for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        $current = Join-Path $current $segments[$index]
        if ([System.IO.Directory]::Exists($current)) {
            $directory = Get-Item -LiteralPath $current -Force
            if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Description traverses a reparse point: '$RelativePath'"
            }
        }
    }

    if (-not [System.IO.File]::Exists($candidate)) {
        throw "$Description does not exist: '$RelativePath'"
    }
    $file = Get-Item -LiteralPath $candidate -Force
    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point: '$RelativePath'"
    }

    return [pscustomobject]@{
        RelativePath = $RelativePath
        FullPath = $candidate
    }
}

function New-SourceRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $resolved = Resolve-ProjectFile -Root $Root -RelativePath $RelativePath -Description $Description
    $bytes = Read-BoundedBytes -Path $resolved.FullPath -MaximumBytes $maximumSourceBytes -Description $Description
    return [ordered]@{
        path = $resolved.RelativePath
        length = $bytes.Length
        sha256 = Get-Sha256Hex -Bytes $bytes
    }
}

function Assert-UniqueStrings {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Values,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Values) {
        $text = [string]$value
        if (-not $seen.Add($text)) {
            throw "$Description contains a duplicate value: '$text'"
        }
    }
}

function Sort-OrdinalStrings {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Values)

    [string[]]$copy = @($Values | ForEach-Object { [string]$_ })
    [System.Array]::Sort($copy, [System.StringComparer]::Ordinal)
    return $copy
}

function Sort-OrdinalObjects {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Values,
        [Parameter(Mandatory = $true)][scriptblock]$Key
    )

    [object[]]$copy = @($Values)
    [string[]]$keys = @($copy | ForEach-Object { [string](& $Key $_) })
    [System.Array]::Sort($keys, $copy, [System.StringComparer]::Ordinal)
    return $copy
}

function Add-PromptDefinition {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Definitions,
        [Parameter(Mandatory = $true)][object]$Prompt,
        [Parameter(Mandatory = $true)][string]$ProcessId,
        [Parameter(Mandatory = $true)][string]$StepId
    )

    $key = [string]$Prompt.key
    $english = [string]$Prompt.english
    $chinese = [string]$Prompt.chinese
    if ($Definitions.ContainsKey($key)) {
        $existing = $Definitions[$key]
        if (([string]$existing.english -cne $english) -or ([string]$existing.chinese -cne $chinese)) {
            throw "Operator prompt '$key' has inconsistent translations."
        }
        $existing.usages.Add([ordered]@{ processId = $ProcessId; stepId = $StepId })
        return
    }

    $Definitions[$key] = [ordered]@{
        english = $english
        chinese = $chinese
        usages = [System.Collections.Generic.List[object]]::new()
    }
    $Definitions[$key].usages.Add([ordered]@{ processId = $ProcessId; stepId = $StepId })
}

function Convert-InterfaceItems {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items)

    return @($Items | ForEach-Object {
        [ordered]@{
            name = [string]$_.name
            type = [string]$_.type
            source = [string]$_.source
        }
    })
}

function Convert-Process {
    param(
        [Parameter(Mandatory = $true)][object]$Process,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][hashtable]$PromptDefinitions
    )

    $processId = [string]$Process.processId
    $requirements = @($Process.requirements)
    $steps = @($Process.steps)
    $tests = @($Process.acceptanceTests)
    Assert-UniqueStrings -Values @($requirements | ForEach-Object { [string]$_.id }) -Description "Process '$processId' requirement IDs"
    Assert-UniqueStrings -Values @($steps | ForEach-Object { [string]$_.id }) -Description "Process '$processId' step IDs"
    Assert-UniqueStrings -Values @($tests | ForEach-Object { [string]$_.id }) -Description "Process '$processId' acceptance-test IDs"

    $requirementMap = @{}
    $stepUse = @{}
    $testUse = @{}
    foreach ($requirement in $requirements) {
        $id = [string]$requirement.id
        $requirementMap[$id] = [string]$requirement.text
        $stepUse[$id] = [System.Collections.Generic.List[string]]::new()
        $testUse[$id] = [System.Collections.Generic.List[string]]::new()
    }
    $stepMap = @{}
    foreach ($step in $steps) {
        $stepId = [string]$step.id
        $stepMap[$stepId] = $true
        foreach ($requirementId in @($step.requirements)) {
            $id = [string]$requirementId
            if (-not $requirementMap.ContainsKey($id)) {
                throw "Process '$processId' step '$stepId' references unknown requirement '$id'."
            }
            $stepUse[$id].Add($stepId)
        }
        if (($null -ne $step.prompt) -and ($null -ne $step.promptVariants)) {
            throw "Process '$processId' step '$stepId' cannot define both prompt and promptVariants."
        }
        $stepPrompts = if ($null -ne $step.prompt) { @($step.prompt) } else { @($step.promptVariants) }
        if ($stepPrompts.Count -gt 0) {
            Assert-UniqueStrings -Values @($stepPrompts | ForEach-Object { [string]$_.key }) -Description "Process '$processId' step '$stepId' prompt keys"
            foreach ($stepPrompt in $stepPrompts) {
                Add-PromptDefinition -Definitions $PromptDefinitions -Prompt $stepPrompt -ProcessId $processId -StepId $stepId
            }
        }
    }

    foreach ($test in $tests) {
        $testId = [string]$test.id
        foreach ($requirementId in @($test.requirements)) {
            $id = [string]$requirementId
            if (-not $requirementMap.ContainsKey($id)) {
                throw "Process '$processId' test '$testId' references unknown requirement '$id'."
            }
            $testUse[$id].Add($testId)
        }
        foreach ($stepIdValue in @($test.steps)) {
            $stepId = [string]$stepIdValue
            if (-not $stepMap.ContainsKey($stepId)) {
                throw "Process '$processId' test '$testId' references unknown step '$stepId'."
            }
        }
    }

    if ([string]$Process.status -eq 'ready') {
        if (($requirements.Count -eq 0) -or ($tests.Count -eq 0)) {
            throw "Ready process '$processId' must contain at least one requirement and acceptance test."
        }
        foreach ($requirementId in @($requirementMap.Keys)) {
            if (($stepUse[$requirementId].Count -eq 0) -or ($testUse[$requirementId].Count -eq 0)) {
                throw "Ready process '$processId' requirement '$requirementId' must be traced to at least one step and test."
            }
        }
    }

    $chain = [ordered]@{
        name = [string]$Process.chain.name
        kind = [string]$Process.chain.kind
        plcPath = [string]$Process.chain.plcPath
        interfaceOwner = [string]$Process.chain.interfaceOwner
        caller = if ($null -eq $Process.chain.caller) { $null } else { [string]$Process.chain.caller }
        inputs = Convert-InterfaceItems -Items @($Process.chain.inputs)
        outputs = Convert-InterfaceItems -Items @($Process.chain.outputs)
    }
    if ([string]$chain.interfaceOwner -eq 'cpstudio') {
        $nonCpStudioInterfaces = @(@($chain.inputs) + @($chain.outputs) | Where-Object { [string]$_.source -cne 'cpstudio' })
        if ($nonCpStudioInterfaces.Count -gt 0) {
            throw "Process '$processId' declares a CpStudio-owned interface but contains a non-CpStudio input or output source."
        }
    }

    $planSteps = @($steps | ForEach-Object {
        $prompt = if ($null -eq $_.prompt) {
            $null
        }
        else {
            [ordered]@{
                key = [string]$_.prompt.key
                english = [string]$_.prompt.english
                chinese = [string]$_.prompt.chinese
            }
        }
        $promptVariants = if ($null -eq $_.promptVariants) {
            @()
        }
        else {
            @($_.promptVariants | ForEach-Object {
                [ordered]@{
                    when = [string]$_.when
                    key = [string]$_.key
                    english = [string]$_.english
                    chinese = [string]$_.chinese
                }
            })
        }
        $parallel = if ($null -eq $_.parallel) {
            $null
        }
        else {
            [ordered]@{
                group = [string]$_.parallel.group
                branch = [int]$_.parallel.branch
            }
        }
        [ordered]@{
            id = [string]$_.id
            kind = [string]$_.kind
            comment = [string]$_.comment
            operation = [string]$_.operation
            transition = if ($null -eq $_.transition) { $null } else { [string]$_.transition }
            prompt = $prompt
            promptVariants = $promptVariants
            requirements = @($_.requirements | ForEach-Object { [string]$_ })
            acceptance = @($_.acceptance | ForEach-Object { [string]$_ })
            parallel = $parallel
        }
    })

    $testCases = @($tests | ForEach-Object {
        [ordered]@{
            processId = $processId
            id = [string]$_.id
            title = [string]$_.title
            requirements = @($_.requirements | ForEach-Object { [string]$_ })
            steps = @($_.steps | ForEach-Object { [string]$_ })
            expected = @($_.expected | ForEach-Object { [string]$_ })
        }
    })

    $traceability = @($requirements | ForEach-Object {
        $id = [string]$_.id
        [ordered]@{
            processId = $processId
            requirementId = $id
            text = [string]$_.text
            stepIds = @(Sort-OrdinalStrings -Values @($stepUse[$id]))
            testIds = @(Sort-OrdinalStrings -Values @($testUse[$id]))
        }
    })

    return [ordered]@{
        sourcePath = $SourcePath
        processId = $processId
        displayName = [string]$Process.displayName
        status = [string]$Process.status
        chain = $chain
        requirements = @($requirements | ForEach-Object { [ordered]@{ id = [string]$_.id; text = [string]$_.text } })
        steps = $planSteps
        cleanup = @($Process.cleanup | ForEach-Object { [string]$_ })
        testCases = $testCases
        traceability = $traceability
    }
}

function ConvertTo-CanonicalJsonText {
    param([Parameter(Mandatory = $true)][object]$Value)

    $text = $Value | ConvertTo-Json -Depth 64
    return ($text -replace "`r`n", "`n").TrimEnd("`r", "`n") + "`n"
}

function Write-AtomicUtf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $parent = [System.IO.Path]::GetDirectoryName($Path)
    $rootPrefix = $Root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $parent.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated output escapes EngineeringRoot: $Path"
    }
    if ([System.IO.Directory]::Exists($parent)) {
        $item = Get-Item -LiteralPath $parent -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Generated output directory must not be a reparse point: $parent"
        }
    }
    else {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    $temporaryPath = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Text, $utf8NoBom)
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

if ([string]::IsNullOrWhiteSpace($EngineeringRoot)) {
    $EngineeringRoot = Join-Path $PSScriptRoot '..\..'
}
$root = Assert-RootDirectory -Path $EngineeringRoot
$packRelativePath = 'project-pack.json'
$packSchemaRelativePath = 'schemas/project-pack.schema.json'
$processSchemaRelativePath = 'schemas/process.schema.json'
$outputRelativePath = 'generated/engineering-plan.json'

$packPath = (Resolve-ProjectFile -Root $root -RelativePath $packRelativePath -Description 'Project Pack').FullPath
$packSchemaPath = (Resolve-ProjectFile -Root $root -RelativePath $packSchemaRelativePath -Description 'Project Pack schema').FullPath
$processSchemaPath = (Resolve-ProjectFile -Root $root -RelativePath $processSchemaRelativePath -Description 'Process schema').FullPath
$pack = Read-JsonDocument -Path $packPath -SchemaPath $packSchemaPath -Description 'Project Pack'

$categoryPaths = [ordered]@{
    projectConfig = @([string]$pack.projectConfig)
    station = @([string]$pack.sources.station)
    io = @([string]$pack.sources.io)
    events = @([string]$pack.sources.events)
    units = @($pack.sources.units | ForEach-Object { [string]$_ })
    processes = @($pack.sources.processes | ForEach-Object { [string]$_ })
    hmi = @($pack.sources.hmi | ForEach-Object { [string]$_ })
    catalog = @($pack.sources.catalog | ForEach-Object { [string]$_ })
    manifests = @($pack.sources.manifests | ForEach-Object { [string]$_ })
}

$allReferencedPaths = @($categoryPaths.Values | ForEach-Object { @($_) })
Assert-UniqueStrings -Values $allReferencedPaths -Description 'Project Pack source paths'

$sourcePaths = @($packRelativePath, $packSchemaRelativePath, $processSchemaRelativePath) + $allReferencedPaths
$sourceRecords = @(Sort-OrdinalObjects -Values @($sourcePaths | ForEach-Object {
    New-SourceRecord -Root $root -RelativePath $_ -Description "Project Pack source '$_'"
}) -Key { param($item) $item.path })

$promptDefinitions = @{}
$processPlans = New-Object System.Collections.Generic.List[object]
foreach ($processRelativePath in @(Sort-OrdinalStrings -Values @($categoryPaths.processes))) {
    if (-not $processRelativePath.EndsWith('.process.json', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Process source must end with '.process.json': '$processRelativePath'"
    }
    $processPath = (Resolve-ProjectFile -Root $root -RelativePath $processRelativePath -Description 'Process source').FullPath
    $process = Read-JsonDocument -Path $processPath -SchemaPath $processSchemaPath -Description "Process '$processRelativePath'"
    $processPlans.Add((Convert-Process -Process $process -SourcePath $processRelativePath -PromptDefinitions $promptDefinitions))
}
Assert-UniqueStrings -Values @($processPlans | ForEach-Object { [string]$_.processId }) -Description 'Project Pack process IDs'
Assert-UniqueStrings -Values @($processPlans | ForEach-Object { [string]$_.chain.name }) -Description 'Project Pack Chain names'
Assert-UniqueStrings -Values @($processPlans | ForEach-Object { [string]$_.chain.plcPath }) -Description 'Project Pack Chain PLC paths'

$readyForEngineering = ([string]$pack.status -eq 'ready') -and
    ($processPlans.Count -gt 0) -and
    (@($processPlans | Where-Object { [string]$_.status -ne 'ready' }).Count -eq 0)

$contentMaterial = @($sourceRecords | ForEach-Object {
    '{0}|{1}|{2}' -f $_.path, $_.length, $_.sha256
}) -join "`n"
$contentMaterial += "`n"
$contentId = Get-Sha256Hex -Bytes $utf8NoBom.GetBytes($contentMaterial)

$operatorPrompts = @(Sort-OrdinalStrings -Values @($promptDefinitions.Keys) | ForEach-Object {
    $key = $_
    $definition = $promptDefinitions[$key]
    [ordered]@{
        key = $key
        english = [string]$definition.english
        chinese = [string]$definition.chinese
        usages = @(Sort-OrdinalObjects -Values @($definition.usages) -Key { param($item) ([string]$item.processId) + "`0" + ([string]$item.stepId) })
    }
})
$testCases = @(Sort-OrdinalObjects -Values @($processPlans | ForEach-Object { @($_.testCases) }) -Key { param($item) ([string]$item.processId) + "`0" + ([string]$item.id) })
$traceability = @(Sort-OrdinalObjects -Values @($processPlans | ForEach-Object { @($_.traceability) }) -Key { param($item) ([string]$item.processId) + "`0" + ([string]$item.requirementId) })
$sfcPlans = @(Sort-OrdinalObjects -Values @($processPlans.ToArray()) -Key { param($item) $item.processId } | ForEach-Object {
    [ordered]@{
        sourcePath = $_.sourcePath
        processId = $_.processId
        displayName = $_.displayName
        status = $_.status
        chain = $_.chain
        steps = $_.steps
        cleanup = $_.cleanup
    }
})

$plan = [ordered]@{
    schemaVersion = 1
    kind = 'ctrlx-opcon-engineering-plan'
    builderVersion = '1.0.0'
    contentId = $contentId
    projectPackSha256 = [string](@($sourceRecords | Where-Object path -eq $packRelativePath)[0].sha256)
    readyForEngineering = $readyForEngineering
    sources = $sourceRecords
    sfcPlans = $sfcPlans
    operatorPrompts = $operatorPrompts
    testCases = $testCases
    traceability = $traceability
}
$expectedText = ConvertTo-CanonicalJsonText -Value $plan
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $root ($outputRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))

if ($RequireReady -and (-not $readyForEngineering)) {
    throw 'Project Pack is valid but not ready for engineering. Set the pack and every process to status=ready and include at least one process.'
}

if ($Command -eq 'Build') {
    Write-AtomicUtf8Text -Path $outputPath -Text $expectedText -Root $root
    $status = 'BUILT'
}
else {
    if (-not [System.IO.File]::Exists($outputPath)) {
        throw "Generated engineering plan is missing. Run Build first: $outputRelativePath"
    }
    $actualText = Read-StrictUtf8Text -Path $outputPath -MaximumBytes $maximumSourceBytes -Description 'Generated engineering plan'
    if ($actualText -cne $expectedText) {
        throw 'Generated engineering plan is stale or was edited. Run Build and review the source changes.'
    }
    $status = 'VALID'
}

$result = [ordered]@{
    status = $status
    command = $Command
    projectPack = $packRelativePath
    output = $outputRelativePath
    contentId = $contentId
    readyForEngineering = $readyForEngineering
    processCount = $processPlans.Count
    promptCount = $operatorPrompts.Count
    testCount = $testCases.Count
    requirementCount = $traceability.Count
}
if ($Json) {
    $result | ConvertTo-Json -Compress
}
else {
    [pscustomobject]$result
}
