#requires -Version 5.1
Set-StrictMode -Version 2.0

$script:PODataRoot = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') 'data'))
$script:POStateRoot = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $null } else { Join-Path $env:LOCALAPPDATA 'PlatinumOptimizer' }
$script:POLogPath = if ($script:POStateRoot) { Join-Path $script:POStateRoot 'logs\optimizer.jsonl' } else { $null }
$script:POCimQueryLog = $null

function Get-POStateRoot {
    if ([string]::IsNullOrWhiteSpace($script:POStateRoot)) {
        throw 'LOCALAPPDATA is not available; a private local state directory cannot be created.'
    }
    return $script:POStateRoot
}

function Get-POJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $script:PODataRoot $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required data file was not found: $path"
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
}

function Get-POProfileCatalog {
    return (Get-POJsonFile -Name 'profiles.json').profiles
}

function Get-POTweakCatalog {
    return (Get-POJsonFile -Name 'tweaks.json').tweaks
}

function Get-POGameCatalog {
    return (Get-POJsonFile -Name 'games.json').games
}

function Get-POServiceCatalog {
    return (Get-POJsonFile -Name 'services.json')
}

function Test-POIsWindows {
    return ($env:OS -eq 'Windows_NT' -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}

function Test-POIsAdministrator {
    if (-not (Test-POIsWindows)) { return $false }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-POVendor {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Name,
        [AllowNull()][string]$Manufacturer,
        [AllowNull()][string]$DeviceId
    )
    $text = ('{0} {1} {2}' -f $Name, $Manufacturer, $DeviceId)
    if ($text -match '(?i)VEN_10DE|NVIDIA') { return 'NVIDIA' }
    if ($text -match '(?i)VEN_1002|Advanced Micro Devices|\bAMD\b|Radeon') { return 'AMD' }
    if ($text -match '(?i)VEN_8086|\bIntel\b') { return 'Intel' }
    return 'Unknown'
}

function ConvertTo-POBytesGB {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    try { return [math]::Round(([double]$Value / 1GB), 2) }
    catch { return $null }
}

function Get-POCimInstances {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ClassName,
        [string]$Namespace = 'root\cimv2'
    )
    try {
        $instances = @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
        if ($null -ne $script:POCimQueryLog) {
            [void]$script:POCimQueryLog.Add([pscustomobject]@{ Namespace = $Namespace; ClassName = $ClassName; Success = $true; Error = $null })
        }
        return $instances
    }
    catch {
        if ($null -ne $script:POCimQueryLog) {
            [void]$script:POCimQueryLog.Add([pscustomobject]@{ Namespace = $Namespace; ClassName = $ClassName; Success = $false; Error = $_.Exception.Message })
        }
        return @()
    }
}

function Add-POCollectionFailure {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Message)
    if ($null -ne $script:POCimQueryLog) {
        [void]$script:POCimQueryLog.Add([pscustomobject]@{ Namespace = 'Windows inventory'; ClassName = $Source; Success = $false; Error = $Message })
    }
}

function Get-POSystemSnapshot {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) {
        return [pscustomobject][ordered]@{
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
            IsWindows = $false
            OS = [pscustomobject]@{ Name = 'Unsupported host'; Family = 'Unsupported'; Version = 'Unknown'; Build = 'Unknown'; Edition = 'Unknown'; Architecture = 'Unknown'; Supported = $false; ServicingStatus = 'Unknown / not a Windows host' }
            Device = [pscustomobject]@{ FormFactor = 'Unknown'; IsLaptop = $null; PowerSource = 'Unknown' }
            CPU = $null; GPUs = @(); Memory = $null; Storage = @(); SystemVolume = $null; Motherboard = $null; BIOS = $null; Monitors = @(); CollectionWarnings = @()
        }
    }

    $script:POCimQueryLog = New-Object System.Collections.ArrayList
    $osRows = @(Get-POCimInstances -ClassName Win32_OperatingSystem)
    $computerRows = @(Get-POCimInstances -ClassName Win32_ComputerSystem)
    $os = if ($osRows.Count -gt 0) { $osRows[0] } else { $null }
    $computer = if ($computerRows.Count -gt 0) { $computerRows[0] } else { $null }
    $bios = @((Get-POCimInstances -ClassName Win32_BIOS) | Select-Object -First 1)
    $baseboard = @((Get-POCimInstances -ClassName Win32_BaseBoard) | Select-Object -First 1)
    $processors = @(Get-POCimInstances -ClassName Win32_Processor)
    $physicalMemory = @(Get-POCimInstances -ClassName Win32_PhysicalMemory)
    $controllers = @(Get-POCimInstances -ClassName Win32_VideoController)
    $batteries = @(Get-POCimInstances -ClassName Win32_Battery)
    $enclosures = @(Get-POCimInstances -ClassName Win32_SystemEnclosure)

    $osCaption = if ($os) { [string]$os.Caption } else { 'Unknown Windows edition' }
    $family = 'Unsupported'
    if ($osCaption -match '(?i)Windows\s+11') { $family = 'Windows 11' }
    elseif ($osCaption -match '(?i)Windows\s+10') { $family = 'Windows 10' }
    $osArchitecture = if ($os) { [string]$os.OSArchitecture } else { 'Unknown' }
    $osVersion = if ($os) { [string]$os.Version } else { 'Unknown' }
    $osBuild = if ($os) { [string]$os.BuildNumber } else { 'Unknown' }
    $osObject = [pscustomobject][ordered]@{
        Name = $osCaption
        Family = $family
        Version = $osVersion
        Build = $osBuild
        Edition = $osCaption
        Architecture = $osArchitecture
        LastBootUpTime = if ($os -and $os.LastBootUpTime) { ([datetime]$os.LastBootUpTime).ToString('o') } else { $null }
        Supported = ($family -in @('Windows 10', 'Windows 11'))
        ServicingStatus = 'Unknown; Windows Update, ESU, LTSC, and organizational support status are not inspected'
    }

    $cpuArchitecture = 'Unknown'
    if ($processors.Count -gt 0) {
        switch ([int]$processors[0].Architecture) {
            0 { $cpuArchitecture = 'x86' }
            5 { $cpuArchitecture = 'ARM' }
            6 { $cpuArchitecture = 'Itanium' }
            9 { $cpuArchitecture = 'x64' }
            12 { $cpuArchitecture = 'ARM64' }
            default { $cpuArchitecture = "SMBIOS/WMI code $($processors[0].Architecture)" }
        }
    }
    $physicalCores = 0; $logicalCores = 0
    foreach ($processor in $processors) {
        if ($processor.NumberOfCores) { $physicalCores += [int]$processor.NumberOfCores }
        if ($processor.NumberOfLogicalProcessors) { $logicalCores += [int]$processor.NumberOfLogicalProcessors }
    }
    $numaRows = @(Get-POCimInstances -ClassName Win32_NumaNode)
    $numaNodeCount = if ($numaRows.Count -gt 0) { $numaRows.Count } else { $null }
    $cpuVendor = if ($processors.Count -gt 0) { Get-POVendor -Name $processors[0].Name -Manufacturer $processors[0].Manufacturer } else { 'Unknown' }
    $cpu = [pscustomobject][ordered]@{
        Manufacturer = if ($processors.Count -gt 0) { [string]$processors[0].Manufacturer } else { 'Unknown' }
        Vendor = $cpuVendor
        Model = if ($processors.Count -gt 0) { [string]$processors[0].Name } else { 'Unknown' }
        Architecture = $cpuArchitecture
        PhysicalCores = if ($physicalCores -gt 0) { $physicalCores } else { $null }
        LogicalProcessors = if ($logicalCores -gt 0) { $logicalCores } else { $null }
        MaximumClockReportedMHz = if ($processors.Count -gt 0) { [int]$processors[0].MaxClockSpeed } else { $null }
        CurrentClockReportedMHz = if ($processors.Count -gt 0) { [int]$processors[0].CurrentClockSpeed } else { $null }
        L2CacheKB = if ($processors.Count -gt 0) { [int]$processors[0].L2CacheSize } else { $null }
        L3CacheKB = if ($processors.Count -gt 0) { [int]$processors[0].L3CacheSize } else { $null }
        VirtualizationFirmwareEnabled = if ($processors.Count -gt 0) { $processors[0].VirtualizationFirmwareEnabled } else { $null }
        Generation = 'Not inferred from marketing-name text'
        PerformanceEfficiencyCoreTopology = 'Not exposed reliably by the generic WMI query'
        NumaNodes = $numaNodeCount
    }

    $gpuList = @()
    foreach ($controller in $controllers) {
        $adapterRam = $null
        try { if ($controller.AdapterRAM) { $adapterRam = [double]$controller.AdapterRAM } } catch { }
        $resolution = $null
        if ($controller.CurrentHorizontalResolution -and $controller.CurrentVerticalResolution) {
            $resolution = '{0} x {1}' -f $controller.CurrentHorizontalResolution, $controller.CurrentVerticalResolution
        }
        $gpuList += [pscustomobject][ordered]@{
            Name = [string]$controller.Name
            Vendor = Get-POVendor -Name $controller.Name -Manufacturer $controller.AdapterCompatibility -DeviceId $controller.PNPDeviceID
            DriverVersion = [string]$controller.DriverVersion
            ReportedAdapterRAMBytes = $adapterRam
            ReportedVRAMGB = if ($adapterRam) { ConvertTo-POBytesGB $adapterRam } else { $null }
            SharedMemoryGB = $null
            ResolutionReportedByAdapter = $resolution
            RefreshRateReportedByAdapterHz = if ($controller.CurrentRefreshRate) { [int]$controller.CurrentRefreshRate } else { $null }
            PnpDeviceId = [string]$controller.PNPDeviceID
        }
    }

    $totalMemory = if ($computer -and $computer.TotalPhysicalMemory) { [double]$computer.TotalPhysicalMemory } else { $null }
    $memoryModules = @()
    foreach ($module in $physicalMemory) {
        $memoryModules += [pscustomobject][ordered]@{
            CapacityGB = ConvertTo-POBytesGB $module.Capacity
            SpeedMHz = if ($module.ConfiguredClockSpeed) { [int]$module.ConfiguredClockSpeed } elseif ($module.Speed) { [int]$module.Speed } else { $null }
            MemoryTypeCode = if ($module.SMBIOSMemoryType) { [int]$module.SMBIOSMemoryType } elseif ($module.MemoryType) { [int]$module.MemoryType } else { $null }
            Manufacturer = [string]$module.Manufacturer
            DeviceLocator = [string]$module.DeviceLocator
        }
    }
    $freeMemoryGB = $null
    if ($os -and $null -ne $os.FreePhysicalMemory) { $freeMemoryGB = [math]::Round(([double]$os.FreePhysicalMemory / 1MB), 2) }
    $memory = [pscustomobject][ordered]@{
        TotalGB = if ($totalMemory) { ConvertTo-POBytesGB $totalMemory } else { $null }
        AvailableGB = $freeMemoryGB
        Modules = $memoryModules
        Channels = 'Unknown; module count is not a reliable channel report'
        Compression = 'Not exposed by this generic snapshot'
        CommitAndPageFile = 'Available in the Diagnostics sample when Windows counters respond'
    }

    $diskList = @()
    foreach ($disk in (Get-POCimInstances -ClassName Win32_DiskDrive)) {
        $diskList += [pscustomobject][ordered]@{
            Model = [string]$disk.Model
            Interface = [string]$disk.InterfaceType
            MediaType = [string]$disk.MediaType
            SizeGB = ConvertTo-POBytesGB $disk.Size
            StatusReportedByWMI = [string]$disk.Status
            BusTypeAndHealth = 'Not inferred from model text; see optional PhysicalDisk data when available'
        }
    }
    try {
        if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
            foreach ($physicalDisk in @(Get-PhysicalDisk -ErrorAction Stop)) {
                $diskList += [pscustomobject][ordered]@{
                    Model = [string]$physicalDisk.FriendlyName
                    Interface = [string]$physicalDisk.BusType
                    MediaType = [string]$physicalDisk.MediaType
                    SizeGB = ConvertTo-POBytesGB $physicalDisk.Size
                    StatusReportedByWMI = [string]$physicalDisk.HealthStatus
                    BusTypeAndHealth = 'Storage module PhysicalDisk inventory'
                }
            }
        }
    }
    catch { Add-POCollectionFailure -Source 'Get-PhysicalDisk' -Message $_.Exception.Message }
    $systemVolume = $null
    if ($env:SystemDrive) {
        try {
            $volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
            if ($volume) {
                $freePercent = $null
                if ($volume.Size) { $freePercent = [math]::Round((100.0 * [double]$volume.FreeSpace / [double]$volume.Size), 1) }
                $systemVolume = [pscustomobject][ordered]@{
                    Drive = [string]$volume.DeviceID
                    FileSystem = [string]$volume.FileSystem
                    SizeGB = ConvertTo-POBytesGB $volume.Size
                    FreeGB = ConvertTo-POBytesGB $volume.FreeSpace
                    FreePercent = $freePercent
                    Warning = if ($null -ne $freePercent -and $freePercent -lt 10) { 'Less than 10% free space' } else { $null }
                }
            }
            else { Add-POCollectionFailure -Source 'Win32_LogicalDisk (system volume)' -Message 'No matching system-volume row was returned.' }
        }
        catch { Add-POCollectionFailure -Source 'Win32_LogicalDisk (system volume)' -Message $_.Exception.Message }
    }
    else { Add-POCollectionFailure -Source 'SystemDrive' -Message 'The Windows system drive variable is not available.' }

    $board = if ($baseboard.Count -gt 0) { $baseboard[0] } else { $null }
    $biosInfo = if ($bios.Count -gt 0) { $bios[0] } else { $null }
    $motherboard = [pscustomobject][ordered]@{
        Manufacturer = if ($board) { [string]$board.Manufacturer } else { 'Unknown' }
        Model = if ($board) { [string]$board.Product } else { 'Unknown' }
        Version = if ($board) { [string]$board.Version } else { 'Unknown' }
    }
    $biosObject = [pscustomobject][ordered]@{
        Manufacturer = if ($biosInfo) { [string]$biosInfo.Manufacturer } else { 'Unknown' }
        Version = if ($biosInfo) { (@($biosInfo.SMBIOSBIOSVersion) -join ' / ') } else { 'Unknown' }
        ReleaseDate = if ($biosInfo -and $biosInfo.ReleaseDate) { ([datetime]$biosInfo.ReleaseDate).ToString('yyyy-MM-dd') } else { 'Unknown' }
        AutomaticUpdate = $false
    }

    $monitorList = @()
    foreach ($monitor in (Get-POCimInstances -ClassName WmiMonitorID -Namespace 'root\wmi')) {
        $manufacturer = 'Unknown'; $friendly = 'Unknown'
        try {
            if ($monitor.ManufacturerName) { $manufacturer = [Text.Encoding]::ASCII.GetString([byte[]]@($monitor.ManufacturerName | Where-Object { $_ -ne 0 })) }
            if ($monitor.UserFriendlyName) { $friendly = [Text.Encoding]::ASCII.GetString([byte[]]@($monitor.UserFriendlyName | Where-Object { $_ -ne 0 })) }
        }
        catch { }
        $monitorList += [pscustomobject][ordered]@{
            Manufacturer = $manufacturer.Trim([char]0)
            Model = $friendly.Trim([char]0)
            Active = [bool]$monitor.Active
            Resolution = 'Not reliably available per monitor from this generic query'
            RefreshRateHz = 'Unknown'
            HDR = 'Unknown'
            ColorDepth = 'Unknown'
        }
    }
    if ($monitorList.Count -eq 0) {
        $monitorList = @([pscustomobject]@{ Manufacturer = 'Unknown'; Model = 'No active monitor identity reported'; Active = $null; Resolution = 'See adapter-reported mode'; RefreshRateHz = 'Unknown'; HDR = 'Unknown'; ColorDepth = 'Unknown' })
    }

    $chassisTypes = @()
    foreach ($enclosure in $enclosures) { $chassisTypes += @($enclosure.ChassisTypes) }
    $laptopChassis = @($chassisTypes | Where-Object { [int]$_ -in @(8, 9, 10, 14, 30, 31, 32) }).Count -gt 0
    $desktopChassis = @($chassisTypes | Where-Object { [int]$_ -in @(3, 4, 5, 6, 7, 13, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 33, 34, 35, 36) }).Count -gt 0
    $isLaptop = $null
    if ($batteries.Count -gt 0 -or $laptopChassis) { $isLaptop = $true }
    elseif ($desktopChassis) { $isLaptop = $false }
    $powerSource = if ($isLaptop -eq $false) { 'AC / not portable' } else { 'Unknown' }
    if ($isLaptop -eq $true) {
        foreach ($batteryStatus in (Get-POCimInstances -ClassName BatteryStatus -Namespace 'root\wmi')) {
            if ($null -ne $batteryStatus.PowerOnline) {
                if ([bool]$batteryStatus.PowerOnline) { $powerSource = 'AC' }
                else { $powerSource = 'Battery' }
                break
            }
        }
        if ($powerSource -eq 'Unknown' -and $batteries.Count -gt 0) {
            $statusCode = [int]$batteries[0].BatteryStatus
            if ($statusCode -eq 1) { $powerSource = 'Battery' }
            elseif ($statusCode -in @(2, 3, 6, 7, 8, 9, 10, 11)) { $powerSource = 'AC' }
        }
    }
    $device = [pscustomobject][ordered]@{
        Manufacturer = if ($computer) { [string]$computer.Manufacturer } else { 'Unknown' }
        Model = if ($computer) { [string]$computer.Model } else { 'Unknown' }
        FormFactor = if ($isLaptop -eq $true) { 'Laptop / portable' } elseif ($isLaptop -eq $false) { 'Desktop / non-portable chassis' } else { 'Unknown; portable status could not be determined' }
        IsLaptop = $isLaptop
        PowerSource = $powerSource
        ChassisTypes = @($chassisTypes)
    }
    $collectionWarnings = @()
    if ($null -ne $script:POCimQueryLog) { $collectionWarnings = @($script:POCimQueryLog | Where-Object { -not $_.Success }) }
    $script:POCimQueryLog = $null

    return [pscustomobject][ordered]@{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        IsWindows = $true
        OS = $osObject
        Device = $device
        CPU = $cpu
        GPUs = $gpuList
        Memory = $memory
        Storage = $diskList
        SystemVolume = $systemVolume
        Motherboard = $motherboard
        BIOS = $biosObject
        Monitors = $monitorList
        CollectionWarnings = $collectionWarnings
    }
}

