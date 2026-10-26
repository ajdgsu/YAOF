# Linux TCP C4 provenance and update mapping

This is an experimental Linux 6.12 TCP adaptation, not a line-for-line copy of QUIC C4. X86 selects built-in C4 with FQ through `SCRIPTS/X86/02_target_only.sh`. Other targets retain their defaults.

## Baseline and upstream snapshot

Upstream: <https://github.com/private-octopus/picoquic>.

- Declared derivation baseline: `879e7ef0f773d07f47926dc8ba3d86cc5e36f039`, 2026-07-13. Its `picoquic/c4.c` content is identical to `0a82f5f8a3361c5a0eee4ad375fae127078423fa`, 2026-07-07.
- Latest C4 source change inspected: `69c59742b8af64c7c43f3de01e1f599b09ff03f5`, 2026-10-20.
- Observed upstream HEAD: `1d81a730ebbc0f4598f8127a7f43260a71a9ac7d`, 2026-10-25. C4 content matches that latest C4 change.
- Original Linux source SHA-256: `aaf87b9c92c46d0624ce48e45b1d945b04c1250b4c1567b9bea7fa4096bcfee5`. The original YAOF payload and prepared Linux 6.12.112 source match it.

YAOF imported the consolidated c301–c313 patch in `5f2eb168c90d45ec6261acd63eaefdf448708bb8`. No later C4 modification or rename precedes this update. The named redmi donor history and `c4-patchset.toml` are unavailable locally. The derivation SHA is verified upstream, but intermediate donor ancestry cannot be independently established. Algorithm mapping uses actual source comparison, with high confidence for the changes below, not a claim of TCP/QUIC behavioral equivalence.

## Changes after the baseline

Dates below are upstream author dates. Each SHA links to the full upstream change.

