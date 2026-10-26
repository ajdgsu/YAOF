#!/usr/bin/env python3
"""Check that source preparation retains the legacy acceleration providers."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class SeedPreservationTests(unittest.TestCase):
    def test_hidden_rsa_is_an_x86_image_default(self):
        source = (ROOT / 'SCRIPTS/X86/02_target_only.sh').read_text()
        self.assertIn('DEFAULT_PACKAGES += kmod-crypto-rsa', source)
        self.assertIn('target/linux/x86/64/target.mk', source)

    def test_wolplus_provider_and_safe_arguments(self):
        source = (ROOT / 'SCRIPTS/01_get_ready.sh').read_text()
        self.assertIn('a4dae85236058a0f070f8dd9b70a920492cea054', source)
        prepare = (ROOT / 'SCRIPTS/02_prepare_package.sh').read_text()
        self.assertIn('stage_directory ../wolplus-donor/luci-app-services-wolplus', prepare)
        patch = (ROOT / 'PATCH/pkgs/wolplus/100-quote-wake-arguments.patch').read_text()
        self.assertIn('shellquote(lan)', patch)
        self.assertIn('shellquote(mac)', patch)

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
