# alloc_diag — EMQX 内存分配器（allocator）诊断工具

`alloc_diag` 通过 RPC 连接正在运行的 EMQX 节点，读取 `erlang:system_info({allocator, Type})` 的结果，并回答一个在生产环境中经常令人困扰的问题：

> **“我通过 `top` 看到 EMQX 的内存使用率很高，但通过 `observer_cli` 或 `erlang:memory/1` 等方式看到的实际内存使用量却很低；同时，`recon_alloc:fragmentation(current)` 也显示 `mbcs_usage` 很低。那为什么这些内存没有还给操作系统呢？”**

它会把那些在 abandon 后进入 carrier pool、且其 free block 已被 `madvise(MADV_FREE)` 标记为可回收的那部分内存单独统计出来，并**根据检测到的 OTP 版本**给出相应的 vm.args 调优建议。

---

## 目录

- [快速开始](#快速开始)
- [一、Erlang 分配器是如何工作的](#一erlang-分配器是如何工作的)
- [二、名词表](#二名词表)
- [三、为什么内存没有还给操作系统（核心问题）](#三为什么内存没有还给操作系统核心问题)
- [四、输出格式详解](#四输出格式详解)
- [五、按 OTP 版本给出的 vm.args 建议](#五按-otp-版本给出的-vmargs-建议)
- [六、如何连接 EMQX 节点（原理）](#六如何连接-emqx-节点原理)
- [七、Docker 使用](#七docker-使用)
- [八、尺寸不匹配诊断（RSS 持续上涨）](#八尺寸不匹配诊断rss-持续上涨)

---

## 快速开始

```bash
# 本机 / 含 release 目录的机器
./alloc_diag.sh --rel /path/to/emqx-release

# 显式指定节点和 cookie（绕过配置探测）
./alloc_diag.sh --rel /path/to/emqx-release --node 'emqx@127.0.0.1' --cookie secret

# 如果生产环境的配置不在 release 目录中，则显式指定配置文件路径
./alloc_diag.sh --rel /usr/lib/emqx --conf /etc/emqx/emqx.conf

# 显示每个 instance 的明细
./alloc_diag.sh --rel /path/to/emqx-release --verbose

# 确认「正在发生」的尺寸不匹配（见第八节）：
#   --trend 60     快速两采样检查
#   --watch 60 10  RSS 波动场景：采样 10 次（间隔 60s），统计活跃区间数
#   --pool-sizes   abandon 池里空闲块的尺寸直方图
./alloc_diag.sh --rel /path/to/emqx-release --trend 60
./alloc_diag.sh --rel /path/to/emqx-release --watch 60 10
./alloc_diag.sh --rel /path/to/emqx-release --pool-sizes
```

**必须使用 EMQX 自己 release 中的 `erts` 来运行**（wrapper 已经帮你处理好了），原因请见[第六节](#六如何连接-emqx-节点原理)。

---

## 一、Erlang 分配器是如何工作的

### 1.1 carrier 和 block

allocator（例如 `binary_alloc`）会先从操作系统一次性申请一块**较大的连续内存**，然后再把它切成更小的块，交给 Erlang 运行时使用：

```
 操作系统 (OS)
   │  通过 mmap 一次性申请一块连续内存（例如 32KB ~ 5MB）
   ▼
┌──────────────────────────────────────────────────────────┐
│ carrier（载体）— 与 OS 打交道的最小单位                      │
│ ┌──────┬──────┬───────┬───────┬────────────┬──────┐      │
│ │ blk0 │ blk1 │ blk2  │ blk3  │   free     │ blk4 │      │
│ │ 在用  │ 在用 │ 在用   │ free  │ (合并出的空)│ 在用  │      │
│ └──────┴──────┴───────┴───────┴────────────┴──────┘      │
└──────────────────────────────────────────────────────────┘
```

- **carrier**：从 OS 拿到的整块连续内存（`Carrier_t`）。它有两类：
  - **MBC（multiblock carrier）**：切成很多小 block，供一般大小的分配使用。
  - **SBC（single-block carrier）**：整块就是一个大 block，供大于等于 `sbct`（默认 512KB）的分配使用。
- **block**：carrier 内部划给调用方的最小内存单位（`Block_t`）。有两种状态：
  - **used / live（在用）**：已经交给应用占用，实际占用了物理页。
  - **free（空闲）**：释放后留下的空位，挂在当前 carrier 的 free 结构里等待复用；相邻的 free block 会被合并。

### 1.2 instance：每个 scheduler 一个

在多核机器上，allocator 会按 **scheduler 拆分成 instance**。每个线程使用各自持有的 instance，并由其对应的锁来避免全局竞争：

```
  scheduler 1 ── instance 0 ──┐
  scheduler 2 ── instance 1 ──┤  每个 instance 独立持有若干 carrier（home）
  scheduler 3 ── instance 2 ──┘
  ...
```

注意：**instance 0 是线程安全的主实例，carrier pool 对它是禁用的**。因此在 `erlang:system_info` 中，instance 0 往往会显示 `{acul, 0}, {cp, undefined}`，这属于正常现象，并不表示迁移机制没有开启。

### 1.3 carrier pool：跨 instance 共享内存

每个 instance 的负载都会出现**突发且不均衡**的情况：A 处于高峰，B 则相对空闲。如果不做共享，A 释放后空出来的 carrier 只能 `munmap` 回收给 OS，而 B 在高峰期再次需要时，只能重新向 OS 申请。这样就会导致**同一时刻出现两份峰值**，并且 `mmap/munmap` 会反复折腾系统。为此，OTP 17 引入了 **carrier 迁移**：

```
  instance A 的负载下降，carrier 利用率 ≤ acul(60%) → abandon
        │
        ▼
  ┌─────────────────────────────────┐
  │      carrier pool（共享池）       │
  │任何 instance 需要时都可 fetch 复用 │
  └─────────────────────────────────┘
        ▲
        │
  instance B 的负载上升 → 直接从 pool 取走，不必重新向 OS 申请
```

**abandon 的时机**：当某个 instance 中的某个 carrier “使用率低于等于 `acul`（默认 60%）”时，它就会被移入 pool。需要注意，阈值是 60%，**而不是 0**——因此被放弃的 carrier 中，仍然可能带着正在使用的 block，这也正是 `pool_used` 的来源。

### 1.4 abandon 时对内存做了什么

`abandon_carrier` 会遍历这个 carrier 里的 **free block**，逐个调用 `madvise(MADV_FREE)`，告诉内核“这些页可以回收”：

```
abandon 之前的 carrier（仍在 instance 手里）
  [在用][在用][free][free]     ← free 不标记，RSS 仍然保留
        │ 使用率 ≤ 60% 触发 abandon
        ▼
进入 pool 的 carrier
  [在用][free][free][free]
    │     └─────────── madvise(MADV_FREE) 标记“可回收”
    └─ pool_used：仍在使用，不标记（应用仍在读写）
```

---

## 二、名词表

| 名词 | 含义 | 在本工具输出中的体现 |
|---|---|---|
| **carrier** | 从 OS 一次性拿到的整块连续内存 | `pool_carriers` / `pool` |
| **block** | carrier 内部划给调用方的内存，分为 used 或 free | — |
| **MBC / SBC** | 多块 carrier / 单块 carrier | 都会出现在 `home` 中 |
| **home** | 仍然归某个 instance 自己持有、尚未进入 pool 的 carrier | `home` |
| **pool** | 被 abandon 后进入共享池的 carrier | `pool` / `pool_carriers` |
| **pool_used** | pool 中仍在使用的 block（在 abandon 时就带着的） | `pool_used` |
| **marked-reclaimable** | pool 中被 `madvise(MADV_FREE)` 标记为 free 的空间，约等于 `pool − pool_used` | `marked_reclaimable` |
| **live** | 应用真正正在使用的字节数（`erlang:memory(binary)`） | 汇总结果中的 live |
| **acul** | abandon 的利用率阈值（默认 60%） | 调优建议 |
| **acnl** | pool 中最多保留的 carrier 数量（默认 1000） | — |
| **acfml** | 可 abandon 的最小 free block 大小阈值（默认 0） | — |
| **acful** | (OTP 26+) “carrier free 利用率下限”，用于控制 free block 是否被标记 | 调优建议 |
| **MADV_FREE** | Linux 上一种惰性的“可回收”标记 | 核心机制 |

---

## 三、为什么内存没有还给操作系统（核心问题）

一个典型现象是：`mbcs_usage` 只有 0.13（也就是 13% 在使用），但 RSS 却始终居高不下。

**答案分两层：**

1. **free block 确实已经被标记了**（在 abandon 进入 pool 时，使用了 `madvise(MADV_FREE)`）；
2. **但 `MADV_FREE` 是惰性的**——它只是告诉内核“这些页可以回收”，而**内核只有在出现内存压力时才会真正回收它们**。在没有压力的时候，这些页仍然会继续占在 RSS 中。

```
工作负载:  ▲▲▲▲ 高峰              ▼▼▼▼ 低谷
VM 保留:   ──────────────────────────  pool 中大量 free block 已被 madvise 标记
内核 RSS:  ──────────────────────────  ← 惰性，不会主动回收
                                             ↕
                                  只有在内存压力出现时，内核才会回收这些页
```

所以，“RSS 很高”并不意味着发生了泄漏，而是 **MADV_FREE 的惰性行为**。验证方法之一是制造内存压力（例如 `stress-ng --vm 2 --vm-bytes 6G --vm-keep`），然后观察在 `recon_alloc:allocated` 基本不变的情况下，beam 的 RSS 下降——这就说明页早已被标记，只是内核还没有及时回收。

**如果想让 RSS 立即下降**：从 OTP 27.3.4.x 起，`+Mumadtn true` 可以把 `madvise(MADV_FREE)` 改成 `MADV_DONTNEED`（立即归还）。代价是这些页在后续复用时需要重新缺页并置零，性能会有所损失——这也是上游默认不启用它的原因。

---

## 四、输出格式详解

实际输出示例（EMQX 4.4.37 / OTP 24）：

```
emqx 4.4.37 (OTP 24) node 'a1f17d962508@172.17.0.2'
                                                ← 节点信息 + 检测到的 OTP 版本
  type           home       pool_carriers  pool       pool_used  marked_reclaimable
  ----------------------------------------------------------------------------------------
  binary_alloc   home=    2.66MB  pool_carriers=    4  pool=    1.75MB  pool_used=    0.40MB  marked_reclaimable=    1.35MB
  ets_alloc      home=    7.63MB  pool_carriers=    1  pool=    0.25MB  pool_used=    0.03MB  marked_reclaimable=    0.22MB
  ...                                                                                        ← 每个 allocator 一行

=== overall ===
  VM retained (home+pool):       171.87MB   ← 各 instance 所有 carrier 空间（含 pool）
    home (not marked):           163.37MB   ← 仍保留在 instance 手中、且未被标记的部分
    pool total (abandoned):        8.50MB   (10 carriers)   ← 被 abandon 后进入 pool 的 carrier 总空间
    pool used (still live):        1.82MB   ← pool 中仍在使用的 block
    pool marked-reclaimable:       6.68MB   (madvise(MADV_FREE))   ← 已被标记、内核可回收的部分
  OS VmRSS:                      156.20MB   ← 进程常驻内存（从目标节点 /proc 读取）
  erlang:memory(binary) live:      2.79MB   ← 真正在使用的 binary 字节数
  erlang:memory(total):          139.57MB   ← VM 自己记账的总内存

=== recommendation (based on detected OTP 24) ===
  This node runs OTP 24 ...
  +M<i>acful and +Mumadtn are NOT available. ...
  ...
```

**每列的含义：**

| 列 | 含义 |
|---|---|
| `home` | 该 allocator 各 instance 当前持有的 carrier 空间（地址空间，包含 used 和 free block）。**这部分 free block 不会被标记**，因此 RSS 会保持占用。 |
| `home_cr` | 各 instance 当前持有的 carrier 数量（尚未进 pool）。 |
| `pool_cr` | 被 abandon 后进入 pool 的 carrier 数量。 |
| `pool` | pool 中 carrier 的总空间。 |
| `pool_used` | pool 中仍在使用的 block。**不会被标记**。 |
| `marked_reclaimable` | `pool − pool_used`。**这是已经标记给内核、但内核尚未真正回收的那部分**。 |

`=== overall ===` 块开头有一行 `total carriers: N (home=…, pool=…)`（所有 allocator 汇总）。之后还有一个 `=== allocator configuration ===` 块，打印每个 allocator 的 `as`（策略）、`acul`/`acnl`/`acfml` abandon 阈值、`sbct`、`smbcs`/`lmbcs` carrier 尺寸、`atags`、`cp`（carrier pool 是否开启）。`min_block_size` 不通过 `system_info` 暴露（它是策略内部常量）。

**快速判读规则：**

1. **`pool` 很大 + RSS 也高** → 这不是泄漏，而是 MADV_FREE 的惰性行为（见[第三节](#三为什么内存没有还给操作系统核心问题)）。
2. **`pool` 接近 0 + RSS 仍高** → free block 根本没有被标记。此时要检查 carrier 迁移是否开启（`acul>0`、没有设置 `+M<i>t false` / `+M<i>as bf`），以及实际利用率是否确实降到了 `acul%` 以下。
3. **`pool` 很大 + RSS 低** → 内核已经回收了其中一部分，这属于正常现象。
4. `--verbose` 会显示每个 instance 的一行；instance 0 始终为 `pool disabled`（这是主实例的特性）。

---

## 五、按 OTP 版本给出的 vm.args 建议

脚本会**探测目标节点的 OTP 版本**（`erlang:system_info(otp_release)`）以及是否支持 `acful`（检查 allocator options 中是否包含 `acful` 字段），然后给出相应建议。这里的 `<i>` 是 allocator 的类型字母：`B`=binary、`E`=ets、`H`=eheap、`S`=sl、`D`=std 等。

### OTP 24（EMQX 4.4.x）

```vm.args
+M<i>as aoffcbf      # 已经是有效默认值（在 carrier 迁移开启时会强制生效），这里明确写出，便于文档化
+M<i>acul 60         # abandon 阈值，默认 60；调低 = 迁移更少、RSS 更高；调高 = 迁移更激进、标记更多
```

**局限**：OTP 24 **没有** `+M<i>acful` 和 `+Mumadtn`。在这种模式下，abandon 的 free block 会使用 `madvise(MADV_FREE)` 进行标记，但**回收是惰性的**——RSS 只有在出现内存压力时才会下降。想要主动降低 RSS，只能升级 OTP。

### OTP 26（EMQX 5.x）

```vm.args
+M<i>acful de        # 关键！默认 0 = 完全不标记 free block；设置为 de 才会启用标记
```

`+Mumadtn` 在 OTP 26 **中不存在**。

### OTP 27.3.4.x 之后 / OTP 28（EMQX 5.x 后期 / 6.x）

```vm.args
+M<i>acful de        # 启用标记（默认 0）
+Mumadtn true        # MADV_DONTNEED：标记的页会立即归还给 OS，RSS 会立刻下降（OTP-19739）
```

`+Mumadtn true` 需要包含 OTP-19739 补丁的版本（2025-09 合入 maint）。较老的 OTP 27.x 版本并没有这个选项。

> **在检测到 OTP 28 的 6.2.0 上已验证过**：脚本能够正确识别 `acful` 的存在，并给出上述两组建议参数。

---

## 六、如何连接 EMQX 节点（原理）

这段内容解释了为什么必须使用 EMQX 自己的 erts：

1. **EMQX 并不使用系统 epmd**。它会通过 `-start_epmd false -epmd_module ekka_epmd` 来注册节点。`ekka_epmd:port_please` 采用的是**确定性映射**：节点 `xxx@host` 的 dist 端口等于 `4370 + 节点名尾号数字`。因此普通的 `erl_call` / epmd 解析方式无法找到它的端口，也就无法连上。
2. 客户端如果要连接，就必须同时带上 `-epmd_module ekka_epmd`（wrapper 会通过 `ERL_FLAGS` 将其传给 escript）。
3. **对于 OTP 28+ 的 escript，需要额外指定 `-boot_var RELEASE_LIB <rel>/lib`**；否则会报 `cannot expand $RELEASE_LIB in bootfile`（wrapper 已经处理好）。
4. 节点名 / cookie 的探测顺序为：生成的 `$REL/data/configs/vm.*.args`（节点实际启动时使用的参数，Docker 也可能会修改节点名）→ `emqx_ctl status` → `emqx.conf`。显式指定的 `--node` / `--cookie` 会优先生效。

---

## 七、Docker 使用

容器里的 dist 端口通常不会暴露到宿主机，因此需要在容器内部运行：

```bash
# 把脚本拷贝到容器中
docker cp alloc_diag.sh emqx:/tmp/
docker cp alloc_diag.escript emqx:/tmp/

# 在容器内运行（自动探测节点名 / cookie / OTP 版本）
docker exec emqx bash /tmp/alloc_diag.sh --rel /opt/emqx
```

已测试的镜像：

- `emqx/emqx-ee:4.4.37`（OTP 24）—— 容器内节点名会被 Docker 改成容器 ID，wrapper 会自动处理。
- `emqx/emqx-enterprise:6.2.0`（OTP 28）—— 已验证新版 OTP 检测以及 `acful` / `+Mumadtn` 建议分支。

---

## 八、尺寸不匹配诊断（RSS 持续上涨）

pool 很大（abandon 的 carrier 很多）**不代表它一定在被复用**。如果新分配的大小和 pool 里留下的空闲块对不上，pool 就服务不了它们，allocator 每次只能重新 `mmap` 一块新 carrier —— 于是哪怕 pool 有 8GB，RSS 仍然一直往上涨。

工具会读取 carrier-pool 的复用计数器（`erlang:system_info` → `mbcs_pool`），按 allocator 打印出来：

```
=== carrier-pool reuse / size-mismatch diagnosis ===
  type           fetch        skip_size    fail_pooled  fail         verdict
  -----------------------------------------------------------------------------------------
  binary_alloc   120          98000        1200         2100         SIZE MISMATCH (blocks too small)
  eheap_alloc    540000       15           2            30           pool reused (not size mismatch)
  ...
```

| 计数器 | 含义 |
|---|---|
| `fetch` | 成功从 pool 复用一个 carrier 的次数（好事） |
| `skip_size` | 找到了 pool 里的 carrier，但它的**最大空闲块比请求还小** —— 尺寸不匹配的直接证据 |
| `fail_pooled` | 搜完本 instance 自己的 pool 也没找到合适的 carrier |
| `fail` | pool 获取的总失败次数 → 只能**新建 carrier → RSS 上涨** |

> 计数器在底层存储为 `{Key, Giga, Low}`，其中 `Giga = count div 10^9`、`Low = count rem 10^9`（见 `erl_alloc_util.c` 里的 `ERTS_ALC_CC_GIGA_VAL` / `ONE_GIGA`）。工具按 `Giga * 10^9 + Low` 合并 —— 注意是 **10⁹，不是 2³⁰**。

**怎么读**：

- `skip_size` / `fail_pooled` 远大于 `fetch` → **尺寸不匹配**：pool 里的空闲块普遍比新需求小，allocator 不停建新 carrier，RSS 随之上涨。
- `fetch` 占主导 → pool 在正常复用，RSS 上涨是**活工作集增长**，不是不匹配。
- 全为 0 → 没有 pool 活动（pool 为空，或 carrier migration 没开 —— 看 home/pool 表和建议里的 `acul` 提示）。

**确认它是「正在发生」而非历史一次性堆积**：

```bash
# 快速两采样检查（RSS 平稳时够用）
./alloc_diag.sh --rel /path/to/emqx-release --trend 60

# RSS 波动场景：采样 10 次（间隔 60s），统计活跃区间数
./alloc_diag.sh --rel /path/to/emqx-release --watch 60 10
```

`--trend` 采样两次并打印差值；`--watch` 采样 `count` 次（间隔 `interval` 秒），额外输出 RSS 净变化、以及有多少个区间（`active`）出现了不匹配。

因为计数器是累计/单调的，**单次短差值可能正好落在波谷、低估正在发生的不匹配**（RSS 平均上行但并非单调）。`--watch` 跨越多个波动周期，是这种情况下该用的工具。

- `d(skip_size)`、`d(fail)` 持续增长、`d(fetch)` 接近 0，且 `active` 很高 → 不匹配正在发生、正是它推高 RSS。
- 各差值都约为 0 → pool 只是历史堆积。

根因通常是**分配尺寸分布发生了偏移**：一波小对象把 carrier abandon 成满是小空闲块的 pool，接着一波大对象塞不进这些小块，于是每一波都重新 `mmap` 新 carrier。先拿到上面的数据，再决定怎么调（`acul`/`acfml`，或确认这个尺寸偏移是否属于预期的负载变化）。

### 8.1 被 abandon 的都是什么尺寸（`--pool-sizes`）

想看 pool 里空闲块的**尺寸分布**（以及它们是不是都一样大）：

```bash
# 默认 hist_start=512 B —— 小对象（<512 B）都会落进同一个桶
./alloc_diag.sh --rel /path/to/emqx-release --pool-sizes

# 细粒度 hist_start=32 B —— 用来区分 ~76B/104B 与 256B 的块
./alloc_diag.sh --rel /path/to/emqx-release --pool-sizes 32
```

它在节点上调用 `instrument:carriers/1`，把每个 pooled carrier 的空闲块尺寸直方图按 allocator 聚合：

```
=== abandoned-pool free-block size distribution (hist_start=512 B) ===
  (log2-bucketed, hist_start=512 B; each slot doubles in size)

  binary_alloc   6 free blocks in pool:
         64 KB  5 blocks
          4 MB  1 block
```

怎么读：池里空闲块大多是 ~64 KB、少量 ~4 MB —— 即**不是单一尺寸**。如果只有一个槽占绝对多数（比如全是 ~8 KB），说明 churn 的是某类固定大小的对象；如果铺满多个槽，则是多种尺寸混在一起。

更小的 `hist_start` 能给出更细的分桶：76 字节的 message payload 会变成一个 ~104 字节的块（payload + header + atag），默认 512 B 直方图会把它们全塞进 "<512 B" 这一档，而 `--pool-sizes 32` 能把它们解析到 "~128 B" 档。用它来确认某类固定尺寸的小消息 churn 正在填满池子。

> 需要 release 里有 `tools` 应用（`instrument` 模块）。如果节点报 `instrument:carriers/1 unavailable`，就在 remsh 里手动跑 `erts_internal:gather_carrier_info/1` 那段脚本。

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `alloc_diag.sh` | wrapper：定位 release/erts、探测节点名与 cookie，并设置 `ERL_FLAGS` |
| `alloc_diag.escript` | 主体逻辑：RPC 抓取数据、解析、汇总、allocator 配置打印、RSS/cgroup、OTP 探测、carrier-pool 复用 / 尺寸不匹配诊断（`--trend`/`--watch`）、abandon 池尺寸直方图（`--pool-sizes`）与建议 |
| `README.md` | 本文档 |
