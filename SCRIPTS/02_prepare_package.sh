#!/bin/bash
clear

### 基础部分 ###
# 使用 O2 级别的优化
sed -i 's/Os/O2 -march=znver3 -Wno-error -Wno-error=mismatched-new-delete -Wno-error=unused-command-line-argument/g' include/target.mk
#sed -i 's/LDFLAGS="$(TARGET_LDFLAGS) $(EXTRA_LDFLAGS)"/LDFLAGS="$(TARGET_LDFLAGS) $(EXTRA_LDFLAGS)" -Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,-z,pack-relative-relocs -Wl,-s/g' include/package-defaults.mk
sed -i 's,XZ_SUPPORT=1,XZ_SUPPORT=1 ZSTD_SUPPORT=1 LZ4_SUPPORT=1,g' tools/squashfs4/Makefile
sed -i 's/HOSTCC="$(HOSTCC)"/HOSTCC="gcc"/g' include/u-boot.mk
#rm -rf package/new/OpenWrt-Add/openwrt-r8168
#git clone https://github.com/sbwml/package_kernel_r8126 package/new/OpenWrt-Add/openwrt-r8168
#rm -rf package/network/utils/linux-atm
#git clone https://github.com/sbwml/package_network_utils_linux-atm package/network/utils/linux-atm
#rm -rf package/boot/rkbin package/boot/uboot-rockchip package/boot/arm-trusted-firmware-rockchip
#git clone https://github.com/sbwml/package_boot_uboot-rockchip package/boot/uboot-rockchip -b v2023.04
#    git clone https://github.com/sbwml/arm-trusted-firmware-rockchip package/boot/arm-trusted-firmware-rockchip -b 0419

echo "src-git tcp_brutal https://github.com/haruue-net/openwrt-tcp-brutal.git;master" >> feeds.conf.default

# 更新 Feeds
./scripts/feeds update -a
./scripts/feeds install -a
#faster squashfs
#sed -i 's,-nopad -noappend -root-owned,-nopad -noappend -root-owned -comp xz -Xe -Xbcj arm -Xpreset 0 -Xstrategy default\,filtered\,huffman_only\,run_length_encoded\,fixed,g' include/image-commands.mk
# 移除 SNAPSHOT 标签
sed -i 's,-SNAPSHOT,,g' include/version.mk
sed -i 's,-SNAPSHOT,,g' package/base-files/image-config.in
sed -i '/CONFIG_BUILDBOT/d' include/feeds.mk
sed -i 's/;)\s*\\/; \\/' include/feeds.mk
# Nginx
sed -i "s/large_client_header_buffers 2 1k/large_client_header_buffers 4 32k/g" feeds/packages/net/nginx-util/files/uci.conf.template
sed -i "s/client_max_body_size 128M/client_max_body_size 2048M/g" feeds/packages/net/nginx-util/files/uci.conf.template
sed -i '/client_max_body_size/a\\tclient_body_buffer_size 8192M;' feeds/packages/net/nginx-util/files/uci.conf.template
sed -i '/client_max_body_size/a\\tserver_names_hash_bucket_size 128;' feeds/packages/net/nginx-util/files/uci.conf.template
sed -i '/ubus_parallel_req/a\        ubus_script_timeout 600;' feeds/packages/net/nginx/files-luci-support/60_nginx-luci-support
sed -ri "/luci-webui.socket/i\ \t\tuwsgi_send_timeout 600\;\n\t\tuwsgi_connect_timeout 600\;\n\t\tuwsgi_read_timeout 600\;" feeds/packages/net/nginx/files-luci-support/luci.locations
sed -ri "/luci-cgi_io.socket/i\ \t\tuwsgi_send_timeout 600\;\n\t\tuwsgi_connect_timeout 600\;\n\t\tuwsgi_read_timeout 600\;" feeds/packages/net/nginx/files-luci-support/luci.locations
# uwsgi
sed -i 's,procd_set_param stderr 1,procd_set_param stderr 0,g' feeds/packages/net/uwsgi/files/uwsgi.init
sed -i 's,buffer-size = 10000,buffer-size = 131072,g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's,logger = luci,#logger = luci,g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i '$a cgi-timeout = 600' feeds/packages/net/uwsgi/files-luci-support/luci-*.ini
sed -i 's/threads = 1/threads = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/processes = 3/processes = 4/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/cheaper = 1/cheaper = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
# rpcd
sed -i 's/option timeout 30/option timeout 60/g' package/system/rpcd/files/rpcd.config
sed -i 's#20) \* 1000#60) \* 1000#g' feeds/luci/modules/luci-base/htdocs/luci-static/resources/rpc.js

