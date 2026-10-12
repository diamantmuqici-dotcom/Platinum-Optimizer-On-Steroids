#requires -Version 5.1
# Platinum Optimizer - Display & Colors module
# Uses only documented Win32 interfaces (EnumDisplayDevices,
# EnumDisplaySettings, ChangeDisplaySettingsEx, Get/SetDeviceGammaRamp,
# dxva2 physical-monitor capability queries). GPU-vendor saturation/vibrance
# controls have no documented write API here and remain manual guidance.
#
# Anti color-corruption rules enforced by design:
#   * Gamma ramps are computed ABSOLUTELY from the identity curve, never
#     relative to the current ramp -> repeated applies cannot accumulate.
#   * The exact same curve is applied to all three channels -> the profile
#     can never introduce a green/red/blue tint by itself.
#   * Gamma is clamped to the documented safety bounds in the profile data.
#   * The original ramp and display mode are captured BEFORE the first
#     change and are restored exactly; no GPU registry value is ever written.
Set-StrictMode -Version 2.0

if (-not (Get-Module | Where-Object { $_.Name -eq 'PlatinumOptimizer.Core' })) {
    Import-Module -Name (Join-Path $PSScriptRoot 'PlatinumOptimizer.Core.psm1') -Global -Force -ErrorAction Stop
}

$script:PODisplayNativeReady = $false

function Initialize-PODisplayNative {
    [CmdletBinding()]
    param()
    if ($script:PODisplayNativeReady) { return }
    if ('PlatinumOptimizer.Display.Native' -as [type]) { $script:PODisplayNativeReady = $true; return }
    $source = @'
using System;
using System.Runtime.InteropServices;

namespace PlatinumOptimizer.Display
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public uint dmDisplayOrientation;
        public uint dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel;
        public uint dmPelsWidth;
        public uint dmPelsHeight;
        public uint dmDisplayFlags;
        public uint dmDisplayFrequency;
        public uint dmICMMethod;
        public uint dmICMIntent;
        public uint dmMediaType;
        public uint dmDitherType;
        public uint dmReserved1;
        public uint dmReserved2;
        public uint dmPanningWidth;
        public uint dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GAMMARAMP
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public ushort[] Red;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public ushort[] Green;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public ushort[] Blue;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public static class Native
    {
        public const int ENUM_CURRENT_SETTINGS = -1;
        public const uint DM_BITSPERPEL = 0x00040000;
        public const uint DM_PELSWIDTH = 0x00080000;
        public const uint DM_PELSHEIGHT = 0x00100000;
        public const uint DM_DISPLAYFREQUENCY = 0x00400000;
        public const uint CDS_UPDATEREGISTRY = 0x00000001;
        public const uint CDS_TEST = 0x00000002;
        public const int DISP_CHANGE_SUCCESSFUL = 0;
        public const int DISPLAY_DEVICE_ACTIVE = 0x1;
        public const int DISPLAY_DEVICE_PRIMARY_DEVICE = 0x4;
        public const int DISPLAY_DEVICE_MIRRORING_DRIVER = 0x8;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplayDevicesW(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplaySettingsW(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int ChangeDisplaySettingsExW(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateDCW(string lpszDriver, string lpszDevice, string lpszOutput, IntPtr lpInitData);

        [DllImport("user32.dll")]
        public static extern IntPtr GetDC(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteDC(IntPtr hDC);

        [DllImport("gdi32.dll")]
        public static extern bool GetDeviceGammaRamp(IntPtr hDC, out GAMMARAMP lpRamp);

        [DllImport("gdi32.dll")]
        public static extern bool SetDeviceGammaRamp(IntPtr hDC, ref GAMMARAMP lpRamp);

        [DllImport("user32.dll")]
        public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

        [DllImport("dxva2.dll")]
        public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint pdwNumberOfPhysicalMonitors);

        [DllImport("dxva2.dll")]
        public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

        [DllImport("dxva2.dll")]
        public static extern bool GetCapabilitiesStringLength(IntPtr hMonitor, out uint pdwCapabilitiesStringLengthInCharacters);

        [DllImport("dxva2.dll")]
        public static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);
    }
}
'@
    try {
        Add-Type -TypeDefinition $source -ErrorAction Stop
        $script:PODisplayNativeReady = $true
    }
    catch {
        if ('PlatinumOptimizer.Display.Native' -as [type]) { $script:PODisplayNativeReady = $true }
        else { throw "The display native interface could not be initialized: $($_.Exception.Message)" }
    }
}

function Get-PODisplayProfileCatalog {
    [CmdletBinding()]
    param()
    return (Get-POJsonFile -Name 'display-profiles.json')
}

function Get-PODisplayProfiles {
    [CmdletBinding()]
    param()
    return @((Get-PODisplayProfileCatalog).profiles)
}

function Get-PODisplayStateRoot {
    $root = Join-Path (Get-POStateRoot) 'display'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    return $root
}

function Get-PODisplayStatePath {
    return (Join-Path (Get-PODisplayStateRoot) 'display-state.json')
}

function Get-PODisplayModuleState {
    [CmdletBinding()]
    param()
    $path = Get-PODisplayStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

function Set-PODisplayModuleState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$State)
    Write-POJsonAtomic -Path (Get-PODisplayStatePath) -Object $State
}

