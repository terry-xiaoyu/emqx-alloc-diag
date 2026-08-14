# alloc_diag — EMQX allocator diagnostics tool

`alloc_diag` connects to a running EMQX node over RPC, collects `erlang:system_info({allocator, Type})` data, and answers a question that often causes confusion in production:

> **"I can see high memory usage from `top`, but `observer_cli` or `erlang:memory/1` reports much less actual usage, and `recon_alloc:fragmentation(current)` shows low `mbcs_usage`. Why is the memory not being returned to the OS?"**

It separately accounts for the memory that has been abandoned into the carrier pool and whose free blocks have been marked reclaimable via `madvise(MADV_FREE)`, and it provides vm.args tuning suggestions based on the detected OTP version.

[中文版](README-ZH.md)

---

## Table of contents

- [Quick start](#quick-start)
- [1. How Erlang allocators work](#1-how-erlang-allocators-work)
- [2. Glossary](#2-glossary)
- [3. Why memory is not returned to the OS](#3-why-memory-is-not-returned-to-the-os)
- [4. Output format details](#4-output-format-details)
- [5. vm.args recommendations by OTP version](#5-vmargs-recommendations-by-otp-version)
- [6. How EMQX node connection works](#6-how-emqx-node-connection-works)
- [7. Docker usage](#7-docker-usage)
- [8. Size-mismatch diagnosis (RSS keeps rising)](#8-size-mismatch-diagnosis-rss-keeps-rising)

---

## Quick start

```bash
# Local machine / machine with a release directory
./alloc_diag.sh --rel /path/to/emqx-release

# Explicitly specify node and cookie (bypass auto-detection)
./alloc_diag.sh --rel /path/to/emqx-release --node 'emqx@127.0.0.1' --cookie secret

# When production config is not inside the release, specify the config file path
./alloc_diag.sh --rel /usr/lib/emqx --conf /etc/emqx/emqx.conf

# Show per-instance details
./alloc_diag.sh --rel /path/to/emqx-release --verbose

# Confirm an ONGOING size mismatch (see Section 8):
#   --trend 60     quick two-sample check
#   --watch 60 10  for fluctuating RSS: 10 samples, 60s apart, count active intervals
#   --pool-sizes   size histogram of the free blocks in the abandoned pool
./alloc_diag.sh --rel /path/to/emqx-release --trend 60
./alloc_diag.sh --rel /path/to/emqx-release --watch 60 10
./alloc_diag.sh --rel /path/to/emqx-release --pool-sizes
```

**You must run it with EMQX's own release `erts`** (the wrapper already handles this), as explained in [Section 6](#6-how-emqx-node-connection-works).

---

## 1. How Erlang allocators work

### 1.1 Carrier and block

An allocator such as `binary_alloc` first requests a large contiguous memory region from the OS and then splits it into smaller blocks for the Erlang runtime:

```
 Operating system (OS)
   │  mmap a large contiguous region (for example 32KB to 5MB)
   ▼
┌────────────────────────────────────────────────────────┐
│ carrier — the smallest unit that interacts with the OS │
│ ┌──────┬──────┬───────┬───────┬────────────┬──────┐    │
│ │ blk0 │ blk1 │ blk2  │ blk3  │   free     │ blk4 │    │
│ │ used │ used │ used  │ free  │ (merged)   │ used │    │
│ └──────┴──────┴───────┴───────┴────────────┴──────┘    │
└────────────────────────────────────────────────────────┘
```

- **carrier**: a large contiguous memory block obtained from the OS (`Carrier_t`). Two types:
  - **MBC (multiblock carrier)**: split into many small blocks for general-sized allocations.
  - **SBC (single-block carrier)**: the whole block is a single large block for allocations of at least `sbct` (default 512KB).
- **block**: the minimal memory unit inside a carrier (`Block_t`). Two states:
  - **used / live**: already handed to the application and occupying real physical pages.
  - **free**: a released slot that remains in the carrier's free structure for reuse; adjacent free blocks are merged.

### 1.2 Instance: one per scheduler

On multi-core machines, allocators are partitioned by scheduler into **instances**. Each thread uses its own locked instance to avoid global contention:

```
  scheduler 1 ── instance 0 ──┐
  scheduler 2 ── instance 1 ──┤  each instance owns a set of carriers (home)
  scheduler 3 ── instance 2 ──┘
  ...
```

Note: **instance 0 is the thread-safe main instance, and the carrier pool is disabled for it**. Therefore `erlang:system_info` will always show `{acul, 0}, {cp, undefined}` for instance 0. This is normal and does not mean migration is disabled.

### 1.3 Carrier pool: shared memory across instances

Each instance's workload is bursty and uneven: one may be busy while another is idle. Without sharing, carriers released by a busy instance can only be `munmap`'d back to the OS, while the other instance may have to request new memory later. This can create duplicate peak usage and repeated mmap/munmap churn. For this reason, OTP 17 introduced **carrier migration**:

```
  instance A load drops, carrier usage ≤ acul (60%) → abandon
        │
        ▼
  ┌────────────────────────────────┐
  │    carrier pool (shared pool)  │
  │    any instance can fetch it   │
  └────────────────────────────────┘
        ▲
        │
  instance B load rises → fetch from pool directly, avoid re-requesting from OS
```

**When abandon happens**: when a carrier in an instance reaches usage of at most `acul` (default 60%), it is moved into the pool. The threshold is 60%, not 0, so abandoned carriers may still contain live blocks, which is what `pool_used` represents.

### 1.4 What happens to memory during abandon

`abandon_carrier` walks the carrier's **free blocks** and calls `madvise(MADV_FREE)` for each to tell the kernel that those pages can be reclaimed:

```
carrier before abandon (still in instance)
  [used][used][free][free]     ← free blocks are not marked, RSS remains reserved
        │ usage ≤ 60% triggers abandon
        ▼
carrier in pool
  [used][free][free][free]
    │     └─────────── madvise(MADV_FREE) marks reclaimable
    └─ pool_used: still in use, not marked (application still reads/writes)
```

---

## 2. Glossary

| Term | Meaning | How it appears in this tool |
|---|---|---|
| **carrier** | A large contiguous memory block allocated from the OS | `pool_carriers` / `pool` |
| **block** | Memory unit inside a carrier, either used or free | — |
| **MBC / SBC** | Multiblock carrier / single-block carrier | shown under `home` |
| **home** | Carriers still owned by an instance and not yet moved to the pool | `home` |
| **pool** | Carriers that were abandoned into the shared pool | `pool` / `pool_carriers` |
| **pool_used** | Blocks still in use inside the pool (carried over from abandon) | `pool_used` |
| **marked-reclaimable** | Free space in the pool marked by `madvise(MADV_FREE)` ≈ `pool - pool_used` | `marked_reclaimable` |
| **live** | Bytes actually in use by the application (`erlang:memory(binary)`) | shown in the summary |
| **acul** | Abandon usage threshold (default 60%) | tuning suggestion |
| **acnl** | Maximum number of carriers retained in the pool (default 1000) | — |
| **acfml** | Minimum free block size threshold for abandon (default 0) | — |
| **acful** | (OTP 26+) "carrier free utilization lower bound", controlling whether free blocks are marked | tuning suggestion |
| **MADV_FREE** | Linux lazy reclaimable marking | core mechanism |

---

## 3. Why memory is not returned to the OS

A typical symptom is that `mbcs_usage` is only 0.13 (13% in use), but RSS stays high.

The answer has two layers:

1. **The free blocks are indeed marked** (via `madvise(MADV_FREE)` when abandoned into the pool).
2. **But `MADV_FREE` is lazy** — it only tells the kernel that those pages may be reclaimed; the kernel only reclaims them when memory pressure appears. When there is no pressure, those pages remain in RSS.

```
workload:   ▲▲▲▲ peak               ▼▼▼▼ trough
VM retained: ────────────────────────── many free blocks in pool already marked
kernel RSS : ────────────────────────── ← lazy, not actively reclaimed
                                             ↕
                                  only when memory pressure appears does the kernel reclaim them
```

So high RSS is not a leak; it is **lazy `MADV_FREE` behavior**. One way to verify this is to create memory pressure (for example `stress-ng --vm 2 --vm-bytes 6G --vm-keep`) and observe that beam RSS drops while `recon_alloc:allocated` stays unchanged, proving that pages were already marked and the kernel was simply lazy.

**To make RSS drop immediately**: from OTP 27.3.4.x onward there is `+Mumadtn true`, which switches from `madvise(MADV_FREE)` to `MADV_DONTNEED` (immediate return). The tradeoff is that pages must be faulted in and zeroed again when reused, which hurts performance — which is why upstream does not enable it by default.

---

## 4. Output format details

Example output (EMQX 4.4.37 / OTP 24):

```
emqx 4.4.37 (OTP 24) node 'a1f17d962508@172.17.0.2'
                                                ← node info + detected OTP version
  type           home       pool_carriers  pool       pool_used  marked_reclaimable
  ----------------------------------------------------------------------------------------
  binary_alloc   home=    2.66MB  pool_carriers=    4  pool=    1.75MB  pool_used=    0.40MB  marked_reclaimable=    1.35MB
  ets_alloc      home=    7.63MB  pool_carriers=    1  pool=    0.25MB  pool_used=    0.03MB  marked_reclaimable=    0.22MB
  ...                                                                                        ← one line per allocator

=== overall ===
  VM retained (home+pool):       171.87MB   ← all carrier space for all instances (including pool)
    home (not marked):           163.37MB   ← still held by instances and not marked
    pool total (abandoned):        8.50MB   (10 carriers)   ← total carrier space abandoned into the pool
    pool used (still live):        1.82MB   ← blocks still in use inside the pool
    pool marked-reclaimable:       6.68MB   (madvise(MADV_FREE))   ← already marked and reclaimable by the kernel
  OS VmRSS:                      156.20MB   ← resident memory as read from the target node /proc
  erlang:memory(binary) live:      2.79MB   ← real bytes in use by binaries
  erlang:memory(total):          139.57MB   ← total memory accounted for by the VM

=== recommendation (based on detected OTP 24) ===
  This node runs OTP 24 ...
  +M<i>acful and +Mumadtn are NOT available. ...
  ...
```

**Meaning of each column**:

| Column | Meaning |
|---|---|
| `home` | The allocator's current carrier space held by each instance (address space, including used and free blocks). **These free blocks are not marked** and RSS remains reserved. |
| `home_cr` | Number of carriers currently held by the instances (not yet pooled). |
| `pool_cr` | Number of carriers abandoned into the pool. |
| `pool` | Total carrier space inside the pool. |
| `pool_used` | Blocks still in use in the pool. **Not marked**. |
| `marked_reclaimable` | `pool - pool_used`. **This is the portion already marked for the kernel, but not yet reclaimed by it**. |

The `=== overall ===` block opens with a `total carriers: N (home=…, pool=…)`
line (summed over all allocators). A `=== allocator configuration ===` block then
prints each allocator's `as` (strategy), `acul`/`acnl`/`acfml` abandon thresholds,
`sbct`, `smbcs`/`lmbcs` carrier sizes, `atags`, and `cp` (carrier pool enabled).
`min_block_size` is not exposed by `system_info` (it is strategy-internal).

**Quick interpretation rules**:

1. **Large `pool` + high RSS** → not a leak; this is lazy `MADV_FREE` behavior (see [Section 3](#3-why-memory-is-not-returned-to-the-os)).
2. **Pool close to zero + high RSS** → free blocks were never marked. Check whether carrier migration is enabled (`acul > 0`, without `+M<i>t false` / `+M<i>as bf`) and whether actual usage really dropped below `acul%`.
3. **Large `pool` + low RSS** → the kernel has already reclaimed part of it; this is normal.
4. `--verbose` shows one line per instance; instance 0 is always `pool disabled` (main instance behavior).

---

## 5. vm.args recommendations by OTP version

The script detects the target node's OTP version (`erlang:system_info(otp_release)`) and whether `acful` is supported (by checking whether the allocator options include an `acful` field), then provides recommendations. Here `<i>` is the allocator type letter: `B` = binary, `E` = ets, `H` = eheap, `S` = sl, `D` = std, etc.

### OTP 24 (EMQX 4.4.x)

```vm.args
+M<i>as aoffcbf      # already an effective default; written explicitly for documentation
+M<i>acul 60         # abandon threshold, default 60; lower = less migration / more RSS, higher = more aggressive migration / more marking
```

**Limitation**: OTP 24 does **not** have `+M<i>acful` or `+Mumadtn`. Free blocks abandoned in this mode are marked with `madvise(MADV_FREE)`, but reclamation is lazy — RSS only drops when memory pressure occurs. To reduce RSS proactively, you must upgrade OTP.

### OTP 26 (EMQX 5.x)

```vm.args
+M<i>acful de        # key! default 0 = do not mark free blocks at all; `de` enables marking
```

`+Mumadtn` does not exist in OTP 26.

### OTP 27.3.4.x and later / OTP 28 (EMQX 5.x late / 6.x)

```vm.args
+M<i>acful de        # enable marking (default 0)
+Mumadtn true        # MADV_DONTNEED: marked pages are returned to the OS immediately, reducing RSS right away (OTP-19739)
```

`+Mumadtn true` requires a build that includes the OTP-19739 patch (merged into maint in 2025-09). Older OTP 27.x builds do not expose this option.

> **Verified on OTP 28 / EMQX 6.2.0**: the script correctly detects that `acful` exists and recommends the two options above.

---

## 6. How EMQX node connection works

This explains why the tool must use EMQX's own `erts`:

1. **EMQX does not use the system epmd**. It registers nodes with `-start_epmd false -epmd_module ekka_epmd`. `ekka_epmd:port_please` uses a **deterministic mapping**: the distribution port for node `xxx@host` is `4370 + last digit of the name`. Because of this, normal `erl_call`/epmd resolution cannot reach the port.
2. The client must also include `-epmd_module ekka_epmd` (the wrapper passes this to the escript via `ERL_FLAGS`).
3. **For OTP 28+, the escript needs `-boot_var RELEASE_LIB <rel>/lib`**; otherwise it fails with `cannot expand $RELEASE_LIB in bootfile` (handled by the wrapper).
4. The node name / cookie detection order is: generated `$REL/data/configs/vm.*.args` (the actual runtime args, and Docker may change the node name) → `emqx_ctl status` → `emqx.conf`. Explicit `--node` / `--cookie` overrides take precedence.

---

## 7. Docker usage

The distribution ports are generally not published to the host, so run it inside the container:

```bash
# Copy scripts into the container
docker cp alloc_diag.sh emqx:/tmp/
docker cp alloc_diag.escript emqx:/tmp/

# Run inside the container (auto-detect node name / cookie / OTP version)
docker exec emqx bash /tmp/alloc_diag.sh --rel /opt/emqx
```

Tested images:

- `emqx/emqx-ee:4.4.37` (OTP 24) — the container node name is rewritten by Docker to the container ID, and the wrapper handles that automatically.
- `emqx/emqx-enterprise:6.2.0` (OTP 28) — verified the new OTP detection and the `acful` / `+Mumadtn` recommendation branches.

---

## 8. Size-mismatch diagnosis (RSS keeps rising)

A large pool (abandoned carriers) does not always mean it is being reused. If
the new allocation size no longer matches the free blocks left in the pool, the
pool cannot serve them, and the allocator `mmap`s a brand-new carrier every
time — RSS keeps rising even though the pool is huge.

The tool reads the carrier-pool reuse counters (`erlang:system_info` →
`mbcs_pool`) and prints them per allocator:

```
=== carrier-pool reuse / size-mismatch diagnosis ===
  type           fetch        skip_size    fail_pooled  fail         verdict
  -----------------------------------------------------------------------------------------
  binary_alloc   120          98000        1200         2100         SIZE MISMATCH (blocks too small)
  eheap_alloc    540000       15           2            30           pool reused (not size mismatch)
  ...
```

| Counter | Meaning |
|---|---|
| `fetch` | a pooled carrier **was** reused (good) |
| `skip_size` | pooled carrier found, but its **largest free block was smaller than the request** — the size-mismatch smoking gun |
| `fail_pooled` | gave up searching the instance's own pool (no carrier fit) |
| `fail` | total pool-allocation failures → a **new carrier is `mmap`'d → RSS grows** |

> Counters are stored as `{Key, Giga, Low}` where `Giga = count div 10^9` and
> `Low = count rem 10^9` (see `ERTS_ALC_CC_GIGA_VAL` / `ONE_GIGA` in
> `erl_alloc_util.c`). The tool combines them as `Giga * 10^9 + Low` — note it
> is **10^9, not 2^30**.

**How to read**:

- `skip_size` / `fail_pooled` >> `fetch` → **size mismatch**: the pool's free
  blocks are mostly too small for new demand. RSS grows because the allocator
  keeps creating new carriers.
- `fetch` dominates → the pool is reused normally; RSS growth is live-set
  growth instead.
- all zero → no pool activity (pool empty, or carrier migration off — check the
  home/pool table and the `acul` note in the recommendations).

**Confirm it is ONGOING (not a historical one-time pileup)**:

```bash
# quick two-sample check (fine when RSS is steady)
./alloc_diag.sh --rel /path/to/emqx-release --trend 60

# fluctuating RSS: sample 10 times, 60s apart, and count active intervals
./alloc_diag.sh --rel /path/to/emqx-release --watch 60 10
```

`--trend` samples twice and prints the deltas. `--watch` samples `count` times,
`interval` seconds apart, and additionally reports the net RSS change and how
many intervals (`active`) saw a mismatch.

Because the counters are cumulative/monotonic, a single short diff can land in a
quiet trough and under-report an ongoing mismatch when RSS fluctuates (rises on
average but not monotonically). `--watch` spans several fluctuation cycles and
is the right tool in that case.

- `d(skip_size)` / `d(fail)` keep growing while `d(fetch)` stays ~0, and
  `active` is high → the mismatch is ongoing and drives RSS up.
- all deltas ~0 → the pool is just a historical pileup.

The root cause is usually a **shift in the allocation-size distribution**: after
a burst of small objects abandoned carriers full of small free blocks, a burst
of larger objects cannot fit them, so each burst `mmap`s new carriers. Collect
the numbers above first, then decide the fix (tune `acul`/`acfml`, or accept the
size shift as an expected workload change).

### 8.1 What sizes are being abandoned (`--pool-sizes`)

To see the **size distribution** of the free blocks sitting in the pool (and
whether they are all the same size or not):

```bash
# default: hist_start=512 B — small blocks (<512 B) all fall in one bucket
./alloc_diag.sh --rel /path/to/emqx-release --pool-sizes

# fine granularity: hist_start=32 B — to distinguish ~76B/104B from 256B blocks
./alloc_diag.sh --rel /path/to/emqx-release --pool-sizes 32
```

This calls `instrument:carriers/1` on the node and aggregates the free-block
size histogram of every pooled carrier, per allocator:

```
=== abandoned-pool free-block size distribution (hist_start=512 B) ===
  (log2-bucketed, hist_start=512 B; each slot doubles in size)

  binary_alloc   6 free blocks in pool:
         64 KB  5 blocks
          4 MB  1 block
```

Reading: the pool's free blocks are mostly ~64 KB plus a few ~4 MB — i.e. **not
one uniform size**. If a single slot dominates (e.g. all ~8 KB), the churn is one
fixed-size object; if it spreads across many slots, many sizes mix together.

A smaller `hist_start` gives finer buckets for small blocks: a 76-byte message
payload becomes a ~104-byte block (payload + header + atag), which the default
512 B histogram lumps into the "<512 B" slot, but `--pool-sizes 32` resolves into
the ~128 B slot. Use this to confirm a fixed-size small-message churn is filling
the pool.

> Requires the `tools` OTP app (`instrument` module) in the release. If the node
> reports `instrument:carriers/1 unavailable`, run the
> `erts_internal:gather_carrier_info/1` snippet manually in a remsh shell.

---

## File list

| File | Purpose |
|---|---|
| `alloc_diag.sh` | Wrapper: locate release/erts, detect node name and cookie, set `ERL_FLAGS` |
| `alloc_diag.escript` | Main logic: RPC collection, parsing, aggregation, allocator configuration, RSS/cgroup, OTP detection, carrier-pool reuse / size-mismatch diagnosis (`--trend`/`--watch`), abandoned-pool size histogram (`--pool-sizes`), and recommendations |
| `README.md` | This document |
