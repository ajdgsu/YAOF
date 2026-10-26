#!/usr/bin/env python3
"""Compile and exercise the actual C4 patch payload without kernel privileges.

Requires Python's standard library and a C compiler. No packages are installed.
The shim is not a substitute for kernel compilation or network acceptance.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "PATCH/kernel/c4/010-net-ipv4-add-c4-tcp-congestion-control.patch"


def c4_source():
    payload = PATCH.read_text().split("+++ b/net/ipv4/tcp_c4.c\n", 1)[1]
    return "\n".join(line[1:] for line in payload.splitlines() if line.startswith("+") and not line.startswith("+++")) + "\n"


class C4Tests(unittest.TestCase):
    def test_actual_patch_payload(self):
        source = c4_source()
        source = "\n".join(line for line in source.splitlines() if not line.startswith("#include"))
        with tempfile.TemporaryDirectory(prefix="yaof-c4-") as tmp:
            tmp = Path(tmp)
            (tmp / "tcp_c4.c").write_text(source)
            for module in (False, True):
                binary = tmp / ("c4-module" if module else "c4-builtin")
                command = shlex.split(os.environ.get("CC", "cc"))
                command += ["-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                            "-Wno-unused-parameter", "-Wno-unused-function", "-fsanitize=undefined",
                            "-fno-sanitize-recover=all", "-I", str(tmp), "-I", str(ROOT / "tools/testing")]
                if module:
                    command += ["-DMODULE"]
                command += [str(ROOT / "tools/testing/c4_test.c"), "-o", str(binary)]
                subprocess.run(command, check=True)
                subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
