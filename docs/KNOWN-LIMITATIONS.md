# Known limitations and validation status

## Environment validation

- This development checkout is running in a non-Windows workspace. Windows PowerShell 5.1, `powercfg.exe`, CIM/WMI Windows providers, UAC, System Restore, and Windows 10/11 hardware are not available here.
- The CMD launcher and PowerShell code have static and repository-level tests, but a live Windows end-to-end run cannot be claimed from this environment. Complete the Windows checklist below before release.
- The legacy V9.3 command file was inspected and retained only as inert text. It is never launched by either CMD entry point.

## Detection limits

- Generic Windows CIM/WMI may omit or inaccurately report CPU hybrid-core topology, processor generation, memory channels/compression, shared GPU memory, adapter-reported VRAM, display HDR/color depth, storage health/temperature, and thermal behavior. Missing fields are reported as unknown.
- Network adapter medium is inferred from Windows adapter metadata. VPN/virtual adapters and vendor naming differences can make the medium classification unknown. TCP global output is retained as Windows-reported text, not interpreted as a universal tuning recommendation.
- Windows may localize `powercfg` output. If the supported GUID/index parser cannot identify a setting, that setting is skipped rather than written.
- Generic counters are short system samples only. This build does not collect GPU utilization, game FPS, frame-time percentiles, thermal throttling, game-server route latency, or exact DPC/ISR latency.
- The display module can enumerate modes and refresh rate where the Win32 display APIs report them. It does not select a new mode in automatic mode. Vendor color-control executables are only detected as hints; their presence does not prove a supported programmable API.

## Automatic-mode change boundary

- The automatic run changes only settings in the `Platinum On Steroids` power scheme. It duplicates the currently active plan when needed, modifies documented processor minimum/maximum state and AC cooling policy where supported, and verifies the active GUID and setting values.
- Laptop battery mode applies a documented 85 percent maximum processor state; this can lower game performance on battery. It does not change battery sleep/display timers, USB behavior, PCIe behavior, processor boost, or core parking.
- Core parking and boost settings are inspected but not forced. A universal parking/boost policy has no established benefit across all CPU topologies, games, firmware, and cooling designs.
- Game Mode, capture, graphics scheduling, display refresh/colors, DNS/TCP/NIC settings, startup entries, services, processes, storage cleanup, and memory policy are assessed read-only. They remain unchanged to preserve user choice, security, connectivity, or workload-specific defaults.
- No automatic network ping is run. Resolver choice alone cannot determine the route or latency to a game server.
- The `--benchmark` mode captures a short operating-system counter sample, not a controlled game benchmark. No FPS/ping guarantee is made.

## Recovery and external system behavior

- A backup is mandatory before power configuration changes. The application requires a checksum-valid backup and verified export of the previously active scheme. An existing Platinum plan is separately exported and its supported processor indexes are captured before modification.
- After the verified application backup and required power exports are in place, Windows System Restore is attempted only when its built-in cmdlet is available. System Protection is never enabled automatically. Windows may block a restore point because protection is off, policy restricts it, or a restore point was recently created; the explicit configuration backup remains the primary recovery path.
- Recovery only restores changes recorded in a valid Platinum Optimizer manifest. For an existing Platinum plan, only setting sides recorded as attempted are eligible, and recovery refuses to overwrite a later value that differs from the optimizer's target. A backup created before per-side write-history recording was introduced cannot safely restore existing Platinum settings; recovery reports the missing history instead of inferring from preset targets. Recovery does not restore arbitrary operating-system state or undo changes made by other utilities after the backup.
- A newly created Platinum plan is retained after a successful restore but is no longer active. The optimizer does not delete user-created or unrelated plans.
- Backups and reports are local and unencrypted. They include hardware, OS, power-plan, service-inventory, and network-adapter metadata; keep the local profile private.
- Power-plan and registry behavior can be constrained by Group Policy, endpoint management, OEM tools, or Windows servicing. A write accepted by a command is not treated as success until a read-back verifies it.

## Windows release checklist

1. Run the test harness in a standard user session and an elevated Windows PowerShell 5.1 session.
2. Right-click `PlatinumOptimizer.bat` and choose **Run as administrator**. Verify the CMD console shows the banner and starts automatic mode without a category menu or graphical window.
3. Double-click the launcher without elevation. Approve UAC and verify output appears in the elevated visible console. Decline UAC and verify no optimizer change occurs.
4. Test installation and checkout paths containing spaces, missing engine/PowerShell behavior, `--scan`, `--benchmark`, `--restore`, and `--self-test`.
5. On a disposable Windows test system, verify the active scheme export and checksums exist before plan creation/configuration; inject a backup failure and confirm the workflow makes no power changes.
6. Verify an absent Platinum plan is created once from the active plan, an existing plan is reused, the selected AC/DC processor values are read back, and the verified plan becomes active.
7. Run automatic mode repeatedly and confirm no duplicate scheme is created and values already at target are reported as already optimized.
8. Test laptop AC and battery detection, unknown chassis/power source, unsupported `powercfg` settings, and localized `powercfg` output. Confirm unknown or unsupported settings are skipped safely.
9. Run `--restore` after the initial automatic run. Confirm the previous active plan is restored, only attempted existing-Platinum AC/DC sides still at the recorded target are restored, later conflicting values are left untouched, and unrelated plans remain unchanged.
10. Test System Restore disabled/recently created/policy-blocked conditions and verify the application backup remains available.
11. Verify network adapter and TCP snapshots are read-only. Confirm DNS, ECN, autotuning, offloads, RSS/RSC, firewall, Defender, Windows Update, services, startup entries, and active processes are unchanged.
12. Check the timestamped human log and JSON report for accurate attempted/applied/already/skipped/failed/unverified counts and a truthful final status.
13. Review Windows event logs and normal sleep/resume, audio, USB/controller, Wi-Fi/Ethernet, VPN, and gaming behavior after the apply/restore cycle.
