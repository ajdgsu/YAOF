# 24.10 -> 25.12 Deferred Items

## Scope
This file records 24.10 custom changes that were intentionally **not** migrated into branch `25.12` during the conservative sync.

## Deferred Patches
- `PATCH/kernel/0900-kernel-add-mglru.patch`
- `PATCH/kernel/bbr3/010-0099-fasterbbr-tsunami.patch`
- `PATCH/kernel/btf/992-tools-libbpf-fix-gcc15-const-qualifier.patch`
- `PATCH/kernel/clang/0005-kernel-Add-support-for-llvm-clang-compiler.patch`
- `PATCH/kernel/clang/0008-meson-add-platform-variable-to-cross-compilation-fil.patch`
- `PATCH/kernel/clang/100-macremapper-fix-clang-build.patch`
- `PATCH/kernel/clang/202-toolchain-gcc-add-support-for-GCC-15.patch`
- `PATCH/kernel/clang/900-fix-build-with-clang.patch`
- `PATCH/kernel/cloudflare-zlib.patch`
- `PATCH/kernel/overlay_fixed_f2fs_options.patch`
- `PATCH/pkgs/macremapper/100-macremapper-fix-clang-build.patch`

## Deferred Script Fragments
The following 24.10-specific script fragments were intentionally excluded:
- kernel `6.6`-specific path edits (`hack-6.6`, `config-6.6`)
- clang toolchain injection blocks (`###clang` section)
- xtables-addons kernel 6.6 compile workaround
- direct application of `PATCH/kernel/clang/*`

## Reason
To keep `25.12` stable first and avoid introducing branch-specific regressions from `24.10` (especially kernel version coupling and clang/xtables-specific fixes).

## Follow-up
Re-evaluate and migrate deferred items incrementally during real `25.12` OpenWrt build verification.