### FW4 ###
rm -rf ./package/network/config/firewall4
cp -rf ../openwrt_ma/package/network/config/firewall4 ./package/network/config/firewall4

### 必要的 Patches ###
# TCP optimizations
cp -rf ../PATCH/kernel/6.7_Boost_For_Single_TCP_Flow/* ./target/linux/generic/backport-6.6/
cp -rf ../PATCH/kernel/6.8_Boost_TCP_Performance_For_Many_Concurrent_Connections-bp_but_put_in_hack/* ./target/linux/generic/hack-6.6/
cp -rf ../PATCH/kernel/6.8_Better_data_locality_in_networking_fast_paths-bp_but_put_in_hack/* ./target/linux/generic/hack-6.6/
# UDP optimizations
cp -rf ../PATCH/kernel/6.7_FQ_packet_scheduling/* ./target/linux/generic/backport-6.6/
# Patch arm64 型号名称
cp -rf ../PATCH/kernel/arm/* ./target/linux/generic/hack-6.6/
# BBRv3
cp -rf ../PATCH/kernel/bbr3/* ./target/linux/generic/backport-6.6/
# LRNG
cp -rf ../PATCH/kernel/lrng/* ./target/linux/generic/hack-6.6/
#cp -rf ../PATCH/kernel/0001-prjc.patch ./target/linux/generic/backport-6.6/
echo '
# CONFIG_RANDOM_DEFAULT_IMPL is not set
CONFIG_LRNG=y
CONFIG_LRNG_DEV_IF=y
# CONFIG_LRNG_IRQ is not set
CONFIG_LRNG_JENT=y
CONFIG_LRNG_CPU=y
# CONFIG_LRNG_SCHED is not set
CONFIG_LRNG_SELFTEST=y
# CONFIG_LRNG_SELFTEST_PANIC is not set
' >>./target/linux/generic/config-6.6
# wg
cp -rf ../PATCH/kernel/wg/* ./target/linux/generic/hack-6.6/
# dont wrongly interpret first-time data
echo "net.netfilter.nf_conntrack_tcp_max_retrans=5" >>./package/kernel/linux/files/sysctl-nf-conntrack.conf
# OTHERS
cp -rf ../PATCH/kernel/others/* ./target/linux/generic/pending-6.6/

### Fullcone-NAT 部分 ###
# bcmfullcone
cp -rf ../PATCH/kernel/bcmfullcone/* ./target/linux/generic/hack-6.6/
# set nf_conntrack_expect_max for fullcone
wget -qO - https://github.com/openwrt/openwrt/commit/bbf39d07.patch | patch -p1
echo "net.netfilter.nf_conntrack_helper = 1" >>./package/kernel/linux/files/sysctl-nf-conntrack.conf
# FW4
mkdir -p package/network/config/firewall4/patches
cp -f ../PATCH/pkgs/firewall/firewall4_patches/*.patch ./package/network/config/firewall4/patches/
mkdir -p package/libs/libnftnl/patches
cp -f ../PATCH/pkgs/firewall/libnftnl/*.patch ./package/libs/libnftnl/patches/
sed -i '/PKG_INSTALL:=/iPKG_FIXUP:=autoreconf' package/libs/libnftnl/Makefile
mkdir -p package/network/utils/nftables/patches
cp -f ../PATCH/pkgs/firewall/nftables/*.patch ./package/network/utils/nftables/patches/
# Patch LuCI 以增添 FullCone 开关
pushd feeds/luci
patch -p1 <../../../PATCH/pkgs/firewall/luci/0001-luci-app-firewall-add-nft-fullcone-and-bcm-fullcone-.patch
popd
#patch -p1 <../PATCH/kernel/overlay_fixed_f2fs_options.patch

### Shortcut-FE 部分 ###
# Patch Kernel 以支持 Shortcut-FE
cp -rf ../PATCH/kernel/sfe/* ./target/linux/generic/hack-6.6/
cp -rf ../lede/target/linux/generic/pending-6.6/613-netfilter_optional_tcp_window_check.patch ./target/linux/generic/pending-6.6/613-netfilter_optional_tcp_window_check.patch
# Patch LuCI 以增添 Shortcut-FE 开关
pushd feeds/luci
patch -p1 <../../../PATCH/pkgs/firewall/luci/0002-luci-app-firewall-add-shortcut-fe-option.patch
popd

### NAT6 部分 ###
# custom nft command
patch -p1 < ../PATCH/pkgs/firewall/100-openwrt-firewall4-add-custom-nft-command-support.patch
# Patch LuCI 以增添 NAT6 开关
pushd feeds/luci
patch -p1 <../../../PATCH/pkgs/firewall/luci/0003-luci-app-firewall-add-ipv6-nat-option.patch
popd
# Patch LuCI 以支持自定义 nft 规则
pushd feeds/luci
patch -p1 <../../../PATCH/pkgs/firewall/luci/0004-luci-add-firewall-add-custom-nft-rule-support.patch
popd

### natflow 部分 ###
pushd feeds/luci
patch -p1 <../../../PATCH/pkgs/firewall/luci/0005-luci-app-firewall-add-natflow-offload-support.patch
popd

### fullcone6 ###
pushd feeds/luci
patch -p1 <../../../PATCH/pkgs/firewall/luci/0007-luci-app-firewall-add-fullcone6-option-for-nftables-.patch
popd

### Other Kernel Hack 部分 ###
# make olddefconfig
wget -qO - https://github.com/openwrt/openwrt/commit/c21a3570.patch | patch -p1
# igc-fix
cp -rf ../lede/target/linux/x86/patches-6.6/996-intel-igc-i225-i226-disable-eee.patch ./target/linux/x86/patches-6.6/996-intel-igc-i225-i226-disable-eee.patch
# btf
cp -rf ../PATCH/kernel/btf/* ./target/linux/generic/hack-6.6/

### 获取额外的基础软件包 ###
# 更换为 ImmortalWrt Uboot 以及 Target
rm -rf ./target/linux/rockchip
cp -rf ../immortalwrt_24/target/linux/rockchip ./target/linux/rockchip
cp -rf ../PATCH/kernel/rockchip/* ./target/linux/rockchip/patches-6.6/
#wget https://github.com/immortalwrt/immortalwrt/raw/refs/tags/v23.05.4/target/linux/rockchip/patches-5.15/991-arm64-dts-rockchip-add-more-cpu-operating-points-for.patch -O target/linux/rockchip/patches-6.6/991-arm64-dts-rockchip-add-more-cpu-operating-points-for.patch
rm -rf package/boot/{rkbin,uboot-rockchip,arm-trusted-firmware-rockchip}
cp -rf ../immortalwrt_24/package/boot/uboot-rockchip ./package/boot/uboot-rockchip
cp -rf ../immortalwrt_24/package/boot/arm-trusted-firmware-rockchip ./package/boot/arm-trusted-firmware-rockchip
sed -i '/REQUIRE_IMAGE_METADATA/d' target/linux/rockchip/armv8/base-files/lib/upgrade/platform.sh
# Disable Mitigations
sed -i 's,rootwait,rootwait mitigations=off,g' target/linux/rockchip/image/default.bootscript
sed -i 's,@CMDLINE@ noinitrd,noinitrd mitigations=off,g' target/linux/x86/image/grub-efi.cfg
sed -i 's,@CMDLINE@ noinitrd,noinitrd mitigations=off,g' target/linux/x86/image/grub-iso.cfg
sed -i 's,@CMDLINE@ noinitrd,noinitrd mitigations=off,g' target/linux/x86/image/grub-pc.cfg

### ADD PKG 部分 ###
cp -rf ../OpenWrt-Add ./package/new
rm -rf feeds/packages/net/{xray-core,v2ray-core,v2ray-geodata,sing-box,frp,microsocks,shadowsocks-libev,zerotier,daed}
rm -rf feeds/luci/applications/{luci-app-frps,luci-app-frpc,luci-app-zerotier,luci-app-filemanager}
rm -rf feeds/packages/utils/coremark

### 获取额外的 LuCI 应用、主题和依赖 ###
# 更换 Nodejs 版本
rm -rf ./feeds/packages/lang/node
rm -rf ./package/new/feeds_packages_lang_node-prebuilt
cp -rf ../OpenWrt-Add/feeds_packages_lang_node-prebuilt ./feeds/packages/lang/node
# 更换 golang 版本
rm -rf ./feeds/packages/lang/golang
cp -rf ../openwrt_pkg_ma/lang/golang ./feeds/packages/lang/golang
# mount cgroupv2
pushd feeds/packages
patch -p1 <../../../PATCH/pkgs/cgroupfs-mount/0001-fix-cgroupfs-mount.patch
popd
mkdir -p feeds/packages/utils/cgroupfs-mount/patches
cp -rf ../PATCH/pkgs/cgroupfs-mount/900-mount-cgroup-v2-hierarchy-to-sys-fs-cgroup-cgroup2.patch ./feeds/packages/utils/cgroupfs-mount/patches/
cp -rf ../PATCH/pkgs/cgroupfs-mount/901-fix-cgroupfs-umount.patch ./feeds/packages/utils/cgroupfs-mount/patches/
cp -rf ../PATCH/pkgs/cgroupfs-mount/902-mount-sys-fs-cgroup-systemd-for-docker-systemd-suppo.patch ./feeds/packages/utils/cgroupfs-mount/patches/
# fstool
wget -qO - https://github.com/coolsnowwolf/lede/commit/8a4db76.patch | patch -p1
# Boost 通用即插即用
rm -rf ./feeds/packages/net/miniupnpd
cp -rf ../openwrt_pkg_ma/net/miniupnpd ./feeds/packages/net/miniupnpd
wget https://github.com/miniupnp/miniupnp/commit/0e8c68d.patch -O feeds/packages/net/miniupnpd/patches/0e8c68d.patch
sed -i 's,/miniupnpd/,/,g' ./feeds/packages/net/miniupnpd/patches/0e8c68d.patch
wget https://github.com/miniupnp/miniupnp/commit/21541fc.patch -O feeds/packages/net/miniupnpd/patches/21541fc.patch
sed -i 's,/miniupnpd/,/,g' ./feeds/packages/net/miniupnpd/patches/21541fc.patch
wget https://github.com/miniupnp/miniupnp/commit/b78a363.patch -O feeds/packages/net/miniupnpd/patches/b78a363.patch
sed -i 's,/miniupnpd/,/,g' ./feeds/packages/net/miniupnpd/patches/b78a363.patch
wget https://github.com/miniupnp/miniupnp/commit/8f2f392.patch -O feeds/packages/net/miniupnpd/patches/8f2f392.patch
sed -i 's,/miniupnpd/,/,g' ./feeds/packages/net/miniupnpd/patches/8f2f392.patch
wget https://github.com/miniupnp/miniupnp/commit/60f5705.patch -O feeds/packages/net/miniupnpd/patches/60f5705.patch
sed -i 's,/miniupnpd/,/,g' ./feeds/packages/net/miniupnpd/patches/60f5705.patch
wget https://github.com/miniupnp/miniupnp/commit/3f3582b.patch -O feeds/packages/net/miniupnpd/patches/3f3582b.patch
sed -i 's,/miniupnpd/,/,g' ./feeds/packages/net/miniupnpd/patches/3f3582b.patch
cp -rf ../PATCH/pkgs/miniupnpd/301-options-force_forwarding-support.patch ./feeds/packages/net/miniupnpd/patches/
pushd feeds/packages
patch -p1 <../../../PATCH/pkgs/miniupnpd/01-set-presentation_url.patch
patch -p1 <../../../PATCH/pkgs/miniupnpd/02-force_forwarding.patch
popd
pushd feeds/luci
patch -p1 <../../../PATCH/pkgs/miniupnpd/luci-upnp-support-force_forwarding-flag.patch
popd
# 动态DNS
sed -i '/boot()/,+2d' feeds/packages/net/ddns-scripts/files/etc/init.d/ddns
# Docker 容器
rm -rf ./feeds/luci/applications/luci-app-dockerman
cp -rf ../dockerman/applications/luci-app-dockerman ./feeds/luci/applications/luci-app-dockerman
sed -i '/auto_start/d' feeds/luci/applications/luci-app-dockerman/root/etc/uci-defaults/luci-app-dockerman
#qosmate
cp -rf ../luci-app-qosmate ./package/new
cp -rf ../qosmate ./package/new
#nginx
rm -f feeds/packages/net/nginx-util/files/nginx.config
cp -f ../PATCH/nginx/nginx.config feeds/packages/net/nginx-util/files
rm -f feeds/packages/net/nginx-util/files/uci.conf.template
cp -f ../PATCH/nginx/uci.conf.template feeds/packages/net/nginx-util/files
pushd feeds/packages
wget -qO- https://github.com/openwrt/packages/commit/e2e5ee69.patch | patch -p1
wget -qO- https://github.com/openwrt/packages/pull/20054.patch | patch -p1
popd
sed -i '/sysctl.d/d' feeds/packages/utils/dockerd/Makefile
rm -rf ./feeds/luci/collections/luci-lib-docker
cp -rf ../docker_lib/collections/luci-lib-docker ./feeds/luci/collections/luci-lib-docker
# IPv6 兼容助手
patch -p1 <../PATCH/pkgs/odhcp6c/1002-odhcp6c-support-dhcpv6-hotplug.patch
# ODHCPD
mkdir -p package/network/services/odhcpd/patches
cp -f ../PATCH/pkgs/odhcpd/0001-odhcpd-improve-RFC-9096-compliance.patch ./package/network/services/odhcpd/patches/0001-odhcpd-improve-RFC-9096-compliance.patch
#wget https://github.com/openwrt/odhcpd/pull/211.patch -O package/network/services/odhcpd/patches/211.patch
wget https://github.com/openwrt/odhcpd/pull/219.patch -O package/network/services/odhcpd/patches/219.patch
wget https://github.com/openwrt/odhcpd/pull/242.patch -O package/network/services/odhcpd/patches/242.patch
mkdir -p package/network/ipv6/odhcp6c/patches
wget https://github.com/openwrt/odhcp6c/pull/75.patch -O package/network/ipv6/odhcp6c/patches/75.patch
wget https://github.com/openwrt/odhcp6c/pull/80.patch -O package/network/ipv6/odhcp6c/patches/80.patch
wget https://github.com/openwrt/odhcp6c/pull/82.patch -O package/network/ipv6/odhcp6c/patches/82.patch
wget https://github.com/openwrt/odhcp6c/pull/83.patch -O package/network/ipv6/odhcp6c/patches/83.patch
wget https://github.com/openwrt/odhcp6c/pull/84.patch -O package/network/ipv6/odhcp6c/patches/84.patch
wget https://github.com/openwrt/odhcp6c/pull/90.patch -O package/network/ipv6/odhcp6c/patches/90.patch
wget https://github.com/openwrt/odhcp6c/pull/98.patch -O package/network/ipv6/odhcp6c/patches/98.patch
# watchcat
echo > ./feeds/packages/utils/watchcat/files/watchcat.config
# 默认开启 Irqbalance
#sed -i "s/enabled '0'/enabled '1'/g" feeds/packages/utils/irqbalance/files/irqbalance.config

# 使用 TEO CPU 空闲调度器
KERNEL_VERSION="6.6"
CONFIG_CONTENT='
CONFIG_CPU_IDLE_GOV_MENU=n
CONFIG_CPU_IDLE_GOV_TEO=y
'
# 查找所有与内核 6.6 相关的配置文件并将这些配置项追加到文件末尾
find ./target/linux/ -name "config-${KERNEL_VERSION}" | xargs -I{} sh -c "echo '$CONFIG_CONTENT' | tee -a {} > /dev/null"

### 最后的收尾工作 ###
# Lets Fuck
mkdir -p package/base-files/files/usr/bin
cp -rf ../OpenWrt-Add/fuck ./package/base-files/files/usr/bin/fuck
# 生成默认配置及缓存
#sed -i 's, , ,g' target/linux/generic/config-6.6
###clang
    rm -rf feeds/packages/net/xtables-addons
    git clone https://github.com/sbwml/kmod_packages_net_xtables-addons feeds/packages/net/xtables-addons
    # netatop
    sed -i 's/$(MAKE)/$(KERNEL_MAKE)/g' feeds/packages/admin/netatop/Makefile
    cp -f ../PATCH/kernel/clang/900-fix-build-with-clang.patch feeds/packages/admin/netatop/patches/900-fix-build-with-clang.patch
    # dmx_usb_module
    rm -rf feeds/packages/libs/dmx_usb_module
    git clone https://git.cooluc.com/sbwml/feeds_packages_libs_dmx_usb_module feeds/packages/libs/dmx_usb_module
    # macremapper
#    patch -Np1 ../PATCH/kernel/clang/100-macremapper-fix-clang-build.patch 
    # coova-chilli module
    rm -rf feeds/packages/net/coova-chilli
    git clone https://github.com/sbwml/kmod_packages_net_coova-chilli feeds/packages/net/coova-chilli
    
    patch -p1 < ../PATCH/pkgs/macremapper/100-macremapper-fix-clang-build.patch
###clang
rm -rf .config
patch -p1 < ../PATCH/kernel/clang/0005-kernel-Add-support-for-llvm-clang-compiler.patch
patch -p1 < ../PATCH/kernel/clang/0008-meson-add-platform-variable-to-cross-compilation-fil.patch
sed -i 's,CONFIG_WERROR=y,# CONFIG_WERROR is not set,g' target/linux/generic/config-6.6
sed -i 's,CONFIG_LTO_NONE=y,CONFIG_LTO_CLANG_FULL=y,g' target/linux/generic/config-6.6
sed -i 's,# CONFIG_SQUASHFS_4K_DEVBLK_SIZE is not set,CONFIG_SQUASHFS_4K_DEVBLK_SIZE=y,g' target/linux/generic/config-6.6
sed -i 's,# CONFIG_SQUASHFS_LZ4 is not set,CONFIG_SQUASHFS_LZ4=y,g' target/linux/generic/config-6.6
sed -i 's,# CONFIG_SQUASHFS_EMBEDDED is not set,CONFIG_SQUASHFS_EMBEDDED=y,g' target/linux/generic/config-6.6
sed -i 's,CONFIG_SQUASHFS_XZ=y,# CONFIG_SQUASHFS_XZ is not set,g' target/linux/generic/config-6.6
sed -i 's,CONFIG_SQUASHFS_FRAGMENT_CACHE_SIZE=3,CONFIG_SQUASHFS_FRAGMENT_CACHE_SIZE=5,g' target/linux/generic/config-6.6
echo "CONFIG_IOSCHED_BFQ=y" >> target/linux/generic/config-6.6
#sed -i 's,CONFIG_CMDLINE="",CONFIG_CMDLINE="rootfs_mount_options.background_gc=on rootfs_mount_options.gc_merge rootfs_mount_options.flush_merge rootfs_mount_options.extent_cache rootfs_mount_options.data_flush rootfs_mount_options.checkpoint_merge rootfs_mount_options.compress_algorithm=lz4 rootfs_mount_options.compress_extension=* rootfs_mount_options.compress_chksum rootfs_mount_options.compress_cache rootfs_mount_options.atgc rootfs_mount_options.age_extent_cache rootfs_mount_options.lazytime rootfs_mount_options.nofail rootfs_mount_options.fsync_mode=strict",g' target/linux/generic/config-6.6
sed -i 's,SQUASHFSCOMP := gzip,SQUASHFSCOMP := lz4 -Xhc,g' include/image.mk
sed -i 's,xz $(LZMA_XZ_OPTIONS) $(BCJ_FILTER),lz4 -Xhc,g' include/image.mk

echo -e "\nconfig LRU_GEN\n       bool \"Multi-Gen LRU\"\n       \n       \n       help\n         A high performance LRU implementation to overcommit memory. See\n         Documentation/admin-guide/mm/multigen_lru.rst for details.\n\nconfig LRU_GEN_ENABLED\n       bool \"Enable by default\"\n       depends on LRU_GEN\n       help\n         This option enables the multi-gen LRU by default.\n\nconfig LRU_GEN_STATS\n       bool \"Full stats for debugging\"\n       depends on LRU_GEN\n       help\n         Do not enable this option unless you plan to look at historical stats\n         from evicted generations for debugging purpose.\n\n         This option has a per-memcg and per-node memory overhead.\n\nconfig LRU_GEN_WALKS_MMU\n       def_bool y\n       depends on LRU_GEN && ARCH_HAS_HW_PTE_YOUNG" >> config/Config-kernel.in
echo "CONFIG_F2FS_FS_COMPRESSION=y" >> target/linux/rockchip/armv8/config-6.6
echo "CONFIG_F2FS_FS_LZ4=y" >> target/linux/rockchip/armv8/config-6.6
echo "# CONFIG_F2FS_FS_LZO is not set" >> target/linux/rockchip/armv8/config-6.6
echo "# CONFIG_F2FS_FS_ZSTD is not set" >> target/linux/rockchip/armv8/config-6.6
cp -rf ../PATCH/pkgs/jool/Makefile feeds/packages/net/jool/Makefile

#exit 0