| Commit | Date | Upstream functions / change | Linux mapping |
| --- | --- | --- | --- |
| [6f02e9d01d8b597245e1e580591821041eb73028](https://github.com/private-octopus/picoquic/commit/6f02e9d01d8b597245e1e580591821041eb73028) | 2026-08-07 | `c4_exit_recovery`: trim stale nominal rate | Recovery-cycle trimming, superseded by max-of-two below |
| [a1bb96209111c2e1a5cc408f4d3387c3da49df47](https://github.com/private-octopus/picoquic/commit/a1bb96209111c2e1a5cc408f4d3387c3da49df47) | 2026-08-08 | Initial exit, recovery, RTT tracking: queue draining | `c4_enter`, `c4_finish_round`; final backlog model replaces temporary flag |
| [7786d816502411fb1ee3fecdbb00e509a6484436](https://github.com/private-octopus/picoquic/commit/7786d816502411fb1ee3fecdbb00e509a6484436) | 2026-08-10 | Recovery and ACK handling: bad-WiFi startup re-entry and congestion reset | Timed startup re-entry and recovery-cycle congestion counter |
| [4b8e3ca34333344f632fd147ea6fd82918d86dab](https://github.com/private-octopus/picoquic/commit/4b8e3ca34333344f632fd147ea6fd82918d86dab) | 2026-08-10 | Remove dead code/comments | No QUIC dead code introduced |
| [79ed9bd93654e44c6f83a14d877e3f5cecc15b2a](https://github.com/private-octopus/picoquic/commit/79ed9bd93654e44c6f83a14d877e3f5cecc15b2a) | 2026-08-11 | Specification reference | Documentation only |
| [01e58483ebed752c54ddfac8b76ebd97dad7845d](https://github.com/private-octopus/picoquic/commit/01e58483ebed752c54ddfac8b76ebd97dad7845d) | 2026-08-19 | Initial entry, recovery exit, ACK: one-second guard and startup floor | `tcp_mstamp` in microseconds, `srtt_us >> 3`, packet/byte conversion through MSS; no ACK-by-ACK floor ratchet |
| [3ec5ea7426bca4055cae92d07c38e049f2a7c688](https://github.com/private-octopus/picoquic/commit/3ec5ea7426bca4055cae92d07c38e049f2a7c688) | 2026-08-28 | Initial exit/recovery: sub-ms drain/trim exceptions | Use TCP SRTT, not the clamped model RTT, to identify sub-ms paths |
| [7bf3040a4da9c2513316d3a3d43a03a205e5738a](https://github.com/private-octopus/picoquic/commit/7bf3040a4da9c2513316d3a3d43a03a205e5738a) | 2026-09-16 | `c4_reset`: reset migrated QUIC path CWIN | Do not force a fixed cwnd on TCP controller switching; clear inline state on `.init`, retain TCP disconnect handling |
| [5504fd63a180a00302084219c3a47cebed36b872](https://github.com/private-octopus/picoquic/commit/5504fd63a180a00302084219c3a47cebed36b872) | 2026-09-24 | Backlog in startup exit, recovery, pushing, ECN | Q10 backlog, recovery gains 960/896/758, pushing plateau accumulation, ECN clears backlog |
| [b579c6a94c84a5d9cc29354687fbd1a50813dc5c](https://github.com/private-octopus/picoquic/commit/b579c6a94c84a5d9cc29354687fbd1a50813dc5c) | 2026-10-03 | Remove drain flag; choose gain from backlog | Final model only; do not add superseded probe-entry accumulation |
| [69c59742b8af64c7c43f3de01e1f599b09ff03f5](https://github.com/private-octopus/picoquic/commit/69c59742b8af64c7c43f3de01e1f599b09ff03f5) | 2026-10-20 | `c4_exit_recovery`: max of last two cycle peaks | `recent_rate`, `previous_rate`; no trim without usable non-app-limited evidence |

Drain gain is exactly **758/1024**, not exactly 75%. Upstream decrements backlog at recovery exit but does **not** require zero backlog before leaving recovery. This port preserves that behavior. Exactly 1 ms is distinct from a sub-ms SRTT; the model's 1 ms floor alone does not activate the low-RTT exception. This is a deliberate Linux deviation: upstream recovery also selects gain 960 when its model RTT is <= 1 ms, whereas this port uses raw TCP SRTT to avoid conflating a clamped estimate with a measured sub-ms path. An unavailable SRTT (`srtt_us == 0`) also disables draining and non-congestion trimming conservatively; it is not evidence of a measured sub-ms RTT. Boundary tests cover 999/1000/1001 us and model RTT 1000 us with SRTT 2000 us.

The former Linux-only cruising-rate decay is replaced by recovery-cycle trimming, rather than applying both policies. The existing simplified fixed probe/push gains remain. QUIC's probe-level cascade, careful resume/seed CWIN, allocation, TLS/logging/options, multipath and ECT(1)/L4S are not introduced.

## Linux correctness boundaries

- Delivery rates are bytes/second. TCP delivery/loss counters and cwnd are packets. RTT/model time is microseconds. SRTT is stored with an eightfold scale. MSS converts packet counts to bytes.
- Linux CWR/Recovery retains PRR ownership of cwnd, including the module-compatible PRR implementation. TCP Loss retains core loss handling. The model deliberately freezes during Linux CWR/Recovery/Loss. The ACK that returns Linux to Open can finish a C4 round immediately; no complete post-recovery measurement round is guaranteed. This is not QUIC's notification schedule.
- C4's own congestion recovery while Linux remains Open rejects nominal-rate increases from congestion-recovery samples, including its exit ACK. Before startup re-entry, the gate considers the current ACK's admissible non-app-limited rate, without moving that sample's peak into the completed round. Congestion-recovery samples remain ineligible for nominal-rate growth, including on a re-entry ACK. C4 recovery while Linux remains Open can re-enter startup when the jitter/rate/time conditions hold. Invalid delivery samples cannot complete a model round. App-limited samples do not create bandwidth peaks or force a zero-rate estimate.
- Preserve TLP CWR loss distinction, DSACK/F-RTO undo, delayed-ACK baseline replacement, same-ACK undo suppression, socket disconnect and idle pacing timestamp handling. New state and startup-exit RTT changes join the loss-undo snapshot.
- Startup damping accumulates Q9 packet credits across ACKs, preserving sub-packet growth instead of truncating every small ACK. Startup re-entry resets ssthresh only outside TCP recovery. Floor changes trigger control application even if the TCP helper does not change cwnd.
- State is inline and pointer-free. The shared congestion-control private area grows from the previous YAOF C4 layout 144 to 208 bytes: **64 additional bytes in every full TCP socket**, regardless of its selected congestion controller, not only C4 sockets. Relative to stock Linux 6.12's 104-byte field, the total change is 104 bytes. Allocator/slab overhead may differ from these structure-size changes. TCP callbacks use the existing socket serialization; pacing publication retains `READ_ONCE`/`WRITE_ONCE`. No worker, allocation, timer or new lifetime owner is added.
- Bound extreme delivery rates before gain/BDP arithmetic. Use kernel 64-bit division helpers, saturation for backlog, and widened RTT comparisons. Counter deltas remain unsigned modular subtraction.

Related upstream [8ba0dc627bcd28d30de2fc3c70f2a8f59268de32](https://github.com/private-octopus/picoquic/commit/8ba0dc627bcd28d30de2fc3c70f2a8f59268de32), 2026-10-22, corrects QUIC ACK-path attribution and loss-counter underflow. Linux `tcp_rate.c` snapshots delivery on the same TCP socket. Linux `tp->lost` is cumulative, unlike `lost_out`; spurious-loss correction does not subtract it in the inspected 6.12.112 `tcp_input.c`. Do not clamp legitimate unsigned counter wrap or copy QUIC multipath plumbing. Tests cover modular wrap.

## Validation and rebuilding

Run `python3 tools/test_c4.py`. It extracts the actual patch payload and exercises both built-in and module branches with undefined-behavior sanitizer. This is a userspace shim, not a full TCP stack or runtime acceptance test.

Also require patch parsing, fresh zero-fuzz application, target-toolchain compilation, and later complete OpenWrt rebuild. A larger `inet_connection_sock` changes kernel layout. Rebuild the full kernel and **all dependent kernel modules**. Never mix old YAOF, official OpenWrt, or other-build kmods with this kernel, even if their ABI/version strings match. The inspected build has `CONFIG_MODVERSIONS=n` and `CONFIG_MODULE_STRIPPED=y`; module loading may lack effective symbol-version/vermagic rejection of incompatible layouts. This is not merely a forced-load risk. Successful loading or matching strings do not establish ABI compatibility. Do not validate the change by replacing only `tcp_c4.o` or one `.ko` in the prior image.

Preserve prior firmware and provenance before the final build. Reuse pinned source/feed inputs without feed refresh. Prefer full `make -j8 V=s`, inspect available memory and nested concurrency first, and reduce the failing sub-build's jobs if OOM occurs. Final acceptance must prove the updated source reached linked `vmlinux` and the delivered image, retain new hashes/provenance, and state any missing boot/network tests.
