# Ubuntu 24.04 OpenWrt Container Runbook

This repository uses the existing Ubuntu 24.04 build container. Inspect and edit files on the host, but run every preparation, dependency probe, clone, feed operation, download, build, test, and interactive compilation through `tools/yaof-container`. Never build on the host and never enter the container with direct `docker exec`.

## Container wrapper and health gate

Run these commands from the repository root on the host:

```text
tools/yaof-container build
tools/yaof-container up
tools/yaof-container status
tools/yaof-container shell
tools/yaof-container exec -- <command> [args...]
tools/yaof-container down
```

`build` only builds the image. `up` starts or recreates `yaof` and waits up to 90 seconds for the firewall, redsocks, and local Stubby resolver health gate. A failed or timed-out gate is a hard stop: do not bypass it or run build work elsewhere. `status` reports service and health state; when diagnosis is needed, host-side observation may use `docker compose logs --tail=100 yaof`, but Docker must not be used to run build commands.

`shell` and `exec` run workloads as UID/GID `1000:1000`; this is mandatory for all build commands. Confirm it before compiling:

```bash
tools/yaof-container exec -- id
tools/yaof-container exec -- bash -lc 'test "$(id -u):$(id -g)" = 1000:1000'
tools/yaof-container exec -- bash -lc 'cd openwrt && make -j1 tools/fakeroot/compile V=s && test -x staging_dir/host/bin/fakeroot'
```

The base container does not provide a global `fakeroot`; OpenWrt builds its own at `staging_dir/host/bin/fakeroot`. After that target succeeds, test a temporary file inside fakeroot: its fakeroot view may be `0:0`, while `stat` outside fakeroot must still show the real builder UID/GID `1000:1000`. Do not use `sudo`, a root shell, or a root-owned build tree. The bind-mounted repository and named `/home/builder` volume survive `up`/`down`; `down` does not remove either.

The container routes traffic through SOCKS5 `192.168.1.1:1091` and authenticated local Cloudflare malware-filtering DNS-over-TLS. This is access policy, not source integrity. Keep OpenWrt package hash checks enabled and record the resolved OpenWrt release/tag/commit plus the tag/commit (or immutable archive hash) of every cloned or downloaded source before calling a build trusted. The current preparation scripts derive releases from web content and use mutable or shallow clones, so review and record their actual revisions; do not call the build reproducible or malware-free based on DNS filtering.

## X86_64 build workflow

Do not run a whole GitHub Actions workflow or copy its control flow into one large command. The workflow is a reference for ordering and target names only. Network-sensitive operations such as feeds, downloads, package compilation, and firmware compilation must be issued as separate, directly observable `tools/yaof-container exec` commands. Scripts are appropriate for coherent batch clone, deterministic patch, and other mechanical batch operations, but they must not hide network retries, source revision capture, or build failures.

Before preparation, inspect every fixed clone destination used by `SCRIPTS/01_get_ready.sh`, including `openwrt/`, `openwrt_snap/`, `immortalwrt_24/`, `immortalwrt_23/`, and `lede/`. Preparation is destructive and non-idempotent: do not rerun it over existing or partial trees. Archive or deliberately remove a destination only after inspecting it, or skip preparation and use an independently verified existing tree.

Use the target-specific X86 seed and scripts, preserving the host repository and the `openwrt` working directory. The following is an example of the stage boundaries; substitute the approved values and inspect each result before continuing:

```bash
# 1. Start and verify the isolated build environment.
tools/yaof-container up
tools/yaof-container exec -- bash -lc 'id; test "$(id -u):$(id -g)" = 1000:1000'

# 2. Prepare only after clone destinations have been inspected.
tools/yaof-container exec -- bash -lc 'cp -r SCRIPTS/X86/. SCRIPTS/ && cp -r SCRIPTS/. ./ && bash 01_get_ready.sh'

# 3. From the OpenWrt tree, keep network-sensitive work independently observable.
tools/yaof-container exec -- bash -lc 'cd openwrt && cp -r ../SCRIPTS/. ./'
tools/yaof-container exec -- bash -lc 'cd openwrt && ./scripts/feeds update -a'
tools/yaof-container exec -- bash -lc 'cd openwrt && ./scripts/feeds install -a'

# Read 02_prepare_package.sh and 02_target_only.sh as command sources. Run their
# network operations directly; batch only the deterministic patch/copy/sed work.
# Purely mechanical helpers such as translation, ACL generation, UPX removal,
# and permission repair may be run separately after their contents are reviewed.
tools/yaof-container exec -- bash -lc 'cd openwrt && bash 04_remove_upx.sh'
tools/yaof-container exec -- bash -lc 'cd openwrt && cp ../SEED/X86/config.seed .config'
tools/yaof-container exec -- bash -lc 'cd openwrt && bash 03_convert_translation.sh'
tools/yaof-container exec -- bash -lc 'cd openwrt && bash 05_create_acl_for_luci.sh -a'
tools/yaof-container exec -- bash -lc 'cd openwrt && chmod 755 ./08_fix_permissions.sh && bash 08_fix_permissions.sh'

# 4. Record the exact tree and source revisions, then resolve configuration.
tools/yaof-container exec -- bash -lc 'cd openwrt && git describe --tags --always --dirty && git rev-parse HEAD && git submodule status --recursive'
tools/yaof-container exec -- bash -lc 'cd openwrt && make defconfig'

# 5. Download separately; keep package hashes enabled and inspect the log even
# when make returns zero because an individual source fetch may still fail.
tools/yaof-container exec -- bash -lc 'cd openwrt && make download -j4 V=s'

# 6. Compile in parallel after download succeeds, then inspect artifacts.
tools/yaof-container exec -- bash -lc 'cd openwrt && make -j"$(($(nproc) + 1))" V=s'
tools/yaof-container exec -- bash -lc 'cd openwrt && find bin/targets -type f -maxdepth 5 -printf "%p %s bytes\\n" | sort'
```

The examples are stages, not a script to paste as one block. Run `make download`, package refreshes, and compilation separately so the first failing package and log remain attributable. A successful Actions job or `defconfig` does not prove a firmware build; verify the actual compile output and final image metadata.

## Current verified X86 build and acceptance plan

The current baseline is branch `25.12`, an OpenWrt `v25.12.x` release resolved
by `SCRIPTS/00_resolve_openwrt_release.sh`, Linux 6.12, built-in C4 with FQ as
the X86 defaults, and plain-LZ4 SquashFS. The last complete local validation
resolved `v25.12.5`; treat that as a known-good reference, not a permanent pin.
Resolve and record the current tag and commit again for every new build.

Run the build as these observable phases:

1. Confirm that the container is healthy and that `id -u:id -g` is
   `1000:1000`. Confirm that no prior `make`, QEMU, or OpenWrt `faked` process
   is still using a materialized tree.
2. Resolve the release inside the container and retain it in an ignored
   `.yaof-*` file so separate wrapper calls use the same value:

   ```bash
   tools/yaof-container exec -- bash -lc '
     release="$(./SCRIPTS/00_resolve_openwrt_release.sh)" &&
     printf "%s\n" "$release" > .yaof-openwrt-release
   '
   ```

3. Inspect every destination in `clone_destinations` in
   `SCRIPTS/01_get_ready.sh`. With no destination present, copy the X86 script
   set and run preparation with the recorded release:

   ```bash
   tools/yaof-container exec -- bash -lc '
     export OPENWRT_RELEASE="$(cat .yaof-openwrt-release)" &&
     cp -r SCRIPTS/X86/. SCRIPTS/ &&
     cp -r SCRIPTS/. ./ &&
     bash 01_get_ready.sh
   '
   ```

4. Copy `SCRIPTS/` into `openwrt/`. Treat `02_prepare_package.sh` and
   `02_target_only.sh` as reviewed command sources. Run their network actions
   separately: feed update/install, fixed commit-patch downloads, the
   `vmlinux-btf` clone, Rockchip patch downloads, Rust and miniupnp patch
   downloads, package-manager patches, and the X86 `profiles.json` download.
   Record every resolved source revision or downloaded archive hash. Then run
   the deterministic patch/copy/configuration blocks and the X86 target block.
   Do not retain an ad-hoc replay script after the build.
5. Run translation, ACL, permission, and seed operations, then capture
   `git describe`, `git rev-parse HEAD`, submodules, feeds, `.config`, and all
   externally imported source revisions before `make defconfig`.
6. Build OpenWrt's own fakeroot, run `make download -j4 V=s`, and inspect the
   complete download log. Compile with `make -j"$(($(nproc) + 1))" V=s` only
   after downloads succeed. A targeted low-concurrency retry does not replace
   this final full parallel build.