function Get-PORegValueState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('CurrentUser', 'LocalMachine', 'ClassesRoot', 'Users', 'CurrentConfig')][string]$Hive,
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][string]$ValueName
    )
    $base = $null; $key = $null
    $exists = $false; $kind = $null; $data = $null; $readable = $true; $readError = $null
    try {
        $hiveEnum = [Microsoft.Win32.RegistryHive][Enum]::Parse([Microsoft.Win32.RegistryHive], $Hive)
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveEnum, [Microsoft.Win32.RegistryView]::Default)
        $key = $base.OpenSubKey($SubKey, $false)
        if ($key -and @($key.GetValueNames()) -contains $ValueName) {
            $exists = $true
            $kind = [string]$key.GetValueKind($ValueName)
            $raw = $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($kind -in @('Binary', 'None')) { $data = [Convert]::ToBase64String([byte[]]$raw) }
            elseif ($kind -eq 'MultiString') { $data = [string[]]$raw }
            else { $data = $raw }
        }
    }
    catch { $readable = $false; $readError = $_.Exception.Message }
    finally {
        if ($key) { $key.Dispose() }
        if ($base) { $base.Dispose() }
    }
    return [pscustomobject][ordered]@{ Hive = $Hive; SubKey = $SubKey; ValueName = $ValueName; Exists = $exists; Kind = $kind; Data = $data; Readable = $readable; ReadError = $readError }
}

function Set-PORegValueState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$State)
    $base = $null; $key = $null
    if ($State.PSObject.Properties['Readable'] -and -not [bool]$State.Readable) { throw "Refusing to restore unreadable registry state: $($State.ReadError)" }
    try {
        $hiveEnum = [Microsoft.Win32.RegistryHive][Enum]::Parse([Microsoft.Win32.RegistryHive], [string]$State.Hive)
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveEnum, [Microsoft.Win32.RegistryView]::Default)
        if (-not $State.Exists) {
            $key = $base.OpenSubKey([string]$State.SubKey, $true)
            if ($key -and @($key.GetValueNames()) -contains [string]$State.ValueName) {
                $key.DeleteValue([string]$State.ValueName, $false)
            }
            return
        }
        $key = $base.CreateSubKey([string]$State.SubKey, $true)
        if (-not $key) { throw "Could not open registry key $($State.SubKey) for write." }
        $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$State.Kind)
        $data = $State.Data
        switch ([string]$State.Kind) {
            { $_ -in @('Binary', 'None') } { $data = [Convert]::FromBase64String([string]$State.Data) }
            'MultiString' { $data = [string[]]@($State.Data) }
            'DWord' { $data = [int32]$State.Data }
            'QWord' { $data = [int64]$State.Data }
            'String' { $data = [string]$State.Data }
            'ExpandString' { $data = [string]$State.Data }
            default { throw "Unsupported registry value kind '$($State.Kind)'." }
        }
        $key.SetValue([string]$State.ValueName, $data, $kind)
    }
    finally {
        if ($key) { $key.Dispose() }
        if ($base) { $base.Dispose() }
    }
}

function Get-POStatusSnapshot {
    [CmdletBinding()]
    param()
    $defenderState = 'Unknown'
    try {
        if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            if ($mp.AntivirusEnabled -and $mp.RealTimeProtectionEnabled) { $defenderState = 'On' }
            elseif ($mp.AntivirusEnabled) { $defenderState = 'Partially enabled (real-time protection off)' }
            else { $defenderState = 'Off or managed by another provider' }
        }
    }
    catch { $defenderState = 'Unknown (status query unavailable)' }
    $firewall = 'Unknown'
    try {
        if (Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
            $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
            if ($profiles.Count -gt 0 -and @($profiles | Where-Object { -not $_.Enabled }).Count -eq 0) { $firewall = 'On for all reported profiles' }
            elseif ($profiles.Count -gt 0) { $firewall = 'Off for one or more profiles' }
        }
    }
    catch { }
    $memoryIntegrity = 'Unknown'
    try {
        $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ($null -ne $deviceGuard) {
            if (@($deviceGuard.SecurityServicesRunning) -contains 2) { $memoryIntegrity = 'On (reported by DeviceGuard)' }
            else { $memoryIntegrity = 'Not reported as running' }
        }
    }
    catch { }
    $secureBoot = 'Unknown'
    try { $secureBoot = [string](Confirm-SecureBootUEFI -ErrorAction Stop) }
    catch { $secureBoot = 'Unknown (UEFI query unavailable or unsupported)' }
    $tpm = 'Unknown'
    try {
        if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
            $tpmInfo = Get-Tpm -ErrorAction Stop
            $tpm = if ($tpmInfo.TpmPresent) { 'Present' } else { 'Not present' }
        }
    }
    catch { }
    $uac = Get-PORegValueState -Hive LocalMachine -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ValueName 'EnableLUA'
    $uacText = 'Unknown'
    if ($uac.Exists) { $uacText = if ([int]$uac.Data -eq 1) { 'Enabled' } else { 'Disabled' } }
    return [pscustomobject][ordered]@{
        Defender = $defenderState
        Firewall = $firewall
        MemoryIntegrity = $memoryIntegrity
        SecureBoot = $secureBoot
        TPM = $tpm
        UAC = $uacText
        DefaultPolicy = 'KEEP SECURITY; no security setting is changed by this application.'
    }
}

function Get-POPowerPlans {
    [CmdletBinding()]
    param()
    $plans = @()
    if (-not (Test-POIsWindows)) { return @() }
    $activeGuid = Get-POActivePowerPlanGuid
    try {
        $raw = @(& powercfg.exe /list 2>&1)
        foreach ($line in $raw) {
            $match = [regex]::Match([string]$line, '(?i)(?<guid>\{?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}?)\s*\((?<name>[^)]+)\)')
            if ($match.Success) {
                $guid = $match.Groups['guid'].Value.Trim('{}')
                $plans += [pscustomobject][ordered]@{ Guid = $guid; Name = $match.Groups['name'].Value.Trim(); IsActive = ($guid -eq $activeGuid) }
            }
        }
    }
    catch { }
    return @($plans | Sort-Object -Property Name, Guid)
}

function Get-POActivePowerPlanGuid {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) { return $null }
    try {
        $raw = @(& powercfg.exe /getactivescheme 2>&1) -join "`n"
        $match = [regex]::Match($raw, '(?i)\{?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\}?')
        if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    }
    catch { }
    return $null
}

function Get-POBuiltinPlanGuid {
    param([Parameter(Mandatory = $true)][ValidateSet('balanced', 'high-performance', 'power-saver', 'ultimate-performance')][string]$Plan)
    $known = @{
        'balanced' = '381b4222-f694-41f0-9685-ff5bb260df2e'
        'high-performance' = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        'power-saver' = 'a1841308-3541-4fab-bc81-f71556f20b4a'
        'ultimate-performance' = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    }
    return $known[$Plan]
}

function Get-POProfiles {
    [CmdletBinding()]
    param()
    return @(Get-POProfileCatalog)
}

function Get-POTweakCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Tweak,
        [Parameter(Mandatory = $true)][psobject]$SystemSnapshot,
        [bool]$Administrator = $false
    )
    $reasons = @()
    if (-not $SystemSnapshot.OS.Supported) { $reasons += 'Unsupported or unidentified Windows edition/build.' }
    if (@($Tweak.supportedVersions).Count -gt 0 -and $SystemSnapshot.OS.Family -notin @($Tweak.supportedVersions)) {
        $reasons += "Not supported on $($SystemSnapshot.OS.Family)."
    }
    if ($Tweak.requiresAdmin -and -not $Administrator) { $reasons += 'Administrator permission is required for this action.' }
    if ($Tweak.id -eq 'power-plan' -and $SystemSnapshot.Device.IsLaptop -eq $true -and $SystemSnapshot.Device.PowerSource -eq 'Battery') {
        $reasons += 'A performance-plan change is blocked while on battery.'
    }
    elseif ($Tweak.id -eq 'power-plan' -and ($null -eq $SystemSnapshot.Device.IsLaptop -or ($SystemSnapshot.Device.IsLaptop -eq $true -and $SystemSnapshot.Device.PowerSource -ne 'AC'))) {
        $reasons += 'Portable status or AC power is unknown; the power-plan change is blocked until detected.'
    }
    return [pscustomobject][ordered]@{
        TweakId = [string]$Tweak.id
        Compatible = ($reasons.Count -eq 0)
        Status = if ($reasons.Count -eq 0) { 'SUPPORTED' } else { 'SKIPPED' }
        Reasons = $reasons
    }
}

function New-POProfilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [Parameter(Mandatory = $true)][psobject]$SystemSnapshot,
        [object[]]$PowerPlans = @(),
        [AllowNull()][string]$ActivePlanGuid
    )
    $profile = @(Get-POProfileCatalog | Where-Object { $_.id -eq $ProfileId } | Select-Object -First 1)
    if ($profile.Count -eq 0) { throw "Unknown profile '$ProfileId'." }
    $profile = $profile[0]
    if ([string]::IsNullOrWhiteSpace($ActivePlanGuid)) { $ActivePlanGuid = Get-POActivePowerPlanGuid }
    $planTarget = [string]$profile.powerTarget
    $targetGuid = $null; $targetLabel = 'Keep current plan'; $warnings = @(); $skipped = @()
    if (-not $SystemSnapshot.OS.Supported) {
        $skipped += 'Windows family is not identified as Windows 10 or Windows 11; the active-plan change is blocked.'
        $planTarget = 'keep'
    }
    if ($planTarget -in @('high-performance', 'ultimate-or-high-performance')) {
        if ($null -eq $SystemSnapshot.Device.IsLaptop) {
            $skipped += 'Performance plan skipped because portable/non-portable form factor could not be confirmed.'
            $planTarget = 'keep'
        }
        elseif ($SystemSnapshot.Device.IsLaptop -and $SystemSnapshot.Device.PowerSource -eq 'Battery') {
            $skipped += 'Performance plan skipped because the portable device is on battery.'
            $planTarget = 'keep'
        }
        elseif ($SystemSnapshot.Device.IsLaptop -and $SystemSnapshot.Device.PowerSource -ne 'AC') {
            $skipped += 'Performance plan skipped because AC power could not be positively confirmed.'
            $planTarget = 'keep'
        }
        elseif ($SystemSnapshot.Device.IsLaptop) {
            $warnings += 'Portable device is on AC. A performance plan can raise power use, fan noise, and temperatures.'
        }
        elseif ($profileId -ne 'max-performance') {
            $warnings += 'A performance plan can raise power use, heat, or fan noise; the effect depends on the hardware and workload.'
        }
    }

    switch ($planTarget) {
        'balanced' { $targetGuid = Get-POBuiltinPlanGuid 'balanced'; $targetLabel = 'Balanced' }
        'high-performance' { $targetGuid = Get-POBuiltinPlanGuid 'high-performance'; $targetLabel = 'High Performance' }
        'power-saver-or-balanced' {
            if ($SystemSnapshot.Device.IsLaptop -ne $true) {
                $skipped += 'Laptop Battery profile is intended for positively identified portable devices; no plan change was selected.'
                $targetLabel = 'Keep current plan'
            }
            else {
                $targetGuid = Get-POBuiltinPlanGuid 'power-saver'; $targetLabel = 'Power Saver'
                if (@($PowerPlans | Where-Object { $_.Guid -eq $targetGuid }).Count -eq 0) {
                    $targetGuid = Get-POBuiltinPlanGuid 'balanced'; $targetLabel = 'Balanced (Power Saver is not installed)'
                }
            }
        }
        'ultimate-or-high-performance' {
            $ultimateGuid = Get-POBuiltinPlanGuid 'ultimate-performance'
            $highGuid = Get-POBuiltinPlanGuid 'high-performance'
            if (@($PowerPlans | Where-Object { $_.Guid -eq $ultimateGuid }).Count -gt 0) { $targetGuid = $ultimateGuid; $targetLabel = 'Ultimate Performance' }
            else { $targetGuid = $highGuid; $targetLabel = 'High Performance (Ultimate Performance not installed)' }
            $warnings += 'Maximum Performance can increase heat, fan noise, and energy use. Stop if temperatures are already high; no thermal sensor is assumed available.'
        }
        'keep' { $targetGuid = $null; $targetLabel = 'Keep current plan' }
        default { $targetGuid = $null; $targetLabel = 'Keep current plan' }
    }

    if ($targetGuid -and @($PowerPlans | Where-Object { $_.Guid -eq $targetGuid }).Count -eq 0) {
        $skipped += "The built-in $targetLabel plan is not currently installed; the optimizer will not create or modify a plan."
        $targetGuid = $null
        $targetLabel = 'Keep current plan'
    }
    if ($targetGuid -and [string]::IsNullOrWhiteSpace($ActivePlanGuid)) {
        $skipped += 'The current active power plan could not be read; a verified rollback target is unavailable.'
        $targetGuid = $null
        $targetLabel = 'Keep current plan'
    }
    $alreadyActive = ($targetGuid -and $ActivePlanGuid -and ($targetGuid -eq $ActivePlanGuid))
    $change = $null
    if ($targetGuid -and -not $alreadyActive) {
        $change = [pscustomobject][ordered]@{
            TweakId = 'power-plan'
            Name = 'Select existing Windows power plan'
            Category = 'Power'
            Risk = [string]$profile.riskCeiling
            FromGuid = $ActivePlanGuid
            ToGuid = $targetGuid
            Target = $targetLabel
            RequiresReboot = $false
            RequiresAdmin = $true
            Status = if ($SystemSnapshot.OS.Supported) { 'READY' } else { 'SKIPPED' }
        }
    }
    elseif ($alreadyActive) {
        $skipped += "The requested $targetLabel plan is already active."
    }

    $recommendations = @()
    foreach ($id in @($profile.manualRecommendations)) {
        $item = @(Get-POTweakCatalog | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        if ($item.Count -gt 0) { $recommendations += [pscustomobject]@{ Id = $id; Name = $item[0].name; Description = $item[0].description; Action = 'Review in Windows Settings' } }
    }
    return [pscustomobject][ordered]@{
        ProfileId = [string]$profile.id
        ProfileName = [string]$profile.name
        Description = [string]$profile.description
        CurrentPowerPlanGuid = $ActivePlanGuid
        CurrentPowerPlanName = [string](@($PowerPlans | Where-Object { $_.Guid -eq $ActivePlanGuid } | Select-Object -First 1).Name)
        TargetPowerPlanName = $targetLabel
        Change = $change
        Recommendations = $recommendations
        Warnings = $warnings
        Skipped = $skipped
        RequiresHighRiskConfirmation = [bool]$profile.requiresExplicitHighRiskConfirmation
        RequiresAdmin = [bool]($null -ne $change)
        RequiresReboot = $false
        EstimatedImpact = 'Not estimated. Power-plan behavior varies by hardware, firmware, cooling, workload, and Windows build; FPS is not measured.'
        SystemSnapshotTime = [string]$SystemSnapshot.CapturedAtUtc
    }
}

