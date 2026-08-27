Set-StrictMode -Version Latest

$script:MaximumRestBytes = 1024 * 1024
$script:MaximumChildren = 256

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-CanonicalJson {
    param([Parameter(Mandatory = $true)]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ($Value | ConvertTo-Json -Compress) }
    if (($Value -is [bool]) -or ($Value -is [ValueType])) { return ($Value | ConvertTo-Json -Compress) }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        $items = @($Value | ForEach-Object { Get-CanonicalJson -Value $_ })
        return '[' + ($items -join ',') + ']'
    }

    $properties = if ($Value -is [System.Collections.IDictionary]) {
        @($Value.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $Value[$_] } })
    }
    else {
        @($Value.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
    }
    $members = @($properties | Sort-Object -Property Name -CaseSensitive | ForEach-Object {
        (($_.Name | ConvertTo-Json -Compress) + ':' + (Get-CanonicalJson -Value $_.Value))
    })
    return '{' + ($members -join ',') + '}'
}

function ConvertFrom-StrictUtf8Json {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Context
    )
    try {
        $decoder = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $decoder.GetString($Bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        return $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$Context did not return strict UTF-8 JSON."
    }
}

function Assert-LocalPleBaseUri {
    param([Parameter(Mandatory = $true)][string]$BaseUri)
    $uri = $null
    if (-not [Uri]::TryCreate($BaseUri, [UriKind]::Absolute, [ref]$uri)) { throw 'PLE REST base URI is invalid.' }
    if (($uri.Scheme -ne 'http') -or ($uri.Host -cne 'localhost') -or ($uri.Port -ne 9002) -or
        (-not [string]::IsNullOrEmpty($uri.UserInfo)) -or (-not [string]::IsNullOrEmpty($uri.Query)) -or
        (-not [string]::IsNullOrEmpty($uri.Fragment)) -or
        ($uri.AbsolutePath.TrimEnd('/') -cne '/plc/engineering/api/v2')) {
        throw 'PLE REST is restricted to http://localhost:9002/plc/engineering/api/v2.'
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Assert-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $prefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must be inside the declared isolation root."
    }
    return $resolvedPath
}

function Assert-IsolatedProjectManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectFilePath,
        [Parameter(Mandatory = $true)][string]$IsolationRoot,
        [Parameter(Mandatory = $true)][string]$IsolationManifestPath
    )
    $project = Assert-PathInsideRoot -Root $IsolationRoot -Path $ProjectFilePath -Description 'Project copy'
    $manifestPath = Assert-PathInsideRoot -Root $IsolationRoot -Path $IsolationManifestPath -Description 'Isolation manifest'
    if (([IO.Path]::GetExtension($project) -cne '.project') -or -not [IO.File]::Exists($project)) {
        throw 'Isolated project must be an existing .project file.'
    }
    if (-not [IO.File]::Exists($manifestPath)) { throw 'Isolation manifest is missing.' }
    if ([IO.Path]::GetFileName($manifestPath) -cne '.ctrlx-isolated-copy.json') { throw 'Isolation manifest must use the fixed .ctrlx-isolated-copy.json name.' }
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    if ($manifestBytes.Length -gt 64KB) { throw 'Isolation manifest exceeds 64 KiB.' }
    $manifest = ConvertFrom-StrictUtf8Json -Bytes $manifestBytes -Context 'Isolation manifest'
    if (($manifest.schemaVersion -ne 1) -or ([string]$manifest.kind -cne 'ctrlx-ple-isolated-project-copy-v1')) {
        throw 'Isolation manifest contract is invalid.'
    }
    $declaredProject = Assert-PathInsideRoot -Root $IsolationRoot -Path (Join-Path $IsolationRoot ([string]$manifest.projectRelativePath)) -Description 'Manifest project'
    if (-not $declaredProject.Equals($project, [StringComparison]::OrdinalIgnoreCase)) { throw 'Isolation manifest identifies a different project.' }
    $actualSha = Get-Sha256Hex -Path $project
    if ([string]$manifest.projectSha256 -cne $actualSha) { throw 'Isolated project bytes do not match the manifest SHA-256.' }
    $sourceProject = [IO.Path]::GetFullPath([string]$manifest.sourceProjectPath)
    if (-not [IO.File]::Exists($sourceProject)) { throw 'Isolation manifest source project is missing.' }
    $resolvedRoot = [IO.Path]::GetFullPath($IsolationRoot).TrimEnd('\', '/')
    if ($sourceProject.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Isolation manifest source project must be outside the isolation root.'
    }
    if ($sourceProject.Equals($project, [StringComparison]::OrdinalIgnoreCase)) { throw 'Project target is not an isolated copy.' }
    if ((Get-Sha256Hex -Path $sourceProject) -cne $actualSha) { throw 'Isolated project no longer matches its declared source bytes.' }
    $activeName = [string]$manifest.expectedActiveProjectName
    if ([string]::IsNullOrWhiteSpace($activeName) -or ($activeName.Length -gt 256)) { throw 'Isolation manifest has no bounded active project identity.' }
    $profileName = [string]$manifest.expectedProfileName
    if ([string]::IsNullOrWhiteSpace($profileName) -or ($profileName.Length -gt 256)) { throw 'Isolation manifest has no bounded expected profile.' }
    return [pscustomobject]@{ Project = $project; SourceProject = $sourceProject; ProjectSha256 = $actualSha; ExpectedActiveProjectName = $activeName; ExpectedProfileName = $profileName }
}

