"""Tests for the restored automatic execution pipeline.

These are repository-level tests (like tests/test_cli_contract.py). They run
anywhere Python runs and guard the exact failure mode that disabled the
optimizer's categories in v2.0.1: modules that are still present in the
repository but no longer reachable from the execution pipeline.

Windows PowerShell 5.1 remains the authority for runtime behaviour; see
tests/Run-Tests.ps1 for the Windows harness and docs/KNOWN-LIMITATIONS.md.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import ps_contract_check as contract  # noqa: E402

ENGINE = ROOT / "src" / "core" / "PlatinumOptimizer.Engine.psm1"
ENTRY = ROOT / "src" / "PlatinumOptimizer.ps1"


class PipelineWiringTests(unittest.TestCase):
    def test_contract_checker_passes_on_current_sources(self) -> None:
        self.assertEqual(contract.check(), [])

    def test_entry_point_imports_every_module_the_pipeline_can_reach(self) -> None:
        text = ENTRY.read_text(encoding="utf-8")
        for module in contract.MODULES:
            with self.subTest(module=module):
                self.assertIn("core\\" + module + ".psm1", text)

    def test_network_and_gaming_modules_are_reachable_again(self) -> None:
        """Regression test for the v2.0.1 defect.

        Network, Gaming and Engine were dropped from the import list while
        their files remained in src/core, so the automatic run could only act
        on the power plan.
        """
        text = ENTRY.read_text(encoding="utf-8")
        for module in (
            "PlatinumOptimizer.Network",
            "PlatinumOptimizer.Gaming",
            "PlatinumOptimizer.Engine",
        ):
            with self.subTest(module=module):
                self.assertIn("core\\" + module + ".psm1", text)

    def test_every_stage_is_invoked_by_the_pipeline(self) -> None:
        calls = contract.called_functions(ENGINE)
        for stage in contract.REQUIRED_STAGES:
            with self.subTest(stage=stage):
                self.assertIn(stage, calls)

    def test_automatic_mode_dispatches_to_the_full_engine(self) -> None:
        automatic = (ROOT / "src" / "core" / "PlatinumOptimizer.Automatic.psm1").read_text(
            encoding="utf-8"
        )
        self.assertIn("Invoke-POFullOptimization", automatic)

    def test_no_unapproved_verbs_are_exported(self) -> None:
        """Fixes the module-import warning (previously 'Compute-POGammaRamp')."""
        for module in contract.MODULES:
            path = contract.module_path(module)
            with self.subTest(module=module):
                for name in sorted(contract.exported_functions(path)):
                    verb = name.split("-", 1)[0]
                    self.assertIn(
                        verb,
                        contract.APPROVED_VERBS,
                        f"{module} exports '{name}' with unapproved verb '{verb}'",
                    )

    def test_no_module_calls_a_function_nothing_exports(self) -> None:
        all_exports: set[str] = set()
        for module in contract.MODULES:
            all_exports.update(contract.exported_functions(contract.module_path(module)))
        for module in contract.MODULES:
            path = contract.module_path(module)
            local = contract.defined_functions(path)
            for callee in sorted(contract.called_functions(path)):
                with self.subTest(module=module, callee=callee):
                    self.assertTrue(
                        callee in all_exports or callee in local,
                        f"{module} calls '{callee}' which no module exports",
                    )


class RemovedFunctionRecoveryTests(unittest.TestCase):
    def test_add_pobackupfile_is_exported_again(self) -> None:
        core = contract.module_path("PlatinumOptimizer.Core")
        exports = contract.exported_functions(core)
        defined = contract.defined_functions(core)
        self.assertIn("Add-POBackupFile", exports)
        self.assertIn("Add-POBackupFile", defined)

    def test_network_ledger_sections_are_restorable(self) -> None:
        core = contract.module_path("PlatinumOptimizer.Core").read_text(encoding="utf-8")
        self.assertIn("'network-tcp', 'network-adapter-power'", core)
        self.assertIn("Restore-PONetworkTcpSection", core)
        self.assertIn("Restore-PONetworkAdapterPowerSection", core)

    def test_backup_change_helpers_accept_network_sections(self) -> None:
        core = contract.module_path("PlatinumOptimizer.Core").read_text(encoding="utf-8")
        self.assertEqual(
            core.count(
                "[ValidateSet('power', 'network', 'registry', 'audio', 'display', "
                "'network-tcp', 'network-adapter-power')]"
            ),
            2,
            "Add-POBackupChange and Update-POBackupChangeStatus must both accept "
            "the Network module's ledger sections",
        )


class TruthfulReportingTests(unittest.TestCase):
    def test_engine_never_pads_its_runtime(self) -> None:
        text = contract.strip_non_code(ENGINE.read_text(encoding="utf-8"))
        self.assertNotRegex(text, r"\bStart-Sleep\b")

    def test_result_status_vocabulary_is_fully_separated(self) -> None:
        """Applied / verified / already / diagnostic / skipped / failed /
        unverified / rolled back must stay distinct counters."""
        text = ENGINE.read_text(encoding="utf-8")
        for status in (
            "APPLIED_VERIFIED",
            "ALREADY_OPTIMIZED",
            "SKIPPED",
            "FAILED",
            "UNVERIFIED",
            "ROLLED_BACK",
            "DIAGNOSTIC",
            "INFO",
        ):
            with self.subTest(status=status):
                self.assertIn(status, text)
        self.assertIn("RolledBack", text)
        self.assertIn("DiagnosticOnly", text)
        self.assertIn("Unverified", text)

    def test_summary_reports_failures_separately_from_successes(self) -> None:
        text = ENGINE.read_text(encoding="utf-8")
        self.assertIn("$failed = @($rows | Where-Object { $_.Status -eq 'FAILED' })", text)
        self.assertIn("$unverified = @($rows | Where-Object { $_.Status -eq 'UNVERIFIED' })", text)
        self.assertIn("$rolledBack = @($rows | Where-Object { $_.Status -eq 'ROLLED_BACK' })", text)

    def test_final_report_states_no_performance_claim(self) -> None:
        text = ENGINE.read_text(encoding="utf-8")
        self.assertIn("No FPS", text)
        self.assertIn("not a game-server", text.lower())

    def test_backup_is_required_before_writes(self) -> None:
        text = ENGINE.read_text(encoding="utf-8")
        self.assertIn("blocked by the backup-first policy", text)


class LiveOutputTests(unittest.TestCase):
    def test_console_writer_is_stage_tagged_and_timestamped(self) -> None:
        text = ENGINE.read_text(encoding="utf-8")
        self.assertIn("Get-POConsoleTimestamp", text)
        self.assertIn("$stageTag", text)
        self.assertIn("$levelTag", text)
        self.assertIn("Write-Host $text -ForegroundColor $color", text)

    def test_console_lines_are_prefixed_with_the_stage_tag(self) -> None:
        text = ENGINE.read_text(encoding="utf-8")
        self.assertIn('"[$stageTag] $levelTag"', text)
        self.assertIn("'{0} {1}{2}' -f", text)

    def test_log_is_appended_immediately_not_buffered(self) -> None:
        text = ENGINE.read_text(encoding="utf-8")
        self.assertIn("System.IO.File]::AppendAllText", text)

    def test_stage_header_reports_progress(self) -> None:
        text = ENGINE.read_text(encoding="utf-8")
        self.assertIn("stage {2} of {3}", text)

    def test_every_stage_tag_used_by_the_specification_is_emitted(self) -> None:
        text = ENGINE.read_text(encoding="utf-8")
        for tag in ("BOOT", "SCAN", "BACKUP", "CPU", "POWER", "NETWORK", "GPU", "DISPLAY", "VERIFY"):
            with self.subTest(tag=tag):
                self.assertIn("Invoke-PO%sStage" % tag.capitalize(), text)


if __name__ == "__main__":
    unittest.main()
