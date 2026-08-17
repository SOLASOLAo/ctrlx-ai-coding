$script:IOE_IPC_DIR = "$env:TEMP\ioe-ipc"
function Invoke-IoeScript([string]$code, [int]$timeoutMs = 120000) {
    $id = [guid]::NewGuid().ToString()
    $cmdDir = Join-Path $script:IOE_IPC_DIR "commands"
    $resDir = Join-Path $script:IOE_IPC_DIR "results"
    $scriptPath = Join-Path $cmdDir "$id.py"
    [System.IO.File]::WriteAllText($scriptPath, $code, (New-Object System.Text.UTF8Encoding $false))
    $cmdJson = '{"requestId":"' + $id + '","scriptPath":"' + $scriptPath.Replace('\','/') + '"}'
    [System.IO.File]::WriteAllText((Join-Path $cmdDir "$id.command.json"), $cmdJson)
    $resPath = Join-Path $resDir "$id.result.json"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if (Test-Path $resPath) {
            Start-Sleep -Milliseconds 150
            $json = [System.IO.File]::ReadAllText($resPath)
            return ($json | ConvertFrom-Json)
        }
        Start-Sleep -Milliseconds 200
    }
    return [pscustomobject]@{ success=$false; error="TIMEOUT after $timeoutMs ms"; output="" }
}