function Get-POCurrentAdapterDns {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$InterfaceIndex)
    $adapter = $null; $ipInterface = $null; $dns4 = @(); $dns6 = @()
    $dns4Readable = $false; $dns6Readable = $false
    $dns4Error = 'The IPv4 DNS server query returned no interface record.'; $dns6Error = 'The IPv6 DNS server query returned no interface record.'
    $dnsConfigState = 'UNKNOWN'; $dnsConfigDetail = 'The per-interface DNS configuration mode could not be read.'
    try { $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Stop } catch { }
    try { $ipInterface = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop } catch { }
    try {
        $dns4Row = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $dns4Row) {
            $dns4 = @($dns4Row.ServerAddresses | ForEach-Object { [string]$_ })
            $dns4Readable = $true; $dns4Error = $null
        }
    }
    catch { $dns4Error = $_.Exception.Message }
    try {
        $dns6Row = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv6 -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $dns6Row) {
            $dns6 = @($dns6Row.ServerAddresses | ForEach-Object { [string]$_ })
            $dns6Readable = $true; $dns6Error = $null
        }
    }
    catch { $dns6Error = $_.Exception.Message }
    if ($adapter -and $adapter.InterfaceGuid) {
        try {
            $policyState = Get-PORegValueState -Hive LocalMachine -SubKey 'SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -ValueName 'NameServer'
            if (-not $policyState.Readable) { $dnsConfigDetail = "DNS policy state read failed: $($policyState.ReadError)" }
            elseif ($policyState.Exists -and -not [string]::IsNullOrWhiteSpace([string]$policyState.Data)) {
                $dnsConfigState = 'POLICY-MANAGED'
                $dnsConfigDetail = 'A machine DNS client policy supplies NameServer; automatic change and rollback are blocked.'
            }
            else {
                $interfaceGuid = ([guid]$adapter.InterfaceGuid).ToString('B')
                $interfaceKey = "SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$interfaceGuid"
                $nameServerState = Get-PORegValueState -Hive LocalMachine -SubKey $interfaceKey -ValueName 'NameServer'
                if ($nameServerState.Readable) {
                    if (-not $nameServerState.Exists -or [string]::IsNullOrWhiteSpace([string]$nameServerState.Data)) {
                        $dnsConfigState = 'AUTOMATIC/DHCP'
                        $dnsConfigDetail = 'No per-interface static IPv4 DNS or machine DNS policy override was found; DHCP must also be enabled before changes.'
                    }
                    else {
                        $dnsConfigState = 'STATIC OVERRIDE PRESENT'
                        $dnsConfigDetail = 'A per-interface IPv4 DNS override is present; automatic DNS change and rollback are blocked.'
                    }
                }
                else { $dnsConfigDetail = "DNS mode registry read failed: $($nameServerState.ReadError)" }
            }
        }
        catch { $dnsConfigDetail = "DNS mode query failed: $($_.Exception.Message)" }
    }
    return [pscustomobject][ordered]@{
        InterfaceIndex = $InterfaceIndex
        InterfaceGuid = if ($adapter) { [string]$adapter.InterfaceGuid } else { $null }
        InterfaceAlias = if ($adapter) { [string]$adapter.Name } else { 'Unknown' }
        InterfaceDescription = if ($adapter) { [string]$adapter.InterfaceDescription } else { 'Unknown' }
        Status = if ($adapter) { [string]$adapter.Status } else { 'Unknown' }
        HardwareInterface = if ($adapter) { [bool]$adapter.HardwareInterface } else { $null }
        DhcpEnabled = if ($ipInterface) { ([string]$ipInterface.Dhcp -eq 'Enabled') } else { $null }
        DnsConfigState = $dnsConfigState
        DnsConfigDetail = $dnsConfigDetail
        IPv4DnsReadable = $dns4Readable
        IPv4DnsReadError = $dns4Error
        IPv4DnsServers = $dns4
        IPv6DnsReadable = $dns6Readable
        IPv6DnsReadError = $dns6Error
        IPv6DnsServers = $dns6
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Test-POAdapterDnsEligibility {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$AdapterState)
    $reasons = @()
    if ([string]$AdapterState.Status -ne 'Up') { $reasons += 'The adapter is not connected (Up).' }
    if ($null -eq $AdapterState.HardwareInterface -or -not [bool]$AdapterState.HardwareInterface) { $reasons += 'Only a positively identified physical adapter is eligible; virtual/VPN or unknown adapter type is blocked.' }
    $interfaceGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$AdapterState.InterfaceGuid, [ref]$interfaceGuid)) { $reasons += 'The adapter interface GUID could not be read for safe backup/restore identity.' }
    if ($null -eq $AdapterState.DhcpEnabled) { $reasons += 'DHCP address assignment could not be verified.' }
    elseif (-not [bool]$AdapterState.DhcpEnabled) { $reasons += 'The adapter is not using DHCP; static address configuration is left untouched.' }
    if (-not [bool]$AdapterState.IPv4DnsReadable) { $reasons += "Current IPv4 DNS server state could not be read: $($AdapterState.IPv4DnsReadError)" }
    if ([string]$AdapterState.DnsConfigState -ne 'AUTOMATIC/DHCP') { $reasons += "Automatic/DHCP DNS mode could not be verified. $($AdapterState.DnsConfigDetail)" }
    return [pscustomobject][ordered]@{
        Eligible = ($reasons.Count -eq 0)
        Status = if ($reasons.Count -eq 0) { 'ELIGIBLE' } else { 'BLOCKED' }
        Reasons = $reasons
    }
}

function Get-PONetworkAdapters {
    [CmdletBinding()]
    param()
    $result = @()
    if (-not (Test-POIsWindows)) { return @() }
    try {
        foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
            $dns = Get-POCurrentAdapterDns -InterfaceIndex ([int]$adapter.ifIndex)
            $addresses = @()
            try { $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '169.254*' } | ForEach-Object { $_.IPAddress }) } catch { }
            $gateway = $null
            try { $gateway = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch { }
            $result += [pscustomobject][ordered]@{
                InterfaceIndex = [int]$adapter.ifIndex
                InterfaceGuid = [string]$adapter.InterfaceGuid
                Name = [string]$adapter.Name
                Description = [string]$adapter.InterfaceDescription
                Status = [string]$adapter.Status
                LinkSpeed = [string]$adapter.LinkSpeed
                HardwareInterface = [bool]$adapter.HardwareInterface
                IPv4Addresses = $addresses
                Gateway = $gateway
                IPv4DnsServers = @($dns.IPv4DnsServers)
                IPv4DnsReadable = $dns.IPv4DnsReadable
                IPv4DnsReadError = $dns.IPv4DnsReadError
                IPv6DnsServers = @($dns.IPv6DnsServers)
                IPv6DnsReadable = $dns.IPv6DnsReadable
                IPv6DnsReadError = $dns.IPv6DnsReadError
                DnsConfigState = $dns.DnsConfigState
                DnsConfigDetail = $dns.DnsConfigDetail
                DhcpEnabled = $dns.DhcpEnabled
            }
        }
    }
    catch {
        return @([pscustomobject]@{
            InterfaceIndex = $null; InterfaceGuid = $null; Name = 'Network inventory unavailable'; Description = 'Get-NetAdapter query failed'
            Status = 'QUERY FAILED'; LinkSpeed = 'Unknown'; HardwareInterface = $false; IPv4Addresses = @(); Gateway = $null
            IPv4DnsServers = @(); IPv4DnsReadable = $false; IPv4DnsReadError = $_.Exception.Message
            IPv6DnsServers = @(); IPv6DnsReadable = $false; IPv6DnsReadError = $_.Exception.Message
            DnsConfigState = 'UNKNOWN'; DnsConfigDetail = $_.Exception.Message; DhcpEnabled = $null
        })
    }
    return $result
}

function Invoke-PONetworkPingTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateLength(1, 253)][string]$HostName,
        [ValidateRange(1, 10)][int]$Count = 4
    )
    $hostValue = $HostName.Trim()
    if ($hostValue -notmatch '^[A-Za-z0-9][A-Za-z0-9.:-]*$') { throw 'Enter a host name or IP address only; spaces and command syntax are not accepted.' }
    $samples = @(); $failure = $null
    try {
        $reply = @(Test-Connection -ComputerName $hostValue -Count $Count -ErrorAction Stop)
        foreach ($item in $reply) {
            if ($null -ne $item.ResponseTime -and [double]$item.ResponseTime -ge 0) { $samples += [double]$item.ResponseTime }
        }
    }
    catch { $failure = $_.Exception.Message }
    $loss = 100
    if ($Count -gt 0) { $loss = [math]::Round((100.0 * ($Count - $samples.Count) / $Count), 1) }
    return [pscustomobject][ordered]@{
        Target = $hostValue
        Sent = $Count
        Received = $samples.Count
        PacketLossPercent = $loss
        AverageMs = if ($samples.Count -gt 0) { [math]::Round(($samples | Measure-Object -Average).Average, 2) } else { $null }
        MinMs = if ($samples.Count -gt 0) { [math]::Round(($samples | Measure-Object -Minimum).Minimum, 2) } else { $null }
        MaxMs = if ($samples.Count -gt 0) { [math]::Round(($samples | Measure-Object -Maximum).Maximum, 2) } else { $null }
        Error = $failure
        Note = 'ICMP may be filtered. This is not a game-server route measurement unless the entered host is the actual game endpoint.'
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-POServiceAudit {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) { return @() }
    $catalog = Get-POServiceCatalog
    $classification = @{}
    foreach ($category in $catalog.classifications.PSObject.Properties) {
        foreach ($serviceName in @($category.Value)) { $classification[[string]$serviceName] = [string]$category.Name }
    }
    $rows = @()
    try { $serviceRecords = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop) }
    catch {
        return @([pscustomobject]@{ Name = 'Inventory unavailable'; DisplayName = 'Win32_Service query failed'; Classification = 'QUERY FAILED'; State = 'Unknown'; StartupType = 'Unknown'; Dependencies = 'Unknown'; DependentServiceCount = $null; DependentServiceQuery = $_.Exception.Message; Action = 'Read-only query failed; no service was changed' })
    }
    $dependentServiceMap = @{}; $dependentServiceErrors = @{}; $dependentQueryError = $null
    try {
        foreach ($scmService in @(Get-Service -ErrorAction Stop)) {
            try { $dependentServiceMap[[string]$scmService.Name] = @($scmService.DependentServices | ForEach-Object { $_.Name }) }
            catch { $dependentServiceErrors[[string]$scmService.Name] = $_.Exception.Message }
        }
    }
    catch { $dependentQueryError = $_.Exception.Message }
    foreach ($service in $serviceRecords) {
        $category = if ($classification.ContainsKey([string]$service.Name)) { $classification[[string]$service.Name] } else { 'UNKNOWN / REVIEW' }
        $serviceName = [string]$service.Name
        $dependents = @(); $dependentError = $null
        if ($dependentQueryError) { $dependentError = $dependentQueryError }
        elseif ($dependentServiceErrors.ContainsKey($serviceName)) { $dependentError = $dependentServiceErrors[$serviceName] }
        elseif ($dependentServiceMap.ContainsKey($serviceName)) { $dependents = @($dependentServiceMap[$serviceName]) }
        else { $dependentError = 'Service was not returned by Get-Service.' }
        $rows += [pscustomobject][ordered]@{
            Name = [string]$service.Name
            DisplayName = [string]$service.DisplayName
            Classification = $category
            State = [string]$service.State
            StartupType = [string]$service.StartMode
            Dependencies = [string]$service.Dependencies
            DependentServiceCount = if ($null -eq $dependentError) { $dependents.Count } else { $null }
            DependentServiceQuery = if ($null -eq $dependentError) { 'OK' } else { "Unavailable: $dependentError" }
            Action = 'Read-only; no service changes are offered'
        }
    }
    if ($serviceRecords.Count -eq 0) { return @([pscustomobject]@{ Name = 'No service rows reported'; DisplayName = 'Win32_Service query returned no entries'; Classification = 'QUERY EMPTY'; State = 'Unknown'; StartupType = 'Unknown'; Dependencies = 'Unknown'; DependentServiceCount = $null; DependentServiceQuery = 'Unknown'; Action = 'Verify WMI/CIM service inventory' }) }
    $rows = $rows | Sort-Object -Property Classification, DisplayName
    return $rows
}

function Get-POBcdAudit {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) { return [pscustomobject]@{ Available = $false; Message = 'BCD inspection is Windows-only.'; Settings = @(); Raw = '' } }
    $raw = @(); $bcdExitCode = $null; $queryError = $null
    try {
        $raw = @(& bcdedit.exe /enum '{current}' /v 2>&1)
        $bcdExitCode = $LASTEXITCODE
    }
    catch { $queryError = $_.Exception.Message }
    $text = $raw -join "`n"
    $names = @('useplatformclock', 'useplatformtick', 'disabledynamictick', 'x2apicpolicy', 'tscsyncpolicy', 'hypervisorlaunchtype', 'bootmenupolicy', 'nx')
    $settings = @()
    foreach ($name in $names) {
        $match = [regex]::Match($text, '(?im)^\s*' + [regex]::Escape($name) + '\s+(.+?)\s*$')
        $current = if ($match.Success) { $match.Groups[1].Value.Trim() } else { 'Unset / not listed' }
        $settings += [pscustomobject][ordered]@{
            Setting = $name
            Current = $current
            Default = 'Not inferred; firmware, Windows build, and boot configuration dependent'
            Recommendation = 'Leave unchanged unless troubleshooting a documented boot issue'
            Risk = 'HIGH / EXPERIMENTAL'
            RequiresReboot = $true
            ModifiedByOptimizer = $false
        }
    }
    $available = ($bcdExitCode -eq 0 -and $text.Length -gt 0 -and $text -notmatch '(?i)access is denied|The boot configuration data store could not be opened')
    if ($available) { $message = 'Read-only inspection. The optimizer never writes BCD values.' }
    elseif ($queryError) { $message = "BCD query failed: $queryError" }
    elseif ($null -ne $bcdExitCode) { $message = "BCD query returned exit code $bcdExitCode; details are not treated as available." }
    else { $message = 'BCD details unavailable; retry from an elevated session.' }
    return [pscustomobject][ordered]@{
        Available = $available
        Message = $message
        Settings = $settings
        Raw = $text
    }
}

function Get-POStartupAudit {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) { return @() }
    $rows = @()
    try { $startupEntries = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop) }
    catch { return @([pscustomobject]@{ Name = 'Inventory unavailable'; Publisher = 'Unknown'; Path = 'Unknown'; Command = 'Unknown'; Location = 'Unknown'; User = 'Unknown'; Enabled = 'QUERY FAILED'; Impact = "Read-only query failed: $($_.Exception.Message)" }) }
    foreach ($entry in $startupEntries) {
        $publisher = 'Unknown / not signed or not resolved'
        $exePath = $null
        $command = [string]$entry.Command
        $match = [regex]::Match($command, '^\s*"(?<quoted>[^"]+\.exe)"|^\s*(?<plain>[^\s]+\.exe)', 'IgnoreCase')
        if ($match.Success) {
            $exePath = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['plain'].Value }
            $exePath = [Environment]::ExpandEnvironmentVariables($exePath)
            try {
                if (Test-Path -LiteralPath $exePath -PathType Leaf) {
                    $signature = Get-AuthenticodeSignature -FilePath $exePath -ErrorAction Stop
                    if ($signature.SignerCertificate) { $publisher = [string]$signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) }
                }
            }
            catch { }
        }
        $rows += [pscustomobject][ordered]@{
            Name = [string]$entry.Name
            Publisher = $publisher
            Path = if ($exePath) { $exePath } else { $command }
            Command = $command
            Location = [string]$entry.Location
            User = [string]$entry.User
            Enabled = 'Registered (runtime state not measured)'
            Impact = 'Not measured'
        }
    }
    if ($startupEntries.Count -eq 0) { return @([pscustomobject]@{ Name = 'No startup entries reported'; Publisher = 'Unknown'; Path = 'Unknown'; Command = 'Unknown'; Location = 'Unknown'; User = 'Unknown'; Enabled = 'No rows returned'; Impact = 'No inventory entry was reported by Win32_StartupCommand' }) }
    return @($rows | Sort-Object -Property Name)
}