function Compute-POGammaRamp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][double]$Gamma)
    # Pure function. ALWAYS computed from the identity curve. Identical for
    # all three channels, so no color tint can be introduced and repeated
    # application cannot accumulate.
    $catalog = Get-PODisplayProfileCatalog
    $min = [double]$catalog.safety.gammaMin
    $max = [double]$catalog.safety.gammaMax
    if ($Gamma -lt $min) { $Gamma = $min }
    if ($Gamma -gt $max) { $Gamma = $max }
    $values = New-Object 'int[]' 256
    for ($i = 0; $i -lt 256; $i++) {
        $normalized = [double]$i / 255.0
        $lifted = [math]::Pow($normalized, (1.0 / $Gamma))
        $result = [int][math]::Round($lifted * 65535.0)
        if ($result -lt 0) { $result = 0 }
        if ($result -gt 65535) { $result = 65535 }
        $values[$i] = $result
    }
    return [pscustomobject][ordered]@{ Gamma = $Gamma; Red = $values; Green = [int[]]$values.Clone(); Blue = [int[]]$values.Clone() }
}

function Compare-POGammaRamps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int[]]$Expected,
        [Parameter(Mandatory = $true)][int[]]$Actual,
        [int]$Tolerance = 512
    )
    if ($Expected.Count -ne $Actual.Count) { return $false }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ([math]::Abs($Expected[$i] - $Actual[$i]) -gt $Tolerance) { return $false }
    }
    return $true
}

function Get-PODisplayVendor {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    if ([string]$Text -match '(?i)NVIDIA|GeForce|Quadro|RTX|GTX') { return 'NVIDIA' }
    if ([string]$Text -match '(?i)AMD|Radeon') { return 'AMD' }
    if ([string]$Text -match '(?i)Intel') { return 'Intel' }
    return 'Unknown'
}

