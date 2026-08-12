# =============================================================
# CollectPCInfo.ps1  -  工控机信息收集脚本
# 本脚本为【只读】脚本，不修改任何系统设置，放心运行。
# 用法：把本文件拷到工控机，双击配套的 Run_CollectPCInfo.bat
#       或右键本文件 -> "使用 PowerShell 运行"
# 运行完成后桌面会生成 PC_Info_Report.txt，把内容全部发给我即可。
# =============================================================
$ErrorActionPreference = 'SilentlyContinue'
$sb = New-Object System.Text.StringBuilder
function Add([string]$s='') { [void]$sb.AppendLine($s) }
function Section([string]$t) { Add ''; Add ("===== " + $t + " =====") }

Add "工控机信息收集报告（只读收集，无任何修改）"
Add ("收集时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add "请把本文件全部内容复制发回给我。"

# ---- 1. 整机/主板/BIOS ----
Section "整机与BIOS信息"
$cs = Get-CimInstance Win32_ComputerSystem
Add ("整机制造商  : " + $cs.Manufacturer)
Add ("整机型号    : " + $cs.Model)
Add ("整机序列号  : " + $cs.SerialNumber)
$bb = Get-CimInstance Win32_BaseBoard
Add ("主板制造商  : " + $bb.Manufacturer)
Add ("主板型号    : " + $bb.Product)
$bios = Get-CimInstance Win32_BIOS
Add ("BIOS厂商    : " + $bios.Manufacturer)
Add ("BIOS版本    : " + $bios.SMBIOSBIOSVersion)
try { Add ("BIOS日期    : " + $bios.ReleaseDate.ToString('yyyy-MM-dd')) } catch { Add ("BIOS日期    : " + $bios.ReleaseDate) }

# ---- 2. 固件类型与安全启动 ----
Section "启动方式（关键）"
$fw = "未知"
$bcd = cmd /c 'bcdedit /enum {current} 2>nul' | Out-String
if ($bcd -match 'winload\.efi') { $fw = "UEFI" }
elseif ($bcd -match 'winload\.exe') { $fw = "Legacy BIOS (传统)" }
if ($fw -eq "未知") {
    $bootPart = Get-Partition | Where-Object IsBoot | Select-Object -First 1
    if ($bootPart) {
        $bootDisk = Get-Disk -Number $bootPart.DiskNumber
        if ($bootDisk.PartitionStyle -eq 'GPT') { $fw = "UEFI (推断: 系统盘为GPT分区表, 基本可确定是UEFI)" }
        else { $fw = "Legacy BIOS (推断: 系统盘为MBR分区表)" }
    }
}
Add ("当前固件类型 : " + $fw)
try {
    $sbStatus = Confirm-SecureBootStatus
    Add ("安全启动Secure Boot : " + $(if ($sbStatus) { "已启用" } else { "未启用" }))
} catch { Add ("安全启动Secure Boot : 无法检测（不支持或需管理员）") }
if ($fw -match '^UEFI') {
    Add ''
    Add "-- UEFI启动项列表 --"
    $fwEntries = & bcdedit /enum firmware 2>$null | Out-String
    if ($fwEntries.Trim()) { Add $fwEntries } else { Add "(读取失败，可尝试用管理员身份运行后再看)" }
}

# ---- 3. CPU / 内存 ----
Section "CPU"
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Add ("型号     : " + $cpu.Name)
Add ("核心/线程: " + $cpu.NumberOfCores + "核 " + $cpu.NumberOfLogicalProcessors + "线程")
$archMap = @{0='x86(32位)';5='ARM';6='IA64';9='x64(64位)';12='ARM64'}
Add ("架构     : " + $archMap[[int]$cpu.Architecture])

Section "内存"
$ram = Get-CimInstance Win32_PhysicalMemory
Add ("总容量 : " + [math]::Round((($ram | Measure-Object Capacity -Sum).Sum)/1GB,1) + " GB")
Add ("内存条数量 : " + $ram.Count)

# ---- 4. 硬盘 ----
Section "硬盘"
Get-PhysicalDisk | ForEach-Object {
    Add ("[磁盘{0}] {1} | 接口:{2} | 介质:{3} | {4:N0}GB | 健康:{5}" -f $_.DeviceNumber, $_.FriendlyName, $_.BusType, $_.MediaType, ($_.Size/1GB), $_.HealthStatus)
}
Add ''
Add "-- 分区情况 --"
Get-Disk | ForEach-Object {
    $d = $_
    $d | Get-Partition | ForEach-Object {
        $p = $_
        $v = $p | Get-Volume
        Add ("磁盘{0} 分区{1} | 类型:{2} | 盘符:{3} | 文件系统:{4} | {5:N1}GB" -f $d.Number, $p.PartitionNumber, $p.Type, $(if($v.DriveLetter){$v.DriveLetter}else{'-'}), $(if($v.FileSystem){$v.FileSystem}else{'-'}), ($p.Size/1GB))
    }
}

# ---- 5. 磁盘控制器（决定Linux安装能否识别硬盘）----
Section "磁盘控制器"
$ctl = @()
$ctl += Get-CimInstance Win32_IDEController
$ctl += Get-CimInstance Win32_SCSIController
$names = $ctl | Select-Object -ExpandProperty Name -Unique
$names | ForEach-Object { Add $_ }
if (($names -join ' ') -match 'Volume Management|VMD') { Add "!! 注意: 检测到Intel VMD，Ubuntu安装可能看不到硬盘，BIOS里需关闭VMD或改AHCI" }
if (($names -join ' ') -match 'RST|Rapid Storage|RAID') { Add "!! 注意: 磁盘控制器为RST/RAID模式，Ubuntu安装若找不到硬盘需在BIOS改为AHCI" }

# ---- 6. U盘检查（启动盘）----
Section "U盘检查（请把Ubuntu启动U盘插在工控机上）"
$usbDisks = Get-Disk | Where-Object BusType -eq 'USB'
if (-not $usbDisks) { Add "!! 未检测到USB磁盘，请确认启动U盘已插入并被识别" }
foreach ($d in $usbDisks) {
    Add ("U盘[磁盘{0}]: {1} | {2:N1}GB | 分区表:{3}" -f $d.Number, $d.FriendlyName, ($d.Size/1GB), $d.PartitionStyle)
    foreach ($p in ($d | Get-Partition)) {
        $v = $p | Get-Volume
        Add ("  分区{0}: 盘符{1} | 文件系统{2} | {3:N1}GB" -f $p.PartitionNumber, $(if($v.DriveLetter){$v.DriveLetter}else{'(无盘符)'}), $v.FileSystem, ($p.Size/1GB))
        if ($v.DriveLetter) {
            $root = ($v.DriveLetter + ':\')
            $items = Get-ChildItem -LiteralPath $root -Force | Select-Object -First 40
            Add ("  根目录内容: " + ($items.Name -join ', '))
            $marks = @()
            if (Test-Path ($root + 'EFI\BOOT\BOOTX64.EFI'))   { $marks += "支持UEFI(x64)启动" }
            if (Test-Path ($root + 'EFI\BOOT\BOOTIA32.EFI'))  { $marks += "支持UEFI(32位)启动" }
            if (Test-Path ($root + 'EFI\BOOT\BOOTAA64.EFI'))  { $marks += "支持UEFI(ARM64)启动" }
            if ((Test-Path ($root + 'bootmgr')) -and (Test-Path ($root + 'boot\BCD'))) { $marks += "含Legacy启动文件(bootmgr/BCD)" }
            if (Test-Path ($root + 'casper'))   { $marks += "Ubuntu Live系统文件(casper)" }
            if (Test-Path ($root + 'ventoy'))   { $marks += "Ventoy启动盘" }
            if ((Test-Path ($root + 'isolinux')) -or (Test-Path ($root + 'syslinux'))) { $marks += "含Legacy Linux引导(isolinux/syslinux)" }
            if ($marks.Count) { Add ("  启动能力判断: " + ($marks -join '；')) } else { Add "  启动能力判断: 未识别出常见启动文件，请确认刻录是否成功" }
        }
    }
    Add ''
}

# ---- 7. 网卡 ----
Section "网卡"
Get-CimInstance Win32_NetworkAdapter | Where-Object PhysicalAdapter | Select-Object -ExpandProperty Name -Unique | ForEach-Object { Add $_ }

# ---- 8. 当前操作系统 ----
Section "当前操作系统"
$os = Get-CimInstance Win32_OperatingSystem
Add ($os.Caption + " | Build " + $os.BuildNumber)

Section "常见BIOS按键参考（具体以我后续给你的方案为准）"
Add "进BIOS: 一般 Del 或 F2（个别机型 Esc / F10 / F1）"
Add "启动菜单(一次性选U盘): 一般 F11 / F12 / F7 / Esc"

# ---- 保存报告 ----
$desktop = [Environment]::GetFolderPath('Desktop')
$path = Join-Path $desktop 'PC_Info_Report.txt'
try { $sb.ToString() | Out-File -FilePath $path -Encoding UTF8 -ErrorAction Stop }
catch { $path = Join-Path $env:TEMP 'PC_Info_Report.txt'; $sb.ToString() | Out-File -FilePath $path -Encoding UTF8 }
Write-Host ""
Write-Host ("报告已生成: " + $path) -ForegroundColor Green
Write-Host "请把该文件的全部内容复制发给我。"