function Invoke-BoundedPleHttp {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'PUT')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $false)][string]$Body,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$MaximumBytes
    )
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $handler.UseDefaultCredentials = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $cancellation = New-Object Threading.CancellationTokenSource
    $cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage
        $request.Method = New-Object System.Net.Http.HttpMethod($Method)
        $request.RequestUri = $Uri
        if ($Method -eq 'PUT') {
            $request.Content = New-Object System.Net.Http.StringContent($Body, [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
        try {
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try {
                $buffer = New-Object byte[] 8192
                $memory = New-Object IO.MemoryStream
                try {
                    while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
                        if (($memory.Length + $count) -gt $MaximumBytes) { throw 'PLE REST response exceeded the configured byte limit.' }
                        $memory.Write($buffer, 0, $count)
                    }
                    $bytes = $memory.ToArray()
                }
                finally { $memory.Dispose() }
            }
            finally { $stream.Dispose() }
            if (-not $response.IsSuccessStatusCode) {
                $httpError = New-Object InvalidOperationException("PLE REST $Method failed with HTTP $([int]$response.StatusCode).")
                $httpError.Data['PleHttpStatus'] = [int]$response.StatusCode
                throw $httpError
            }
            return $bytes
        }
        finally { $response.Dispose(); $request.Dispose() }
    }
    finally { $cancellation.Dispose(); $client.Dispose(); $handler.Dispose() }
}

function Invoke-TransportJson {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Transport,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $false)]$Payload,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $body = if ($null -eq $Payload) { $null } else { $Payload | ConvertTo-Json -Depth 64 -Compress }
    if (($null -ne $body) -and ([Text.Encoding]::UTF8.GetByteCount($body) -gt $script:MaximumRestBytes)) { throw 'PLE REST request exceeds 1 MiB.' }
    $transportOutput = @(& $Transport $Method $Uri $body $TimeoutSeconds $script:MaximumRestBytes)
    if ($transportOutput.Count -eq 0) { throw "PLE REST $Method returned no response body." }
    if (@($transportOutput | Where-Object { -not ($_ -is [byte]) }).Count -ne 0) {
        throw 'PLE REST transport returned an invalid response type.'
    }
    [byte[]]$bytes = $transportOutput
    if ($bytes.Length -gt $script:MaximumRestBytes) { throw 'PLE REST response exceeds 1 MiB.' }
    return ConvertFrom-StrictUtf8Json -Bytes $bytes -Context "PLE REST $Method"
}