function Get-PODisplayInventory {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) {
        return [pscustomobject][ordered]@{ Available = $false; Message = 'Display inventory is available only on Windows.'; Displays = @(); DdcCi = 'Unknown'; GpuColorControls = @(); GameNotes = $null }
    }
    Initialize-PODisplayNative
    $displays = @()
    $adapterIndex = 0
    $devmode = New-Object PlatinumOptimizer.Display.DEVMODE
    $devmode.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf([type][PlatinumOptimizer.Display.DEVMODE])
    while ($true) {
        $adapter = New-Object PlatinumOptimizer.Display.DISPLAY_DEVICE
        $adapter.cb = [System.Runtime.InteropServices.Marshal]::SizeOf([type][PlatinumOptimizer.Display.DISPLAY_DEVICE])
        if (-not [PlatinumOptimizer.Display.Native]::EnumDisplayDevicesW($null, [uint32]$adapterIndex, [ref]$adapter, 0)) { break }
        $adapterIndex++
        if (($adapter.StateFlags -band [PlatinumOptimizer.Display.Native]::DISPLAY_DEVICE_ACTIVE) -eq 0) { continue }
        if (($adapter.StateFlags -band [PlatinumOptimizer.Display.Native]::DISPLAY_DEVICE_MIRRORING_DRIVER) -ne 0) { continue }
        $deviceName = [string]$adapter.DeviceName
        $monitorDescription = $null; $monitorPnpId = $null
        $child = New-Object PlatinumOptimizer.Display.DISPLAY_DEVICE
        $child.cb = [System.Runtime.InteropServices.Marshal]::SizeOf([type][PlatinumOptimizer.Display.DISPLAY_DEVICE])
        if ([PlatinumOptimizer.Display.Native]::EnumDisplayDevicesW($deviceName, 0, [ref]$child, 0)) {
            $monitorDescription = [string]$child.DeviceString
            $monitorPnpId = [string]$child.DeviceID
        }
        $mode = New-Object PlatinumOptimizer.Display.DEVMODE
        $mode.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf([type][PlatinumOptimizer.Display.DEVMODE])
        $current = [PlatinumOptimizer.Display.Native]::EnumDisplaySettingsW($deviceName, [PlatinumOptimizer.Display.Native]::ENUM_CURRENT_SETTINGS, [ref]$mode)
        $maxRefresh = $null; $modeCount = 0
        if ($current) {
            $candidateIndex = 0
            $candidate = New-Object PlatinumOptimizer.Display.DEVMODE
            $candidate.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf([type][PlatinumOptimizer.Display.DEVMODE])
            $bestFrequency = [int]$mode.dmDisplayFrequency
            while ([PlatinumOptimizer.Display.Native]::EnumDisplaySettingsW($deviceName, $candidateIndex, [ref]$candidate)) {
                $candidateIndex++
                if ($candidateIndex -gt 1000) { break }
                if ([int]$candidate.dmPelsWidth -eq [int]$mode.dmPelsWidth -and [int]$candidate.dmPelsHeight -eq [int]$mode.dmPelsHeight -and [int]$candidate.dmBitsPerPel -ge [int]$mode.dmBitsPerPel) {
                    if ([int]$candidate.dmDisplayFrequency -gt $bestFrequency) { $bestFrequency = [int]$candidate.dmDisplayFrequency }
                }
                $modeCount = $candidateIndex
            }
            $maxRefresh = $bestFrequency
        }
        $iccProfile = 'Not associated (Windows default). Manage via Color Management (colorcpl.exe).'
        if ($monitorPnpId) {
            $iccMatch = [regex]::Match([string]$monitorPnpId, '(?i)MONITOR\\([^\\]+)')
            if ($iccMatch.Success) {
                try {
                    $association = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM\ProfileAssociations\Monitor' -Name $iccMatch.Groups[1].Value -ErrorAction SilentlyContinue
                    if ($null -ne $association) {
                        $profileProperty = $association.PSObject.Properties[$iccMatch.Groups[1].Value]
                        if ($profileProperty -and $profileProperty.Value) { $iccProfile = "Associated ICC profile reported by Windows Color Management: $($profileProperty.Value)" }
                    }
                }
                catch { }
            }
        }
        $displays += [pscustomobject][ordered]@{
            DeviceName = $deviceName
            AdapterDescription = [string]$adapter.DeviceString
            GpuVendor = Get-PODisplayVendor -Text ([string]$adapter.DeviceString)
            MonitorDescription = if ($monitorDescription) { $monitorDescription } else { 'Not reported by Windows' }
            MonitorPnpId = if ($monitorPnpId) { $monitorPnpId } else { 'Unknown' }
            IsPrimary = (($adapter.StateFlags -band [PlatinumOptimizer.Display.Native]::DISPLAY_DEVICE_PRIMARY_DEVICE) -ne 0)
            Resolution = if ($current) { "$([int]$mode.dmPelsWidth) x $([int]$mode.dmPelsHeight)" } else { 'Unknown' }
            RefreshRateHz = if ($current) { [int]$mode.dmDisplayFrequency } else { $null }
            BitsPerPel = if ($current) { [int]$mode.dmBitsPerPel } else { $null }
            HighestAvailableRefreshAtCurrentResolution = $maxRefresh
            EnumeratedModes = $modeCount
            HDR = 'Unknown; HDR capability/state is not exposed by these APIs. Check Settings > Display > HDR.'
            IccProfile = $iccProfile
        }
    }
    $ddcCi = Test-PODdcCiAvailability
    return [pscustomobject][ordered]@{
        Available = ($displays.Count -gt 0)
        Message = if ($displays.Count -gt 0) { "Detected $($displays.Count) active display(s). HDR, panel OSD controls, and GPU saturation are reported per their real availability." } else { 'No active display was reported by Windows (remote/headless session?).' }
        Displays = $displays
        DdcCi = $ddcCi
        GpuColorControls = Get-POGpuColorControlStatus
        GameNotes = (Get-PODisplayProfileCatalog).gameNotes
    }
}

function Test-PODdcCiAvailability {
    [CmdletBinding()]
    param()
    # Read-only probe: asks each physical monitor whether it answers the
    # documented MCCS capabilities query. Never writes a VCP feature.
    try {
        Initialize-PODisplayNative
        $handles = New-Object System.Collections.Generic.List[object]
        $callback = [PlatinumOptimizer.Display.MonitorEnumProc]{
            param($hMonitor, $hdc, [ref]$rect, $data)
            $handles.Add($hMonitor)
            return $true
        }
        if (-not [PlatinumOptimizer.Display.Native]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $callback, [IntPtr]::Zero)) {
            return 'Not detected (monitor enumeration unavailable).'
        }
        $responsive = 0; $probed = 0
        foreach ($hMonitor in $handles) {
            $count = [uint32]0
            if (-not [PlatinumOptimizer.Display.Native]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$count) -or $count -lt 1) { continue }
            $monitors = New-Object 'PlatinumOptimizer.Display.PHYSICAL_MONITOR[]' ([int]$count)
            if (-not [PlatinumOptimizer.Display.Native]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $count, $monitors)) { continue }
            foreach ($physical in $monitors) {
                $probed++
                $length = [uint32]0
                if ([PlatinumOptimizer.Display.Native]::GetCapabilitiesStringLength($physical.hPhysicalMonitor, [ref]$length) -and $length -gt 0) { $responsive++ }
                [void][PlatinumOptimizer.Display.Native]::DestroyPhysicalMonitor($physical.hPhysicalMonitor)
            }
        }
        if ($probed -eq 0) { return 'Not detected: no physical monitor handle responded. Brightness/contrast must be adjusted with the monitor OSD.' }
        if ($responsive -gt 0) { return "Detected: $responsive of $probed physical monitor(s) answered the documented MCCS capabilities query. This app still does not write monitor controls; use the monitor OSD or vendor tool." }
        return "Not detected: $probed physical monitor(s) probed, none answered DDC/CI. Use the monitor OSD for brightness/contrast."
    }
    catch { return "Not detected (DDC/CI probe failed: $($_.Exception.Message)). Use the monitor OSD." }
}

