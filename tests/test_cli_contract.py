"""Repository-level tests for the CMD-only automatic execution contract."""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CliContractTests(unittest.TestCase):
    def test_primary_launcher_is_ascii_cmd_and_supports_only_documented_modes(self) -> None:
        launcher = (ROOT / "PlatinumOptimizer.bat").read_bytes()
        self.assertTrue(launcher.isascii())
        text = launcher.decode("ascii")
        self.assertIn("%~dp0src\\Launcher.ps1", text)
        self.assertIn("--scan", text)
        self.assertIn("--benchmark", text)
        self.assertIn("--restore", text)
        self.assertIn("--self-test", text)
        self.assertNotIn("#>PO_PAYLOAD", text)
        self.assertNotIn("-STA", text)

    def test_uac_handoff_is_visible_and_waited(self) -> None:
        launcher = (ROOT / "src/Launcher.ps1").read_text(encoding="utf-8")
        self.assertIn("ValidateSet('Auto', 'Scan', 'Benchmark', 'Restore', 'SelfTest')", launcher)
        self.assertIn("WindowsPrincipal", launcher)
        self.assertIn("-Verb RunAs", launcher)
        self.assertIn("-Wait -PassThru", launcher)
        self.assertIn("exit ([int]$child.ExitCode)", launcher)

    def test_launcher_does_not_use_net_session_or_elevate_the_batch_file(self) -> None:
        batch = (ROOT / "PlatinumOptimizer.bat").read_text(encoding="ascii").lower()
        launcher = (ROOT / "src/Launcher.ps1").read_text(encoding="utf-8")
        # `net session` can fail for an already elevated user when the Server
        # service is disabled. Re-launching a .bat through ShellExecute also
        # makes quoting/exit-code handling unreliable. Check elevation from
        # the Windows token and elevate Windows PowerShell itself instead.
        self.assertNotIn("net session", batch)
        self.assertNotIn("start-process", batch)
        self.assertIn("WindowsPrincipal", launcher)
        self.assertIn("-FilePath $powershellPath", launcher)
        self.assertIn("$quotedLauncherPath", launcher)
        self.assertNotIn("-FilePath $launcherPath", launcher)

    def test_no_graphical_entry_point_or_xaml_remains(self) -> None:
        self.assertFalse((ROOT / "src/ui/MainWindow.xaml").exists())
        engine = (ROOT / "src/PlatinumOptimizer.ps1").read_text(encoding="utf-8")
        for token in (
            "PresentationFramework",
            "PresentationCore",
            "System.Windows.Forms",
            "XamlReader",
            "MainWindow.xaml",
            "ShowDialog",
        ):
            self.assertNotIn(token, engine)
        self.assertNotIn("Read-Host", engine)

    def test_compatibility_launcher_delegates_to_new_entry(self) -> None:
        text = (ROOT / "Platinum+Optimizer.V9.3.FREE.cmd").read_text(encoding="ascii")
        self.assertRegex(text, re.compile(r'(?i)call\s+"%~dp0PlatinumOptimizer\.bat"'))
        self.assertNotIn("legacy\\Platinum+Optimizer.V9.3.FREE.cmd.disabled.txt", text)

    def test_backup_validation_is_before_plan_creation(self) -> None:
        power = (ROOT / "src/core/PlatinumOptimizer.Power.psm1").read_text(encoding="utf-8")
        start = power.index("function Invoke-POPlatinumPlanWorkflow")
        end = power.index("function Set-POPlatinumPlanActive", start)
        workflow = power[start:end]
        backup = workflow.index("$backup = New-POBackup")
        validate = workflow.index("$backupValidation = Test-POBackup")
        create = workflow.index("$createResult = New-POPlatinumPlan")
        self.assertLess(backup, validate)
        self.assertLess(validate, create)
        backup_callback = workflow.index("& $OnBackupCreated $backup")
        active_export_check = workflow.index("$activeExportPath = Join-Path $backup.Path")
        restore_point_callback = workflow.index("& $OnVerifiedBackup $backup")
        self.assertLess(validate, backup_callback)
        self.assertLess(backup_callback, active_export_check)
        self.assertLess(active_export_check, restore_point_callback)
        self.assertLess(restore_point_callback, create)
        automatic = (ROOT / "src/core/PlatinumOptimizer.Automatic.psm1").read_text(encoding="utf-8")
        self.assertIn("-OnBackupCreated $backupReportCallback", automatic)
        self.assertIn("-OnVerifiedBackup $restorePointCallback", automatic)
        self.assertIn("System Restore point created and verified after the application backup", automatic)
        self.assertIn("power\\active-plan.pow", workflow)
        self.assertIn("power\\platinum-plan-before.pow", workflow)

    def test_automatic_writer_does_not_tune_network_or_write_registry(self) -> None:
        automatic = (ROOT / "src/core/PlatinumOptimizer.Automatic.psm1").read_text(encoding="utf-8")
        self.assertIn("Invoke-POPlatinumPlanWorkflow -PresetId $presetId -Activate", automatic)
        for token in (
            "Set-DnsClientServerAddress",
            "Set-NetAdapterPowerManagement",
            "Set-PORegValueState",
            "netsh.exe int tcp set",
            "ipconfig.exe /flushdns",
        ):
            self.assertNotIn(token, automatic)

    def test_power_plan_creation_uses_powercfgs_documented_rename_verb(self) -> None:
        power = (ROOT / "src/core/PlatinumOptimizer.Power.psm1").read_text(encoding="utf-8")
        start = power.index("function New-POPlatinumPlan")
        end = power.index("function Invoke-POPlatinumPresetValues", start)
        create_plan = power[start:end]
        self.assertIn("-Arguments @('/changename', $newGuid, $name", create_plan)
        self.assertNotIn("'/setname'", create_plan)

    def test_automatic_report_schema_predeclares_all_late_written_fields(self) -> None:
        automatic = (ROOT / "src/core/PlatinumOptimizer.Automatic.psm1").read_text(encoding="utf-8")
        start = automatic.index("function New-POAutomaticRunContext")
        end = automatic.index("function Write-POAutomaticEvent", start)
        context = automatic[start:end]
        report_start = context.index("Report = [pscustomobject][ordered]@{")
        report_end = context.index("\n        }", report_start)
        report = context[report_start:report_end]
        for field in ("status", "summaryText", "metrics"):
            self.assertRegex(report, rf"(?m)^\s+{field}\s*=")

    def test_live_console_trace_shows_real_powercfg_commands_and_verified_settings(self) -> None:
        core = (ROOT / "src/core/PlatinumOptimizer.Core.psm1").read_text(encoding="utf-8")
        power = (ROOT / "src/core/PlatinumOptimizer.Power.psm1").read_text(encoding="utf-8")
        automatic = (ROOT / "src/core/PlatinumOptimizer.Automatic.psm1").read_text(encoding="utf-8")
        self.assertIn("[TRACE {0}] > powercfg.exe {1}", core)
        self.assertIn("exit={2}; {3} ms", core)
        self.assertIn("[POWER APPLY]", power)
        self.assertIn("[POWER VERIFIED]", power)
        self.assertIn("Label = 'APPLIED / VERIFIED'", automatic)

    def test_current_console_banner_identifies_patch_release(self) -> None:
        engine = (ROOT / "src/PlatinumOptimizer.ps1").read_text(encoding="utf-8")
        self.assertIn("$script:POApplicationVersion = '2.0.2'", engine)
        self.assertIn("VERSION 2.0.2", engine)
        self.assertIn("-DisableNameChecking", engine)

    def test_windows_process_arguments_are_quoted_without_literal_escape_slashes(self) -> None:
        core = (ROOT / "src/core/PlatinumOptimizer.Core.psm1").read_text(encoding="utf-8")
        quote = chr(34)
        self.assertIn(f"$value.Contains('{quote}')", core)
        self.assertIn(f"$quotedArguments.Add(('{quote}{{0}}{quote}' -f $value))", core)
        self.assertIn("$startInfo.UseShellExecute = $false", core)

    def test_automatic_power_presets_are_conservative(self) -> None:
        catalog = json.loads((ROOT / "src/data/power-settings.json").read_text(encoding="utf-8"))
        self.assertEqual(catalog["planName"], "Platinum On Steroids")
        self.assertEqual(catalog["duplicateBaseScheme"], "balanced")
        presets = {preset["id"]: preset for preset in catalog["presets"]}
        forbidden = {
            "core-parking-min-cores",
            "core-parking-max-cores",
            "core-parking-utility-distribution",
            "processor-boost-policy",
            "pci-express-aspm",
            "usb-selective-suspend",
            "sleep-after",
            "display-off-after",
        }
        for preset_id in ("gaming", "laptop"):
            for side in ("ac", "dc"):
                settings = presets[preset_id].get(side, {}) or {}
                self.assertTrue(forbidden.isdisjoint(settings), f"{preset_id}.{side} contains a speculative setting")
                self.assertLessEqual(settings.get("processor-min-state", 0), 5)
                self.assertLessEqual(settings.get("processor-max-state", 0), 100)
        self.assertEqual(presets["laptop"]["dc"]["processor-max-state"], 85)

    def test_obsolete_single_file_ui_builder_is_removed(self) -> None:
        self.assertFalse((ROOT / "tools/build_single_file.py").exists())

    def test_restore_selection_skips_consumed_backups_and_requires_a_verified_pre_restore_export(self) -> None:
        core = (ROOT / "src/core/PlatinumOptimizer.Core.psm1").read_text(encoding="utf-8")
        automatic = (ROOT / "src/core/PlatinumOptimizer.Automatic.psm1").read_text(encoding="utf-8")
        self.assertIn("function Test-POBackupNeedsRestore", core)
        self.assertIn("Test-POBackupNeedsRestore -Manifest $manifest", automatic)
        self.assertIn("power\\active-plan.pow", automatic)
        self.assertIn("current Platinum plan and settings could not be completely exported", automatic)
        self.assertIn("restoredAndVerified", automatic)
        self.assertIn("$restoreAssessment.PendingSections", automatic)
        self.assertIn("alreadyRestoredSections", automatic)
        self.assertIn("LedgerWarning", automatic)
        self.assertIn("$completed + @($Context.AlreadyOptimized) + @($Context.Skipped)", automatic)
        self.assertIn("$Context.Report.summary = $Summary", automatic)
        self.assertIn("Could not enumerate installed Windows power plans", core)

    def test_existing_platinum_recovery_uses_recorded_setting_writes_and_side_filters(self) -> None:
        core = (ROOT / "src/core/PlatinumOptimizer.Core.psm1").read_text(encoding="utf-8")
        power = (ROOT / "src/core/PlatinumOptimizer.Power.psm1").read_text(encoding="utf-8")
        restore_start = core.index("function Restore-POPowerPlan")
        restore_end = core.index("function Restore-PONetworkDns", restore_start)
        restore = core[restore_start:restore_end]
        self.assertIn("settingWritesRecorded", restore)
        self.assertIn("Get-POPlatinumSettingRestoreSelection", restore)
        self.assertNotIn("expectedSettings", restore)
        self.assertIn("PowerSettingWrites", core)
        self.assertIn("ConvertTo-POPowerSettingWriteLedger", power)
        self.assertIn("-PowerSettingWrites @($settingWriteLedger)", power)
        self.assertIn("-SettingKeys @($restoreSettingKeys | Select-Object -Unique)", restore)
        self.assertIn("-SettingKeys @($rollbackKeys | Select-Object -Unique)", power)
        self.assertIn("$currentValue -ne $targetValue", power)
        self.assertIn("$currentValue -ne $targetValue", core)
        backup_restore_start = core.index("function Restore-POBackup")
        backup_restore_end = core.index("function Invoke-POProfilePlan", backup_restore_start)
        backup_restore = core[backup_restore_start:backup_restore_end]
        self.assertIn("Test-POBackupNeedsRestore -Manifest $manifest", backup_restore)
        self.assertIn("$restoreSelection.PendingSections", backup_restore)
        self.assertIn("AlreadyRestored = $restoredBefore", backup_restore)

    def test_launcher_and_readme_use_current_mode_names(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        for option in ("--scan", "--benchmark", "--restore", "--self-test"):
            self.assertIn(option, readme)
        self.assertIn("automatic mode", readme.lower())
        self.assertIn("does not promise FPS", readme)


if __name__ == "__main__":
    unittest.main()