function Get-PODriverInventory {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) { return @() }
    $wantedClasses = @('DISPLAY', 'NET', 'MEDIA', 'SCSIADAPTER', 'HDC', 'SYSTEM')
    $rows = @()
    try { $driverRecords = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop) }
    catch { return @([pscustomobject]@{ DeviceClass = 'QUERY FAILED'; Device = 'Inventory unavailable'; Manufacturer = 'Unknown'; DriverVersion = 'Unknown'; DriverDate = 'Unknown'; Signed = $null; Signer = 'Unknown'; InfName = 'Unknown'; Action = "Read-only driver query failed: $($_.Exception.Message)" }) }
    foreach ($driver in $driverRecords) {
        $className = [string]$driver.DeviceClass
        $name = [string]$driver.DeviceName
        if ($className -notin $wantedClasses -and $name -notmatch '(?i)chipset|storage|audio|network|ethernet|wi-fi|wireless|bluetooth|display|graphics|gpu') { continue }
        $date = 'Unknown'
        try { if ($driver.DriverDate) { $date = ([datetime]$driver.DriverDate).ToString('yyyy-MM-dd') } } catch { }
        $rows += [pscustomobject][ordered]@{
            DeviceClass = if ($className) { $className } else { 'Unknown' }
            Device = $name
            Manufacturer = [string]$driver.Manufacturer
            DriverVersion = [string]$driver.DriverVersion
            DriverDate = $date
            Signed = $driver.IsSigned
            Signer = [string]$driver.Signer
            InfName = [string]$driver.InfName
            Action = 'Inventory only; no driver is downloaded, removed, or replaced'
        }
    }
    if ($rows.Count -eq 0) {
        $emptyMessage = if ($driverRecords.Count -eq 0) { 'Win32_PnPSignedDriver returned no entries.' } else { 'The query succeeded, but no devices matched the selected driver classes.' }
        return @([pscustomobject]@{ DeviceClass = 'NO MATCH'; Device = 'No matching driver rows'; Manufacturer = 'Unknown'; DriverVersion = 'Unknown'; DriverDate = 'Unknown'; Signed = $null; Signer = 'Unknown'; InfName = 'Unknown'; Action = $emptyMessage })
    }
    $rows = $rows | Sort-Object -Property DeviceClass, Device
    return $rows
}

function Get-POScheduledTaskAudit {
    [CmdletBinding()]
    param([ValidateRange(1, 5000)][int]$MaximumTasks = 1000)
    if (-not (Test-POIsWindows)) { return @() }
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return @([pscustomobject]@{ TaskPath = ''; TaskName = 'Inventory unavailable'; Author = 'Unknown'; State = 'Unknown'; Trigger = 'Unknown'; LastRun = 'Unknown'; Impact = 'Not measured'; Action = 'ScheduledTasks module is unavailable; no task was changed' })
    }
    $rows = @(); $truncated = $false; $totalTaskCount = 0
    try {
        $allTasks = @(Get-ScheduledTask -ErrorAction Stop)
        $totalTaskCount = $allTasks.Count
        $truncated = ($totalTaskCount -gt $MaximumTasks)
        $tasks = @($allTasks | Select-Object -First $MaximumTasks)
    }
    catch {
        $queryError = $_.Exception.Message
        return @([pscustomobject]@{ TaskPath = ''; TaskName = 'Inventory unavailable'; Author = 'Unknown'; State = 'Unknown'; Trigger = 'Unknown'; LastRun = 'Unknown'; Impact = 'Not measured'; Action = "Read-only query failed: $queryError" })
    }
    foreach ($task in $tasks) {
        $lastRun = 'Unknown'
        try {
            $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1601) { $lastRun = ([datetime]$info.LastRunTime).ToString('yyyy-MM-dd HH:mm:ss') }
            else { $lastRun = 'Never / not reported' }
        }
        catch { }
        $triggers = @()
        foreach ($trigger in @($task.Triggers)) {
            if ($trigger) {
                $triggerName = [string]$trigger.CimClass.CimClassName
                if (-not $triggerName) { $triggerName = $trigger.GetType().Name }
                $boundary = [string]$trigger.StartBoundary
                $triggers += if ($boundary) { "$triggerName ($boundary)" } else { $triggerName }
            }
        }
        $rows += [pscustomobject][ordered]@{
            TaskPath = [string]$task.TaskPath
            TaskName = [string]$task.TaskName
            Author = if ($task.Author) { [string]$task.Author } else { 'Unknown' }
            State = [string]$task.State
            Trigger = if ($triggers.Count) { $triggers -join '; ' } else { 'Unknown / event-driven' }
            LastRun = $lastRun
            Impact = 'Not measured'
            Action = 'Read-only; tasks are never disabled or deleted'
        }
    }
    if ($tasks.Count -eq 0) { return @([pscustomobject]@{ TaskPath = ''; TaskName = 'No scheduled tasks reported'; Author = 'Unknown'; State = 'Unknown'; Trigger = 'Unknown'; LastRun = 'Unknown'; Impact = 'No rows returned'; Action = 'Verify the ScheduledTasks module and query permissions' }) }
    if ($truncated) { $rows += [pscustomobject]@{ TaskPath = ''; TaskName = 'Inventory truncated'; Author = 'Unknown'; State = 'Unknown'; Trigger = 'Unknown'; LastRun = 'Unknown'; Impact = 'Not measured'; Action = "Displayed the first $MaximumTasks of $totalTaskCount tasks; increase MaximumTasks for a full inventory" } }
    $rows = $rows | Sort-Object -Property TaskPath, TaskName
    return $rows
}

function Get-POAppxInventory {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) { return @() }
    $protected = @('Microsoft.WindowsStore', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.SecHealthUI', 'Microsoft.DesktopAppInstaller', 'Microsoft.VCLibs', 'Microsoft.NET.Native')
    $optional = @('Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop', 'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.YourPhone', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Microsoft.SkypeApp', 'Clipchamp.Clipchamp', 'Microsoft.DevHome', 'MSTeams')
    $rows = @()
    $packages = @()
    try { $packages = @(Get-AppxPackage -ErrorAction Stop) }
    catch {
        return @([pscustomobject]@{ Name = 'Inventory unavailable'; Version = 'Unknown'; Publisher = 'Unknown'; Category = 'QUERY FAILED'; InstallLocation = ''; Action = "Read-only AppX query failed: $($_.Exception.Message)" })
    }
    foreach ($package in $packages) {
        $category = 'UNKNOWN / REVIEW'
        if (@($protected | Where-Object { $package.Name -like "$_*" }).Count -gt 0) { $category = 'SYSTEM / KEEP' }
        elseif (@($optional | Where-Object { $package.Name -like "$_*" }).Count -gt 0) { $category = 'OPTIONAL / USER CHOICE' }
        $rows += [pscustomobject][ordered]@{
            Name = [string]$package.Name
            Version = [string]$package.Version
            Publisher = [string]$package.Publisher
            Category = $category
            InstallLocation = [string]$package.InstallLocation
            Action = 'Inventory only; removal is disabled because reliable offline restore is not guaranteed'
        }
    }
    $rows = $rows | Sort-Object -Property Category, Name
    return $rows
}

function Get-POInstalledGames {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) { return @() }
    $catalog = @(Get-POGameCatalog)
    $found = @{}
    foreach ($game in $catalog) { $found[$game.id] = @() }
    function Add-POGameInstall {
        param([string]$Title, [string]$Source, [string]$Path)
        foreach ($game in $catalog) {
            $isMatch = $false
            foreach ($alias in @($game.matchNames)) {
                if (-not [string]::IsNullOrWhiteSpace($alias)) {
                    $aliasPattern = '(?i)(^|[^A-Za-z0-9])' + [regex]::Escape([string]$alias) + '([^A-Za-z0-9]|$)'
                    if ($Title -match $aliasPattern) { $isMatch = $true; break }
                }
            }
            if ($isMatch) {
                $existing = @($found[$game.id] | Where-Object { $_.Path -eq $Path -and $_.Source -eq $Source })
                if ($existing.Count -eq 0) {
                    $found[$game.id] += [pscustomobject][ordered]@{ GameId = $game.id; Game = $game.name; DetectedTitle = $Title; Source = $Source; Path = $Path; Status = 'Detected; executable path should be reviewed' }
                }
            }
        }
    }
    $steamPaths = @()
    try {
        $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
        if ($steam -and (Test-Path -LiteralPath $steam)) { $steamPaths += $steam }
    }
    catch { }
    foreach ($steamPath in @($steamPaths | Select-Object -Unique)) {
        $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        $libraries = @($steamPath)
        try {
            if (Test-Path -LiteralPath $vdf) {
                $vdfText = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop
                foreach ($match in [regex]::Matches($vdfText, '"path"\s*"(?<path>[^"]+)"', 'IgnoreCase')) {
                    $libraryPath = $match.Groups['path'].Value -replace '\\\\', '\'
                    if (Test-Path -LiteralPath $libraryPath) { $libraries += $libraryPath }
                }
            }
        }
        catch { }
        foreach ($library in @($libraries | Select-Object -Unique)) {
            $manifestRoot = Join-Path $library 'steamapps'
            try {
                foreach ($manifest in @(Get-ChildItem -LiteralPath $manifestRoot -Filter 'appmanifest_*.acf' -File -ErrorAction Stop)) {
                    $text = Get-Content -LiteralPath $manifest.FullName -Raw -ErrorAction Stop
                    $nameMatch = [regex]::Match($text, '"name"\s*"(?<value>[^"]+)"', 'IgnoreCase')
                    $dirMatch = [regex]::Match($text, '"installdir"\s*"(?<value>[^"]+)"', 'IgnoreCase')
                    if ($nameMatch.Success) {
                        $install = if ($dirMatch.Success) { Join-Path (Join-Path $manifestRoot 'common') $dirMatch.Groups['value'].Value } else { $manifestRoot }
                        Add-POGameInstall -Title $nameMatch.Groups['value'].Value -Source 'Steam' -Path $install
                    }
                }
            }
            catch { }
        }
    }
    $epicRoot = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    try {
        foreach ($manifest in @(Get-ChildItem -LiteralPath $epicRoot -Filter '*.item' -File -ErrorAction Stop)) {
            try {
                $record = Get-Content -LiteralPath $manifest.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                Add-POGameInstall -Title ([string]$record.DisplayName) -Source 'Epic Games' -Path ([string]$record.InstallLocation)
            }
            catch { }
        }
    }
    catch { }
    try {
        foreach ($package in @(Get-AppxPackage -ErrorAction Stop)) {
            Add-POGameInstall -Title ([string]$package.Name) -Source 'Microsoft Store / Xbox package inventory' -Path ([string]$package.InstallLocation)
        }
    }
    catch { }
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstallRoots) {
        try {
            foreach ($entry in @(Get-ItemProperty -Path $root -ErrorAction Stop | Where-Object { $_.DisplayName })) {
                Add-POGameInstall -Title ([string]$entry.DisplayName) -Source 'Registered installer' -Path ([string]$entry.InstallLocation)
            }
        }
        catch { }
    }
    $result = @()
    foreach ($game in $catalog) {
        if (@($found[$game.id]).Count -gt 0) { $result += @($found[$game.id]) }
    }
    $customPath = Join-Path (Join-Path (Get-POStateRoot) 'games') 'custom-games.json'
    try {
        if (Test-Path -LiteralPath $customPath) { $result += @(Get-Content -LiteralPath $customPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) }
    }
    catch { $result += [pscustomobject]@{ GameId = 'discovery-warning'; Game = 'Custom game list unavailable'; DetectedTitle = 'Unknown'; Source = 'Local catalog'; Path = $customPath; Status = "Read-only query failed: $($_.Exception.Message)" } }
    if ($result.Count -eq 0) { return @([pscustomobject]@{ GameId = 'discovery-status'; Game = 'No catalog games detected'; DetectedTitle = 'Unknown'; Source = 'Supported local metadata'; Path = ''; Status = 'No match was found. This is not a complete PC game inventory; add a game manually to review it.' }) }
    return $result
}

function Add-POCustomGame {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ExecutablePath)
    $fullPath = [System.IO.Path]::GetFullPath($ExecutablePath)
    if ([System.IO.Path]::GetExtension($fullPath) -notin @('.exe', '.lnk')) { throw 'Choose a game executable (.exe) or shortcut (.lnk).' }
    $root = Join-Path (Get-POStateRoot) 'games'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $customPath = Join-Path $root 'custom-games.json'
    $items = @()
    if (Test-Path -LiteralPath $customPath -PathType Leaf) {
        try { $items = @(Get-Content -LiteralPath $customPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) }
        catch { throw "The custom game list could not be read; it was not overwritten. $($_.Exception.Message)" }
    }
    if (@($items | Where-Object { $_.Path -eq $fullPath }).Count -eq 0) {
        $items += [pscustomobject][ordered]@{ GameId = 'custom-' + [guid]::NewGuid().ToString('N'); Game = [System.IO.Path]::GetFileNameWithoutExtension($fullPath); DetectedTitle = [System.IO.Path]::GetFileNameWithoutExtension($fullPath); Source = 'Custom'; Path = $fullPath; Status = 'User-added; no process memory access' }
        Write-POJsonAtomic -Path $customPath -Object $items
    }
    return $items
}

function Get-POBenchmarkSnapshot {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 30)][int]$SampleSeconds = 5,
        [switch]$IncludeNetworkPing,
        [string]$NetworkHost = '1.1.1.1'
    )
    if (-not (Test-POIsWindows)) { throw 'Benchmark snapshot is available only on Windows.' }
    $cpuSamples = @(); $dpcSamples = @(); $interruptSamples = @()
    for ($i = 0; $i -lt $SampleSeconds; $i++) {
        try {
            $cpuCounter = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
            if ($null -ne $cpuCounter.PercentProcessorTime) { $cpuSamples += [double]$cpuCounter.PercentProcessorTime }
            if ($null -ne $cpuCounter.PercentDPCTime) { $dpcSamples += [double]$cpuCounter.PercentDPCTime }
            if ($null -ne $cpuCounter.PercentInterruptTime) { $interruptSamples += [double]$cpuCounter.PercentInterruptTime }
        }
        catch { }
        if ($i -lt ($SampleSeconds - 1)) { Start-Sleep -Seconds 1 }
    }
    $operatingSystem = $null; $computer = $null
    try { $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { }
    $memory = $null
    try { $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop } catch { }
    $disk = $null
    try { $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop } catch { }
    $ping = $null
    if ($IncludeNetworkPing) {
        try { $ping = Invoke-PONetworkPingTest -HostName $NetworkHost -Count 4 } catch { $ping = [pscustomobject]@{ Target = $NetworkHost; Error = $_.Exception.Message; AverageMs = $null; PacketLossPercent = $null } }
    }
    $totalBytes = if ($computer -and $computer.TotalPhysicalMemory) { [double]$computer.TotalPhysicalMemory } else { $null }
    $availableGB = if ($operatingSystem -and $null -ne $operatingSystem.FreePhysicalMemory) { [math]::Round(([double]$operatingSystem.FreePhysicalMemory / 1MB), 2) } else { $null }
    $availableMBytes = if ($memory -and $null -ne $memory.AvailableMBytes) { [double]$memory.AvailableMBytes } else { $null }
    if ($null -ne $availableMBytes) { $availableGB = [math]::Round(($availableMBytes / 1024.0), 2) }
    $commitGB = if ($memory -and $null -ne $memory.CommittedBytes) { ConvertTo-POBytesGB $memory.CommittedBytes } else { $null }
    $commitLimitGB = if ($memory -and $null -ne $memory.CommitLimit) { ConvertTo-POBytesGB $memory.CommitLimit } else { $null }
    $startupCount = @((Get-POStartupAudit)).Count
    $cpuAverage = if ($cpuSamples.Count -gt 0) { [math]::Round(($cpuSamples | Measure-Object -Average).Average, 1) } else { $null }
    $dpcAverage = if ($dpcSamples.Count -gt 0) { [math]::Round(($dpcSamples | Measure-Object -Average).Average, 2) } else { $null }
    $interruptAverage = if ($interruptSamples.Count -gt 0) { [math]::Round(($interruptSamples | Measure-Object -Average).Average, 2) } else { $null }
    return [pscustomobject][ordered]@{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        SampleSeconds = $SampleSeconds
        Metrics = [pscustomobject][ordered]@{
            CpuUsagePercent = $cpuAverage
            RamTotalGB = if ($totalBytes) { ConvertTo-POBytesGB $totalBytes } else { $null }
            RamAvailableGB = $availableGB
            MemoryCommitGB = $commitGB
            MemoryCommitLimitGB = $commitLimitGB
            DiskPercentTime = if ($disk -and $null -ne $disk.PercentDiskTime) { [double]$disk.PercentDiskTime } else { $null }
            DiskBytesPerSecond = if ($disk -and $null -ne $disk.DiskBytesPerSec) { [double]$disk.DiskBytesPerSec } else { $null }
            DpcTimePercent = $dpcAverage
            InterruptTimePercent = $interruptAverage
            DpcLatency = 'Not measured; DPC/ISR execution-time percentages are not latency measurements'
            GPUUsage = 'Not measured by the generic Windows CIM path'
            FrameRateAndFrameTime = 'Not measured; no game injection or overlay source is used'
            StartupEntryCount = $startupCount
            UptimeAtCapture = if ($operatingSystem -and $operatingSystem.LastBootUpTime) { ([datetime]::Now - [datetime]$operatingSystem.LastBootUpTime).ToString() } else { 'Unknown' }
            BootDuration = 'Not measured; current uptime is not boot duration'
            NetworkPing = $ping
        }
        Notes = @(
            'This is a short system sample, not a controlled game benchmark. Repeat under comparable idle/workload conditions.',
            'Missing counters are shown as unavailable, never converted into zero.',
            'No FPS, frame-time, DPC-latency, or thermal result is fabricated.'
        )
    }
}