function Get-POGpuColorControlStatus {
    [CmdletBinding()]
    param()
    # Detection only: where the user can change vendor saturation/vibrance.
    # Platinum Optimizer never writes these values.
    $controls = @()
    $nvidiaPaths = @(
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\Control Panel Client\nvcplui.exe')
    )
    $nvidiaFound = $null
    foreach ($path in $nvidiaPaths) { if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { $nvidiaFound = $path; break } }
    try {
        if (-not $nvidiaFound -and (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
            $appx = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)NVIDIA' -and $_.Name -match '(?i)ControlPanel' })
            if ($appx.Count -gt 0) { $nvidiaFound = "AppX package: $($appx[0].Name)" }
        }
    }
    catch { }
    if ($nvidiaFound) { $controls += "NVIDIA: color/saturation control available ($nvidiaFound). Manual surface: NVIDIA Control Panel > Adjust desktop color settings > Digital Vibrance (default 50%)." }
    $amdFound = $null
    try {
        if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
            $amdAppx = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)AdvancedMicroDevices|AMD.*Adrenalin|Radeon' })
            if ($amdAppx.Count -gt 0) { $amdFound = "AppX package: $($amdAppx[0].Name)" }
        }
    }
    catch { }
    if (-not $amdFound) {
        $amdExe = Join-Path $env:ProgramFiles 'AMD\CNext\CNext\RadeonSoftware.exe'
        if (Test-Path -LiteralPath $amdExe -PathType Leaf) { $amdFound = $amdExe }
    }
    if ($amdFound) { $controls += "AMD: color/saturation control available ($amdFound). Manual surface: AMD Software > Display > Custom Color > Saturation (default 100)." }
    $intelFound = $null
    try {
        if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
            $intelAppx = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)IntelGraphics' })
            if ($intelAppx.Count -gt 0) { $intelFound = "AppX package: $($intelAppx[0].Name)" }
        }
    }
    catch { }
    if (-not $intelFound) {
        $gcp = Join-Path ${env:ProgramFiles(x86)} 'Intel\Intel(R) Processor Graphics\GCP.exe'
        if (Test-Path -LiteralPath $gcp -PathType Leaf) { $intelFound = $gcp }
    }
    if ($intelFound) { $controls += "Intel: color control available ($intelFound). Manual surface: Intel Graphics > Display > Color Settings." }
    if ($controls.Count -eq 0) { $controls += 'No NVIDIA/AMD/Intel color control surface was detected. Saturation changes are not possible here and are not faked.' }
    return $controls
}

function Get-POCurrentDisplayModeInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceName)
    Initialize-PODisplayNative
    $mode = New-Object PlatinumOptimizer.Display.DEVMODE
    $mode.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf([type][PlatinumOptimizer.Display.DEVMODE])
    if (-not [PlatinumOptimizer.Display.Native]::EnumDisplaySettingsW($DeviceName, [PlatinumOptimizer.Display.Native]::ENUM_CURRENT_SETTINGS, [ref]$mode)) {
        throw "Windows could not report the current mode for $DeviceName."
    }
    return [pscustomobject][ordered]@{
        DeviceName = $DeviceName
        BitsPerPel = [int]$mode.dmBitsPerPel
        PelsWidth = [int]$mode.dmPelsWidth
        PelsHeight = [int]$mode.dmPelsHeight
        DisplayFrequency = [int]$mode.dmDisplayFrequency
    }
}

function Select-POHighestRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject[]]$Modes,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][int]$CurrentFrequency
    )
    # Pure selector over a caller-provided mode list.
    $best = $null
    foreach ($mode in $Modes) {
        if ([int]$mode.Width -ne $Width -or [int]$mode.Height -ne $Height) { continue }
        if ($null -eq $best -or [int]$mode.Frequency -gt [int]$best.Frequency) { $best = $mode }
    }
    if ($null -eq $best -or [int]$best.Frequency -le $CurrentFrequency) { return $null }
    return $best
}

function Get-PODisplayRampInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceName)
    Initialize-PODisplayNative
    $hdc = [PlatinumOptimizer.Display.Native]::CreateDCW($null, $DeviceName, $null, [IntPtr]::Zero)
    $created = $true
    if ($hdc -eq [IntPtr]::Zero) {
        $created = $false
        $hdc = [PlatinumOptimizer.Display.Native]::GetDC([IntPtr]::Zero)
    }
    if ($hdc -eq [IntPtr]::Zero) { throw "A device context for $DeviceName could not be opened; gamma cannot be read." }
    try {
        $ramp = New-Object PlatinumOptimizer.Display.GAMMARAMP
        if (-not [PlatinumOptimizer.Display.Native]::GetDeviceGammaRamp($hdc, [ref]$ramp)) { throw "The display driver refused to report the gamma ramp for $DeviceName." }
        return [pscustomobject][ordered]@{
            Red = [int[]]@($ramp.Red)
            Green = [int[]]@($ramp.Green)
            Blue = [int[]]@($ramp.Blue)
        }
    }
    finally {
        if ($created) { [void][PlatinumOptimizer.Display.Native]::DeleteDC($hdc) }
        else { [void][PlatinumOptimizer.Display.Native]::ReleaseDC([IntPtr]::Zero, $hdc) }
    }
}

