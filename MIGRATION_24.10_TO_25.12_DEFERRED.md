# 24.10 -> 25.12 Migration Status

## Scope
This file records the 24.10 custom changes that remain intentionally deferred
from branch `25.12`, along with items resolved during build verification.

## Deferred Patches
- `PATCH/kernel/clang/0005-kernel-Add-support-for-llvm-clang-compiler.patch`
- `PATCH/kernel/clang/0008-meson-add-platform-variable-to-cross-compilation-fil.patch`
- `PATCH/kernel/clang/100-macremapper-fix-clang-build.patch`
- `PATCH/kernel/clang/900-fix-build-with-clang.patch`
- `PATCH/pkgs/macremapper/100-macremapper-fix-clang-build.patch`

## Resolved During 25.12 Verification
- MGLRU support was migrated and is applied by `SCRIPTS/02_prepare_package.sh`.
- The obsolete BBRv3/faster-BBR patch series was removed; the X86 target uses
  the maintained C4 congestion-control patch instead.
- The stale GCC 15 toolchain and libbpf compatibility patches were removed
  because the relevant fixes are already present upstream.
- The module-size validation bypass, Cloudflare zlib patch, and fixed F2FS
  overlay patch were removed from the verified 25.12 patch set.

## Deferred Script Fragments
The following 24.10-specific script fragments were intentionally excluded:
- kernel `6.6`-specific path edits (`hack-6.6`, `config-6.6`)
- clang toolchain injection blocks (`###clang` section)
- xtables-addons kernel 6.6 compile workaround
- direct application of `PATCH/kernel/clang/*`

## Reason
To keep `25.12` stable first and avoid introducing branch-specific regressions from `24.10` (especially kernel version coupling and clang/xtables-specific fixes).

## Follow-up
Re-evaluate only the remaining deferred clang and macremapper items
incrementally during future `25.12` OpenWrt build verification.
