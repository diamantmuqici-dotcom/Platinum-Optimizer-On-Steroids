# Technical references

The automatic pipeline uses documented Windows inventory and power-management interfaces. The references below support the operations used; they do **not** prove a universal FPS or latency improvement.

1. **Powercfg command-line options** — Microsoft documents listing/querying schemes, duplicating and renaming plans, setting AC/DC indexes, reading hidden settings with `/qh`, exporting/importing, activating, and deleting a scheme. The optimizer checks command exit status and verifies the active GUID/settings after a write.
   <https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options>
2. **Processor power settings** — Microsoft power configuration documentation describes the processor power subgroup `54533251-82be-4824-96c1-47b60b740d00`, minimum processor state `893dee8e-2bef-41e0-89c6-b55d0929964c`, maximum processor state `bc5038f7-23e0-4960-96da-33abaf5935ec`, and system cooling policy `94d3a615-a899-4ac5-ae2b-e4d8f634367f`. The automatic pipeline only writes its bounded preset values when Windows exposes and verifies the setting.
   <https://learn.microsoft.com/en-us/windows-hardware/customize/power/unattend/microsoft-windows-powersettings>
3. **Core parking policy settings** — Microsoft documents the Windows power setting identifiers for core parking. Platinum Optimizer reads those values when they are exposed but does not universally disable parking or alter core topology.
   <https://learn.microsoft.com/en-us/windows/client-management/advanced-configuration-options-for-core-parking>
4. **Processor inventory** — `Win32_Processor` exposes Windows-reported model, vendor, architecture, logical/physical count, clock/cache, and virtualization metadata. Firmware/provider data may be incomplete; the optimizer preserves unknowns.
   <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-processor>
5. **Memory inventory** — `Win32_PhysicalMemory` exposes capacity, configured speed, memory-type code, manufacturer, and slot locator when firmware reports them. DIMM count is not treated as memory-channel topology.
   <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-physicalmemory>
6. **Computer system hardware classes** — Microsoft documents Windows CIM/WMI inventory for video controllers, storage, and related device classes. Generic inventory does not guarantee accurate VRAM, temperature, HDR, or per-display mode data.
   <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/computer-system-hardware-classes>
7. **Network adapters** — Microsoft documents the `Get-NetAdapter` inventory cmdlet. The optimizer reads adapter status/link metadata and TCP global state; it does not set DNS, congestion control, ECN, autotuning, offloads, RSS/RSC, duplex, or adapter power policy in automatic mode.
   <https://learn.microsoft.com/en-us/powershell/module/netadapter/get-netadapter>
8. **TCP global settings** — `netsh interface tcp show global` is a Windows read-only display command. The optimizer captures its output as the operating system reports it and does not import third-party TCP recipes.
   <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-interface>
9. **System Restore cmdlets** — Windows PowerShell exposes `Checkpoint-Computer` and `Get-ComputerRestorePoint` for restore-point creation and verification when System Protection is available. The optimizer does not enable System Protection and reports restore-point failure without substituting it for its explicit local backup.
   <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/checkpoint-computer>
10. **Windows Game Mode** — Microsoft describes Game Mode as a user-configured Windows feature whose results depend on the game/system. The application observes existing gaming-related values but does not change user capture/Game Bar preferences or write unsupported registry policies.
    <https://support.microsoft.com/en-us/help/4028293/windows-using-game-mode-on-your-pc>
11. **Windows graphics preferences** — Microsoft documents per-application graphics preferences and Windows display/game settings. The application detects display modes when available but does not force HAGS, resolution, refresh rate, gamma, ICC profiles, or vendor saturation settings during automatic optimization.
    <https://support.microsoft.com/en-us/windows/hardware/display-graphics/optimizations-for-windowed-games-in-windows-11>
12. **Display configuration APIs** — Microsoft documents `EnumDisplayDevices`, `EnumDisplaySettings`, `ChangeDisplaySettingsEx`, and gamma-ramp APIs. The retained display module uses these for diagnostics and its explicitly reversible legacy functions; automatic mode remains read-only.
    <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-changedisplaysettingsexa>
13. **Windows Color Management** — Windows Color System documentation describes ICC profile management. The optimizer reads associations where available and does not install or force a color profile.
    <https://learn.microsoft.com/en-us/windows/win32/wcs/windows-color-system>

## Additional Microsoft references (current automatic behavior)

17. **TCP global state** — Microsoft PowerShell *NetTCPIP* module: `Get-NetTCPSetting -SettingStore Active` and `netsh int tcp show global` expose Windows-reported TCP policy. The current automatic pipeline records the supported read-only `netsh` snapshot and does not alter autotuning, ECN, timestamps, congestion control, RSS/RSC, or offloads.
    <https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-nettcpsetting> ·
    <https://learn.microsoft.com/en-us/windows-server/networking/technologies/netsh/netsh-interface-tcp>
18. **Adapter power management** — Microsoft PowerShell *NetAdapter* documents `Get-NetAdapterPowerManagement` / `Set-NetAdapterPowerManagement` for adapter power policy. The current automatic path inventories adapters only; it does not call the setter or change connectivity.
    <https://learn.microsoft.com/en-us/powershell/module/netadapter/set-netadapterpowermanagement>
19. **System Restore point** — Microsoft PowerShell exposes `Checkpoint-Computer` and `Get-ComputerRestorePoint` when System Protection is available. The current workflow attempts a restore point only after its verified application backup and required power exports; it never enables System Protection. The local configuration backup remains the primary recovery path.
    <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/checkpoint-computer>
20. **Game capture / Game DVR settings** — Microsoft Support documents background recording and the Settings > Gaming > Captures surface. The current automatic path reads relevant gaming values and leaves Game Mode, Game Bar, and capture preferences unchanged.
    <https://support.microsoft.com/en-us/windows/record-game-clips-on-your-pc-with-game-bar-2ed42714-8bdd-34f3-4b6d-cab7d4d9bce7>
21. **Hardware-accelerated GPU scheduling** — Microsoft documents HAGS in Settings > System > Display > Graphics. Support depends on GPU and driver; enabling requires a reboot. The current path reports the `HwSchMode` state where available and leaves it unchanged.
    <https://support.microsoft.com/en-us/windows/how-to-enable-hardware-accelerated-gpu-scheduling-in-windows-11-a2db51b8-2be5-4d51-8d08-8f5fbd1a4b6d>

## Interpretation policy

- A documented Windows API is an interface contract, not evidence that a setting improves a particular game.
- Copying a power scheme makes the plan selectable; it does not establish that the plan improves FPS or frame pacing.
- DNS resolver choice can affect name lookup behavior but does not determine the route to a game server. Ping also depends on ISP routing, distance, congestion, and the remote server.
- A brief CPU/memory/disk sample is not an in-game benchmark. DPC-time percentage is not DPC/ISR latency.
- Unmeasured or undocumented settings are left read-only rather than promoted from forum recipes.