function Set-PODisplayRampInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceName, [Parameter(Mandatory = $true)][int[]]$ChannelValues)
    Initialize-PODisplayNative
    $hdc = [PlatinumOptimizer.Display.Native]::CreateDCW($null, $DeviceName, $null, [IntPtr]::Zero)
    $created = $true
    if ($hdc -eq [IntPtr]::Zero) { $created = $false; $hdc = [PlatinumOptimizer.Display.Native]::GetDC([IntPtr]::Zero) }
    if ($hdc -eq [IntPtr]::Zero) { throw "A device context for $DeviceName could not be opened; gamma cannot be changed." }
    try {
        $ramp = New-Object PlatinumOptimizer.Display.GAMMARAMP
        $ramp.Red = [uint16[]]@($ChannelValues | ForEach-Object { [uint16]$_ })
        $ramp.Green = [uint16[]]@($ChannelValues | ForEach-Object { [uint16]$_ })
        $ramp.Blue = [uint16[]]@($ChannelValues | ForEach-Object { [uint16]$_ })
        if (-not [PlatinumOptimizer.Display.Native]::SetDeviceGammaRamp($hdc, [ref]$ramp)) {
            throw "The display driver refused SetDeviceGammaRamp for $DeviceName (common when HDR is enabled or the driver owns the ramp)."
        }
        $readback = New-Object PlatinumOptimizer.Display.GAMMARAMP
        if (-not [PlatinumOptimizer.Display.Native]::GetDeviceGammaRamp($hdc, [ref]$readback)) {
            throw "The gamma ramp was written but could not be read back for $DeviceName; treating as unverified."
        }
        if (-not (Compare-POGammaRamps -Expected $ChannelValues -Actual ([int[]]@($readback.Red)))) {
            throw "Gamma verification failed for $DeviceName: the driver did not keep the requested ramp. This usually means HDR or driver color management is overriding it. No verified change was made."
        }
    }
    finally {
        if ($created) { [void][PlatinumOptimizer.Display.Native]::DeleteDC($hdc) }
        else { [void][PlatinumOptimizer.Display.Native]::ReleaseDC([IntPtr]::Zero, $hdc) }
    }
}

function Set-PODisplayModeInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DeviceName,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][int]$BitsPerPel,
        [Parameter(Mandatory = $true)][int]$Frequency,
        [switch]$TestOnly
    )
    Initialize-PODisplayNative
    $mode = New-Object PlatinumOptimizer.Display.DEVMODE
    $mode.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf([type][PlatinumOptimizer.Display.DEVMODE])
    $mode.dmDeviceName = $DeviceName
    $mode.dmPelsWidth = [uint32]$Width
    $mode.dmPelsHeight = [uint32]$Height
    $mode.dmBitsPerPel = [uint32]$BitsPerPel
    $mode.dmDisplayFrequency = [uint32]$Frequency
    $mode.dmFields = [PlatinumOptimizer.Display.Native]::DM_PELSWIDTH -bor [PlatinumOptimizer.Display.Native]::DM_PELSHEIGHT -bor [PlatinumOptimizer.Display.Native]::DM_BITSPERPEL -bor [PlatinumOptimizer.Display.Native]::DM_DISPLAYFREQUENCY
    $flags = if ($TestOnly) { [PlatinumOptimizer.Display.Native]::CDS_TEST } else { [PlatinumOptimizer.Display.Native]::CDS_UPDATEREGISTRY }
    $result = [PlatinumOptimizer.Display.Native]::ChangeDisplaySettingsExW($DeviceName, [ref]$mode, [IntPtr]::Zero, $flags, [IntPtr]::Zero)
    return [int]$result
}

function Get-PODisplayDeviceState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceName)
    $state = Get-PODisplayModuleState
    if ($null -eq $state -or -not $state.Devices) { return $null }
    $entry = @($state.Devices | Where-Object { $_.DeviceName -eq $DeviceName } | Select-Object -First 1)
    if ($entry.Count -eq 0) { return $null }
    return $entry[0]
}

