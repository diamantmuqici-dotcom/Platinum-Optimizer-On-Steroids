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

## Interpretation policy

- A Microsoft WMI property is an inventory surface, not a guarantee that every OEM populates it accurately.
- `powercfg` makes a plan selectable; it does not establish that the plan improves a particular game's FPS or frame-time distribution. The prior active GUID and, where Windows permits, a `.pow` export are recorded.
- Static DNS servers replace DHCP-provided DNS on that adapter until reset; resolver choice can change lookup behavior, but it does not generally change the game's routing or server path.
- A brief CPU or DPC-time counter sample is not an in-game benchmark or a DPC/ISR latency measurement. The report compares observations and never converts unavailable metrics to zero.
- Registry keys without a supported Windows/vendor contract are not promoted from forum recipes into automatic settings. The V9.3 audit CSV marks their defaults and effects unknown.