function Get-EncodedPouUri {
    param([string]$BaseUri, [string[]]$Segments)
    $encoded = @($Segments | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    return "$BaseUri/pous/$encoded"
}

function Get-UniqueChildByElementType {
    param(
        [scriptblock]$Transport, [string]$BaseUri, [string[]]$ParentSegments,
        $Parent, [string]$ElementType, [int]$TimeoutSeconds
    )
    $children = @($Parent.children)
    if ($children.Count -gt $script:MaximumChildren) { throw 'PLE REST child list exceeds 256 entries.' }
    $matches = New-Object Collections.Generic.List[object]
    foreach ($childName in $children) {
        if ([string]::IsNullOrWhiteSpace([string]$childName)) { throw 'PLE REST returned an empty child name.' }
        $segments = @($ParentSegments) + @([string]$childName)
        try {
            $item = Invoke-TransportJson -Transport $Transport -Method GET -Uri (Get-EncodedPouUri -BaseUri $BaseUri -Segments $segments) -TimeoutSeconds $TimeoutSeconds
        }
        catch {
            if ($_.Exception.Data['PleHttpStatus'] -eq 400) { continue }
            throw
        }
        if ([string]$item.elementType -ceq $ElementType) { $matches.Add([pscustomobject]@{ Segments = $segments; Value = $item }) }
    }
    if ($matches.Count -ne 1) { throw "Expected exactly one $ElementType child; found $($matches.Count)." }
    return $matches[0]
}

function Assert-ExactPropertySet {
    param($Value, [string[]]$Expected, [string]$Context)
    $actual = @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    $wanted = @($Expected | Sort-Object -CaseSensitive)
    if (($actual.Count -ne $wanted.Count) -or (($actual -join "`n") -cne ($wanted -join "`n"))) {
        throw "$Context contains missing or unknown fields."
    }
}

function Get-CompileOptionsProjection {
    param($Value, [string]$Context)
    Assert-ExactPropertySet -Value $Value -Expected @('name','elementType','id','children','elementProperties','fixCompilerVersion','settings','maxCompilerWarnings') -Context $Context
    if ([string]$Value.elementType -cne 'CompileOptionsEditor') { throw "$Context has an unexpected elementType." }
    if ($null -ne $Value.id) { throw "$Context id must be null." }
    if (@($Value.children).Count -ne 0) { throw "$Context children must be empty." }
    if (@($Value.elementProperties.PSObject.Properties).Count -ne 0) { throw "$Context elementProperties must be empty." }
    Assert-ExactPropertySet -Value $Value.settings -Expected @('allowUniCodeIdentifiers','replaceConstants','enableBreakpointLogging') -Context "$Context settings"
    foreach ($setting in @('allowUniCodeIdentifiers','replaceConstants','enableBreakpointLogging')) {
        if (-not ($Value.settings.$setting -is [bool])) { throw "$Context setting $setting must be Boolean." }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Value.name) -or [string]::IsNullOrWhiteSpace([string]$Value.fixCompilerVersion)) { throw "$Context has an empty required field." }
    return [pscustomobject][ordered]@{
        name = [string]$Value.name
        elementType = 'CompileOptionsEditor'
        fixCompilerVersion = [string]$Value.fixCompilerVersion
        settings = [pscustomobject][ordered]@{
            allowUniCodeIdentifiers = [bool]$Value.settings.allowUniCodeIdentifiers
            replaceConstants = [bool]$Value.settings.replaceConstants
            enableBreakpointLogging = [bool]$Value.settings.enableBreakpointLogging
        }
        maxCompilerWarnings = [string]$Value.maxCompilerWarnings
    }
}

function Assert-ActiveProjectIdentity {
    param([scriptblock]$Transport, [string]$BaseUri, $Identity, [int]$TimeoutSeconds, [string]$Stage)
    $meta = Invoke-TransportJson -Transport $Transport -Method GET -Uri "$BaseUri/projects/current?option=meta" -TimeoutSeconds $TimeoutSeconds
    foreach ($required in @('path','name','profileName')) {
        if (($null -eq $meta.PSObject.Properties[$required]) -or [string]::IsNullOrWhiteSpace([string]$meta.$required)) {
            throw "Active project metadata is missing $required at $Stage."
        }
    }
    $activePath = [IO.Path]::GetFullPath([string]$meta.path)
    if ($activePath.Equals($Identity.SourceProject, [StringComparison]::OrdinalIgnoreCase)) { throw "Source project is active at $Stage." }
    if (-not $activePath.Equals($Identity.Project, [StringComparison]::OrdinalIgnoreCase)) { throw "Active project path mismatch at $Stage." }
    if (([string]$meta.name -cne $Identity.ExpectedActiveProjectName) -or ([string]$meta.name -cne [IO.Path]::GetFileNameWithoutExtension($Identity.Project))) { throw "Active project name mismatch at $Stage." }
    if ([string]$meta.profileName -cne $Identity.ExpectedProfileName) { throw "Active project profile mismatch at $Stage." }
    return $meta
}

function Invoke-CompileOptionsWarningLimitValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectFilePath,
        [Parameter(Mandatory = $true)][string]$IsolationRoot,
        [Parameter(Mandatory = $true)][string]$IsolationManifestPath,
        [Parameter(Mandatory = $false)][string]$BaseUri = 'http://localhost:9002/plc/engineering/api/v2',
        [Parameter(Mandatory = $false)][string]$DesiredValue = '<no limit>',
        [Parameter(Mandatory = $false)][ValidateRange(1, 60)][int]$TimeoutSeconds = 10,
        [Parameter(Mandatory = $false)][switch]$KeepValidatedValue,
        [Parameter(Mandatory = $false)][scriptblock]$Transport
    )
    if (($DesiredValue -cne '<no limit>') -and ($DesiredValue -notmatch '^[1-9][0-9]{0,8}$')) { throw 'Desired warning limit must be <no limit> or a positive decimal string.' }
    $base = Assert-LocalPleBaseUri -BaseUri $BaseUri
    $identity = Assert-IsolatedProjectManifest -ProjectFilePath $ProjectFilePath -IsolationRoot $IsolationRoot -IsolationManifestPath $IsolationManifestPath
    if ($null -eq $Transport) {
        $Transport = { param($Method, $Uri, $Body, $Timeout, $Maximum) Invoke-BoundedPleHttp -Method $Method -Uri $Uri -Body $Body -TimeoutSeconds $Timeout -MaximumBytes $Maximum }
    }

    $null = Assert-ActiveProjectIdentity -Transport $Transport -BaseUri $base -Identity $identity -TimeoutSeconds $TimeoutSeconds -Stage 'initial discovery'
    $root = Invoke-TransportJson -Transport $Transport -Method GET -Uri "$base/pous" -TimeoutSeconds $TimeoutSeconds
    $settings = Get-UniqueChildByElementType -Transport $Transport -BaseUri $base -ParentSegments @() -Parent $root -ElementType ProjectSettings -TimeoutSeconds $TimeoutSeconds
    $compile = Get-UniqueChildByElementType -Transport $Transport -BaseUri $base -ParentSegments $settings.Segments -Parent $settings.Value -ElementType CompileOptionsEditor -TimeoutSeconds $TimeoutSeconds
    $original = $compile.Value
    $originalProjection = Get-CompileOptionsProjection -Value $original -Context 'Initial CompileOptionsEditor response'
    $originalJson = Get-CanonicalJson -Value $originalProjection
    $modified = ($originalProjection | ConvertTo-Json -Depth 16 -Compress) | ConvertFrom-Json
    $modified.maxCompilerWarnings = $DesiredValue
    $modifiedWithout = ($modified | ConvertTo-Json -Depth 16 -Compress) | ConvertFrom-Json
    $originalWithout = ($originalProjection | ConvertTo-Json -Depth 16 -Compress) | ConvertFrom-Json
    $modifiedWithout.PSObject.Properties.Remove('maxCompilerWarnings')
    $originalWithout.PSObject.Properties.Remove('maxCompilerWarnings')
    if ((Get-CanonicalJson $modifiedWithout) -cne (Get-CanonicalJson $originalWithout)) { throw 'Mutation changed fields other than maxCompilerWarnings.' }

    $compileUri = Get-EncodedPouUri -BaseUri $base -Segments $compile.Segments
    $putAttempted = $false
    $rollbackRequired = $false
    try {
        $null = Assert-ActiveProjectIdentity -Transport $Transport -BaseUri $base -Identity $identity -TimeoutSeconds $TimeoutSeconds -Stage 'before PUT'
        $putAttempted = $true
        $rollbackRequired = $true
        $null = Invoke-TransportJson -Transport $Transport -Method PUT -Uri $compileUri -Payload $modified -TimeoutSeconds $TimeoutSeconds
        $readback = Invoke-TransportJson -Transport $Transport -Method GET -Uri $compileUri -TimeoutSeconds $TimeoutSeconds
        $readbackProjection = Get-CompileOptionsProjection -Value $readback -Context 'CompileOptionsEditor readback'
        if ([string]$readbackProjection.maxCompilerWarnings -cne $DesiredValue) { throw 'Compile warning limit readback did not match the requested value.' }
        $readbackWithout = ($readbackProjection | ConvertTo-Json -Depth 16 -Compress) | ConvertFrom-Json
        $readbackWithout.PSObject.Properties.Remove('maxCompilerWarnings')
        if ((Get-CanonicalJson $readbackWithout) -cne (Get-CanonicalJson $originalWithout)) { throw 'Compile options readback changed fields other than maxCompilerWarnings.' }
        $null = Assert-ActiveProjectIdentity -Transport $Transport -BaseUri $base -Identity $identity -TimeoutSeconds $TimeoutSeconds -Stage 'after PUT'
        if ((Get-Sha256Hex -Path $identity.Project) -cne $identity.ProjectSha256) {
            throw 'Isolated .project container bytes changed during REST validation.'
        }
        if ($KeepValidatedValue) { $rollbackRequired = $false }
    }
    catch {
        $primaryError = $_.Exception.Message
        if ($putAttempted) {
            # The catch path owns rollback.  Disable the finally-path attempt so
            # a rollback failure cannot be masked by a second rollback failure.
            $rollbackRequired = $false
            try {
                $null = Assert-ActiveProjectIdentity -Transport $Transport -BaseUri $base -Identity $identity -TimeoutSeconds $TimeoutSeconds -Stage 'before failure rollback'
                $null = Invoke-TransportJson -Transport $Transport -Method PUT -Uri $compileUri -Payload $originalProjection -TimeoutSeconds $TimeoutSeconds
                $restored = Invoke-TransportJson -Transport $Transport -Method GET -Uri $compileUri -TimeoutSeconds $TimeoutSeconds
                $restoredProjection = Get-CompileOptionsProjection -Value $restored -Context 'Failure rollback readback'
                if ((Get-CanonicalJson $restoredProjection) -cne $originalJson) { throw 'Rollback readback does not match the original known projection.' }
                $null = Assert-ActiveProjectIdentity -Transport $Transport -BaseUri $base -Identity $identity -TimeoutSeconds $TimeoutSeconds -Stage 'after failure rollback'
            }
            catch { throw "Compile warning-limit validation failed: $primaryError Rollback also failed: $($_.Exception.Message)" }
        }
        throw "Compile warning-limit validation failed: $primaryError"
    }
    finally {
        if ($rollbackRequired) {
            try {
                $null = Assert-ActiveProjectIdentity -Transport $Transport -BaseUri $base -Identity $identity -TimeoutSeconds $TimeoutSeconds -Stage 'before success rollback'
                $null = Invoke-TransportJson -Transport $Transport -Method PUT -Uri $compileUri -Payload $originalProjection -TimeoutSeconds $TimeoutSeconds
                $restored = Invoke-TransportJson -Transport $Transport -Method GET -Uri $compileUri -TimeoutSeconds $TimeoutSeconds
                $restoredProjection = Get-CompileOptionsProjection -Value $restored -Context 'Success rollback readback'
                if ((Get-CanonicalJson $restoredProjection) -cne $originalJson) { throw 'Final rollback readback does not match the original known projection.' }
                $null = Assert-ActiveProjectIdentity -Transport $Transport -BaseUri $base -Identity $identity -TimeoutSeconds $TimeoutSeconds -Stage 'after success rollback'
            }
            catch { throw "Validated value could not be restored: $($_.Exception.Message)" }
        }
    }

    if ((Get-Sha256Hex -Path $identity.Project) -cne $identity.ProjectSha256) {
        throw 'Isolated .project container bytes changed during REST validation.'
    }

    return [pscustomobject]@{
        contractVersion = 1
        contractId = 'ctrlx-ple-compile-warning-limit-isolated-v1'
        projectFilePath = $identity.Project
        projectSha256 = $identity.ProjectSha256
        activeProjectName = $identity.ExpectedActiveProjectName
        compileOptionsPath = ($compile.Segments -join '/')
        originalValue = [string]$originalProjection.maxCompilerWarnings
        validatedValue = $DesiredValue
        retained = [bool]$KeepValidatedValue
        inMemoryProjectMutationUsed = $true
        projectContainerSaved = $false
        reopenOrDiscardRequired = $true
        safeNextAction = 'Close PLE without saving, then reopen or discard the isolated project copy.'
        onlineOperationsUsed = $false
    }
}

Export-ModuleMember -Function Invoke-CompileOptionsWarningLimitValidation