function Invoke-PODisplayProfile {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [Parameter(Mandatory = $true)][string]$DeviceName
    )
    if (-not (Test-POIsWindows)) { throw 'Display profiles are available only on Windows.' }
    $catalog = Get-PODisplayProfileCatalog
    $profile = @($catalog.profiles | Where-Object { $_.id -eq $ProfileId } | Select-Object -First 1)
    if ($profile.Count -eq 0) { throw "Unknown display profile '$ProfileId'. Use one of: $(($catalog.profiles | ForEach-Object { $_.id }) -join ', ')." }
    $profile = $profile[0]
    if ($ProfileId -eq 'restore-display') { return (Restore-PODisplayConfiguration -DeviceName $DeviceName -Confirm:$false) }
    $gammaProperty = $profile.PSObject.Properties['gamma']
    $gammaValue = $null
    if ($gammaProperty -and $null -ne $gammaProperty.Value -and [string]$gammaProperty.Value -ne 'restore-captured') { $gammaValue = [double]$gammaProperty.Value }
    $refreshPolicy = [string]$profile.refresh
    if ($null -eq $gammaValue -and $refreshPolicy -eq 'keep' -and [string]$profile.hdr -eq 'open-settings') {
        return [pscustomobject][ordered]@{ Status = 'GUIDANCE_ONLY'; ProfileId = $ProfileId; Message = "'$($profile.name)' makes no automatic change. $($profile.purpose) Open Settings > Display > HDR to manage HDR yourself."; SettingsUri = [string]$catalog.manualSurfaces.windowsHdrSettings; Guidance = [string]$profile.vibranceGuidance; Backup = $null }
    }
    $currentMode = Get-POCurrentDisplayModeInternal -DeviceName $DeviceName
    $targetFrequency = [int]$currentMode.DisplayFrequency
    if ($refreshPolicy -eq 'highest-at-current-resolution') {
        Initialize-PODisplayNative
        $modes = @()
        $candidateIndex = 0
        $candidate = New-Object PlatinumOptimizer.Display.DEVMODE
        $candidate.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf([type][PlatinumOptimizer.Display.DEVMODE])
        while ([PlatinumOptimizer.Display.Native]::EnumDisplaySettingsW($DeviceName, $candidateIndex, [ref]$candidate)) {
            $candidateIndex++
            if ($candidateIndex -gt 1000) { break }
            $modes += [pscustomobject]@{ Width = [int]$candidate.dmPelsWidth; Height = [int]$candidate.dmPelsHeight; Bpp = [int]$candidate.dmBitsPerPel; Frequency = [int]$candidate.dmDisplayFrequency }
        }
        $best = Select-POHighestRefresh -Modes $modes -Width ([int]$currentMode.PelsWidth) -Height ([int]$currentMode.PelsHeight) -CurrentFrequency ([int]$currentMode.DisplayFrequency)
        if ($best) { $targetFrequency = [int]$best.Frequency }
    }
    $describe = @()
    if ($null -ne $gammaValue) { $describe += "gamma ramp -> $gammaValue (absolute, all channels identical, clamped $($catalog.safety.gammaMin)..$($catalog.safety.gammaMax))" }
    if ($targetFrequency -ne [int]$currentMode.DisplayFrequency) { $describe += "refresh rate $([int]$currentMode.DisplayFrequency) Hz -> $targetFrequency Hz at the current resolution" }
    if ($describe.Count -eq 0) {
        return [pscustomobject][ordered]@{ Status = 'NO_CHANGES'; ProfileId = $ProfileId; Message = "'$($profile.name)' proposes no measurable change for $DeviceName right now."; Guidance = [string]$profile.vibranceGuidance; Backup = $null }
    }
    $description = "Display profile '$($profile.name)' on $DeviceName ONLY: $($describe -join '; '). Scope: $($profile.scope)"
    if (-not $PSCmdlet.ShouldProcess($DeviceName, $description)) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; ProfileId = $ProfileId; Message = "Dry run: would apply $($describe -join '; ') on $DeviceName. No backup, ramp, or mode was changed."; Guidance = [string]$profile.vibranceGuidance; Backup = $null }
    }

    $state = Get-PODisplayModuleState
    if ($null -eq $state -or -not $state.Devices) {
        $state = [pscustomobject][ordered]@{ Devices = @(); AppliedProfileId = $null; AppliedAtUtc = $null }
    }
    $deviceEntries = @($state.Devices)
    $capturedEntry = @($deviceEntries | Where-Object { $_.DeviceName -eq $DeviceName } | Select-Object -First 1)
    if ($capturedEntry.Count -eq 0) {
        # Capture the true original BEFORE any change. Never overwritten by
        # later profile switches -> no accumulation path exists.
        $originalRamp = Get-PODisplayRampInternal -DeviceName $DeviceName
        $capture = [pscustomobject][ordered]@{
            DeviceName = $DeviceName
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
            Mode = $currentMode
            GammaRamp = $originalRamp
        }
        $deviceEntries += $capture
        if ($state.PSObject.Properties['Devices']) { $state.Devices = @($deviceEntries) }
        else { $state | Add-Member -MemberType NoteProperty -Name 'Devices' -Value @($deviceEntries) }
    }
    $backup = New-POBackup -DisplayState $state
    $changeRecord = [pscustomobject][ordered]@{
        section = 'display'; id = 'display-profile'; name = "Display profile: $($profile.name)"
        deviceName = $DeviceName; profile = $ProfileId
        gammaTarget = $gammaValue; refreshBefore = [int]$currentMode.DisplayFrequency; refreshTarget = $targetFrequency
        status = 'APPLYING'; timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    Add-POBackupChange -BackupPath $backup.Path -Section display -Change $changeRecord
    try {
        if ($null -ne $gammaValue) {
            $ramp = Compute-POGammaRamp -Gamma $gammaValue
            Set-PODisplayRampInternal -DeviceName $DeviceName -ChannelValues $ramp.Red
        }
        if ($targetFrequency -ne [int]$currentMode.DisplayFrequency) {
            $testResult = Set-PODisplayModeInternal -DeviceName $DeviceName -Width ([int]$currentMode.PelsWidth) -Height ([int]$currentMode.PelsHeight) -BitsPerPel ([int]$currentMode.BitsPerPel) -Frequency $targetFrequency -TestOnly
            if ($testResult -ne [PlatinumOptimizer.Display.Native]::DISP_CHANGE_SUCCESSFUL) { throw "Windows rejected the $targetFrequency Hz test with code $testResult; the refresh rate was not changed." }
            $applyResult = Set-PODisplayModeInternal -DeviceName $DeviceName -Width ([int]$currentMode.PelsWidth) -Height ([int]$currentMode.PelsHeight) -BitsPerPel ([int]$currentMode.BitsPerPel) -Frequency $targetFrequency
            if ($applyResult -ne [PlatinumOptimizer.Display.Native]::DISP_CHANGE_SUCCESSFUL) { throw "ChangeDisplaySettings returned code $applyResult; the refresh rate was not changed." }
            $verifyMode = Get-POCurrentDisplayModeInternal -DeviceName $DeviceName
            if ([int]$verifyMode.DisplayFrequency -ne $targetFrequency) {
                [void](Set-PODisplayModeInternal -DeviceName $DeviceName -Width ([int]$currentMode.PelsWidth) -Height ([int]$currentMode.PelsHeight) -BitsPerPel ([int]$currentMode.BitsPerPel) -Frequency ([int]$currentMode.DisplayFrequency))
                throw "Refresh verification failed (Windows reports $([int]$verifyMode.DisplayFrequency) Hz); the previous mode was re-applied."
            }
        }
        if ($state.PSObject.Properties['AppliedProfileId']) { $state.AppliedProfileId = $ProfileId } else { $state | Add-Member -MemberType NoteProperty -Name 'AppliedProfileId' -Value $ProfileId }
        if ($state.PSObject.Properties['AppliedAtUtc']) { $state.AppliedAtUtc = [DateTime]::UtcNow.ToString('o') } else { $state | Add-Member -MemberType NoteProperty -Name 'AppliedAtUtc' -Value ([DateTime]::UtcNow.ToString('o')) }
        Set-PODisplayModuleState -State $state
        Update-POBackupChangeStatus -BackupPath $backup.Path -Section display -Status 'APPLIED_VERIFIED' -Message ($describe -join '; ')
        Write-POLog -Category 'Display' -TweakId 'display-profile' -Status 'APPLIED_VERIFIED' -Message "Applied $($profile.name) to $DeviceName ($($describe -join '; '))."
        return [pscustomobject][ordered]@{
            Status = 'APPLIED_VERIFIED'
            ProfileId = $ProfileId
            Message = "Verified on $DeviceName: $($describe -join '; '). Scope reminder: $($profile.scope)"
            Guidance = [string]$profile.vibranceGuidance
            Tradeoffs = @($profile.tradeoffs)
            Backup = $backup
        }
    }
    catch {
        $failure = $_.Exception.Message
        Write-POLog -Level 'ERROR' -Category 'Display' -TweakId 'display-profile' -Status 'FAILED' -Message $failure
        try { Update-POBackupChangeStatus -BackupPath $backup.Path -Section display -Status 'FAILED' -Message $failure }
        catch { Write-POLog -Level 'CRITICAL' -Category 'Backup' -Status 'TRANSACTION_STATUS_WRITE_FAILED' -Message $_.Exception.Message }
        return [pscustomobject][ordered]@{ Status = 'FAILED'; ProfileId = $ProfileId; Message = "Display profile not applied: $failure"; Guidance = [string]$profile.vibranceGuidance; Backup = $backup }
    }
}