function Save-POBenchmarkSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('before', 'after', 'standalone')][string]$Label,
          [Parameter(Mandatory = $true)][psobject]$Snapshot)
    $root = Join-Path (Get-POStateRoot) 'benchmarks'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $baseName = '{0}_{1}' -f $Label, (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff')
    $file = Join-Path $root ($baseName + '.json')
    $suffix = 1
    while (Test-Path -LiteralPath $file) { $file = Join-Path $root ('{0}_{1}.json' -f $baseName, $suffix); $suffix++ }
    Write-POJsonAtomic -Path $file -Object $Snapshot
    return $file
}

function Compare-POBenchmarkSnapshots {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Before, [Parameter(Mandatory = $true)][psobject]$After)
    $metricNames = @('CpuUsagePercent', 'RamAvailableGB', 'MemoryCommitGB', 'DiskPercentTime', 'DiskBytesPerSecond', 'DpcTimePercent', 'InterruptTimePercent')
    $rows = @()
    foreach ($name in $metricNames) {
        $a = $Before.Metrics.$name; $b = $After.Metrics.$name
        $valid = ($null -ne $a -and $null -ne $b -and $a -is [ValueType] -and $b -is [ValueType])
        $rows += [pscustomobject][ordered]@{
            Metric = $name
            Before = if ($valid) { $a } else { 'Unavailable' }
            After = if ($valid) { $b } else { 'Unavailable' }
            Delta = if ($valid) { [math]::Round(([double]$b - [double]$a), 2) } else { $null }
            Interpretation = if ($valid) { 'Observed difference only; workload and noise may explain it' } else { 'Not compared; metric missing in at least one sample' }
        }
    }
    return [pscustomobject][ordered]@{
        BeforeCapturedAtUtc = $Before.CapturedAtUtc
        AfterCapturedAtUtc = $After.CapturedAtUtc
        Metrics = $rows
        GamingPerformanceScore = 'NOT SCORED — no standardized in-game FPS/frame-time benchmark was collected.'
        Conclusion = 'Report measured values only. A difference is not automatically a causal optimization benefit.'
    }
}

function Get-PORegistrySnapshotKeys {
    $keys = @(
        @{ Hive = 'CurrentUser'; SubKey = 'Software\Microsoft\GameBar'; ValueName = 'AutoGameModeEnabled' },
        @{ Hive = 'CurrentUser'; SubKey = 'Software\Microsoft\GameBar'; ValueName = 'AllowAutoGameMode' },
        @{ Hive = 'CurrentUser'; SubKey = 'System\GameConfigStore'; ValueName = 'GameDVR_Enabled' },
        @{ Hive = 'CurrentUser'; SubKey = 'Software\Microsoft\Windows\CurrentVersion\GameDVR'; ValueName = 'AppCaptureEnabled' }
    )
    $states = @($keys | ForEach-Object { Get-PORegValueState -Hive $_.Hive -SubKey $_.SubKey -ValueName $_.ValueName })
    $unreadable = @($states | Where-Object { -not $_.Readable })
    if ($unreadable.Count -gt 0) { throw ('Registry backup is incomplete: ' + (@($unreadable | ForEach-Object { "$($_.SubKey)\$($_.ValueName): $($_.ReadError)" }) -join '; ')) }
    return $states
}

function Get-POBackupRoot {
    return (Join-Path (Get-POStateRoot) 'Backups')
}

function Write-POJsonAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Object)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = $Path + '.tmp'
    $Object | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Write-POLog {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'CRITICAL')][string]$Level = 'INFO',
        [string]$Category = 'System', [string]$TweakId = '', [string]$Status = 'INFO',
        [string]$Message = '', [string]$Command = '', [Nullable[int]]$ExitCode = $null
    )
    try {
        $root = Split-Path -Parent $script:POLogPath
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        $record = [pscustomobject][ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            level = $Level
            category = $Category
            tweakId = $TweakId
            status = $Status
            message = $Message
            command = $Command
            exitCode = if ($null -ne $ExitCode) { [int]$ExitCode } else { $null }
        }
        Add-Content -LiteralPath $script:POLogPath -Value ($record | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
    }
    catch { }
}

function Get-POPathRootPrefix {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $trimmed = $fullPath.TrimEnd($separators)
    if ([string]::IsNullOrEmpty($trimmed)) { return [string][System.IO.Path]::DirectorySeparatorChar }
    return $trimmed + [System.IO.Path]::DirectorySeparatorChar
}

function Get-POPathComparison {
    if (Test-POIsWindows) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Get-POBackupActualPaths {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Backup root is a reparse point.' }
    $rootPrefix = Get-POPathRootPrefix -Path $rootFull
    $comparison = Get-POPathComparison
    $manifestPath = Join-Path $rootFull 'manifest.json'
    $paths = @()
    $directories = New-Object 'System.Collections.Generic.Stack[string]'
    $directories.Push($rootFull)
    while ($directories.Count -gt 0) {
        $directory = $directories.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point is not allowed inside a backup: $($entry.FullName)" }
            if ($entry.PSIsContainer) { $directories.Push($entry.FullName); continue }
            if ($entry.FullName.Equals($manifestPath, $comparison)) { continue }
            if (-not $entry.FullName.StartsWith($rootPrefix, $comparison)) { throw "File is outside the backup directory: $($entry.FullName)" }
            $paths += $entry.FullName.Substring($rootPrefix.Length)
        }
    }
    return $paths
}

function Get-POFileInventory {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $files = @()
    foreach ($relative in @(Get-POBackupActualPaths -Root $rootFull)) {
        $fullPath = Join-Path $rootFull $relative
        $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $files += [pscustomobject][ordered]@{ Path = $relative; Length = [long]$file.Length; SHA256 = $hash }
    }
    return $files
}

function New-POBackup {
    [CmdletBinding()]
    param([int]$NetworkInterfaceIndex = -1)
    if (-not (Test-POIsWindows)) { throw 'Backups can only be created on Windows.' }
    $root = Get-POBackupRoot
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $id = 'Backup_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    $backupPath = Join-Path $root $id
    $suffix = 1
    while (Test-Path -LiteralPath $backupPath) {
        $backupPath = Join-Path $root ('{0}_{1}' -f $id, $suffix)
        $suffix++
    }
    foreach ($folder in @('registry', 'bcd', 'services', 'power', 'network', 'system')) {
        New-Item -ItemType Directory -Path (Join-Path $backupPath $folder) -Force | Out-Null
    }
    $warnings = @()
    $snapshot = Get-POSystemSnapshot
    foreach ($queryWarning in @($snapshot.CollectionWarnings)) { $warnings += "$($queryWarning.ClassName): $($queryWarning.Error)" }
    Write-POJsonAtomic -Path (Join-Path $backupPath 'system\snapshot.json') -Object $snapshot
    $activeGuid = Get-POActivePowerPlanGuid
    $powerExport = $null
    if ($activeGuid) {
        $powerExport = Join-Path $backupPath 'power\active-plan.pow'
        try {
            & powercfg.exe /export $powerExport $activeGuid 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $powerExport -PathType Leaf)) {
                $warnings += "Power plan export returned exit code $LASTEXITCODE; the previous active GUID was still recorded."
                $powerExport = $null
            }
        }
        catch { $warnings += "Power plan export failed: $($_.Exception.Message)"; $powerExport = $null }
    }
    else { $warnings += 'The active power plan GUID could not be read.' }
    $powerState = [pscustomobject][ordered]@{ ActivePlanGuid = $activeGuid; ExportFile = if ($powerExport) { 'power\active-plan.pow' } else { $null }; CapturedAtUtc = [DateTime]::UtcNow.ToString('o') }
    Write-POJsonAtomic -Path (Join-Path $backupPath 'power\active-plan.json') -Object $powerState

    $dnsSnapshot = @()
    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        try {
            $adapters = @(Get-NetAdapter -ErrorAction Stop)
            foreach ($adapter in $adapters) {
                if ($NetworkInterfaceIndex -ge 0 -and [int]$adapter.ifIndex -ne $NetworkInterfaceIndex) { continue }
                $dnsState = Get-POCurrentAdapterDns -InterfaceIndex ([int]$adapter.ifIndex)
                $dnsSnapshot += $dnsState
                if (-not $dnsState.IPv4DnsReadable) { $warnings += "IPv4 DNS state unavailable for adapter $($adapter.Name): $($dnsState.IPv4DnsReadError)" }
            }
        }
        catch { $warnings += "Network snapshot is incomplete: $($_.Exception.Message)" }
    }
    else { $warnings += 'Network snapshot unavailable: Get-NetAdapter is not installed.' }
    Write-POJsonAtomic -Path (Join-Path $backupPath 'network\dns-before.json') -Object $dnsSnapshot

    $serviceState = @()
    try { $serviceRecords = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop) }
    catch { $serviceRecords = @(); $warnings += "Service inventory query failed: $($_.Exception.Message)" }
    foreach ($service in $serviceRecords) {
        $serviceState += [pscustomobject][ordered]@{ Name = [string]$service.Name; DisplayName = [string]$service.DisplayName; State = [string]$service.State; StartMode = [string]$service.StartMode; DelayedAutoStart = $null }
    }
    Write-POJsonAtomic -Path (Join-Path $backupPath 'services\inventory.json') -Object $serviceState

    $registryState = Get-PORegistrySnapshotKeys
    Write-POJsonAtomic -Path (Join-Path $backupPath 'registry\game-settings-before.json') -Object $registryState

    $bcdStatus = 'Read-only BCD export; the optimizer does not modify boot settings.'
    try {
        $bcdText = @(& bcdedit.exe /enum '{current}' /v 2>&1) -join "`r`n"
        Set-Content -LiteralPath (Join-Path $backupPath 'bcd\current-entry.txt') -Value $bcdText -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { $warnings += "BCD inventory returned exit code $LASTEXITCODE." }
    }
    catch { $bcdStatus = "BCD inventory unavailable: $($_.Exception.Message)"; $warnings += $bcdStatus }
    Set-Content -LiteralPath (Join-Path $backupPath 'bcd\README.txt') -Value $bcdStatus -Encoding UTF8

    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        id = Split-Path -Leaf $backupPath
        createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        applicationVersion = '1.0.0'
        status = 'VALID'
        modifiedSections = @()
        changes = @()
        restoreHistory = @()
        files = @(Get-POFileInventory -Root $backupPath)
        warnings = $warnings
        machine = [pscustomobject]@{ WindowsFamily = $snapshot.OS.Family; WindowsBuild = $snapshot.OS.Build; ComputerModel = $snapshot.Device.Model }
        restorationScope = 'Only sections recorded in modifiedSections are restored. BCD, services, AppX, and security are captured for audit but never modified by profiles.'
    }
    Write-POJsonAtomic -Path (Join-Path $backupPath 'manifest.json') -Object $manifest
    $validation = Test-POBackup -Path $backupPath
    if (-not $validation.Valid) { throw ('New backup failed checksum/path verification: ' + (@($validation.Issues) -join '; ')) }
    Write-POLog -Category 'Backup' -Status 'CREATED' -Message "Created and verified local backup $($manifest.id)."
    return [pscustomobject][ordered]@{ Path = $backupPath; Id = $manifest.id; Status = $manifest.status; Warnings = $warnings; Manifest = $manifest }
}

function Test-POBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $manifestPath = Join-Path $Path 'manifest.json'
    $issues = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ Valid = $false; Status = 'INVALID'; Issues = @('Backup directory is missing') }
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; Status = 'INVALID'; Issues = @('manifest.json is missing') }
    }
    try {
        $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or ($manifestItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ Valid = $false; Status = 'INVALID'; Issues = @('Backup directory or manifest is a reparse point') }
        }
    }
    catch { return [pscustomobject]@{ Valid = $false; Status = 'INVALID'; Issues = @('Backup directory or manifest cannot be inspected') } }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { return [pscustomobject]@{ Valid = $false; Status = 'INVALID'; Issues = @('manifest.json cannot be parsed') } }
    $requiredFields = @('schemaVersion', 'id', 'status', 'files', 'modifiedSections', 'changes', 'restoreHistory')
    $missingFields = @($requiredFields | Where-Object { $null -eq $manifest.PSObject.Properties[$_] })
    if ($missingFields.Count -gt 0) { return [pscustomobject]@{ Valid = $false; Status = 'INVALID'; Issues = @('Manifest fields are missing: ' + ($missingFields -join ', ')); Manifest = $manifest } }
    if ($manifest.schemaVersion -ne 1) { $issues += 'Unsupported or missing backup schemaVersion' }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.id)) { $issues += 'Backup id is missing' }
    elseif ([string]$manifest.id -ne (Split-Path -Leaf ([System.IO.Path]::GetFullPath($Path)))) { $issues += 'Backup id does not match its directory name' }
    if ([string]$manifest.status -ne 'VALID') { $issues += 'Backup manifest status is not VALID' }
    if (@($manifest.files).Count -eq 0) { $issues += 'Backup file inventory is empty' }
    $rootFull = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = Get-POPathRootPrefix -Path $rootFull
    $comparison = Get-POPathComparison
    $actualRelativePaths = @(); $actualPathSet = @{}; $manifestPathSet = @{}
    try {
        $actualRelativePaths = @(Get-POBackupActualPaths -Root $rootFull)
        foreach ($actualRelativePath in $actualRelativePaths) { $actualPathSet[[string]$actualRelativePath] = $true }
    }
    catch { $issues += "Could not enumerate backup files safely: $($_.Exception.Message)" }
    foreach ($entry in @($manifest.files)) {
        if ($null -eq $entry) { $issues += 'Manifest contains a null file entry'; continue }
        $entryFields = @('Path', 'SHA256', 'Length')
        $missingEntryFields = @($entryFields | Where-Object { $null -eq $entry.PSObject.Properties[$_] })
        if ($missingEntryFields.Count -gt 0) { $issues += ('Manifest file entry is missing fields: ' + ($missingEntryFields -join ', ')); continue }
        $relativePath = [string]$entry.PSObject.Properties['Path'].Value
        if ([string]::IsNullOrWhiteSpace($relativePath)) { $issues += 'Manifest contains an empty file path'; continue }
        if ($manifestPathSet.ContainsKey($relativePath)) { $issues += "Manifest contains a duplicate file path: $relativePath"; continue }
        $manifestPathSet[$relativePath] = $true
        try { $candidate = [System.IO.Path]::GetFullPath((Join-Path $Path $relativePath)) }
        catch { $issues += "Invalid relative path in manifest: $relativePath"; continue }
        if (-not $candidate.StartsWith($rootPrefix, $comparison)) { $issues += "Invalid relative path in manifest: $relativePath"; continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { $issues += "Backup file is missing: $relativePath"; continue }
        $expectedHash = [string]$entry.PSObject.Properties['SHA256'].Value
        $expectedLength = 0L
        if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$' -or -not [long]::TryParse([string]$entry.PSObject.Properties['Length'].Value, [ref]$expectedLength) -or $expectedLength -lt 0) {
            $issues += "Invalid checksum metadata: $relativePath"
            continue
        }
        $reparseFound = $false
        $current = $candidate
        while ($current -and -not $current.Equals($rootFull, $comparison)) {
            try {
                $currentItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $reparseFound = $true; break }
            }
            catch { $issues += "Could not inspect backup path: $relativePath"; $reparseFound = $true; break }
            $current = Split-Path -Path $current -Parent
        }
        if ($reparseFound) { $issues += "Reparse point in backup path: $relativePath"; continue }
        try {
            $fileInfo = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if ([long]$fileInfo.Length -ne $expectedLength) { $issues += "Length mismatch: $relativePath"; continue }
            $actual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($actual -ne $expectedHash) { $issues += "Checksum mismatch: $relativePath" }
        }
        catch { $issues += "Could not verify: $relativePath" }
    }
    foreach ($actualRelativePath in $actualPathSet.Keys) {
        if (-not $manifestPathSet.ContainsKey([string]$actualRelativePath)) { $issues += "Unlisted file in backup: $actualRelativePath" }
    }
    if ($issues.Count -eq 0) { return [pscustomobject]@{ Valid = $true; Status = 'VALID'; Issues = @(); Manifest = $manifest } }
    return [pscustomobject]@{ Valid = $false; Status = 'INVALID'; Issues = $issues; Manifest = $manifest }
}

