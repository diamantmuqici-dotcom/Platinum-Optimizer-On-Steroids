# Technical references

These sources justify the limited supported integrations used by Platinum Optimizer. They do **not** prove a universal FPS or latency improvement; the application measures locally and leaves performance conclusions to observed results.

1. **Power plans** — Microsoft, *Powercfg command-line options*: list/query/set the active plan and export/import a scheme for rollback.
   <https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options>
2. **DNS** — Microsoft PowerShell, *Set-DnsClientServerAddress*: configure DNS on an interface; `-ResetServerAddresses` restores default/DHCP-provided servers. The UI restricts this to one connected physical adapter only after DHCP and the absence of a per-interface static IPv4 DNS override are both confirmed; unknown state is blocked.
   <https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientserveraddress?view=windowsserver2025-ps>
3. **DNS policy guard** — Microsoft Policy CSP, *ADMX_DnsClient*: documents the machine `DNS_NameServer` policy, its Windows 10/11 applicability, and that it supersedes per-interface/DHCP DNS. The application checks the documented policy location read-only and blocks changes when configured.
   <https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-dnsclient>
4. **DNS mode guard** — Archived Microsoft TechNet, *Automating TCP/IP Networking on Clients: Part 5: Scripting DNS on Clients*: describes `NameServer` and `DhcpNameServer` under the per-interface TCP/IP registry key and their use in distinguishing static from DHCP DNS configuration. The application reads the per-interface value plus the machine DNS Client policy value; if either read fails, or an override/policy is present, it does not change DNS.
   <https://learn.microsoft.com/en-us/previous-versions/tn-archive/ee692588(v=technet.10)>
5. **CPU inventory** — Microsoft Win32 apps, *Win32_Processor* class: WMI properties include name, manufacturer, architecture, core/thread counts, current/max clock, cache sizes, virtualization firmware state, and processor identifiers.
   <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-processor>
6. **Memory-module inventory** — Microsoft Win32 apps, *Win32_PhysicalMemory* class: capacity, configured speed, SMBIOS memory type, manufacturer, and module locator are available where firmware reports them. Channel topology is not inferred from DIMM count.
   <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-physicalmemory>
7. **Video/storage/device inventory** — Microsoft Win32 apps, *Computer System Hardware Classes*: documents WMI/CIM inventory families including video controllers, desktop monitors, and disk drives. Vendor-specific adapter telemetry, per-monitor HDR, accurate VRAM, and temperatures are not assumed to be available from these generic classes.
   <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/computer-system-hardware-classes>
8. **Game Mode** — Microsoft Support, *Use Game Mode while gaming on your Windows device*: describes the Windows Settings control and notes that frame-rate stability depends on the game and system.
   <https://support.microsoft.com/en-us/help/4028293/windows-using-game-mode-on-your-pc>
9. **Graphics preferences** — Microsoft Support, *Optimizations for windowed games in Windows 11*: documents Windows Graphics Settings and per-app graphics preference controls. The app opens this UI rather than forcing a registry or driver value.
   <https://support.microsoft.com/en-us/windows/hardware/display-graphics/optimizations-for-windowed-games-in-windows-11>

10. **Custom power plan lifecycle** — Microsoft, *Powercfg command-line options*: `/duplicatescheme`, `/setname`, `/setacvalueindex`, `/setdcvalueindex`, `/qh`, `/export`, `/import`, `/setactive`, and `/delete` are the supported scheme-management surface used by the Platinum On Steroids plan. Exit codes and re-reads gate every step.
    <https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options>
11. **Processor power settings** — Microsoft WDK, *Policy Settings* (Processor Power Management): documents the subgroup `54533251-82be-4824-96c1-47b60b740d00` and settings used here: minimum processor state `893dee8e-2bef-41e0-89c6-b55d0929964c`, maximum processor state `bc5038f7-23e0-4960-96da-33abaf5935ec`, system cooling policy `94d3a615-a899-4ac5-ae2b-e4d8f634367f`, and processor performance boost policy/mode `be337238-0d82-4146-a960-4f3749d470c7`. PCI Express ASPM `ee12f906-d277-404b-b6da-e5fa1a576df5`, USB selective suspend `48e6b7a6-50f5-4782-a5d4-53bb8f07e226`, sleep-after `29f6c1db-86da-48c5-9fdb-f2b67b1f44da`, and display-off `3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e` are likewise documented settings.
    <https://learn.microsoft.com/en-us/windows-hardware/customize/power/unattend/microsoft-windows-powersettings>
12. **Core parking settings** — Microsoft Windows configuration documentation for core parking policy settings (CPMAXCORES `ea062031-0e34-4ff1-9b6d-eb1059334028` AC / `ea062031-0e34-4ff1-9b6d-eb1059334029` DC, CPMINCORES `0cc5b647-c1df-4637-891a-dec35c318583` AC / `0cc5b647-c1df-4637-891a-dec35c318584` DC, utility distribution `4bdaf4e9-d103-46d7-a5f0-6280121616ef`, concurrency threshold `2430ab6f-a520-44a2-9601-f7f23b5134b1`). These settings are applied only when the platform exposes them.
    <https://learn.microsoft.com/en-us/windows/client-management/advanced-configuration-options-for-core-parking> (see also the per-setting pages under the same documentation family)
