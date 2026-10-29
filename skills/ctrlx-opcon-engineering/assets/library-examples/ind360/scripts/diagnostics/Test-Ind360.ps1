# Windows PowerShell 5.1; saved as UTF-8 with BOM for Chinese console text.
[CmdletBinding()]
param(
  [string]$TargetIp = '127.0.0.1',
  [ValidateRange(1, 65535)][int]$Port = 1026,
  [ValidateRange(100, 60000)][int]$TimeoutMs = 5000,
  [switch]$ReadOnly
)

function Invoke-Ind360Command {
  param(
    [string]$TargetIp,
    [int]$Port,
    [ValidateSet('SI', 'S', 'TA', 'I2', 'I3', 'I4', 'Z', 'T', 'TAC')][string]$Command,
    [int]$TimeoutMs = 5000
  )
  $result = [pscustomobject]@{
    Command = $Command; Status = 'TRANSPORT_ERROR'; Stage = 'CONNECT'
    Reply = ''; Message = ''; LocalEndpoint = ''; ElapsedMs = 0
    Sent = $false; OutcomeUnknown = $false
  }
  $client = New-Object System.Net.Sockets.TcpClient
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $frame = New-Object Text.StringBuilder
  try {
    $pending = $client.BeginConnect($TargetIp, $Port, $null, $null)
    try {
      if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        throw 'TCP 连接超时；检查目标地址、服务网口、网线及 Cisco 路由。'
      }
      $client.EndConnect($pending)
    } finally {
      $pending.AsyncWaitHandle.Close()
    }
    $result.LocalEndpoint = $client.Client.LocalEndPoint.ToString()
    $stream = $client.GetStream()
    $result.Stage = 'SEND'
    $stream.WriteTimeout = [Math]::Max(1, $TimeoutMs - [int]$clock.ElapsedMilliseconds)
    $bytes = [Text.Encoding]::ASCII.GetBytes($Command + "`r`n")
    # A partial write may already have reached the scale. Never replay a command.
    $result.Sent = $true
    $stream.Write($bytes, 0, $bytes.Length)
    $result.Stage = 'RECEIVE'
    while ($true) {
      $remaining = $TimeoutMs - [int]$clock.ElapsedMilliseconds
      if ($remaining -le 0) { throw '等待完整 CRLF 回复超时。' }
      $stream.ReadTimeout = $remaining
      $value = $stream.ReadByte()
      if ($value -lt 0) { throw '对端关闭连接，尚未收到完整 CRLF 回复。' }
      [void]$frame.Append([char]$value)
      if ($frame.Length -gt 4096) { throw '回复超过 4096 字节；可能连接了错误的服务。' }
      if ($frame.Length -ge 2 -and $frame[$frame.Length - 2] -eq "`r" -and $frame[$frame.Length - 1] -eq "`n") { break }
    }
    $result.Reply = $frame.ToString()
    $line = $result.Reply.Substring(0, $result.Reply.Length - 2)
    $result.Stage = 'PARSE'
    $result.Status = 'BAD_REPLY'
    $result.Message = '收到回复，但不是本命令预期的 MT-SICS 格式。'
    $responseName = if ($Command -eq 'SI') { 'S' } else { $Command }
    $number = '([-+]?\d+(?:\.\d+)?)\s+(\S+)'
    $weightPattern = switch ($Command) {
      'SI' { '^S\s+([SD])\s+' + $number + '$' }
      'S'  { '^S\s+(S)\s+' + $number + '$' }
      'T'  { '^T\s+(S)\s+' + $number + '$' }
      'TA' { '^TA\s+(A)\s+' + $number + '$' }
      default { '(?!)' }
    }
    if ($line -cmatch $weightPattern) {
      $result.Status = 'OK'
      $stateText = if ($Matches[1] -eq 'D') { '动态/未稳定' } elseif ($Matches[1] -eq 'S') { '稳定' } else { '有效' }
      $label = if ($Command -in @('T', 'TA')) { '皮重' } else { '净重' }
      $result.Message = '{0}: {1} {2} ({3})' -f $label, $Matches[2], $Matches[3], $stateText
    } elseif ($Command -in @('I2', 'I3', 'I4') -and $line -cmatch ('^' + $Command + '\s+A\s+"(.+)"$')) {
      $result.Status = 'OK'
      $result.Message = $Matches[1]
    } elseif ($Command -in @('Z', 'TAC') -and $line -cmatch ('^' + $Command + '\s+A$')) {
      $result.Status = 'OK'
      $result.Message = '仪表已明确确认命令成功。'
    } elseif ($line -cmatch '^(ES|ET|EL)$') {
      $result.Status = 'REJECTED'
      $result.Message = '仪表返回协议错误/不支持/逻辑错误；TCP 已通，请保留原始回复。'
    } elseif ($line -cmatch ('^' + $responseName + '\s+(I|L|\+|-)$')) {
      $result.Status = 'REJECTED'
      $result.Message = '仪表拒绝或暂不能执行（例如不稳定、超量程）；这不是 TCP 连接失败。'
    }
  } catch {
    $result.Reply = $frame.ToString()
    $failure = $_.Exception.GetBaseException()
    $result.Message = $failure.Message
    if ($failure -is [Net.Sockets.SocketException]) {
      $result.Message += ' [SocketError={0}, NativeError={1}]' -f $failure.SocketErrorCode, $failure.NativeErrorCode
    }
  } finally {
    $client.Close()
    $result.ElapsedMs = $clock.ElapsedMilliseconds
    $result.OutcomeUnknown = $result.Sent -and $Command -in @('Z', 'T', 'TAC') -and $result.Status -notin @('OK', 'REJECTED')
  }
  return $result
}

