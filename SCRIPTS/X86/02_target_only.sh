#!/bin/bash

set -Eeuo pipefail

source ./00_resolve_openwrt_release.sh

# Use plain LZ4 for x86 SquashFS images. The high-compression -Xhc mode is
# intentionally disabled.
sed -i '/^SQUASHFSCOMP := /d' target/linux/x86/image/Makefile
sed -i '/include $(INCLUDE_DIR)\/image.mk/a SQUASHFSCOMP := lz4' \
    target/linux/x86/image/Makefile

sed -i \
    -e '/^CONFIG_LZ4_DECOMPRESS=/d' \
    -e '/^# CONFIG_LZ4_DECOMPRESS is not set$/d' \
    -e '/^CONFIG_SQUASHFS_LZ4=/d' \
    -e '/^# CONFIG_SQUASHFS_LZ4 is not set$/d' \
    -e '/^CONFIG_SQUASHFS_XZ=/d' \
    -e '/^# CONFIG_SQUASHFS_XZ is not set$/d' \
    target/linux/x86/config-6.12
printf '%s\n' \
    'CONFIG_LZ4_DECOMPRESS=y' \
    'CONFIG_SQUASHFS_LZ4=y' \
    '# CONFIG_SQUASHFS_XZ is not set' \
    >> target/linux/x86/config-6.12

sed -i \
    '/define KernelPackage\/fs-squashfs/,/endef/ s/CONFIG_SQUASHFS_XZ=y/CONFIG_SQUASHFS_LZ4=y/' \
    package/kernel/linux/modules/fs.mk

sed -i 's/O2/O3 -march=znver4 -Wno-error -Wno-error=mismatched-new-delete/g' include/target.mk

# libsodium
sed -i 's,no-mips16 no-lto,no-mips16,g' feeds/packages/libs/libsodium/Makefile

echo '#!/bin/sh
# Put your custom commands here that should be executed once
# the system init finished. By default this file does nothing.

if grep -q "Default string" /tmp/sysinfo/model 2>/dev/null; then
    echo "Generic PC" > /tmp/sysinfo/model
fi

PSTATE_STATUS_FILE="/sys/devices/system/cpu/intel_pstate/status"
if [ -f "$PSTATE_STATUS_FILE" ]; then
    if [ "$(cat "$PSTATE_STATUS_FILE")" = "passive" ]; then
        echo "active" > "$PSTATE_STATUS_FILE"
    fi
    for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$cpu_gov" ] && echo "powersave" > "$cpu_gov"
    done
    for cpu_epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [ -f "$cpu_epp" ] && echo "balance_performance" > "$cpu_epp"
    done
fi

exit 0
' > ./package/base-files/files/etc/rc.local

#Vermagic
latest_version="$(resolve_openwrt_release)"
download_version="${latest_version#v}"
profiles_tmp="$(mktemp ./profiles.json.XXXXXX)"
vermagic_tmp="$(mktemp ./.vermagic.XXXXXX)"
cleanup_vermagic_download() {
    rm -f "$profiles_tmp" "$vermagic_tmp"
}
trap cleanup_vermagic_download EXIT
wget --server-response --show-progress --https-only --timeout=30 --tries=3 \
    -O "$profiles_tmp" \
    "https://downloads.openwrt.org/releases/${download_version}/targets/x86/64/profiles.json"
jq -e -r '.linux_kernel.vermagic | strings | select(length > 0)' \
    "$profiles_tmp" > "$vermagic_tmp"
test -s "$vermagic_tmp"
mv -f "$profiles_tmp" profiles.json
mv -f "$vermagic_tmp" .vermagic
trap - EXIT
sed -i -e 's/^\(.\).*vermagic$/\1cp $(TOPDIR)\/.vermagic $(LINUX_DIR)\/.vermagic/' include/kernel-defaults.mk

# 预配置一些插件
cp -rf ../PATCH/files ./files

find ./ -name *.orig | xargs rm -f
find ./ -name *.rej | xargs rm -f

exit 0