function Get-POBackups {
    [CmdletBinding()]
    param()
    $root = Get-POBackupRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $items = @()
    try { $directories = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop | Sort-Object -Property LastWriteTime -Descending) }
    catch { throw "Backup inventory could not be read from '$root': $($_.Exception.Message)" }
    foreach ($directory in $directories) {
        $validation = Test-POBackup -Path $directory.FullName
        $manifest = $validation.Manifest
        $items += [pscustomobject][ordered]@{
            Id = $directory.Name
            Path = $directory.FullName
            CreatedAt = if ($manifest) { [string]$manifest.createdAt } else { $directory.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
            Status = $validation.Status
            ChangeCount = if ($manifest) { @($manifest.changes).Count } else { 0 }
            Changes = if ($manifest) { @($manifest.changes | ForEach-Object { $_.name }) -join ', ' } else { '' }
            Issues = @($validation.Issues)
        }
    }
    return $items
}

function Add-POBackupChange {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath,
          [Parameter(Mandatory = $true)][ValidateSet('power', 'network', 'registry')][string]$Section,
          [Parameter(Mandatory = $true)][psobject]$Change)
    $manifestPath = Join-Path $BackupPath 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $sections = @($manifest.modifiedSections)
    if ($sections -notcontains $Section) { $sections += $Section }
    $manifest.modifiedSections = $sections
    $changes = @($manifest.changes)
    $changes += $Change
    $manifest.changes = $changes
    Write-POJsonAtomic -Path $manifestPath -Object $manifest
}

function Update-POBackupChangeStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath,
          [Parameter(Mandatory = $true)][ValidateSet('power', 'network', 'registry')][string]$Section,
          [Parameter(Mandatory = $true)][string]$Status,
          [string]$Message = '',
          [AllowNull()][string[]]$AfterIPv4)
    $manifestPath = Join-Path $BackupPath 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $changes = @($manifest.changes)
    $matches = @($changes | Where-Object { $_.section -eq $Section } | Select-Object -Last 1)
    if ($matches.Count -eq 0) { throw "No $Section transaction is recorded in this backup." }
    $change = $matches[0]
    if ($change.PSObject.Properties['status']) { $change.status = $Status }
    else { $change | Add-Member -MemberType NoteProperty -Name 'status' -Value $Status }
    if ($change.PSObject.Properties['resultMessage']) { $change.resultMessage = $Message }
    else { $change | Add-Member -MemberType NoteProperty -Name 'resultMessage' -Value $Message }
    if ($PSBoundParameters.ContainsKey('AfterIPv4')) {
        if ($change.PSObject.Properties['afterIPv4']) { $change.afterIPv4 = @($AfterIPv4) }
        else { $change | Add-Member -MemberType NoteProperty -Name 'afterIPv4' -Value @($AfterIPv4) }
    }
    $manifest.changes = $changes
    Write-POJsonAtomic -Path $manifestPath -Object $manifest
}

function Set-POActivePowerPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][guid]$Guid)
    & powercfg.exe /setactive $Guid.ToString() 2>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "powercfg /setactive failed with exit code $exitCode." }
    $actual = Get-POActivePowerPlanGuid
    if ($actual -ne $Guid.ToString().ToLowerInvariant()) { throw "Power-plan verification failed. Requested $Guid; Windows reports $actual." }
    return $actual
}

function Restore-POPowerPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath, [Parameter(Mandatory = $true)][psobject]$Manifest)
    $statePath = Join-Path $BackupPath 'power\active-plan.json'
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if (-not $state.ActivePlanGuid) { throw 'The backup does not contain an active power-plan GUID.' }
    $guid = [string]$state.ActivePlanGuid
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParse($guid, [ref]$parsedGuid)) { throw 'The backup contains an invalid active power-plan GUID.' }
    $change = @($Manifest.changes | Where-Object { $_.section -eq 'power' } | Select-Object -Last 1)
    if ($change.Count -eq 0 -or $change[0].id -ne 'power-plan') { throw 'No supported power-plan change was recorded in this backup.' }
    if ([string]$change[0].fromGuid -ne $guid) { throw 'The transaction ledger and saved original power-plan GUID do not match.' }
    $targetGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$change[0].toGuid, [ref]$targetGuid)) { throw 'The recorded target power-plan GUID is invalid.' }
    $allowedTargets = @((Get-POBuiltinPlanGuid 'balanced'), (Get-POBuiltinPlanGuid 'high-performance'), (Get-POBuiltinPlanGuid 'power-saver'), (Get-POBuiltinPlanGuid 'ultimate-performance'))
    if ($targetGuid.ToString() -notin $allowedTargets) { throw 'The recorded target is not a supported built-in Windows power plan.' }
    $currentActive = Get-POActivePowerPlanGuid
    if ([string]::IsNullOrWhiteSpace($currentActive)) { throw 'The current active power plan could not be read; restore was blocked.' }
    if ($currentActive -eq $parsedGuid.ToString()) { return }
    if ($currentActive -ne $targetGuid.ToString()) { throw 'The active power plan changed after Platinum Optimizer applied its plan; refusing to overwrite that newer user choice.' }
    $available = @(Get-POPowerPlans | Where-Object { $_.Guid -eq $guid })
    if ($available.Count -eq 0 -and $state.ExportFile) {
        $exportRelative = [string]$state.ExportFile
        if ($exportRelative -ne 'power\active-plan.pow' -and $exportRelative -ne 'power/active-plan.pow') { throw 'The backup contains an invalid power-plan export path.' }
        $export = Join-Path $BackupPath $exportRelative
        if (Test-Path -LiteralPath $export -PathType Leaf) {
            & powercfg.exe /import $export $guid 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Power-plan restore import failed with exit code $LASTEXITCODE." }
        }
    }
    [void](Set-POActivePowerPlan -Guid ([guid]$guid))
}

function Restore-PONetworkDns {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath,
          [Parameter(Mandatory = $true)][psobject]$Manifest)
    $change = @($Manifest.changes | Where-Object { $_.section -eq 'network' } | Select-Object -Last 1)
    if ($change.Count -eq 0 -or $change[0].id -ne 'dns-provider') { throw 'No supported DNS-provider change was recorded in this backup.' }
    $index = 0
    if (-not [int]::TryParse([string]$change[0].interfaceIndex, [ref]$index) -or $index -lt 0) { throw 'The recorded network interface index is invalid.' }
    $ledgerGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$change[0].interfaceGuid, [ref]$ledgerGuid)) { throw 'The recorded adapter identity is missing or invalid.' }
    $statePath = Join-Path $BackupPath 'network\dns-before.json'
    $states = @(Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    $state = @($states | Where-Object { [int]$_.InterfaceIndex -eq $index } | Select-Object -First 1)
    if ($state.Count -eq 0) { throw "The DNS backup for adapter index $index is missing." }
    $savedGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$state[0].InterfaceGuid, [ref]$savedGuid) -or $savedGuid -ne $ledgerGuid) { throw 'The adapter identity in the transaction ledger does not match the saved DNS snapshot.' }
    if (-not $state[0].IPv4DnsReadable -or -not $state[0].DhcpEnabled -or $state[0].DnsConfigState -ne 'AUTOMATIC/DHCP') { throw 'The original adapter IPv4 DNS, DHCP, and automatic-DNS state were not all verified; automatic DNS rollback is blocked.' }
    $adapter = Get-NetAdapter -InterfaceIndex $index -ErrorAction Stop
    if ([string]$adapter.InterfaceGuid -ne $ledgerGuid.ToString()) { throw 'The interface index now belongs to a different adapter; refusing to change it.' }
    if ($adapter.Status -ne 'Up' -or -not $adapter.HardwareInterface) { throw 'The original adapter is not a connected physical interface; restore was blocked.' }
    $current = Get-POCurrentAdapterDns -InterfaceIndex $index
    if (-not $current.IPv4DnsReadable -or $current.InterfaceGuid -ne $ledgerGuid.ToString()) { throw 'Current DNS or adapter identity could not be verified; restore was blocked.' }
    if ($null -eq $current.DhcpEnabled -or -not $current.DhcpEnabled) { throw 'The adapter current IP configuration is not verified as DHCP; restore was blocked.' }
    if ($current.DnsConfigState -eq 'AUTOMATIC/DHCP') { return }
    if ($current.DnsConfigState -ne 'STATIC OVERRIDE PRESENT') { throw "Current DNS mode is '$($current.DnsConfigState)'; policy-managed or unknown state is not overwritten." }
    if (-not $change[0].PSObject.Properties['afterIPv4'] -or [string]$change[0].status -ne 'APPLIED_VERIFIED') { throw 'The verified post-change resolver list is unavailable; refusing to overwrite potentially newer DNS settings.' }
    $currentServers = @($current.IPv4DnsServers | ForEach-Object { [string]$_ })
    $recordedServers = @($change[0].afterIPv4 | ForEach-Object { [string]$_ })
    if (($currentServers -join '|') -ne ($recordedServers -join '|')) { throw 'DNS servers changed after Platinum Optimizer applied them; review current DNS manually before restoring.' }
    Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction Stop
    $after = Get-POCurrentAdapterDns -InterfaceIndex $index
    if (-not $after.IPv4DnsReadable -or -not $after.DhcpEnabled -or $after.DnsConfigState -ne 'AUTOMATIC/DHCP' -or $after.InterfaceGuid -ne $ledgerGuid.ToString()) { throw 'The adapter DNS reset completed but the IPv4 DNS, DHCP, automatic-DNS, and adapter-identity state could not be verified.' }
}

function Restore-PORegistryChanges {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath,
          [Parameter(Mandatory = $true)][psobject]$Manifest)
    $registryChanges = @($Manifest.changes | Where-Object { $_.section -eq 'registry' })
    if ($registryChanges.Count -eq 0) { throw 'No registry change was recorded in this backup.' }
    $snapshots = @(Get-Content -LiteralPath (Join-Path $BackupPath 'registry\game-settings-before.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    foreach ($change in $registryChanges) {
        $state = @($snapshots | Where-Object { $_.Hive -eq $change.hive -and $_.SubKey -eq $change.subKey -and $_.ValueName -eq $change.valueName } | Select-Object -First 1)
        if ($state.Count -eq 0) { throw "Registry snapshot missing for $($change.subKey)\$($change.valueName)." }
        if (-not $state[0].Readable) { throw "Registry snapshot was unreadable for $($change.subKey)\$($change.valueName)." }
        $allowedKeys = @(
            'Software\Microsoft\GameBar|AutoGameModeEnabled',
            'Software\Microsoft\GameBar|AllowAutoGameMode',
            'System\GameConfigStore|GameDVR_Enabled',
            'Software\Microsoft\Windows\CurrentVersion\GameDVR|AppCaptureEnabled'
        )
        $targetKey = "$($state[0].SubKey)|$($state[0].ValueName)"
        if ($state[0].Hive -ne 'CurrentUser' -or $targetKey -notin $allowedKeys) { throw "Registry restore target is not on the allowlist: $targetKey." }
        Set-PORegValueState -State $state[0]
        $verify = Get-PORegValueState -Hive $state[0].Hive -SubKey $state[0].SubKey -ValueName $state[0].ValueName
        if (-not $verify.Readable -or $verify.Exists -ne $state[0].Exists -or ($verify.Exists -and ($verify.Kind -ne $state[0].Kind -or (ConvertTo-Json $verify.Data -Compress) -ne (ConvertTo-Json $state[0].Data -Compress)))) {
            throw "Registry restore verification failed for $($state[0].SubKey)\$($state[0].ValueName)."
        }
    }
}

function Restore-POBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][string]$BackupPath)
    $fullPath = [System.IO.Path]::GetFullPath($BackupPath)
    $root = Get-POPathRootPrefix -Path (Get-POBackupRoot)
    if (-not $fullPath.StartsWith($root, (Get-POPathComparison))) { throw 'Restore is limited to backups inside the Platinum Optimizer backup directory.' }
    $validation = Test-POBackup -Path $fullPath
    if (-not $validation.Valid) { throw ('Backup validation failed: ' + (@($validation.Issues) -join '; ')) }
    $manifest = $validation.Manifest
    $allowedSections = @('power', 'network', 'registry')
    $sections = @($manifest.modifiedSections | Select-Object -Unique)
    $unknownSections = @($sections | Where-Object { $_ -notin $allowedSections })
    if ($unknownSections.Count -gt 0) { throw ('Backup contains unsupported restore sections: ' + ($unknownSections -join ', ')) }
    $changeSections = @($manifest.changes | ForEach-Object { if ($null -ne $_ -and $null -ne $_.PSObject.Properties['section']) { [string]$_.PSObject.Properties['section'].Value } else { '' } } | Select-Object -Unique)
    $unknownChangeSections = @($changeSections | Where-Object { $_ -notin $allowedSections -or [string]::IsNullOrWhiteSpace([string]$_) })
    if ($unknownChangeSections.Count -gt 0) { throw ('Backup contains invalid change-ledger sections: ' + ($unknownChangeSections -join ', ')) }
    foreach ($section in $sections) {
        if (@($manifest.changes | Where-Object { $_.section -eq $section }).Count -eq 0) { throw "Restore section '$section' has no matching change-ledger entry." }
    }
    foreach ($section in $changeSections) {
        if ($section -notin $sections) { throw "Change-ledger section '$section' is not listed in modifiedSections." }
    }
    if ($sections.Count -eq 0) { return [pscustomobject]@{ Status = 'NO_CHANGES'; Message = 'This backup has no optimizer changes to restore.'; Restored = @() } }
    if (-not $PSCmdlet.ShouldProcess($manifest.id, 'Restore recorded Platinum Optimizer changes')) {
        return [pscustomobject]@{ Status = 'SIMULATED'; Message = 'Restore was not executed.'; Restored = @() }
    }
    if (-not (Test-POIsAdministrator)) { throw 'Restoring system settings requires an elevated Administrator session.' }
    $restored = @(); $failures = @()
    foreach ($section in $sections) {
        try {
            switch ($section) {
                'power' { Restore-POPowerPlan -BackupPath $fullPath -Manifest $manifest }
                'network' { Restore-PONetworkDns -BackupPath $fullPath -Manifest $manifest }
                'registry' { Restore-PORegistryChanges -BackupPath $fullPath -Manifest $manifest }
                default { throw "No restore handler exists for changed section '$section'; no further sections were attempted." }
            }
            $restored += $section
            Write-POLog -Category 'Restore' -Status 'VERIFIED' -Message "Restored section '$section' from $($manifest.id)."
        }
        catch {
            $failures += "${section}: $($_.Exception.Message)"
            Write-POLog -Level 'CRITICAL' -Category 'Restore' -Status 'FAILED' -Message $failures[-1]
            break
        }
    }
    $history = @($manifest.restoreHistory)
    $history += [pscustomobject]@{ timestampUtc = [DateTime]::UtcNow.ToString('o'); restoredSections = $restored; failures = $failures }
    $manifest.restoreHistory = $history
    Write-POJsonAtomic -Path (Join-Path $fullPath 'manifest.json') -Object $manifest
    if ($failures.Count -gt 0) { return [pscustomobject]@{ Status = 'PARTIAL_FAILURE'; Message = 'Restore stopped after a failed section.'; Restored = $restored; Failures = $failures } }
    return [pscustomobject]@{ Status = 'RESTORED'; Message = 'Recorded changes were restored and verified.'; Restored = $restored; Failures = @() }
}

