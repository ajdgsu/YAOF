#!/bin/bash
set -euo pipefail

if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear
fi

exec {PREPARE_LOCK_FD}<.
if ! flock -n "${PREPARE_LOCK_FD}"; then
	echo "Another 02_prepare_package.sh instance is modifying this tree" >&2
	exit 1
fi

reject_symlink_path() {
	local path=$1
	local component

	# Relative paths must also validate the logical working-directory ancestry.
	# This keeps checks effective after pushd changes the patch application root.
	if [[ "${path}" != /* ]]; then
		path="$(pwd -L)/${path}"
	fi
	while [[ "${path}" != . && "${path}" != / ]]; do
		if [[ -L "${path}" ]]; then
			echo "Symlink path component rejected: ${path}" >&2
			return 1
		fi
		component=${path%/*}
		if [[ "${component}" == "${path}" ]]; then
			path=.
		elif [[ -z "${component}" ]]; then
			path=/
		else
			path=${component}
		fi
	done
}

check_patch_destination() {
	local source=$1
	local destination=$2
	local destination_dir

	if ! reject_symlink_path "${source}" || ! reject_symlink_path "${destination}" || [[ ! -f "${source}" ]]; then
		echo "Missing patch source: ${source}" >&2
		return 1
	fi
	destination_dir=${destination%/*}
	if [[ -L "${destination_dir}" || ! -d "${destination_dir}" ]]; then
		echo "Missing patch directory: ${destination_dir}" >&2
		return 1
	fi
	if [[ -e "${destination}" || -L "${destination}" ]]; then
		if [[ -L "${destination}" || ! -f "${destination}" ]] || ! cmp -s "${source}" "${destination}"; then
			echo "Patch collision: ${destination}" >&2
			return 1
		fi
	fi
	return 0
}

stage_patch() {
	local source=$1
	local destination=$2
	local destination_dir
	local temporary

	if ! reject_symlink_path "${source}" || ! reject_symlink_path "${destination}" || [[ ! -f "${source}" ]]; then
		echo "Missing patch source: ${source}" >&2
		return 1
	fi
	destination_dir=${destination%/*}
	if [[ -L "${destination_dir}" || ! -d "${destination_dir}" ]]; then
		echo "Missing patch directory: ${destination_dir}" >&2
		return 1
	fi
	if [[ -e "${destination}" || -L "${destination}" ]]; then
		if [[ -L "${destination}" || ! -f "${destination}" ]] || ! cmp -s "${source}" "${destination}"; then
			echo "Patch collision: ${destination}" >&2
			return 1
		fi
		return 0
	fi

	temporary=$(mktemp "${destination}.tmp.XXXXXX")
	if ! install -m 0644 "${source}" "${temporary}"; then
		rm -f "${temporary}"
		return 1
	fi
	if ln "${temporary}" "${destination}" 2>/dev/null; then
		rm -f "${temporary}"
		return 0
	fi
	if [[ ! -L "${destination}" && -f "${destination}" ]] && cmp -s "${source}" "${destination}"; then
		rm -f "${temporary}"
		return 0
	fi
	rm -f "${temporary}"
	echo "Patch collision: ${destination}" >&2
	return 1
}

directory_modes_match() {
	local source=$1
	local destination=$2
	local comparison=${3:-exact}

	cmp -s \
		<(cd "${source}" && {
			if [[ "${comparison}" == cgroup ]]; then
				find -P . -path './patches' -prune -o -printf '%P\t%y\t%m\0'
			else
				find -P . -printf '%P\t%y\t%m\0'
			fi
		} | LC_ALL=C sort -z) \
		<(cd "${destination}" && {
			if [[ "${comparison}" == cgroup ]]; then
				find -P . -path './patches' -prune -o -printf '%P\t%y\t%m\0'
			else
				find -P . -printf '%P\t%y\t%m\0'
			fi
		} | LC_ALL=C sort -z)
}

directory_matches_exactly() {
	local source=$1
	local destination=$2

	if ! reject_symlink_path "${source}" || ! reject_symlink_path "${destination}" || [[ ! -d "${source}" || ! -d "${destination}" ]]; then
		return 1
	fi
	if find -P "${source}" -type l -print -quit | grep -q . || find -P "${destination}" -type l -print -quit | grep -q .; then
		return 1
	fi
	diff --brief --recursive --no-dereference "${source}" "${destination}" >/dev/null &&
		directory_modes_match "${source}" "${destination}"
}

stage_directory() {
	local source=$1
	local destination=$2
	local destination_dir
	local temporary

	if ! reject_symlink_path "${source}" || ! reject_symlink_path "${destination}" || [[ ! -d "${source}" ]] || find -P "${source}" -type l -print -quit | grep -q .; then
		echo "Missing directory source: ${source}" >&2
		return 1
	fi
	destination_dir=${destination%/*}
	if [[ -L "${destination_dir}" || ! -d "${destination_dir}" ]]; then
		echo "Missing destination directory: ${destination_dir}" >&2
		return 1
	fi
	if [[ -e "${destination}" || -L "${destination}" ]]; then
		if directory_matches_exactly "${source}" "${destination}"; then
			return 0
		fi
		echo "Directory collision: ${destination}" >&2
		return 1
	fi

	temporary=$(mktemp -d "${destination}.tmp.XXXXXX")
	if ! cp -a "${source}/." "${temporary}/"; then
		rm -rf "${temporary}"
		return 1
	fi
	if ! mv -T -n "${temporary}" "${destination}"; then
		rm -rf "${temporary}"
		return 1
	fi
	if [[ ! -e "${temporary}" ]]; then
		return 0
	fi
	rm -rf "${temporary}"
	echo "Directory collision: ${destination}" >&2
	return 1
}

directory_matches_source() {
	local source=$1
	local destination=$2

	if ! reject_symlink_path "${source}" || ! reject_symlink_path "${destination}" || [[ ! -d "${source}" || ! -d "${destination}" ]]; then
		return 1
	fi
	if find -P "${source}" -type l -print -quit | grep -q . || find -P "${destination}" -type l -print -quit | grep -q .; then
		return 1
	fi
	# The init file is validated separately as an exact pre- or post-patch state.
	diff --brief --recursive --no-dereference --exclude=patches --exclude=cgroupfs-mount.init "${source}" "${destination}" >/dev/null &&
		directory_modes_match "${source}" "${destination}" cgroup
}

replace_file() {
	local source=$1
	local destination=$2
	local destination_dir
	local temporary

	if ! reject_symlink_path "${source}" || ! reject_symlink_path "${destination}" || [[ ! -f "${source}" ]]; then
		echo "Missing replacement source: ${source}" >&2
		return 1
	fi
	destination_dir=${destination%/*}
	if [[ -L "${destination_dir}" || ! -d "${destination_dir}" ]]; then
		echo "Missing replacement directory: ${destination_dir}" >&2
		return 1
	fi
	temporary=$(mktemp "${destination}.tmp.XXXXXX")
	if ! install -m 0644 "${source}" "${temporary}"; then
		rm -f "${temporary}"
		return 1
	fi
	if ! reject_symlink_path "${destination}" || ! mv -fT "${temporary}" "${destination}"; then
		rm -f "${temporary}"
		echo "Failed to replace: ${destination}" >&2
		return 1
	fi
}

normalize_exact_line() {
	local file=$1
	local expected=$2
	local temporary

	if [[ ! -f "${file}" ]]; then
		echo "Missing line-normalization target: ${file}" >&2
		return 1
	fi
	temporary=$(mktemp "${file}.tmp.XXXXXX")
	if ! EXPECTED_LINE="${expected}" awk '
		BEGIN { expected = ENVIRON["EXPECTED_LINE"] }
		$0 == expected {
			if (!seen) {
				print
				seen = 1
			}
			next
		}
		{ print }
		END {
			if (!seen) print expected
		}
	' "${file}" >"${temporary}"; then
		rm -f -- "${temporary}"
		return 1
	fi
	if ! chmod --reference="${file}" "${temporary}" || ! mv -f -- "${temporary}" "${file}"; then
		rm -f -- "${temporary}"
		return 1
	fi
}

normalize_patch_target() {
	local path=$1
	local component
	local normalized=

	[[ "${path}" != /* ]] || return 1
	while [[ -n "${path}" ]]; do
		component=${path%%/*}
		if [[ "${path}" == */* ]]; then
			path=${path#*/}
		else
			path=
		fi
		case "${component}" in
			''|.)
				;;
			..)
				if [[ "${normalized}" == */* ]]; then
					normalized=${normalized%/*}
				elif [[ -n "${normalized}" ]]; then
					normalized=
				else
					return 1
				fi
				;;
			*)
				normalized+="${normalized:+/}${component}"
				;;
		esac
	done
	[[ -n "${normalized}" ]] || return 1
	printf '%s\n' "${normalized}"
}

strip_patch_target() {
	local path=$1

	[[ "${path}" == /dev/null ]] && {
		printf '%s\n' "${path}"
		return 0
	}
	[[ "${path}" != /* && "${path}" == */* ]] || return 1
	path=${path#*/}
	while [[ "${path}" == /* ]]; do
		path=${path#/}
	done
	[[ -n "${path}" ]] || return 1
	printf '%s\n' "${path}"
}

validate_patch_target() {
	local path=$1
	local normalized

	[[ "${path}" == /dev/null ]] && return 0
	case "${path}" in
		/*)
			echo "Absolute patch target rejected: ${path}" >&2
			return 1
			;;
	esac
	if ! reject_symlink_path "${path}"; then
		echo "Symlinked patch target rejected: ${path}" >&2
		return 1
	fi
	if ! normalized=$(normalize_patch_target "${path}"); then
		echo "Patch target escapes application root: ${path}" >&2
		return 1
	fi
	if ! reject_symlink_path "${normalized}"; then
		echo "Symlinked patch target rejected: ${path}" >&2
		return 1
	fi
}

validate_patch_targets() {
	local patch_file=$1
	local first_character
	local headers_seen=0
	local in_hunk=0
	local line
	local new_remaining=0
	local old_remaining=0
	local path
	local previous_path=
	local previous_is_header=0

	while IFS= read -r line || [[ -n "${line}" ]]; do
		if (( in_hunk )); then
			first_character=${line:0:1}
			case "${first_character}" in
				' ')
					old_remaining=$((old_remaining - 1))
					new_remaining=$((new_remaining - 1))
					;;
				-)
					old_remaining=$((old_remaining - 1))
					;;
				+)
					new_remaining=$((new_remaining - 1))
					;;
				\\)
					continue
					;;
				*)
					echo "Malformed patch hunk: ${patch_file}" >&2
					return 1
					;;
			esac
			if (( old_remaining < 0 || new_remaining < 0 )); then
				echo "Malformed patch hunk: ${patch_file}" >&2
				return 1
			fi
			if (( old_remaining == 0 && new_remaining == 0 )); then
				in_hunk=0
			fi
			continue
		fi
		if [[ "${line}" =~ ^@@[[:space:]]-([0-9]+)(,([0-9]+))?[[:space:]]\+([0-9]+)(,([0-9]+))?[[:space:]]@@ ]]; then
			old_remaining=${BASH_REMATCH[3]:-1}
			new_remaining=${BASH_REMATCH[6]:-1}
			if (( old_remaining != 0 || new_remaining != 0 )); then
				in_hunk=1
			fi
			continue
		fi
		if (( previous_is_header )); then
			if [[ "${line}" != +++\ * ]]; then
				echo "Malformed patch file header: ${patch_file}" >&2
				return 1
			fi
			path=${line:4}
			path=${path%%$'\t'*}
			if ! previous_path=$(strip_patch_target "${previous_path}") || ! path=$(strip_patch_target "${path}"); then
				echo "Invalid -p1 patch target in: ${patch_file}" >&2
				return 1
			fi
			validate_patch_target "${previous_path}" || return 1
			validate_patch_target "${path}" || return 1
			previous_path=
			previous_is_header=0
			headers_seen=$((headers_seen + 1))
			continue
		fi
		if [[ "${line}" == ---\ * ]]; then
			previous_path=${line:4}
			previous_path=${previous_path%%$'\t'*}
			previous_is_header=1
			continue
		fi
		if (( headers_seen > 0 )) && [[ "${line}" == +* || "${line}" == -* ]] && [[ "${line}" != '-- ' ]]; then
			echo "Malformed patch body outside hunk: ${patch_file}" >&2
			return 1
		fi
	done < "${patch_file}"
	if (( in_hunk || previous_is_header )); then
		echo "Malformed patch: ${patch_file}" >&2
		return 1
	fi
	if (( headers_seen == 0 )); then
		echo "Patch has no file headers: ${patch_file}" >&2
		return 1
	fi
}

check_patch_once() {
	local patch_file=$1

	if ! reject_symlink_path "${patch_file}" || [[ ! -f "${patch_file}" ]]; then
		echo "Missing patch source: ${patch_file}" >&2
		return 1
	fi
	if ! validate_patch_targets "${patch_file}"; then
		return 1
	fi
	if patch -p1 --batch --force --fuzz=0 --dry-run -R < "${patch_file}" >/dev/null 2>&1; then
		return 0
	fi
	if patch -p1 --batch --force --fuzz=0 --dry-run < "${patch_file}" >/dev/null 2>&1; then
		return 0
	fi
	echo "Patch does not apply: ${patch_file}" >&2
	return 1
}

apply_patch_once() {
	local patch_file=$1

	if ! reject_symlink_path "${patch_file}" || [[ ! -f "${patch_file}" ]]; then
		echo "Missing patch source: ${patch_file}" >&2
		return 1
	fi
	if ! validate_patch_targets "${patch_file}"; then
		return 1
	fi
	if patch -p1 --batch --force --fuzz=0 --dry-run -R < "${patch_file}" >/dev/null 2>&1; then
		echo "Patch already applied: ${patch_file}"
	elif patch -p1 --batch --force --fuzz=0 --dry-run < "${patch_file}" >/dev/null 2>&1; then
		if ! patch -p1 --batch --force --fuzz=0 < "${patch_file}"; then
			echo "Failed to apply patch: ${patch_file}" >&2
			return 1
		fi
	else
		echo "Patch does not apply: ${patch_file}" >&2
		return 1
	fi
}

### 基础部分 ###
# 使用 O2 级别的优化
sed -i 's/Os/O2/g' include/target.mk
sed -i 's,XZ_SUPPORT=1,XZ_SUPPORT=1 ZSTD_SUPPORT=1 LZ4_SUPPORT=1,g' tools/squashfs4/Makefile
sed -i 's/HOSTCC="$(HOSTCC)"/HOSTCC="gcc"/g' include/u-boot.mk
normalize_exact_line feeds.conf.default 'src-git tcp_brutal https://github.com/haruue-net/openwrt-tcp-brutal.git;master'
# 更新 Feeds
./scripts/feeds update -a
./scripts/feeds install -a
CROWDSEC_UCI_PATCH=../PATCH/pkgs/crowdsec/001-share-uci-config.patch
MACREMAPPER_CLANG_PATCH=../PATCH/pkgs/macremapper/100-macremapper-fix-clang-build.patch
NGINX_RUNTIME_PATCH=../PATCH/pkgs/nginx/100-luci-runtime-settings.patch
apply_patch_once "${CROWDSEC_UCI_PATCH}"
apply_patch_once "${MACREMAPPER_CLANG_PATCH}"
apply_patch_once "${NGINX_RUNTIME_PATCH}"
# tcp-brutal v1.0.3 still resolves to commit 204aeea3437a83599c1c1fa1b97e4425cfdfc49d,
# but current OpenWrt archive generation produces this corrected mirror hash.
sed -i 's/0c7f5581da3bc5726bfd36a1f4863f77ca9a2684449d4b1d416577557b3d6f92/2b666b71de07256449b3e967da63f48fdb0c1146194d8deaf7edb20a82a99811/' \
    feeds/tcp_brutal/kernel/tcp-brutal/Makefile

# 定义预期的内核版本
SUPPORTED_KERNEL="6.12"

current_version=$(sed -n 's/^KERNEL_PATCHVER:=//p' ./target/linux/rockchip/Makefile) # 如 6.12
if [ -z "${current_version}" ]; then
    echo "Error: Failed to extract KERNEL_PATCHVER from ./target/linux/rockchip/Makefile"
    exit 1
fi
if [[ "${SUPPORTED_KERNEL}" != "${current_version}" ]]; then
    echo "##########
      错误：
      编译的内核版本为 ${current_version} ，
      预期的版本为 ${SUPPORTED_KERNEL}
    ##########"
    exit 1
fi
export KERNEL_VERSION="${SUPPORTED_KERNEL}"
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "KERNEL_VERSION=${SUPPORTED_KERNEL}" | tee -a "$GITHUB_ENV"
else
    echo "KERNEL_VERSION=${SUPPORTED_KERNEL}"
fi
# 移除 SNAPSHOT 标签
sed -i 's,-SNAPSHOT,,g' include/version.mk
sed -i 's,-SNAPSHOT,,g' package/base-files/image-config.in
sed -i '/CONFIG_BUILDBOT/d' include/feeds.mk
sed -i 's/;)\s*\\/; \\/' include/feeds.mk
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
# Patch arm64 型号名称
ARM64_CPUINFO_PATCH=../PATCH/kernel/arm/312-arm64-cpuinfo-Add-model-name-in-proc-cpuinfo-for-64bit-ta.patch
ARM64_CPUINFO_DIR="./target/linux/generic/hack-${KERNEL_VERSION}"
ARM64_CPUINFO_DEST="${ARM64_CPUINFO_DIR}/$(basename "${ARM64_CPUINFO_PATCH}")"
if [[ ! -d "${ARM64_CPUINFO_DIR}" ]]; then
	echo "Missing ARM64 kernel patch directory: ${ARM64_CPUINFO_DIR}" >&2
	exit 1
fi
# NanoPi R2S/R4S PWM fan DTS support is Rockchip-target-specific.
ROCKCHIP_PWM_FAN_PATCH=../PATCH/kernel/rockchip/014-rockchip-add-pwm-fan-controller-for-nanopi-r2s-r4s.patch
ROCKCHIP_PWM_FAN_DIR="./target/linux/rockchip/patches-${KERNEL_VERSION}"
ROCKCHIP_PWM_FAN_DEST="${ROCKCHIP_PWM_FAN_DIR}/$(basename "${ROCKCHIP_PWM_FAN_PATCH}")"
if [[ ! -d "${ROCKCHIP_PWM_FAN_DIR}" ]]; then
	echo "Missing Rockchip kernel patch directory: ${ROCKCHIP_PWM_FAN_DIR}" >&2
	exit 1
fi
MGLRU_PATCH=../PATCH/kernel/0900-kernel-add-mglru.patch
C4_PATCH=../PATCH/kernel/c4/010-net-ipv4-add-c4-tcp-congestion-control.patch
C4_DIR="./target/linux/generic/backport-${KERNEL_VERSION}"
C4_DEST="${C4_DIR}/$(basename "${C4_PATCH}")"
check_patch_destination "${ARM64_CPUINFO_PATCH}" "${ARM64_CPUINFO_DEST}"
check_patch_destination "${ROCKCHIP_PWM_FAN_PATCH}" "${ROCKCHIP_PWM_FAN_DEST}"
check_patch_destination "${C4_PATCH}" "${C4_DEST}"
check_patch_once "${MGLRU_PATCH}"
stage_patch "${ARM64_CPUINFO_PATCH}" "${ARM64_CPUINFO_DEST}"
stage_patch "${ROCKCHIP_PWM_FAN_PATCH}" "${ROCKCHIP_PWM_FAN_DEST}"
stage_patch "${C4_PATCH}" "${C4_DEST}"
# MGLRU OpenWrt kernel selectors
apply_patch_once "${MGLRU_PATCH}"
# LRNG
cp -rf ../PATCH/kernel/lrng/* ./target/linux/generic/hack-${KERNEL_VERSION}/
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
' >>./target/linux/generic/config-${KERNEL_VERSION}
# NETKIT
echo '
CONFIG_NETKIT=y
CONFIG_IPV6_MULTIPLE_TABLES=y
' >>./target/linux/generic/config-${KERNEL_VERSION}
# wg
cp -rf ../PATCH/kernel/wg/* ./target/linux/generic/hack-${KERNEL_VERSION}/
# dont wrongly interpret first-time data
echo "net.netfilter.nf_conntrack_tcp_max_retrans=5" >>./package/kernel/linux/files/sysctl-nf-conntrack.conf
# OTHERS
cp -rf ../PATCH/kernel/others/* ./target/linux/generic/pending-${KERNEL_VERSION}/
# luci-app-attendedsysupgrade
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci-nginx/Makefile

### Fullcone-NAT 部分 ###
# bcmfullcone
cp -rf ../PATCH/kernel/bcmfullcone/* ./target/linux/generic/hack-${KERNEL_VERSION}/
# set nf_conntrack_expect_max for fullcone
wget -qO - https://github.com/openwrt/openwrt/commit/bbf39d07.patch | patch -p1
echo "net.netfilter.nf_conntrack_helper = 1" >>./package/kernel/linux/files/sysctl-nf-conntrack.conf
# FW4
mkdir -p package/network/config/firewall4/patches
#cp -f ../PATCH/pkgs/firewall/firewall4_patches/*.patch ./package/network/config/firewall4/patches/
mkdir -p package/libs/libnftnl/patches
cp -f ../PATCH/pkgs/firewall/libnftnl/*.patch ./package/libs/libnftnl/patches/
sed -i '/PKG_INSTALL:=/iPKG_FIXUP:=autoreconf' package/libs/libnftnl/Makefile
mkdir -p package/network/utils/nftables/patches
cp -f ../PATCH/pkgs/firewall/nftables/*.patch ./package/network/utils/nftables/patches/
# Patch LuCI 以增添 FullCone 开关
pushd feeds/luci
apply_patch_once ../../../PATCH/pkgs/firewall/luci/0001-luci-app-firewall-add-nft-fullcone-and-bcm-fullcone-.patch
popd

### Shortcut-FE 部分 ###
# Patch Kernel 以支持 Shortcut-FE
cp -rf ../PATCH/kernel/sfe/* ./target/linux/generic/hack-${KERNEL_VERSION}/
cp -rf ../lede/target/linux/generic/pending-${KERNEL_VERSION}/613-netfilter_optional_tcp_window_check.patch ./target/linux/generic/pending-${KERNEL_VERSION}/613-netfilter_optional_tcp_window_check.patch
# Stage SFEv2 as an alternative runtime to the legacy Shortcut-FE modules.
SFEV2_SOURCE=../PATCH/pkgs/sfev2
SFEV2_DEST=./package/sfev2
stage_directory "${SFEV2_SOURCE}" "${SFEV2_DEST}"
# Patch LuCI 以增添 Shortcut-FE 开关
pushd feeds/luci
apply_patch_once ../../../PATCH/pkgs/firewall/luci/0002-luci-app-firewall-add-shortcut-fe-option.patch
popd

### NAT6 部分 ###
# custom nft command
apply_patch_once ../PATCH/pkgs/firewall/100-openwrt-firewall4-add-custom-nft-command-support.patch
cp -f ../PATCH/pkgs/firewall/firewall4_patches/*.patch ./package/network/config/firewall4/patches/
# Patch LuCI 以增添 NAT6 开关
pushd feeds/luci
apply_patch_once ../../../PATCH/pkgs/firewall/luci/0003-luci-app-firewall-add-ipv6-nat-option.patch
popd
# Patch LuCI 以支持自定义 nft 规则
pushd feeds/luci
apply_patch_once ../../../PATCH/pkgs/firewall/luci/0004-luci-add-firewall-add-custom-nft-rule-support.patch
popd

### natflow 部分 ###
pushd feeds/luci
apply_patch_once ../../../PATCH/pkgs/firewall/luci/0005-luci-app-firewall-add-natflow-offload-support.patch
apply_patch_once ../../../PATCH/pkgs/firewall/luci/0008-luci-app-firewall-add-sfe-v2-option.patch
popd

### fullcone6 ###
pushd feeds/luci
apply_patch_once ../../../PATCH/pkgs/firewall/luci/0007-luci-app-firewall-add-fullcone6-option-for-nftables-.patch
popd

### Other Kernel Hack 部分 ###
# make olddefconfig
wget -qO - https://github.com/openwrt/openwrt/commit/c21a3570.patch | patch -p1
# igc-fix
cp -rf ../lede/target/linux/x86/patches-${KERNEL_VERSION}/996-intel-igc-i225-i226-disable-eee.patch ./target/linux/x86/patches-${KERNEL_VERSION}/996-intel-igc-i225-i226-disable-eee.patch
# btf
cp -rf ../PATCH/kernel/btf/* ./target/linux/generic/hack-${KERNEL_VERSION}/

### 获取额外的基础软件包 ###
# Disable Mitigations
sed -i 's,rootwait,rootwait mitigations=off,g' target/linux/rockchip/image/default.bootscript
sed -i 's,@CMDLINE@ noinitrd,noinitrd mitigations=off,g' target/linux/x86/image/grub-efi.cfg
sed -i 's,@CMDLINE@ noinitrd,noinitrd mitigations=off,g' target/linux/x86/image/grub-iso.cfg
sed -i 's,@CMDLINE@ noinitrd,noinitrd mitigations=off,g' target/linux/x86/image/grub-pc.cfg

### ADD PKG 部分 ###
cp -rf ../OpenWrt-Add ./package/new
FULLCONENAT_NFT_CHAIN_NOTIFIER_PATCH=../PATCH/pkgs/fullconenat-nft/002-chain-notifier-api.patch
FULLCONENAT_NFT_CHAIN_NOTIFIER_DEST=./package/new/lede_pkg/fullconenat-nft/patches/$(basename "${FULLCONENAT_NFT_CHAIN_NOTIFIER_PATCH}")
stage_patch "${FULLCONENAT_NFT_CHAIN_NOTIFIER_PATCH}" "${FULLCONENAT_NFT_CHAIN_NOTIFIER_DEST}"
# OpenWrt-Add carries duplicate copies of these packages. Keep the maintained
# openwrt_helloworld variants so Kconfig sees each package exactly once.
rm -rf ./package/new/OpenWrt-mihomo/{mihomo-alpha,mihomo-meta}
rm -rf ./package/new/trojan-plus
# Symmetric CONFLICTS entries form a recursive dependency with current Kconfig.
# One package-manager conflict declaration is sufficient for mutual exclusion.
sed -i '/CONFLICTS:=mihomo-meta/d' ./package/new/openwrt_helloworld/mihomo-alpha/Makefile
rm -rf feeds/packages/net/{xray-core,v2ray-core,v2ray-geodata,sing-box,frp,microsocks,shadowsocks-libev,zerotier,daed}
rm -rf feeds/luci/applications/{luci-app-frps,luci-app-frpc,luci-app-zerotier,luci-app-filemanager}
rm -rf feeds/packages/utils/coremark
sed -i 's/+@KERNEL_DEBUG_INFO_BTF/+vmlinux-btf/' ./package/new/openwrt-einat-ebpf/Makefile
git clone https://github.com/QiuSimons/vmlinux-btf ./package/new/vmlinux-btf

### 获取额外的 LuCI 应用、主题和依赖 ###
# RK
sed -i '/REQUIRE_IMAGE_METADATA/d' target/linux/rockchip/armv8/base-files/lib/upgrade/platform.sh
wget https://github.com/coolsnowwolf/lede/raw/refs/heads/master/target/linux/rockchip/patches-6.12/991-arm64-dts-rockchip-add-more-cpu-operating-points-for.patch -O target/linux/rockchip/patches-6.12/991.patch
wget https://github.com/coolsnowwolf/lede/raw/refs/heads/master/target/linux/rockchip/patches-6.12/992-rockchip-rk3399-overclock-to-2.2-1.8-GHz.patch -O target/linux/rockchip/patches-6.12/992.patch
# 更换 Nodejs 版本
rm -rf ./feeds/packages/lang/node
rm -rf ./package/new/feeds_packages_lang_node-prebuilt
cp -rf ../OpenWrt-Add/feeds_packages_lang_node-prebuilt ./feeds/packages/lang/node
# 更换 golang 版本
rm -rf ./feeds/packages/lang/golang
cp -rf ../openwrt_pkg_ma/lang/golang ./feeds/packages/lang/golang
#git clone https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang
# apk
pushd feeds/luci
wget -qO- https://github.com/sbwml/r4s_build_script/raw/refs/heads/master/openwrt/patch/luci/applications/luci-app-package-manager/0001-luci-app-package-manager-support-installing-uploaded.patch | patch -p1
popd
# rust
wget https://github.com/rust-lang/rust/commit/cdae267.patch -O feeds/packages/lang/rust/patches/cdae267.patch
sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' feeds/packages/lang/rust/Makefile
RUST_VALUES_FILE="feeds/packages/lang/rust/rust-values.mk"
if [ -f "${RUST_VALUES_FILE}" ]; then
	if ! grep -q '^RUSTC_GLOBAL_CODEGEN_FLAGS:=-C lto=true -C opt-level=3$' "${RUST_VALUES_FILE}"; then
		sed -i '/^CARGO_RUSTFLAGS+=-Ctarget-feature=-crt-static $(RUSTC_LDFLAGS)$/i \
# Global rustc codegen tuning for Rust packages using rust-package.mk.\
RUSTC_GLOBAL_CODEGEN_FLAGS:=-C lto=true -C opt-level=3\
ifeq ($(ARCH),x86_64)\
  RUSTC_GLOBAL_CODEGEN_FLAGS+=-C target-cpu=znver4\
endif\
' "${RUST_VALUES_FILE}"
	fi

	sed -i 's|^CARGO_RUSTFLAGS+=-Ctarget-feature=-crt-static $(RUSTC_LDFLAGS).*|CARGO_RUSTFLAGS+=-Ctarget-feature=-crt-static $(RUSTC_LDFLAGS) $(RUSTC_GLOBAL_CODEGEN_FLAGS)|' "${RUST_VALUES_FILE}"
	sed -i 's|^CARGO_PROFILE_RELEASE_OPT_LEVEL=.*|CARGO_PROFILE_RELEASE_OPT_LEVEL=3|' "${RUST_VALUES_FILE}"
fi
# mount cgroupv2
CGROUPFS_MOUNT_SOURCE=../lede_pkg_ma/utils/cgroupfs-mount
CGROUPFS_MOUNT_DIR=feeds/packages/utils/cgroupfs-mount
if ! reject_symlink_path "${CGROUPFS_MOUNT_SOURCE}" || ! reject_symlink_path "${CGROUPFS_MOUNT_DIR}"; then
	echo "Symlinked cgroupfs-mount import path rejected" >&2
	exit 1
fi
if [[ -d "${CGROUPFS_MOUNT_DIR}" ]] && ! find -P "${CGROUPFS_MOUNT_DIR}" -mindepth 1 -print -quit | grep -q .; then
	rmdir -- "${CGROUPFS_MOUNT_DIR}"
fi
if [[ ! -e "${CGROUPFS_MOUNT_DIR}" && ! -L "${CGROUPFS_MOUNT_DIR}" ]]; then
	stage_directory "${CGROUPFS_MOUNT_SOURCE}" "${CGROUPFS_MOUNT_DIR}"
elif ! directory_matches_source "${CGROUPFS_MOUNT_SOURCE}" "${CGROUPFS_MOUNT_DIR}"; then
	echo "cgroupfs-mount package collision: ${CGROUPFS_MOUNT_DIR}" >&2
	exit 1
fi
if [[ -L "${CGROUPFS_MOUNT_DIR}" || ! -f "${CGROUPFS_MOUNT_DIR}/Makefile" || ! -f "${CGROUPFS_MOUNT_DIR}/files/cgroupfs-mount.init" ]]; then
	echo "Incomplete cgroupfs-mount package: ${CGROUPFS_MOUNT_DIR}" >&2
	exit 1
fi
CGROUP_INIT_PATCH=../../../PATCH/pkgs/cgroupfs-mount/0001-fix-cgroupfs-mount.patch
CGROUP_V2_PATCH=../PATCH/pkgs/cgroupfs-mount/900-mount-cgroup-v2-hierarchy-to-sys-fs-cgroup-cgroup2.patch
CGROUP_UMOUNT_PATCH=../PATCH/pkgs/cgroupfs-mount/901-fix-cgroupfs-umount.patch
CGROUP_SYSTEMD_PATCH=../PATCH/pkgs/cgroupfs-mount/902-mount-sys-fs-cgroup-systemd-for-docker-systemd-suppo.patch
CGROUP_PATCH_DIR="${CGROUPFS_MOUNT_DIR}/patches"
CGROUP_V2_DEST="${CGROUP_PATCH_DIR}/$(basename "${CGROUP_V2_PATCH}")"
CGROUP_UMOUNT_DEST="${CGROUP_PATCH_DIR}/$(basename "${CGROUP_UMOUNT_PATCH}")"
CGROUP_SYSTEMD_DEST="${CGROUP_PATCH_DIR}/$(basename "${CGROUP_SYSTEMD_PATCH}")"
if ! reject_symlink_path "${CGROUP_PATCH_DIR}" || [[ -L "${CGROUP_PATCH_DIR}" || ( -e "${CGROUP_PATCH_DIR}" && ! -d "${CGROUP_PATCH_DIR}" ) ]]; then
	echo "Invalid cgroupfs-mount patch directory: ${CGROUP_PATCH_DIR}" >&2
	exit 1
fi
mkdir -p "${CGROUP_PATCH_DIR}"
check_patch_destination "${CGROUP_V2_PATCH}" "${CGROUP_V2_DEST}"
check_patch_destination "${CGROUP_UMOUNT_PATCH}" "${CGROUP_UMOUNT_DEST}"
check_patch_destination "${CGROUP_SYSTEMD_PATCH}" "${CGROUP_SYSTEMD_DEST}"
if ! reject_symlink_path feeds/packages; then
	echo "Symlinked feeds/packages path rejected" >&2
	exit 1
fi
pushd feeds/packages
check_patch_once "${CGROUP_INIT_PATCH}"
popd
stage_patch "${CGROUP_V2_PATCH}" "${CGROUP_V2_DEST}"
stage_patch "${CGROUP_UMOUNT_PATCH}" "${CGROUP_UMOUNT_DEST}"
stage_patch "${CGROUP_SYSTEMD_PATCH}" "${CGROUP_SYSTEMD_DEST}"
pushd feeds/packages
apply_patch_once "${CGROUP_INIT_PATCH}"
popd
# fstool
wget -qO - https://github.com/coolsnowwolf/lede/commit/8a4db76.patch | patch -p1
# Boost 通用即插即用
rm -rf ./feeds/packages/net/miniupnpd
cp -rf ../openwrt_pkg_ma/net/miniupnpd ./feeds/packages/net/miniupnpd
mkdir -p feeds/packages/net/miniupnpd/patches
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
wget https://github.com/miniupnp/miniupnp/commit/6aefa9a.patch -O feeds/packages/net/miniupnpd/patches/6aefa9a.patch
sed -i 's,/miniupnpd/,/,g' ./feeds/packages/net/miniupnpd/patches/6aefa9a.patch
pushd feeds/packages
apply_patch_once ../../../PATCH/pkgs/miniupnpd/01-set-presentation_url.patch
apply_patch_once ../../../PATCH/pkgs/miniupnpd/02-force_forwarding.patch
popd
pushd feeds/luci
apply_patch_once ../../../PATCH/pkgs/miniupnpd/luci-upnp-support-force_forwarding-flag.patch
popd
# 动态DNS
sed -i '/boot()/,+2d' feeds/packages/net/ddns-scripts/files/etc/init.d/ddns
# Docker 容器
rm -rf ./feeds/luci/applications/luci-app-dockerman
cp -rf ../dockerman/applications/luci-app-dockerman ./feeds/luci/applications/luci-app-dockerman
sed -i 's/^PKG_VERSION:=v/PKG_VERSION:=/' ./feeds/luci/applications/luci-app-dockerman/Makefile
sed -i '/auto_start/d' feeds/luci/applications/luci-app-dockerman/root/etc/uci-defaults/luci-app-dockerman
# qosmate
cp -rf ../luci-app-qosmate ./package/new
cp -rf ../qosmate ./package/new
cp -rf ../lucky ./package/new
# nginx
replace_file ../PATCH/nginx/nginx.config feeds/packages/net/nginx-util/files/nginx.config
replace_file ../PATCH/nginx/uci.conf.template feeds/packages/net/nginx-util/files/uci.conf.template
pushd feeds/packages
wget -qO- https://github.com/openwrt/packages/commit/e2e5ee69.patch | patch -p1
wget -qO- https://github.com/openwrt/packages/pull/20054.patch | patch -p1
popd
sed -i '/sysctl.d/d' feeds/packages/utils/dockerd/Makefile
rm -rf ./feeds/luci/collections/luci-lib-docker
cp -rf ../docker_lib/collections/luci-lib-docker ./feeds/luci/collections/luci-lib-docker
sed -i 's/^PKG_VERSION:=v/PKG_VERSION:=/' ./feeds/luci/collections/luci-lib-docker/Makefile
# ODHCPD
rm -rf ./package/network/services/odhcpd
cp -rf ../openwrt_ma/package/network/services/odhcpd ./package/network/services/odhcpd
rm -rf ./package/network/ipv6/odhcp6c
cp -rf ../openwrt_ma/package/network/ipv6/odhcp6c ./package/network/ipv6/odhcp6c
# IPv6 compatibility helper: apply after the authoritative odhcp6c replacement.
ODHCP6C_HOTPLUG_PATCH=../PATCH/pkgs/odhcp6c/1002-odhcp6c-support-dhcpv6-hotplug.patch
apply_patch_once "${ODHCP6C_HOTPLUG_PATCH}"
# watchcat
echo > ./feeds/packages/utils/watchcat/files/watchcat.config
# 默认开启 Irqbalance
#sed -i "s/enabled '0'/enabled '1'/g" feeds/packages/utils/irqbalance/files/irqbalance.config

# 使用 TEO CPU 空闲调度器
CONFIG_CONTENT='
CONFIG_CPU_IDLE_GOV_MENU=n
CONFIG_CPU_IDLE_GOV_TEO=y
'
# 查找所有与内核相关的配置文件并将这些配置项追加到文件末尾
find ./target/linux/ -name "config-${KERNEL_VERSION}" | xargs -I{} sh -c "echo '$CONFIG_CONTENT' | tee -a {} > /dev/null"

### 最后的收尾工作 ###
# Lets Fuck
mkdir -p package/base-files/files/usr/bin
cp -rf ../OpenWrt-Add/fuck ./package/base-files/files/usr/bin/fuck
#cp -rf ../PATCH/pkgs/jool/Makefile feeds/packages/net/jool/Makefile
# 生成默认配置及缓存
rm -rf .config
sed -i 's,CONFIG_WERROR=y,# CONFIG_WERROR is not set,g' target/linux/generic/config-${KERNEL_VERSION}

./scripts/feeds update -i
./scripts/feeds install -a

#exit 0
