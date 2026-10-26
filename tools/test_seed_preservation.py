#!/usr/bin/env python3
"""Check that source preparation retains the legacy acceleration providers."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class SeedPreservationTests(unittest.TestCase):
    def test_pinned_legacy_provider(self):
        source = (ROOT / 'SCRIPTS/01_get_ready.sh').read_text()
        self.assertIn('ee22ca3f6086a525d62d702f9ad41c0e77941c40', source)
        self.assertIn('OpenWrt-Add-legacy', source)
        prepare = (ROOT / 'SCRIPTS/02_prepare_package.sh').read_text()
        self.assertIn('stage_directory ../OpenWrt-Add-legacy/shortcut-fe ./package/new/shortcut-fe', prepare)
        self.assertIn('stage_directory ../lede/package/libs/pcre ./package/libs/pcre', prepare)
        self.assertIn('usr/include/shortcut-fe-legacy', prepare)


if __name__ == '__main__':
    unittest.main()
