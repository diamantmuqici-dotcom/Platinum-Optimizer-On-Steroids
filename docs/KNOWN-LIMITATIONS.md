# Known limitations and validation status

## Environment validation

- The available development workspace is Linux. Windows PowerShell 5.1, WPF, `powercfg.exe`, CIM Windows providers, `Set-DnsClientServerAddress`, UAC, and Windows 10/11 are not available here.
- The new WPF app and Windows-specific core therefore cannot be launched or integration-tested in this environment. No Windows 10/11 result is claimed. Run `tests/Run-Tests.ps1` on Windows PowerShell 5.1, then complete the manual checks below before release.
- The legacy batch source was read completely, archived as inert text, statically inventoried, and not executed.

## Detection gaps are explicit

- The OS gate identifies Windows 10/11 family and reports the build, but does not verify update health, ESU/LTSC enrollment, domain policy, or organizational servicing status. As of 2026-10-04, the ordinary Windows 10 servicing lifecycle has passed its 2025-10-14 end-of-support date; the UI therefore labels the servicing lifecycle Unknown rather than implying that every Windows 10 installation is currently supported.
- Windows generic CIM/WMI does not consistently expose CPU P-core/E-core topology, processor generation, NUMA topology, memory channels, compression, reliable GPU VRAM/shared memory, per-display refresh/HDR/color depth, NVMe health/temperature, CPU/GPU temperatures, or thermal throttling state. The UI shows Unknown/Not exposed and does not infer vendor settings from model text.
- Generic WMI counters can be absent or localized/inconsistent. Missing samples remain unavailable; the app does not translate absent values to zero.
- `Win32_VideoController.AdapterRAM` can be firmware/provider-reported and may be limited or inaccurate. It is labelled reported, never used to set VRAM allocation.
- Exact per-driver DPC/ISR latency requires a reliable ETW trace or specialist diagnostic source. This application does not currently collect a WPR/xperf trace and does not claim that DPC-time percentage is latency.
- GPU usage, FPS, frame time, 1% lows, game-server route latency, and thermals are not collected by this build. No game process is injected or inspected.

## Feature boundaries

- The profile engine changes only the active GUID of an already-installed Windows plan; it does not tune per-AC/DC subsettings, CPU boost, core parking, GPU clocks, HAGS, service state, or sleep values. The built-in plan may be absent on some OEM/laptop configurations; the plan is skipped.
- Network resolver changes only IPv4 on one connected physical adapter after both DHCP address assignment and the absence of a per-interface static IPv4 DNS override are confirmed. Static IP/DNS, VPN/virtual interfaces, policy-managed configuration, IPv6 DNS, and other adapters are not changed. An unknown DNS mode is blocked. A selected adapter can disconnect or become policy-managed between preview and apply; failures are reported and rollback is attempted.
- A DNS restore uses `-ResetServerAddresses` because the app only permits changes when the captured configuration was verified as DHCP plus automatic DNS. It restores automatic/DHCP behavior, not an arbitrary static or VPN configuration.
- Game discovery is local and metadata-based. Steam/Epic manifests, AppX inventory, and uninstall registrations are supported hints; some launchers/games are not visible, and detected install paths must be reviewed. The ARC Raiders executable candidate is intentionally blank until verified against the installed build.
- AppX removal and one-click service/task/startup changes are deliberately not implemented. Reliable reversibility and per-machine dependency analysis are prerequisites; the current views are read-only.
- Temp cleanup is irreversible. It is age- and path-restricted and opt-in; it is not backed up or presented as a performance tweak.
- Restore can only undo operations recorded by Platinum Optimizer. It cannot recover unrecorded user changes, removed data from the archived V9.3 script, or a whole Windows installation.
- Backup ZIP exports are not encrypted. Local DNS/service/system metadata may be sensitive.

## Manual Windows release checklist

1. Run the PowerShell test harness in a standard user session and elevated session.
2. Launch `Platinum+Optimizer.V9.3.FREE.cmd` on a clean Windows 10 build and a clean Windows 11 build; confirm it launches the new UI and never executes the archived batch content.
3. Verify standard-user detection, Settings links, game/app inventory, and that preview/dry run create no backup and do not change power/DNS/registry/services/BCD.
4. On a disposable test PC/VM, elevate intentionally; test existing-plan switch, active-GUID verification, timestamped backup, restore, and an injected failure/rollback case.
5. Verify DNS change/restore only on a disposable DHCP-enabled physical adapter; test cancellation, invalid custom IPv4, disconnected adapter, and failure rollback. Do not test on a managed production VPN/network.
6. Verify backup checksum rejection after modifying a snapshot file, export warning, restore scope, and backup deletion path guard.
7. Check AppX, service, task, startup, security, BCD, and driver pages remain read-only.
8. Check high-performance plans are blocked on battery, unknown power source, and unknown form factor; maximum mode requires the separate warning confirmation.
9. Confirm no background sampling unless monitoring is enabled and no automatic reboot occurs.
10. Review Windows Event Viewer, Defender, Windows Update, Store, Bluetooth, audio, USB/controller, VPN, and sleep/resume behavior after the change/restore cycle.