function Invoke-POProfilePlan {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][psobject]$Plan, [switch]$ConfirmAdvanced)
    if ($null -eq $Plan.Change) {
        return [pscustomobject]@{ Status = 'NO_CHANGES'; Message = 'No compatible power-plan change is needed. Recommendations are read-only.'; Backup = $null }
    }
    if (-not (Test-POIsWindows)) { throw 'This operation is available only on Windows.' }
    $profileId = [string]$Plan.ProfileId
    $profile = @(Get-POProfileCatalog | Where-Object { $_.id -eq $profileId } | Select-Object -First 1)
    if ($profile.Count -eq 0) { throw 'The reviewed profile is unknown; create a new preview.' }

    $currentBefore = Get-POActivePowerPlanGuid
    $systemSnapshot = Get-POSystemSnapshot
    $powerPlans = @(Get-POPowerPlans)
    $freshPlan = New-POProfilePlan -ProfileId $profileId -SystemSnapshot $systemSnapshot -PowerPlans $powerPlans -ActivePlanGuid $currentBefore
    if (-not $freshPlan.Change) { throw 'Hardware, power source, or plan availability changed after preview; review a fresh plan before applying.' }
    if ([string]$Plan.CurrentPowerPlanGuid -ne [string]$currentBefore -or [string]$Plan.Change.ToGuid -ne [string]$freshPlan.Change.ToGuid) {
        throw 'The active power plan or target changed after preview; review the refreshed plan before applying.'
    }
    $allowedPlans = @((Get-POBuiltinPlanGuid 'balanced'), (Get-POBuiltinPlanGuid 'high-performance'), (Get-POBuiltinPlanGuid 'power-saver'), (Get-POBuiltinPlanGuid 'ultimate-performance'))
    if ([string]$freshPlan.Change.ToGuid -notin $allowedPlans) { throw 'The proposed target is not one of the supported built-in Windows power plans.' }
    if (-not $PSCmdlet.ShouldProcess($freshPlan.TargetPowerPlanName, "Activate existing power plan for $($freshPlan.ProfileName)")) {
        return [pscustomobject]@{ Status = 'SIMULATED'; Message = 'Dry run only; no backup or system setting was changed.'; Backup = $null }
    }
    if ($profile[0].requiresExplicitHighRiskConfirmation -and -not $ConfirmAdvanced) { throw 'This profile requires a separate explicit thermal/power risk confirmation.' }
    if (-not (Test-POIsAdministrator)) { throw 'Administrator permission is required. Reopen Platinum Optimizer as Administrator only if you choose to apply.' }

    $backup = New-POBackup
    $powerStatePath = Join-Path $backup.Path 'power\active-plan.json'
    $powerState = Get-Content -LiteralPath $powerStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $from = [string]$powerState.ActivePlanGuid
    if ([string]::IsNullOrWhiteSpace($from) -or $from -ne [string]$currentBefore -or (Get-POActivePowerPlanGuid) -ne $from) {
        throw 'The active power plan changed during backup or could not be recorded; no change was applied. Preview again.'
    }
    $changeRecord = [pscustomobject][ordered]@{
        section = 'power'; id = 'power-plan'; name = 'Active Windows power plan'; fromGuid = $from; toGuid = [string]$freshPlan.Change.ToGuid; target = [string]$freshPlan.TargetPowerPlanName; status = 'APPLYING'; timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    Add-POBackupChange -BackupPath $backup.Path -Section power -Change $changeRecord
    try {
        if ((Get-POActivePowerPlanGuid) -ne $from) { throw 'The active plan changed immediately before apply; the newer selection was left untouched.' }
        [void](Set-POActivePowerPlan -Guid ([guid]$freshPlan.Change.ToGuid))
        Update-POBackupChangeStatus -BackupPath $backup.Path -Section power -Status 'APPLIED_VERIFIED' -Message "Activated $($freshPlan.TargetPowerPlanName)."
        Write-POLog -Category 'Power' -TweakId 'power-plan' -Status 'APPLIED_VERIFIED' -Message "Activated $($freshPlan.TargetPowerPlanName)." -Command "powercfg /setactive $($freshPlan.Change.ToGuid)" -ExitCode 0
        return [pscustomobject]@{ Status = 'APPLIED_VERIFIED'; Message = "Activated $($freshPlan.TargetPowerPlanName); the prior plan is backed up."; Backup = $backup; RequiresReboot = $false }
    }
    catch {
        $originalError = $_.Exception.Message
        Write-POLog -Level 'ERROR' -Category 'Power' -TweakId 'power-plan' -Status 'FAILED' -Message $originalError -Command "powercfg /setactive $($freshPlan.Change.ToGuid)"
        $rollbackStatus = 'ROLLBACK_SKIPPED_ACTIVE_PLAN_UNKNOWN'
        $activeAfterFailure = Get-POActivePowerPlanGuid
        if ($activeAfterFailure -eq $from) {
            $rollbackStatus = 'NOT_APPLIED_OR_ORIGINAL_STILL_ACTIVE'
        }
        elseif ($activeAfterFailure -eq [string]$freshPlan.Change.ToGuid) {
            try {
                [void](Set-POActivePowerPlan -Guid ([guid]$from))
                $rollbackStatus = 'ROLLED_BACK_VERIFIED'
                Write-POLog -Level 'WARNING' -Category 'Power' -TweakId 'power-plan' -Status $rollbackStatus -Message 'Restored the original active plan after apply/verification failure.'
            }
            catch {
                $rollbackStatus = 'ROLLBACK_FAILED'
                Write-POLog -Level 'CRITICAL' -Category 'Power' -TweakId 'power-plan' -Status $rollbackStatus -Message $_.Exception.Message
            }
        }
        else {
            $rollbackStatus = 'ROLLBACK_SKIPPED_NEWER_PLAN_ACTIVE'
            Write-POLog -Level 'CRITICAL' -Category 'Power' -TweakId 'power-plan' -Status $rollbackStatus -Message "The active plan is '$activeAfterFailure', not the original or optimizer target; it was left untouched."
        }
        try { Update-POBackupChangeStatus -BackupPath $backup.Path -Section power -Status $rollbackStatus -Message $originalError }
        catch { Write-POLog -Level 'CRITICAL' -Category 'Backup' -Status 'TRANSACTION_STATUS_WRITE_FAILED' -Message $_.Exception.Message }
        return [pscustomobject]@{ Status = 'FAILED'; Message = $originalError; Rollback = $rollbackStatus; Backup = $backup }
    }
}

function Test-POIPv4DnsAddresses {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Addresses)
    if ($Addresses.Count -lt 1 -or $Addresses.Count -gt 4) { return [pscustomobject]@{ Valid = $false; Message = 'Enter between one and four IPv4 DNS server addresses.'; Addresses = @() } }
    $normalized = @()
    foreach ($address in $Addresses) {
        $candidate = ([string]$address).Trim()
        if ($candidate -notmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$') {
            return [pscustomobject]@{ Valid = $false; Message = "Enter standard dotted-decimal IPv4 DNS addresses (a.b.c.d): $candidate"; Addresses = @() }
        }
        $parsed = $null
        if (-not [System.Net.IPAddress]::TryParse($candidate, [ref]$parsed) -or $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return [pscustomobject]@{ Valid = $false; Message = "Invalid IPv4 DNS server address: $candidate"; Addresses = @() }
        }
        if ($parsed.Equals([System.Net.IPAddress]::Any) -or $parsed.Equals([System.Net.IPAddress]::Broadcast) -or $parsed.GetAddressBytes()[0] -ge 224) {
            return [pscustomobject]@{ Valid = $false; Message = "This is not a usable unicast IPv4 DNS server address: $candidate"; Addresses = @() }
        }
        $normalized += $parsed.ToString()
    }
    return [pscustomobject]@{ Valid = $true; Message = 'Valid IPv4 DNS server addresses.'; Addresses = $normalized }
}