7. Verify `bin/targets/x86/64/sha256sums`, every gzip artifact, the actual
   `mksquashfs4` arguments, and the SquashFS superblock. Inspect the image and
   confirm it contains `qca-nss-sfe.ko`, `ecm.ko`, `shortcut-fe.ko`,
   `shortcut-fe-ipv6.ko`, `shortcut-fe-cm.ko`, `nft_fullcone.ko`, and
   `/etc/init.d/sfe-ecm` before runtime testing.

The last reviewed image used `mksquashfs4 -comp lz4`, no `-Xhc`, a 4096-byte
SquashFS block size, and passed `gzip -t`, `sha256sum -c`, module stress, QEMU
boot, DHCP, DNS, HTTPS, LuCI, and bidirectional `iperf3`. A new build must pass
the same gates; historical hashes or logs are not proof for a new image.

## Module stress and QEMU runtime acceptance

Run `tools/qemu-c4-acceptance` on the host as the normal user after the
container build. The script itself uses passwordless `sudo` only for KVM and
temporary network resources. `RUN_DIR` must not already exist:

```bash
WAN_PARENT=enp10s0 \
RUN_DIR=/tmp/yaof-c4-acceptance-new \
tools/qemu-c4-acceptance \
  openwrt/bin/targets/x86/64/openwrt-x86-64-generic-squashfs-combined.img.gz
```

The full run is the acceptance path. It performs 100 ordered load/unload
cycles for `qca-nss-sfe` plus `ecm`, 100 cycles for the legacy Shortcut-FE
stack, and scans the isolated dmesg window for Oops, warnings, UAF, refcount,
deadlock, hung-task, and call-trace signatures. Dependencies must load in
forward order and unload in reverse order: `qca-nss-sfe` before `ecm`, and
`shortcut-fe`, `shortcut-fe-ipv6`, then `shortcut-fe-cm` before reversing the
sequence.

The network phase verifies C4, FQ, WAN and LAN DHCP, gateway and upstream
routing, DNS, HTTPS, LuCI, endpoint traffic, forwarded traffic, and C4 on an
OpenWrt-originated flow. It continuously pings the host gateway and compares
the host WAN link, address, and route snapshots before and after cleanup.
`SKIP_MODULE_STRESS=1` is allowed only for a network-only retry after the same
image has already completed the full module stress successfully; retain both
run directories and identify which evidence belongs to each gate.

The acceptance script temporarily disables `einat` and `qosmate` inside the
ephemeral guest to isolate core routing and DHCP. This does not validate those
optional dataplane services. Validate them in a separate run if their behavior
is part of the change under test.

## Failure handling and known code issues

For a `make` or `download` failure, first classify it as network/source retrieval or code/configuration. Check the failing URL, proxy/DNS/health state, and package log separately from compiler errors, patch rejects, missing symbols, and reproducibility errors. For a network failure, retry only the failed package or module at low concurrency, for example `make -j1 package/<path>/download V=s` or `make -j1 package/<path>/compile V=s`; after the network is fixed, resume with the normal parallel command and then run the full parallel build. Never replace the complete OpenWrt build with `make -j1 V=s`, and never use a blanket ignore-errors or serial fallback to declare success.

Record and resolve these recurring code problems explicitly:

- The old libbpf GCC 15 const-qualifier patch is already upstream; remove or do not reapply the stale patch and verify the package source and patch list.
- APK package versions must not begin with `v`; normalize the version at the package metadata boundary.
- mihomo/trojan duplicate package definitions can create recursive dependency conflicts; keep one authoritative package and inspect dependency paths.
- CrowdSec's two packages must not both install `/etc/config/crowdsec`; choose one owner and verify package file manifests.
- Before updating tcp-brutal, verify the upstream tag and commit and use a deterministic archive/hash. Do not update from an unverified moving branch or guessed hash.

Observed failures and their required responses:

- `clone destination already exists`: preparation is refusing to overwrite a
  partial or previously modified source tree. Inspect its Git status and
  provenance first. Archive or remove it only deliberately, then restart from
  the clone phase; never rerun preparation on top of it.
