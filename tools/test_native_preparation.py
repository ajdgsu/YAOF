#!/usr/bin/env python3
"""Regression checks for native preparation isolation."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class NativePreparationTests(unittest.TestCase):
    def test_backups_are_run_local(self):
        source = (ROOT / "SCRIPTS/01_get_ready.sh").read_text()
        self.assertNotRegex(source, r"/tmp/[^\s]*\.bak")
        self.assertIn('mktemp -d "$PWD/.yaof-prepare-backup.XXXXXX"', source)
        self.assertIn('"$prepare_backup/procd.bak"', source)

    def test_donor_is_checked_and_waited(self):
        source = (ROOT / "SCRIPTS/01_get_ready.sh").read_text()
        destinations = re.search(r"clone_destinations=\((.*?)\)", source, re.S).group(1)
        self.assertIn("imm_pkg", destinations.split())
        self.assertIn('start_clone "$immortalwrt_pkg_repo" master imm_pkg', source)

    def test_removed_rust_patch_is_not_downloaded(self):
        source = (ROOT / "SCRIPTS/02_prepare_package.sh").read_text()
        self.assertNotIn("rust-lang/rust/commit/cdae267.patch", source)
        self.assertIn("RUSTC_GLOBAL_CODEGEN_FLAGS", source)

    def test_target_preserves_patch_evidence(self):
        source = (ROOT / "SCRIPTS/X86/02_target_only.sh").read_text()
        self.assertNotRegex(source, r"find .*\.(orig|rej).*rm")


if __name__ == "__main__":
    unittest.main()