function Set-PODnsProvider {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][int]$InterfaceIndex,
        [Parameter(Mandatory = $true)][ValidateSet('Automatic', 'Cloudflare', 'Google', 'Quad9', 'Custom')][string]$Provider,
        [string[]]$CustomServers = @(),
        [string]$ExpectedInterfaceGuid = '',
        [string[]]$ExpectedIPv4DnsServers = $null
    )
    if (-not (Test-POIsWindows)) { throw 'DNS changes are available only on Windows.' }
    if (-not (Get-Command Set-DnsClientServerAddress -ErrorAction SilentlyContinue)) { throw 'The Windows DnsClient module is unavailable.' }
    $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Stop
    $before = Get-POCurrentAdapterDns -InterfaceIndex $InterfaceIndex
    if ([string]$adapter.InterfaceGuid -ne [string]$before.InterfaceGuid) { throw 'The network adapter changed during preflight; refresh the list and review again.' }
    $eligibility = Test-POAdapterDnsEligibility -AdapterState $before
    if (-not $eligibility.Eligible) { throw ($eligibility.Reasons -join ' ') }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedInterfaceGuid) -and $before.InterfaceGuid -ne $ExpectedInterfaceGuid) { throw 'The selected adapter identity changed since preview; refresh the adapter and review again.' }
    if ($PSBoundParameters.ContainsKey('ExpectedIPv4DnsServers')) {
        $expectedDnsJson = ConvertTo-Json -InputObject @($ExpectedIPv4DnsServers) -Compress
        $currentDnsJson = ConvertTo-Json -InputObject @($before.IPv4DnsServers) -Compress
        if ($expectedDnsJson -ne $currentDnsJson) { throw 'The current IPv4 DNS server list changed since preview; review the refreshed adapter details.' }
    }
    if ($Provider -eq 'Automatic') { return [pscustomobject]@{ Status = 'NO_CHANGES'; Message = 'This adapter already uses verified automatic/DHCP DNS; no reset or backup was needed.'; Backup = $null } }
    $serverAddresses = @()
    switch ($Provider) {
        'Automatic' { $serverAddresses = @() }
        'Cloudflare' { $serverAddresses = @('1.1.1.1', '1.0.0.1') }
        'Google' { $serverAddresses = @('8.8.8.8', '8.8.4.4') }
        'Quad9' { $serverAddresses = @('9.9.9.9', '149.112.112.112') }
        'Custom' { $serverAddresses = @($CustomServers) }
    }
    if ($Provider -ne 'Automatic') {
        $validated = Test-POIPv4DnsAddresses -Addresses $serverAddresses
        if (-not $validated.Valid) { throw $validated.Message }
        $serverAddresses = @($validated.Addresses)
    }
    $description = if ($Provider -eq 'Automatic') { 'Reset adapter DNS to automatic/DHCP' } else { "Set adapter DNS to $($serverAddresses -join ', ')" }
    if (-not $PSCmdlet.ShouldProcess($adapter.Name, $description)) {
        return [pscustomobject]@{ Status = 'SIMULATED'; Message = "Would $description on $($adapter.Name)."; Backup = $null }
    }
    if (-not (Test-POIsAdministrator)) { throw 'Administrator permission is required to change adapter DNS.' }
    $backup = New-POBackup -NetworkInterfaceIndex $InterfaceIndex
    $backupDnsPath = Join-Path $backup.Path 'network\dns-before.json'
    $backupDnsStates = @(Get-Content -LiteralPath $backupDnsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    $backupDns = @($backupDnsStates | Where-Object { [int]$_.InterfaceIndex -eq $InterfaceIndex } | Select-Object -First 1)
    if ($backupDns.Count -eq 0 -or $backupDns[0].InterfaceGuid -ne $before.InterfaceGuid -or -not $backupDns[0].IPv4DnsReadable -or -not $backupDns[0].DhcpEnabled -or $backupDns[0].DnsConfigState -ne 'AUTOMATIC/DHCP') {
        throw 'The backup did not confirm the same adapter identity, readable IPv4 DNS state, DHCP, and automatic DNS mode; no resolver change was applied.'
    }
    $beforeServers = ConvertTo-Json -InputObject @($before.IPv4DnsServers) -Compress
    $backupServers = ConvertTo-Json -InputObject @($backupDns[0].IPv4DnsServers) -Compress
    if ($beforeServers -ne $backupServers) { throw 'DNS state changed while the backup was being created; no resolver change was applied. Review the adapter and retry.' }
    $immediatelyBefore = Get-POCurrentAdapterDns -InterfaceIndex $InterfaceIndex
    $immediateEligibility = Test-POAdapterDnsEligibility -AdapterState $immediatelyBefore
    $immediateServers = ConvertTo-Json -InputObject @($immediatelyBefore.IPv4DnsServers) -Compress
    if (-not $immediateEligibility.Eligible -or $immediatelyBefore.InterfaceGuid -ne $before.InterfaceGuid -or $immediateServers -ne $beforeServers) {
        throw 'Adapter or DNS state changed immediately before apply; no resolver change was made. Review the adapter and retry.'
    }
    $changeRecord = [pscustomobject][ordered]@{
        section = 'network'; id = 'dns-provider'; name = "DNS resolver ($($adapter.Name))"; interfaceIndex = $InterfaceIndex; interfaceGuid = [string]$before.InterfaceGuid; interfaceDescription = [string]$before.InterfaceDescription; provider = $Provider; beforeIPv4 = @($before.IPv4DnsServers); afterIPv4 = @(); status = 'APPLYING'; timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    Add-POBackupChange -BackupPath $backup.Path -Section network -Change $changeRecord
    try {
        if ($Provider -eq 'Automatic') { Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ResetServerAddresses -ErrorAction Stop }
        else { Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $serverAddresses -ErrorAction Stop }
        $after = Get-POCurrentAdapterDns -InterfaceIndex $InterfaceIndex
        if ($Provider -eq 'Automatic') {
            if (-not $after.IPv4DnsReadable -or -not $after.DhcpEnabled -or $after.DnsConfigState -ne 'AUTOMATIC/DHCP' -or $after.InterfaceGuid -ne $before.InterfaceGuid) { throw 'DNS reset returned without verifiable IPv4 DNS, adapter identity, and automatic/DHCP state.' }
        }
        else {
            if (-not $after.IPv4DnsReadable) { throw "Changed IPv4 DNS state could not be read: $($after.IPv4DnsReadError)" }
            if ($after.InterfaceGuid -ne $before.InterfaceGuid -or $after.Status -ne 'Up' -or -not $after.HardwareInterface -or -not $after.DhcpEnabled) { throw 'Adapter identity, connected physical status, or DHCP state changed during DNS apply.' }
            if ($after.DnsConfigState -ne 'STATIC OVERRIDE PRESENT') { throw 'Windows did not report the expected per-interface static DNS override after the change.' }
            $actual = @($after.IPv4DnsServers | ForEach-Object { [string]$_ })
            if (($actual -join '|') -ne ($serverAddresses -join '|')) { throw "DNS verification failed; Windows reported '$($actual -join ', ')' instead of '$($serverAddresses -join ', ')'." }
        }
        $verifiedDnsServers = @($after.IPv4DnsServers)
        Update-POBackupChangeStatus -BackupPath $backup.Path -Section network -Status 'APPLIED_VERIFIED' -Message "$description on $($adapter.Name)." -AfterIPv4 $verifiedDnsServers
        Write-POLog -Category 'Network' -TweakId 'dns-provider' -Status 'APPLIED_VERIFIED' -Message "$description on $($adapter.Name)." -Command 'Set-DnsClientServerAddress' -ExitCode 0
        return [pscustomobject]@{ Status = 'APPLIED_VERIFIED'; Message = "$description. DNS changes may affect name resolution only; game-server latency is not guaranteed to change."; Backup = $backup }
    }
    catch {
        $failure = $_.Exception.Message
        Write-POLog -Level 'ERROR' -Category 'Network' -TweakId 'dns-provider' -Status 'FAILED' -Message $failure -Command 'Set-DnsClientServerAddress'
        $rollback = 'ROLLBACK_SKIPPED_CURRENT_STATE_UNVERIFIED'
        $failureState = $null
        try { $failureState = Get-POCurrentAdapterDns -InterfaceIndex $InterfaceIndex }
        catch { $rollback = "ROLLBACK_SKIPPED_QUERY_FAILED: $($_.Exception.Message)" }
        if ($failureState) {
            if ($failureState.InterfaceGuid -ne $before.InterfaceGuid) { $rollback = 'ROLLBACK_SKIPPED_ADAPTER_CHANGED' }
            elseif ($failureState.Status -ne 'Up' -or -not $failureState.HardwareInterface) { $rollback = 'ROLLBACK_SKIPPED_ADAPTER_NOT_CONNECTED_PHYSICAL' }
            elseif (-not $failureState.IPv4DnsReadable) { $rollback = 'ROLLBACK_SKIPPED_DNS_UNREADABLE' }
            elseif (-not $failureState.DhcpEnabled) { $rollback = 'ROLLBACK_SKIPPED_DHCP_STATE_CHANGED' }
            elseif ($failureState.DnsConfigState -eq 'AUTOMATIC/DHCP') { $rollback = 'ROLLED_BACK_VERIFIED' }
            elseif ($failureState.DnsConfigState -eq 'STATIC OVERRIDE PRESENT') {
                $failureServers = @($failureState.IPv4DnsServers | ForEach-Object { [string]$_ })
                if (($failureServers -join '|') -ne ($serverAddresses -join '|')) { $rollback = 'ROLLBACK_SKIPPED_DNS_CHANGED_AFTER_APPLY' }
                else {
                    $rollbackState = $null
                    try { $rollbackState = Get-POCurrentAdapterDns -InterfaceIndex $InterfaceIndex }
                    catch { $rollback = "ROLLBACK_SKIPPED_QUERY_FAILED: $($_.Exception.Message)" }
                    if ($rollbackState) {
                        if ($rollbackState.InterfaceGuid -ne $before.InterfaceGuid) { $rollback = 'ROLLBACK_SKIPPED_ADAPTER_CHANGED' }
                        elseif ($rollbackState.Status -ne 'Up' -or -not $rollbackState.HardwareInterface) { $rollback = 'ROLLBACK_SKIPPED_ADAPTER_NOT_CONNECTED_PHYSICAL' }
                        elseif (-not $rollbackState.IPv4DnsReadable) { $rollback = 'ROLLBACK_SKIPPED_DNS_UNREADABLE' }
                        elseif (-not $rollbackState.DhcpEnabled) { $rollback = 'ROLLBACK_SKIPPED_DHCP_STATE_CHANGED' }
                        elseif ($rollbackState.DnsConfigState -eq 'AUTOMATIC/DHCP') { $rollback = 'ROLLED_BACK_VERIFIED' }
                        elseif ($rollbackState.DnsConfigState -ne 'STATIC OVERRIDE PRESENT') { $rollback = 'ROLLBACK_SKIPPED_POLICY_OR_DNS_MODE_CHANGED' }
                        else {
                            $confirmedServers = @($rollbackState.IPv4DnsServers | ForEach-Object { [string]$_ })
                            if (($confirmedServers -join '|') -ne ($serverAddresses -join '|')) { $rollback = 'ROLLBACK_SKIPPED_DNS_CHANGED_AFTER_APPLY' }
                            else {
                                try {
                                    Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                                    $verify = Get-POCurrentAdapterDns -InterfaceIndex $InterfaceIndex
                                    if ($verify.InterfaceGuid -eq $before.InterfaceGuid -and $verify.Status -eq 'Up' -and $verify.HardwareInterface -and $verify.IPv4DnsReadable -and $verify.DhcpEnabled -and $verify.DnsConfigState -eq 'AUTOMATIC/DHCP') { $rollback = 'ROLLED_BACK_VERIFIED' }
                                    else { $rollback = 'ROLLBACK_FAILED: Adapter identity or DHCP/automatic DNS state did not verify.' }
                                }
                                catch { $rollback = "ROLLBACK_FAILED: $($_.Exception.Message)" }
                            }
                        }
                    }
                }
            }
            else { $rollback = 'ROLLBACK_SKIPPED_POLICY_OR_DNS_MODE_CHANGED' }
        }
        Write-POLog -Level $(if ($rollback -like 'ROLLBACK_FAILED*' -or $rollback -like 'ROLLBACK_SKIPPED*') { 'CRITICAL' } else { 'WARNING' }) -Category 'Network' -TweakId 'dns-provider' -Status $rollback -Message 'Rollback was verified, skipped, or failed after DNS apply/verification failure.'
        try { Update-POBackupChangeStatus -BackupPath $backup.Path -Section network -Status $rollback -Message $failure }
        catch { Write-POLog -Level 'CRITICAL' -Category 'Backup' -Status 'TRANSACTION_STATUS_WRITE_FAILED' -Message $_.Exception.Message }
        return [pscustomobject]@{ Status = 'FAILED'; Message = "$failure Rollback result: $rollback. Backup retained: $($backup.Id)."; Rollback = $rollback; Backup = $backup }
    }
}

function Get-POUserTempPreview {
    [CmdletBinding()]
    param([ValidateRange(1, 365)][int]$MinimumAgeDays = 7)
    $temp = [Environment]::GetEnvironmentVariable('TEMP', 'User')
    if ([string]::IsNullOrWhiteSpace($temp)) { $temp = $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($temp) -or -not (Test-Path -LiteralPath $temp -PathType Container)) { throw "The current user's TEMP directory could not be resolved." }
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'The current user profile LocalAppData folder could not be resolved.' }
    $canonical = [System.IO.Path]::GetFullPath($temp).TrimEnd('\')
    $expectedTemp = [System.IO.Path]::GetFullPath((Join-Path $localAppData 'Temp')).TrimEnd('\')
    if (-not $canonical.Equals($expectedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup refused: TEMP does not resolve to this user's LocalAppData\Temp folder ($canonical)." }
    $rootItem = Get-Item -LiteralPath $canonical -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Cleanup refused: the current TEMP directory is a reparse point.' }
    $rootPrefix = $canonical.TrimEnd('\') + '\'
    $cutoff = (Get-Date).AddDays(-$MinimumAgeDays)
    $items = @(); $errors = @(); $skippedReparsePoints = 0
    $directories = New-Object 'System.Collections.Generic.Stack[string]'
    $directories.Push($canonical)
    while ($directories.Count -gt 0) {
        $directory = $directories.Pop()
        try { $entries = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
        catch { $errors += "Could not inspect $directory`: $($_.Exception.Message)"; continue }
        foreach ($entry in $entries) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $skippedReparsePoints++; continue }
            if ($entry.PSIsContainer) { $directories.Push($entry.FullName); continue }
            $fullPath = [System.IO.Path]::GetFullPath($entry.FullName)
            if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($entry.LastWriteTime -lt $cutoff) {
                $items += [pscustomobject]@{ FullName = $fullPath; Length = [long]$entry.Length; LastWriteTime = $entry.LastWriteTime }
            }
        }
    }
    return [pscustomobject][ordered]@{
        Root = $canonical
        MinimumAgeDays = $MinimumAgeDays
        FileCount = $items.Count
        TotalBytes = [long](($items | Measure-Object -Property Length -Sum).Sum)
        Files = $items
        Errors = $errors
        SkippedReparsePoints = $skippedReparsePoints
        Reversible = $false
        Note = 'Preview only. Reparse points are not traversed; files can be in use. No Windows, driver, update, shader, browser, or application cache locations are included.'
    }
}

function Clear-POUserTemp {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][psobject]$Preview)
    if (-not $Preview.Root) { throw 'Cleanup preview has no root; run a new preview.' }
    if (@($Preview.Errors).Count -gt 0) { throw 'Cleanup preview was incomplete because some folders could not be inspected; resolve the errors and run a new preview.' }
    if (-not $Preview.Files) { return [pscustomobject]@{ Status = 'NO_FILES'; Deleted = 0; Errors = @() } }
    if ($null -eq $Preview.MinimumAgeDays -or [int]$Preview.MinimumAgeDays -lt 1 -or [int]$Preview.MinimumAgeDays -gt 365) { throw 'Preview age is invalid; run a new preview.' }
    if (-not $PSCmdlet.ShouldProcess("$($Preview.FileCount) old files in $($Preview.Root)", 'Delete user temporary files (not reversible)')) {
        return [pscustomobject]@{ Status = 'SIMULATED'; Deleted = 0; Errors = @() }
    }
    $currentTemp = [Environment]::GetEnvironmentVariable('TEMP', 'User')
    if ([string]::IsNullOrWhiteSpace($currentTemp)) { $currentTemp = $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($currentTemp)) { throw 'Current TEMP cannot be resolved; no files were deleted.' }
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'The current user profile LocalAppData folder could not be resolved.' }
    $currentRoot = [System.IO.Path]::GetFullPath($currentTemp).TrimEnd('\')
    $expectedTemp = [System.IO.Path]::GetFullPath((Join-Path $localAppData 'Temp')).TrimEnd('\')
    $previewRoot = [System.IO.Path]::GetFullPath([string]$Preview.Root).TrimEnd('\')
    if (-not $currentRoot.Equals($expectedTemp, [StringComparison]::OrdinalIgnoreCase) -or -not $previewRoot.Equals($expectedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw "The current user's TEMP directory changed or is outside LocalAppData\Temp; run a new preview." }
    $rootItem = Get-Item -LiteralPath $previewRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Cleanup refused: the current TEMP directory is a reparse point.' }
    $rootPrefix = $previewRoot.TrimEnd('\') + '\'
    $cutoff = (Get-Date).AddDays(-[int]$Preview.MinimumAgeDays)
    $deleted = 0; $errors = @()
    foreach ($item in @($Preview.Files)) {
        try {
            $fullPath = [System.IO.Path]::GetFullPath([string]$item.FullName)
            if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Preview entry is outside the current TEMP directory.' }
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
            $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Preview entry became a reparse point.' }
            if ($file.LastWriteTime -ge $cutoff) { throw 'Preview entry is no longer older than the selected minimum age.' }
            if ([long]$file.Length -ne [long]$item.Length -or ([datetime]$file.LastWriteTime -ne [datetime]$item.LastWriteTime)) { throw 'Preview entry changed after review; run a new preview.' }
            Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            $deleted++
        }
        catch { $errors += "$($item.FullName): $($_.Exception.Message)" }
    }
    $status = if ($errors.Count -eq 0) { 'COMPLETED' } else { 'PARTIAL_FAILURE' }
    Write-POLog -Level $(if ($errors.Count -gt 0) { 'WARNING' } else { 'INFO' }) -Category 'Storage' -TweakId 'temporary-cleanup' -Status $status -Message "Deleted $deleted user temporary files; $($errors.Count) failed."
    return [pscustomobject]@{ Status = $status; Deleted = $deleted; Errors = $errors; Reversible = $false }
}

function Get-POResourceSample {
    [CmdletBinding()]
    param()
    $cpu = $null; $ram = $null; $disk = $null
    try { $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop } catch { }
    try { $ram = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop } catch { }
    try { $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop } catch { }
    return [pscustomobject][ordered]@{
        CpuPercent = if ($cpu -and $null -ne $cpu.PercentProcessorTime) { [math]::Round([double]$cpu.PercentProcessorTime, 1) } else { $null }
        AvailableMemoryGB = if ($ram -and $null -ne $ram.AvailableMBytes) { [math]::Round(([double]$ram.AvailableMBytes / 1024), 1) } else { $null }
        DiskActivePercent = if ($disk -and $null -ne $disk.PercentDiskTime) { [math]::Round([double]$disk.PercentDiskTime, 1) } else { $null }
        GpuPercent = $null
        PingMs = $null
        GpuNote = 'Not measured by the generic Windows CIM path'
        PingNote = 'Run a user-initiated network test to measure ICMP response'
        SampledAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Open-POWindowsSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidatePattern('^ms-settings:')][string]$Uri)
    if (-not (Test-POIsWindows)) { throw 'Windows Settings shortcuts are available only on Windows.' }
    Start-Process -FilePath $Uri -ErrorAction Stop
}

function Export-POBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory = $true)][string]$BackupPath,
          [Parameter(Mandatory = $true)][string]$DestinationPath)
    $backupFull = [System.IO.Path]::GetFullPath($BackupPath)
    $backupRoot = Get-POPathRootPrefix -Path (Get-POBackupRoot)
    if (-not $backupFull.StartsWith($backupRoot, (Get-POPathComparison))) { throw 'Export is limited to backups inside the Platinum Optimizer backup directory.' }
    $validation = Test-POBackup -Path $backupFull
    if (-not $validation.Valid) { throw ('Backup validation failed: ' + (@($validation.Issues) -join '; ')) }
    $destination = [System.IO.Path]::GetFullPath($DestinationPath)
    if ([System.IO.Path]::GetExtension($destination) -ne '.zip') { $destination += '.zip' }
    $backupPrefix = Get-POPathRootPrefix -Path $backupFull
    if ($destination.StartsWith($backupPrefix, (Get-POPathComparison))) { throw 'The ZIP export must be outside the source backup directory.' }
    if (-not $PSCmdlet.ShouldProcess($destination, 'Export local backup as an unencrypted ZIP archive')) {
        return [pscustomobject]@{ Status = 'SIMULATED'; Path = $destination }
    }
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path -LiteralPath $destination) { throw 'The export destination already exists; choose another file name.' }
    Compress-Archive -Path (Join-Path $BackupPath '*') -DestinationPath $destination -CompressionLevel Optimal -ErrorAction Stop
    return [pscustomobject]@{ Status = 'EXPORTED'; Path = $destination; Encrypted = $false; ContainsSystemDetails = $true }
}

function Remove-POBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][string]$BackupPath)
    $fullPath = [System.IO.Path]::GetFullPath($BackupPath)
    $root = Get-POPathRootPrefix -Path (Get-POBackupRoot)
    if (-not $fullPath.StartsWith($root, (Get-POPathComparison))) { throw 'Delete is limited to backups inside the Platinum Optimizer backup directory.' }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) { throw 'Backup directory does not exist.' }
    $backupItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($backupItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to delete a backup directory that is a reparse point.' }
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Permanently delete this backup')) { return $false }
    Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
    return $true
}

Export-ModuleMember -Function @(
    'Get-POStateRoot', 'Get-POProfileCatalog', 'Get-POTweakCatalog', 'Get-POGameCatalog', 'Get-POServiceCatalog',
    'Test-POIsWindows', 'Test-POIsAdministrator', 'Get-POSystemSnapshot', 'Get-POStatusSnapshot', 'Get-POPowerPlans',
    'Get-PORegValueState', 'Test-POIPv4DnsAddresses',
    'Get-POActivePowerPlanGuid', 'Get-POBuiltinPlanGuid', 'Get-POProfiles', 'Get-POTweakCompatibility', 'New-POProfilePlan',
    'Get-PONetworkAdapters', 'Get-POCurrentAdapterDns', 'Test-POAdapterDnsEligibility', 'Invoke-PONetworkPingTest', 'Get-POServiceAudit', 'Get-POBcdAudit',
    'Get-POStartupAudit', 'Get-PODriverInventory', 'Get-POScheduledTaskAudit', 'Get-POAppxInventory', 'Get-POInstalledGames', 'Add-POCustomGame', 'Get-POBenchmarkSnapshot',
    'Save-POBenchmarkSnapshot', 'Compare-POBenchmarkSnapshots', 'New-POBackup', 'Test-POBackup', 'Get-POBackups',
    'Restore-POBackup', 'Invoke-POProfilePlan', 'Set-PODnsProvider', 'Get-POUserTempPreview', 'Clear-POUserTemp',
    'Get-POResourceSample', 'Open-POWindowsSettings', 'Export-POBackup', 'Remove-POBackup', 'Write-POLog'
)
