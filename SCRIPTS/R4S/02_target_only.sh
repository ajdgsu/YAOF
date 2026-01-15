#!/bin/bash
clear

# 使用特定的优化
sed -i 's,-mcpu=generic,-march=armv8-a+crc+crypto,g' include/target.mk
sed -i 's,kmod-r8168,kmod-r8169,g' target/linux/rockchip/image/armv8.mk
sed -i 's/Os/O3 -march=armv8-a+crc+crypto -Wno-error -Wno-error=mismatched-new-delete/g' include/target.mk

sed -i 's,define Package\/iptables\/Default,define Package\/iptables\/Default\n  CFLAGS += -O3 -funroll-loops --param max-unroll-times=8 --param max-unrolled-insns=500 --param max-average-unrolled-insns=50,g' package/network/utils/iptables/Makefile
sed -i 's,define Package\/nftables\/Default,define Package\/nftables\/Default\n  CFLAGS += -O3 -funroll-loops --param max-unroll-times=8 --param max-unrolled-insns=500 --param max-average-unrolled-insns=50,g' package/network/utils/nftables/Makefile

#Vermagic
latest_version="$(curl -s https://github.com/openwrt/openwrt/tags | grep -Eo "v[0-9\.]+\-*r*c*[0-9]*.tar.gz" | sed -n '/[2-9]4/p' | sed -n 1p | sed 's/v//g' | sed 's/.tar.gz//g')"
wget https://downloads.openwrt.org/releases/${latest_version}/targets/rockchip/armv8/profiles.json
jq -r '.linux_kernel.vermagic' profiles.json >.vermagic
sed -i -e 's/^\(.\).*vermagic$/\1cp $(TOPDIR)\/.vermagic $(LINUX_DIR)\/.vermagic/' include/kernel-defaults.mk

# 预配置一些插件
cp -rf ../PATCH/files ./files

find ./ -name *.orig | xargs rm -f
find ./ -name *.rej | xargs rm -f

#exit 0
