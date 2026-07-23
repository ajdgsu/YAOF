#!/bin/bash

set -Eeuo pipefail

# 这个脚本的作用是从不同的仓库中克隆openwrt相关的代码，并进行一些处理

# 定义一个函数，用来克隆指定的仓库和分支
clone_repo() {
  # 参数1是仓库地址，参数2是分支名，参数3是目标目录
  local repo_url="$1"
  local branch_name="$2"
  local target_dir="$3"
  # 克隆仓库到目标目录，并指定分支名和深度为1
  git clone -b "$branch_name" --depth 1 "$repo_url" "$target_dir"
}

source "./SCRIPTS/00_resolve_openwrt_release.sh"

# 定义一些变量，存储仓库地址和分支名
if [[ -n "${OPENWRT_RELEASE:-}" ]]; then
  if [[ ! "$OPENWRT_RELEASE" =~ ^v25\.12\.[0-9]+$ ]]; then
    echo "invalid OPENWRT_RELEASE: $OPENWRT_RELEASE" >&2
    exit 1
  fi
  latest_release="$OPENWRT_RELEASE"
else
  latest_release="$(resolve_openwrt_release)"
fi
immortalwrt_repo="https://github.com/immortalwrt/immortalwrt.git"
immortalwrt_pkg_repo="https://github.com/immortalwrt/packages.git"
immortalwrt_luci_repo="https://github.com/immortalwrt/luci.git"
lede_repo="https://github.com/coolsnowwolf/lede.git"
lede_luci_repo="https://github.com/coolsnowwolf/luci.git"
lede_pkg_repo="https://github.com/coolsnowwolf/packages.git"
openwrt_repo="https://github.com/openwrt/openwrt.git"
openwrt_pkg_repo="https://github.com/openwrt/packages.git"
openwrt_luci_repo="https://github.com/openwrt/luci.git"
lienol_repo="https://github.com/Lienol/openwrt.git"
lienol_pkg_repo="https://github.com/Lienol/openwrt-package"
openwrt_add_repo="https://github.com/QiuSimons/OpenWrt-Add.git"
openwrt_node_repo="https://github.com/nxhack/openwrt-node-packages.git"
passwall_pkg_repo="https://github.com/xiaorouji/openwrt-passwall-packages"
passwall_luci_repo="https://github.com/xiaorouji/openwrt-passwall"
openwrt_third_repo="https://github.com/jjm2473/openwrt-third"
dockerman_repo="https://github.com/lisaac/luci-app-dockerman"
diskman_repo="https://github.com/lisaac/luci-app-diskman"
docker_lib_repo="https://github.com/lisaac/luci-lib-docker"
mosdns_repo="https://github.com/QiuSimons/openwrt-mos"
ssrp_repo="https://github.com/fw876/helloworld"
zxlhhyccc_repo="https://github.com/zxlhhyccc/bf-package-master"
linkease_repo="https://github.com/linkease/openwrt-app-actions"
linkease_pkg_repo="https://github.com/jjm2473/packages"
linkease_luci_repo="https://github.com/jjm2473/luci"
sirpdboy_repo="https://github.com/sirpdboy/sirpdboy-package"
sbwdaednext_repo="https://github.com/sbwml/luci-app-daed-next"
lucidaednext_repo="https://github.com/QiuSimons/luci-app-daed-next"
sbwfw876_repo="https://github.com/sbwml/openwrt_helloworld"
sbw_pkg_repo="https://github.com/sbwml/openwrt_pkgs"
natmap_repo="https://github.com/blueberry-pie-11/luci-app-natmap"
xwrt_repo="https://github.com/QiuSimons/openwrt-natflow"
qosmate="https://github.com/hudra0/qosmate.git"
luci_app_qosmate="https://github.com/hudra0/luci-app-qosmate.git"
tcp_brutal="https://github.com/haruue-net/openwrt-tcp-brutal.git"
lucky="https://github.com/sirpdboy/luci-app-lucky.git"