function Show-Ind360Result {
  param($Result)
  Write-Host ('[{0}] TX {1}<CR><LF>  [{2} / {3} / {4} ms]' -f (Get-Date -Format 'HH:mm:ss.fff'), $Result.Command, $Result.Status, $Result.Stage, $Result.ElapsedMs)
  if ($Result.LocalEndpoint) { Write-Host ('  本地连接: ' + $Result.LocalEndpoint) }
  $printable = [regex]::Replace($Result.Reply, '[^\x20-\x7e]', {
    param($m)
    if ($m.Value -eq "`r") { '<CR>' } elseif ($m.Value -eq "`n") { '<LF>' }
    else { '<0x{0:X2}>' -f [int][char]$m.Value }
  })
  Write-Host ('  RX ' + $(if ($printable) { $printable } else { '(无回复)' }))
  Write-Host ('  ' + $Result.Message)
  if (-not $Result.Sent) { Write-Host '  命令未发送。' }
  if ($Result.OutcomeUnknown) {
    Write-Host '  命令可能已经执行，但未获明确确认。未自动重发；本次会话禁止再次清零/去皮/清皮。' -ForegroundColor Yellow
    Write-Host '  请先在仪表上确认实际状态。仍可使用菜单读取重量。'
  }
}

# Dot-source only defines the wire client, allowing tests on a loopback simulator.
if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$logDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../data/reports/ind360'))
[void](New-Item -ItemType Directory -Path $logDirectory -Force)
$logPath = Join-Path $logDirectory ('IND360-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$exitCode = 0
Start-Transcript -LiteralPath $logPath | Out-Null
try {
  Write-Host 'IND360 独立通信诊断 v1 | MT-SICS TCP | Windows PowerShell'
  Write-Host ('日志: ' + $logPath)
  Write-Host '请先手动断开 Cisco，并关闭其他占用仪表 SICS 的测试软件。'
  Write-Host '测试期间不要同时在 PLC/HMI 发起称重命令；仪表只允许一个 SICS 连接。'
  Write-Host '本工具不更改 VPN、网卡、仪表配置或 PLC 程序。启动时只读；控制命令须在菜单单独确认。'
  if (-not $ReadOnly) {
    $inputIp = Read-Host ('仪表服务网口 IPv4 [回车使用 ' + $TargetIp + ']')
    if ($inputIp) { $TargetIp = $inputIp.Trim() }
    $inputPort = Read-Host ('PC Application 端口 [回车使用 ' + $Port + ']')
    if ($inputPort) { $Port = [int]$inputPort }
  }
  $parsedIp = $null
  if (-not [Net.IPAddress]::TryParse($TargetIp, [ref]$parsedIp) -or $parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw '请输入有效 IPv4 地址，例如 192.168.0.8。'
  }
  if ($Port -lt 1 -or $Port -gt 65535) { throw '端口必须为 1 到 65535。' }
  Write-Host ('目标: {0}:{1} | 单次超时: {2} ms | 每个命令新建连接，不重试' -f $TargetIp, $Port, $TimeoutMs)
  try {
    Write-Host (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
      Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize | Out-String)
    Write-Host '当前选路（只读取，不修改）：'
    Write-Host (Find-NetRoute -RemoteIPAddress $TargetIp -ErrorAction Stop |
      Format-List IPAddress, InterfaceAlias, InterfaceIndex, DestinationPrefix, NextHop, RouteMetric | Out-String)
  } catch { Write-Host ('无法读取网络详情，仍继续通信测试: ' + $_.Exception.Message) }

  Write-Host '开始只读检查：SI 即时净重、I2 型号、I3 固件、I4 序列号、TA 皮重。'
  $weightRead = $false
  foreach ($command in @('SI', 'I2', 'I3', 'I4', 'TA')) {
    $result = Invoke-Ind360Command -TargetIp $TargetIp -Port $Port -Command $command -TimeoutMs $TimeoutMs
    Show-Ind360Result $result
    if ($command -eq 'SI') { $weightRead = $result.Status -eq 'OK' }
    if ($result.Status -eq 'TRANSPORT_ERROR') { break }
    Start-Sleep -Milliseconds 150
  }
  if ($weightRead) {
    Write-Host '读重成功：电脑到仪表的 MT-SICS 可用。请比较面板读数；PLC 路径和库 Ready 仍需单独核对。' -ForegroundColor Green
  } else {
    Write-Host '本次未取得有效净重。日志中的 CONNECT / RECEIVE / PARSE 分别对应连接、接收和报文解析阶段。' -ForegroundColor Yellow
    Write-Host '核对服务网口 IP、PC Application 已启用、端口 1026，以及是否有其他 SICS 客户端占用。'
    $exitCode = 1
  }

  $controlsBlocked = $false
  while (-not $ReadOnly) {
    Write-Host "`n1=再做只读检查  2=读即时净重  3=读稳定净重  4=连续读10次"
    Write-Host '5=清零(Z)  6=去皮(T)  7=清除皮重(TAC)  0/回车=退出'
    $choice = Read-Host '选择'
    if (-not $choice -or $choice -eq '0') { break }
    $commands = switch ($choice) {
      '1' { 'SI'; 'I2'; 'I3'; 'I4'; 'TA' }
      '2' { 'SI' }
      '3' { 'S' }
      '4' { 1..10 | ForEach-Object { 'SI' } }
      '5' { 'Z' }
      '6' { 'T' }
      '7' { 'TAC' }
      default { Write-Host '请选择 0 到 7。' }
    }
    if ($choice -in @('5', '6', '7')) {
      if ($controlsBlocked) { Write-Host '上次控制结果不确定，已禁止再次控制。请先现场核实，退出后再决定是否重新测试。'; continue }
      $command = [string]$commands
      $confirmation = Read-Host ('将改变仪表零点或皮重。确认现场允许后，输入 ' + $command + ' 执行一次，其他输入取消')
      if ($confirmation -cne $command) { Write-Host '已取消，未发送。'; continue }
    }
    foreach ($command in $commands) {
      $result = Invoke-Ind360Command -TargetIp $TargetIp -Port $Port -Command $command -TimeoutMs $TimeoutMs
      Show-Ind360Result $result
      if ($result.OutcomeUnknown) { $controlsBlocked = $true }
      if ($result.Status -eq 'TRANSPORT_ERROR') { break }
      Start-Sleep -Milliseconds 500
    }
  }
} catch {
  Write-Host ('程序错误: ' + $_.Exception.Message) -ForegroundColor Red
  $exitCode = 1
} finally {
  Write-Host ('诊断结束，日志已保存: ' + $logPath)
  Stop-Transcript | Out-Null
}
if ($ReadOnly) { exit $exitCode }
