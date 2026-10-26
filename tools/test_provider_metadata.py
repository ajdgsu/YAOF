#!/usr/bin/env python3
"""Exercise the real provider metadata generator without changing seed packages."""
import pathlib
import re
import subprocess
import sys
root = pathlib.Path(sys.argv[1]).resolve()
result = subprocess.run(['perl', 'scripts/package-metadata.pl', 'config', 'tmp/.packageinfo'], cwd=root, check=True, capture_output=True, text=True).stdout
for consumer, default, alternative in [
    ('luci-app-homeproxy', 'sing-box', 'sing-box-tiny'),
    ('momo', 'sing-box', 'sing-box-tiny'),
    ('luci-app-momo', 'momo', None),
    ('luci-app-weechat', 'weechat-minimal', 'weechat-full'),
]:
    match = re.search(r'\tconfig PACKAGE_' + re.escape(consumer) + r'\n(.*?)(?=\n\tconfig |\Z)', result, re.S)
    assert match, consumer
    block = match.group(1)
    for line in block.splitlines():
        if 'depends on' in line:
            assert not re.search(r'PACKAGE_' + re.escape(consumer) + r'(?![\w-])', line), line
    if alternative:
        assert f'select PACKAGE_{default} if PACKAGE_{alternative}<PACKAGE_{consumer}' in block, block
print('All four consumer dependency graphs are non-self-referential; provider select ranks preserved')
