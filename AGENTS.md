# OpenWrt X86_64 Build Runbook

Builds may run directly on the host or in another explicitly isolated environment. The build method must match the current task instructions. Do not assume a container, proxy, or network service is available. Do not install system dependencies or alter host networking to make a build work. Record the compiler, OpenWrt toolchain, cached source revisions, and build outputs used for each build.

For native builds, use an independent project-local tree when the existing tree contains user changes or stale outputs. Preserve prior images, prepared trees, logs, and provenance before rebuilding. Run preparation, compilation, tests, and interactive compilation as separate observable commands. Use the existing OpenWrt host tools and toolchain when they are available.

## X86_64 build workflow

Do not run a whole GitHub Actions workflow or copy its control flow into one large command. The workflow is a reference for ordering and target names only. Network-sensitive operations such as feeds, downloads, package compilation, and firmware compilation must be issued as separate, directly observable commands. Scripts are appropriate for coherent batch clone, deterministic patch, and other mechanical batch operations, but they must not hide network retries, source revision capture, or build failures.

Before preparation, inspect every fixed clone destination used by `SCRIPTS/01_get_ready.sh`, including `openwrt/`, `openwrt_snap/`, `immortalwrt_24/`, `immortalwrt_23/`, and `lede/`. Preparation is destructive and non-idempotent: do not rerun it over existing or partial trees. Archive or deliberately remove a destination only after inspecting it, or skip preparation and use an independently verified existing tree.

Use the target-specific X86 seed and scripts, preserving the host repository and the `openwrt` working directory. The following is an example of the stage boundaries; substitute the approved values and inspect each result before continuing:

```bash
# 1. Confirm the selected native toolchain and the independent build tree.
# Record compiler versions, cached source hashes, configuration, and Git state.
# Do not reuse stale kernel objects after changing a persistent patch.

# 2. Prepare only after clone destinations have been inspected.
# Use the repository scripts from the selected native tree.

# 3. Keep network-sensitive work independently observable when it is needed.
# Do not refresh feeds when pinned feeds and package sources are already preserved.

# Read 02_prepare_package.sh and 02_target_only.sh as command sources. Run their
# deterministic patch/copy/configuration blocks separately and retain logs.

# 4. Record the exact tree and source revisions, then resolve configuration.
make -C openwrt defconfig

# 5. Download separately when required. Keep package hashes enabled and inspect
# the complete log even when an individual source fetch may still fail.
make -C openwrt download -j4 V=s

# 6. Compile in parallel after downloads succeed, then inspect artifacts.
make -C openwrt -j8 V=s
find openwrt/bin/targets -type f -maxdepth 5 -printf "%p %s bytes\\n" | sort
```

The examples are stages, not a script to paste as one block. Run `make download`, package refreshes, and compilation separately so the first failing package and log remain attributable. A successful Actions job or `defconfig` does not prove a firmware build; verify the actual compile output and final image metadata.

## Current verified X86 build and acceptance plan

The current baseline is branch `25.12`, an OpenWrt `v25.12.x` release recorded
in the build provenance, Linux 6.12, built-in C4 with FQ as the X86 defaults,
and plain-LZ4 SquashFS. Preserve the recorded release and source revisions for
comparison. Do not silently replace pinned inputs with moving branches.

Run the build as these observable phases:

1. Confirm that no prior make, QEMU, or OpenWrt `faked` process is using the
   selected materialized tree.
2. Inspect every destination in `clone_destinations` before preparation.
3. Record the OpenWrt release, source revisions, feeds, `.config`, and imported
   source hashes before `make defconfig`.
4. Use the existing host tools and OpenWrt toolchain. Run `make download -j4 V=s`
   only when cached inputs are insufficient. Compile with `make -j8 V=s` after
   downloads succeed. A targeted retry does not replace the full parallel build.
5. Verify `bin/targets/x86/64/sha256sums`, every gzip artifact, the actual
   `mksquashfs4` arguments, and the SquashFS superblock. Inspect the image and
   confirm its required kernel modules before runtime testing.

The last reviewed image used `mksquashfs4 -comp lz4`, no `-Xhc`, a 4096-byte
SquashFS block size, and passed `gzip -t`, `sha256sum -c`, module stress, QEMU
boot, DHCP, DNS, HTTPS, LuCI, and bidirectional `iperf3`. A new build must pass
the same gates; historical hashes or logs are not proof for a new image.

## Module stress and QEMU runtime acceptance

Run `tools/qemu-c4-acceptance` as the normal user after the native build.
The script itself uses passwordless `sudo` only for KVM and temporary network
resources. `RUN_DIR` must not already exist:

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