# 检查所有目标目录，避免并行克隆覆盖已有内容
clone_destinations=(
  openwrt openwrt_snap immortalwrt_24 immortalwrt_23 lede lede_pkg_ma
  openwrt_ma openwrt_pkg_ma OpenWrt-Add dockerman docker_lib qosmate
  luci-app-qosmate lucky tcp_brutal
)
for clone_destination in "${clone_destinations[@]}"; do
  if [[ -e "$clone_destination" ]]; then
    echo "clone destination already exists: $clone_destination" >&2
    exit 1
  fi
done

# 开始克隆仓库，并行执行
clone_pids=()
clone_names=()
start_clone() {
  clone_repo "$1" "$2" "$3" &
  clone_pids+=("$!")
  clone_names+=("$3")
}

start_clone "$openwrt_repo" "$latest_release" openwrt
#clone_repo $openwrt_repo openwrt-25.12 openwrt &
start_clone "$openwrt_repo" openwrt-25.12 openwrt_snap
start_clone "$immortalwrt_repo" openwrt-24.10 immortalwrt_24
start_clone "$immortalwrt_repo" openwrt-23.05 immortalwrt_23

start_clone "$lede_repo" master lede
start_clone "$lede_pkg_repo" master lede_pkg_ma
start_clone "$openwrt_repo" main openwrt_ma
start_clone "$openwrt_pkg_repo" master openwrt_pkg_ma
start_clone "$openwrt_add_repo" master OpenWrt-Add
start_clone "$dockerman_repo" master dockerman
start_clone "$docker_lib_repo" master docker_lib

start_clone "$qosmate" main qosmate
start_clone "$luci_app_qosmate" main luci-app-qosmate
start_clone "$lucky" main lucky
start_clone "$tcp_brutal" master tcp_brutal

# 等待所有后台任务完成，并在任何失败后停止后续处理
clone_failed=0
for clone_index in "${!clone_pids[@]}"; do
  if ! wait "${clone_pids[$clone_index]}"; then
    echo "clone failed: ${clone_names[$clone_index]}" >&2
    clone_failed=1
  fi
done
if (( clone_failed != 0 )); then
  exit 1
fi

# 进行一些处理
cp -rf openwrt_snap/include/package-pack.mk /tmp/package-pack.mk.bak
cp -rf openwrt_snap/include/package.mk /tmp/package.mk.bak
cp -rf openwrt_snap/include/kernel.mk /tmp/kernel.mk.bak
cp -rf openwrt_snap/scripts/metadata.pm /tmp/metadata.pm.bak
cp -rf openwrt/package/libs/toolchain/Makefile /tmp/Makefile.bak
cp -rf openwrt/package/system/procd /tmp/procd.bak
cp -rf openwrt/package/libs/libubox /tmp/libubox.bak
find openwrt/package/* -maxdepth 0 ! -name 'firmware' ! -name 'kernel' ! -name 'base-files' ! -name 'Makefile' -exec rm -rf {} +
rm -rf ./openwrt/package/base-files/files/lib
cp -rf ./openwrt_snap/package/base-files/files/lib ./openwrt/package/base-files/files/
rm -rf ./openwrt_snap/package/firmware ./openwrt_snap/package/kernel ./openwrt_snap/package/base-files ./openwrt_snap/package/Makefile
cp -rf ./openwrt_snap/package/* ./openwrt/package/
cp -rf /tmp/package-pack.mk.bak ./openwrt/include/package-pack.mk
cp -rf /tmp/package.mk.bak ./openwrt/include/package.mk
cp -rf /tmp/kernel.mk.bak ./openwrt/include/kernel.mk
cp -rf /tmp/metadata.pm.bak ./openwrt/scripts/metadata.pm
cp -rf /tmp/Makefile.bak ./openwrt/package/libs/toolchain/Makefile
cp -rf ./openwrt_snap/feeds.conf.default ./openwrt/feeds.conf.default
rm -rf openwrt/package/system/procd
cp -rf /tmp/procd.bak ./openwrt/package/system/procd
rm -rf openwrt/package/libs/libubox
cp -rf /tmp/libubox.bak ./openwrt/package/libs/libubox

# 退出脚本
exit 0