- One of the parallel clones fails but other directories remain: the entire
  preparation attempt is incomplete. Do not reuse the mixed tree. Diagnose
  proxy/DNS/source availability, then inspect every destination's Git status,
  remote, revision, timestamps, and ownership by the failed attempt. Archive
  by default. Remove a destination only after confirming that it belongs
  exclusively to that attempt and contains no unique changes, then rerun from
  a clean set.
- A patch parses but later source is missing declarations or an include guard:
  inspect the unified-diff hunk counts. A short hunk count can truncate a patch
  without an obvious compiler error at the patching stage. Require
  `git apply --numstat` for every patch and ordered zero-fuzz replay for coupled
  stacks; do not rely on `patch` returning zero alone.
- `git diff --check` reports whitespace in an embedded upstream quilt patch:
  determine whether the whitespace is historical patch payload or a new edit.
  Validate patch syntax, target source, and `--fuzz=0` application before
  changing third-party patch context merely to silence the check.
- SFE/ECM compilation or unload hangs around notifier or callback teardown:
  preserve the reviewed registration ownership, callback generation, and
  shared IPv4/IPv6 worker teardown semantics. Do not replace a targeted fix
  with unconditional unregister under a held worker mutex. Rebuild both
  `qca-nss-sfe` and `qca-nss-ecm`, then rerun the complete module stress.
- `modprobe ecm` fails while `qca-nss-sfe` is absent, or `rmmod qca-nss-sfe`
  reports busy: load the provider before the consumer and unload the consumer
  first. For the legacy stack, unload connection manager, IPv6, then core.
- QEMU WAN sends DHCP discovery but never receives the unicast offer: the
  macvtap interface MAC must equal the guest WAN NIC MAC. Broadcast discovery
  can work with different MACs while unicast DHCP replies are dropped. Keep
  `WAN_MVT_MAC="${WAN_GUEST_MAC}"` and keep the LAN and WAN-peer MACs unique.
- Long guest commands or module loops stop partway through serial input: send a
  heredoc script and execute it after the terminating marker. Split marker
  strings in transmitted commands so command echo cannot satisfy log waits.
- WAN DHCP changes or disappears during core network testing: stop and disable
  `einat` and `qosmate` only in the ephemeral guest, restart the network, and
  repeat the core acceptance. This isolation is not a substitute for separate
  validation of those services.
- QEMU validation risks host connectivity: stop immediately. Never bridge,
  move, down/up, restart, or reconfigure the physical WAN. Use macvtap plus an
  isolated LAN bridge/netns and keep the continuity monitor running until all
  temporary resources are gone.
- Disk space remains consumed after deleting `staging_dir`: check for orphaned
  `staging_dir/host/bin/faked` processes. Terminate only the verified build
  leftovers, then remove build trees. Also check QEMU PIDs, `yc4-*` links,
  namespaces, dhcpcd state, and decompressed images before declaring cleanup.

## X86 SquashFS and QEMU acceptance

For X86, SquashFS must use plain LZ4. The actual `mksquashfs` invocation must be `-comp lz4` with no `-Xhc`; do not silently produce XZ or LZ4 high-compression output. Enable kernel LZ4 support and disable SquashFS XZ in the kernel configuration. Verify the finished filesystem with OpenWrt's own `staging_dir/host/bin/unsquashfs4 -s build_dir/target-x86_64_musl/linux-x86_64/root.squashfs`, run `gzip -t` and `sha256sum -c` on the release artifacts, and then verify that the image boots; configuration alone is insufficient.

For QEMU WAN validation, use macvtap. Never bridge, move, down/up, or restart the host's physical WAN interface. Give LAN a separate TAP attached to an isolated bridge/netns; never reuse the WAN link. If the upstream router uses `192.168.1.0/24`, configure the runtime LAN as `192.168.50.1/24` to avoid overlap. Verify, with evidence, WAN DHCP, LAN DHCP, LuCI reachability, routing, router/DNS access, and HTTPS access. Before finishing, remove the QEMU process, macvtap, TAP, bridge, netns, leases, and other temporary resources, then compare the host interface/address/route state with a recorded baseline and confirm it is unchanged.

<!-- CODEGRAPH_START -->
## CodeGraph

When `.codegraph/` exists at the repository root, use CodeGraph before shell search or direct file reads to locate symbols, references, architecture, or call paths. Use `codegraph explore "<question>"` when the MCP tool is unavailable.
<!-- CODEGRAPH_END -->