13. **Audio communications behavior** — the Sound control panel Communications tab stores its choice in `HKCU\Software\Microsoft\Multimedia\Audio\UserDuckingPreference` (0 mute all, 1 reduce 80% default, 2 reduce 50%, 3 do nothing). This is the only audio value the application writes; it is captured, verified, and restorable. Endpoint formats, enhancements, exclusive mode, and spatial audio remain under their supported Windows UI because no documented write interface exists.
    <https://support.microsoft.com/en-us/windows/how-to-adjust-volume-and-sound-settings-in-windows> (see Sound settings / Sound Control Panel)
14. **Display configuration and gamma** — Microsoft Win32 documentation: `EnumDisplayDevices`, `EnumDisplaySettings`, `ChangeDisplaySettingsEx` (with `CDS_TEST`), `GetDeviceGammaRamp`/`SetDeviceGammaRamp` (gdi32), and `CreateDC`/`DeleteDC` are the documented surfaces used for display inventory, refresh-rate changes, and bounded gamma profiles. The gamma design applies an absolute, channel-identical curve so repeated application cannot accumulate and no tint can be introduced.
    <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-changedisplaysettingsexa>
15. **Monitor configuration (DDC/CI)** — Microsoft Win32 documentation for the high-level monitor configuration functions (`GetPhysicalMonitorsFromHMONITOR`, `GetCapabilitiesStringLength`, `DestroyPhysicalMonitor`). Platinum Optimizer uses these read-only to probe DDC/CI capability and never writes a VCP feature; brightness/contrast hardware controls remain the monitor OSD.
    <https://learn.microsoft.com/en-us/windows/win32/monitor/high-level-monitor-configuration>
16. **Windows Color Management** — ICC profile associations are read from the documented Windows Color Management association location and surfaced with `colorcpl.exe` as the supported management UI; no profile is installed or forced.
    <https://learn.microsoft.com/en-us/windows/win32/wcs/windows-color-system>

## Added in v2.0 (automatic CMD engine)

17. **TCP global state** — Microsoft PowerShell *NetTCPIP* module: `Get-NetTCPSetting -SettingStore Active` reports receive-window autotuning level (local/effective), ECN capability, timestamps, congestion provider, RSS state, initial RTO, and retransmission values with language-neutral enums; `netsh int tcp show global` / `netsh int tcp set global` is the documented command-line surface. The engine only restores autotuning to the documented default (`normal`) when it is below default, and only enables RSS when it is disabled on a multi-processor system; ECN/timestamps/RSC/congestion provider are reported, never flipped.
    <https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-nettcpsetting> ·
    <https://learn.microsoft.com/en-us/windows-server/networking/technologies/netsh/netsh-interface-tcp>
18. **Adapter power management** — Microsoft PowerShell *NetAdapter* module: `Get-NetAdapterPowerManagement` / `Set-NetAdapterPowerManagement` are the documented interface for the "Allow the computer to turn off this device to save power" control. Only connected physical wired adapters are changed, previous values are captured, and every write is verified by re-reading.
    <https://learn.microsoft.com/en-us/powershell/module/netadapter/set-netadapterpowermanagement>
19. **System Restore point** — Microsoft PowerShell, *Checkpoint-Computer* (and the `SystemRestoreConfig` WMI class for availability): a restore point is attempted only when System Restore is not reported disabled, the call is time-bounded, and the result is reported truthfully. It is supplemental protection — the checksum-verified configuration backup is the primary restore path.
    <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/checkpoint-computer>
20. **Game capture / Game DVR settings** — Microsoft Support, *Record game clips on your PC with Game Bar*: documents background recording and the Settings > Gaming > Captures surface. The engine writes only the same user-scope switches that surface manages (`AppCaptureEnabled`, `GameDVR_Enabled`) plus the documented Game Mode values, each captured-before/verified-after and restorable; the Game Bar app itself stays installed and enabled.
    <https://support.microsoft.com/en-us/windows/record-game-clips-on-your-pc-with-game-bar-2ed42714-8bdd-34f3-4b6d-cab7d4d9bce7>
21. **Hardware-accelerated GPU scheduling** — Microsoft Support/Windows documentation for HAGS in Settings > System > Display > Graphics. Support depends on GPU and driver; enabling requires a reboot. The engine only reports the documented `HwSchMode` state and recommends the supported Settings surface — it never writes the value.
    <https://support.microsoft.com/en-us/windows/how-to-enable-hardware-accelerated-gpu-scheduling-in-windows-11-a2db51b8-2be5-4d51-8d08-8f5fbd1a4b6d>

## Interpretation policy

- A Microsoft WMI property is an inventory surface, not a guarantee that every OEM populates it accurately.
- `powercfg` makes a plan selectable; it does not establish that the plan improves a particular game's FPS or frame-time distribution. The prior active GUID and, where Windows permits, a `.pow` export are recorded.
- Static DNS servers replace DHCP-provided DNS on that adapter until reset; resolver choice can change lookup behavior, but it does not generally change the game's routing or server path.
- A brief CPU or DPC-time counter sample is not an in-game benchmark or a DPC/ISR latency measurement. The report compares observations and never converts unavailable metrics to zero.
- Registry keys without a supported Windows/vendor contract are not promoted from forum recipes into automatic settings. The V9.3 audit CSV marks their defaults and effects unknown.