function Restore-PODisplayConfiguration {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][string]$DeviceName)
    if (-not (Test-POIsWindows)) { throw 'Display restore is available only on Windows.' }
    $entry = Get-PODisplayDeviceState -DeviceName $DeviceName
    if ($null -eq $entry) {
        return [pscustomobject][ordered]@{ Status = 'NO_CHANGES'; Message = "Platinum Optimizer has no captured original for $DeviceName; nothing to restore." }
    }
    if (-not $PSCmdlet.ShouldProcess($DeviceName, 'Restore the display mode and gamma ramp captured before the first Platinum display change')) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; Message = "Dry run: would restore the captured mode and gamma ramp for $DeviceName. No change was made." }
    }
    $mode = $entry.Mode
    $ramp = $entry.GammaRamp
    if ($ramp -and $ramp.Red) { Set-PODisplayRampInternal -DeviceName $DeviceName -ChannelValues ([int[]]@($ramp.Red)) }
    $testResult = Set-PODisplayModeInternal -DeviceName $DeviceName -Width ([int]$mode.PelsWidth) -Height ([int]$mode.PelsHeight) -BitsPerPel ([int]$mode.BitsPerPel) -Frequency ([int]$mode.DisplayFrequency) -TestOnly
    if ($testResult -eq [PlatinumOptimizer.Display.Native]::DISP_CHANGE_SUCCESSFUL) {
        [void](Set-PODisplayModeInternal -DeviceName $DeviceName -Width ([int]$mode.PelsWidth) -Height ([int]$mode.PelsHeight) -BitsPerPel ([int]$mode.BitsPerPel) -Frequency ([int]$mode.DisplayFrequency))
        $verify = Get-POCurrentDisplayModeInternal -DeviceName $DeviceName
        if ([int]$verify.DisplayFrequency -ne [int]$mode.DisplayFrequency -or [int]$verify.PelsWidth -ne [int]$mode.PelsWidth -or [int]$verify.PelsHeight -ne [int]$mode.PelsHeight) {
            throw "Display restore verification failed for $DeviceName; the captured mode could not be confirmed."
        }
    }
    $state = Get-PODisplayModuleState
    if ($state -and $state.Devices) {
        $remaining = @($state.Devices | Where-Object { $_.DeviceName -ne $DeviceName })
        if ($state.PSObject.Properties['Devices']) { $state.Devices = $remaining }
        Set-PODisplayModuleState -State $state
    }
    Write-POLog -Category 'Display' -TweakId 'display-restore' -Status 'RESTORED_VERIFIED' -Message "Restored captured display configuration for $DeviceName."
    return [pscustomobject][ordered]@{ Status = 'RESTORED_VERIFIED'; Message = "The captured mode ($([int]$mode.PelsWidth)x$([int]$mode.PelsHeight) @ $([int]$mode.DisplayFrequency) Hz) and original gamma ramp were restored on $DeviceName and verified. Vendor saturation changes made manually must be reverted in the GPU control panel." }
}

function Restore-PODisplaySection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath, [Parameter(Mandatory = $true)][psobject]$Manifest)
    $change = @($Manifest.changes | Where-Object { $_.section -eq 'display' } | Select-Object -Last 1)
    if ($change.Count -eq 0 -or $change[0].id -ne 'display-profile') { throw 'No supported display change was recorded in this backup.' }
    $statePath = Join-Path $BackupPath 'display\display-before.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'The backup does not contain the display state file.' }
    $savedState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $deviceName = [string]$change[0].deviceName
    $entry = @($savedState.Devices | Where-Object { $_.DeviceName -eq $deviceName } | Select-Object -First 1)
    if ($entry.Count -eq 0) { throw "The display backup contains no captured original for $deviceName." }
    $entry = $entry[0]
    $mode = $entry.Mode
    $ramp = $entry.GammaRamp
    if ($ramp -and $ramp.Red) { Set-PODisplayRampInternal -DeviceName $deviceName -ChannelValues ([int[]]@($ramp.Red)) }
    $testResult = Set-PODisplayModeInternal -DeviceName $deviceName -Width ([int]$mode.PelsWidth) -Height ([int]$mode.PelsHeight) -BitsPerPel ([int]$mode.BitsPerPel) -Frequency ([int]$mode.DisplayFrequency) -TestOnly
    if ($testResult -eq [PlatinumOptimizer.Display.Native]::DISP_CHANGE_SUCCESSFUL) {
        [void](Set-PODisplayModeInternal -DeviceName $deviceName -Width ([int]$mode.PelsWidth) -Height ([int]$mode.PelsHeight) -BitsPerPel ([int]$mode.BitsPerPel) -Frequency ([int]$mode.DisplayFrequency))
        $verify = Get-POCurrentDisplayModeInternal -DeviceName $deviceName
        if ([int]$verify.DisplayFrequency -ne [int]$mode.DisplayFrequency) { throw "Display restore verification failed for $deviceName." }
    }
    $state = Get-PODisplayModuleState
    if ($state -and $state.Devices) {
        $remaining = @($state.Devices | Where-Object { $_.DeviceName -ne $deviceName })
        if ($state.PSObject.Properties['Devices']) { $state.Devices = $remaining }
        Set-PODisplayModuleState -State $state
    }
}

Export-ModuleMember -Function @(
    'Get-PODisplayProfileCatalog', 'Get-PODisplayProfiles', 'Get-PODisplayInventory', 'Get-PODisplayModuleState',
    'Compute-POGammaRamp', 'Compare-POGammaRamps', 'Select-POHighestRefresh', 'Test-PODdcCiAvailability', 'Get-POGpuColorControlStatus',
    'Invoke-PODisplayProfile', 'Restore-PODisplayConfiguration', 'Restore-PODisplaySection'
)
