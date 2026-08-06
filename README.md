# alloc_diag — EMQX 内存分配器(allocator)诊断工具

`alloc_diag` 通过 RPC 连接运行中的 EMQX 节点，抓取 `erlang:system_info({allocator, Type})` 数据，回答一个在生产上经常困扰人的问题：

> **"我的 EMQX RSS 很高，但是 `mbcs_usage` 很低，内存为什么没有还给操作系统？"**

它把"被 abandon 进 carrier pool、free block 已被 `madvise(MADV_FREE)` 标记为可回收"的那部分内存单独算出来，并**根据检测到的 OTP 版本**给出 vm.args 调优建议。

---

## 目录

- [快速开始](#快速开始)
- [一、Erlang 分配器是怎么工作的](#一erlang-分配器是怎么工作的)
- [二、名词表](#二名词表)
- [三、为什么内存不还给操作系统（核心问题）](#三为什么内存不还给操作系统核心问题)
- [四、输出格式详解](#四输出格式详解)
- [五、vm.args 建议（按 OTP 版本）](#五vmargs-建议按-otp-版本)
- [六、如何连接 EMQX 节点（原理）](#六如何连接-emqx-节点原理)
- [七、Docker 使用](#七docker-使用)

---

## 快速开始

```bash
# 本机 / 有 release 目录的机器
./alloc_diag.sh --rel /path/to/emqx-release

# 显式指定节点和 cookie（绕过配置探测）
./alloc_diag.sh --rel /path/to/emqx-release --node 'emqx@127.0.0.1' --cookie secret

# 生产环境 config 不在 release 里时，指定配置文件路径
./alloc_diag.sh --rel /usr/lib/emqx --conf /etc/emqx/emqx.conf

# 每个 instance 的明细
./alloc_diag.sh --rel /path/to/emqx-release --verbose
```

**必须用 EMQX 自己 release 的 `erts` 来跑**（wrapper 已经帮你做这件事），原因见[第六节](#六如何连接-emqx-节点原理)。

---

## 一、Erlang 分配器是怎么工作的

### 1.1 carrier 和 block

allocator（如 `binary_alloc`）从操作系统一次性申请**大块连续内存**，再把它切成小块分给 Erlang 运行时使用：

```
 操作系统 (OS)
   │  通过 mmap 一次性申请一块连续内存（例如 32KB ~ 5MB）
   ▼
┌──────────────────────────────────────────────────────────┐
│ carrier（载体）— 与 OS 打交道的最小单位                        │
│ ┌──────┬──────┬───────┬───────┬────────────┬──────┐       │
│ │ blk0 │ blk1 │ blk2  │ blk3  │   free     │ blk4 │       │
│ │ 在用  │ 在用  │ 在用   │ free  │ (合并出的空) │ 在用  │       │
│ └──────┴──────┴───────┴───────┴────────────┴──────┘       │
└──────────────────────────────────────────────────────────┘
```

- **carrier**：从 OS 拿到的整块内存（`Carrier_t`）。两类：
  - **MBC（multiblock carrier）**：切成很多小 block，给一般大小的分配用。
  - **SBC（single-block carrier）**：整块就是一个大 block，给 ≥ `sbct`（默认 512KB）的大分配用。
- **block**：carrier 内部划给调用方的最小内存单位（`Block_t`）。两种状态：
  - **used / live（在用）**：已经交给应用，占用真实物理页。
  - **free（空闲）**：释放后留下的空位，挂在本 carrier 的 free 结构里等复用；相邻 free block 会合并。

### 1.2 instance：每个 scheduler 一个

多核机器上 allocator 按 **scheduler 拆分 instance**，每线程用自己锁定的 instance，避免全局锁竞争：

```
  scheduler 1 ── instance 0 ──┐
  scheduler 2 ── instance 1 ──┤  每个 instance 独立持有若干 carrier（home）
  scheduler 3 ── instance 2 ──┘
  ...
```

注意：**instance 0 是 thread-safe 主实例，carrier pool 对它禁用**。所以 `erlang:system_info` 里 instance 0 永远显示 `{acul, 0}, {cp, undefined}`，这是正常的，不代表迁移没开。

### 1.3 carrier pool：跨 instance 共享内存

每个 instance 的负载是**突发且不均衡**的：A 高峰、B 空闲。如果不共享，A 空闲下来的 carrier 只能 munmap 还给 OS，B 高峰时再重新 mmap，于是**同一时刻可能同时存在两份峰值**，且 mmap/munmap 反复折腾 OS。于是 OTP 17 引入了 **carrier 迁移**：

```
  instance A 流量退了，carrier 利用率 ≤ acul(60%) → abandon
        │
        ▼
  ┌────────────────────────────────┐
  │    carrier pool（共享池）        │
  │  任何 instance 需要时 fetch 复用  │
  └────────────────────────────────┘
        ▲
        │
  instance B 流量来了 → 从 pool 直接取走，不用向 OS 重新申请
```

**abandon 的时机**：当某 instance 的某 carrier "用到 ≤ `acul`（默认 60%）"时，它就被放弃进 pool。注意阈值是 60%，**不是 0**——所以被放弃的 carrier 里可能还带着在用的 block（这就是 `pool_used`）。

### 1.4 abandon 时对内存做了什么

`abandon_carrier` 会遍历这个 carrier 里的 **free block**，逐个调用 `madvise(MADV_FREE)` 告诉内核"这些页可以回收"：

```
abandon 前的 carrier（还在 instance 手里）
  [在用][在用][free][free]     ← free 不标记，RSS 全部保留
        │ 用到 ≤ 60% 触发 abandon
        ▼
进入 pool 的 carrier
  [在用][free][free][free]
    │     └─────────── madvise(MADV_FREE) 标记"可回收"
    └─ pool_used：还在用，不标记（应用仍在读写）
```

---

## 二、名词表

| 名词 | 含义 | 在本工具输出中的体现 |
|---|---|---|
| **carrier** | 从 OS 一次性拿到的整块连续内存 | `pool_carriers` / `pool` |
| **block** | carrier 内划给调用方的内存，used 或 free | — |
| **MBC / SBC** | 多块 carrier / 单块 carrier | 都在 `home` 里 |
| **home** | 还归某个 instance 自己持有、没进 pool 的 carrier | `home` |
| **pool** | 被 abandon、进入共享池的 carrier | `pool` / `pool_carriers` |
| **pool_used** | pool 里仍在用的 block（abandon 时还带着的） | `pool_used` |
| **marked-reclaimable** | pool 里被 `madvise(MADV_FREE)` 标记的 free 空间 ≈ `pool − pool_used` | `marked_reclaimable` |
| **live** | 应用真正在用的字节（`erlang:memory(binary)`） | 汇总里的 live |
| **acul** | abandon 利用率阈值（默认 60%） | 诊断建议 |
| **acnl** | pool 最多保留的 carrier 数（默认 1000） | — |
| **acfml** | 可 abandon 的最小 free block 大小门槛（默认 0） | — |
| **acful** | (OTP 26+) "carrier free 利用率下限"，控制 free block 是否被标记 | 诊断建议 |
| **MADV_FREE** | Linux 惰性"可回收"标记 | 核心机制 |

---

## 三、为什么内存不还给操作系统（核心问题）

典型现象：`mbcs_usage` 只有 0.13（13% 在用），但 RSS 居高不下。

**答案分两层：**

1. **free block 确实被标记了**（abandon 进 pool 时 `madvise(MADV_FREE)`），
2. **但 `MADV_FREE` 是惰性的**——它只是告诉内核"这些页可以回收"，**内核只在内存压力出现时才真正回收**。没压力时，这些页继续占着 RSS。

```
工作负载:  ▲▲▲▲ 高峰              ▼▼▼▼ 低谷
VM 保留:   ──────────────────────────  pool 里大量 free 块已 madvise 标记
内核 RSS:  ──────────────────────────  ← 惰性，不主动收
                                             ↕
                                  只有内存压力出现，内核才回收这些页
```

所以"RSS 高"不是泄漏，是 **MADV_FREE 惰性**。验证方法：制造内存压力（如 `stress-ng --vm 2 --vm-bytes 6G --vm-keep`），观察 beam 的 RSS 在 `recon_alloc:allocated` 不变的情况下下降——就证明页早已标记，只是内核懒。

**要让 RSS 立即降**：OTP 27.3.4.x 之后有 `+Mumadtn true`，把 `madvise(MADV_FREE)` 换成 `MADV_DONTNEED`（立即归还）。代价是复用这些页时要重新缺页置零，性能有损——这是上游不默认开的原因。

---

## 四、输出格式详解

实际输出（EMQX 4.4.37 / OTP 24）：

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
    home (not marked):           163.37MB   ← 还攥在 instance 手里、没标记的
    pool total (abandoned):        8.50MB   (10 carriers)   ← 被 abandon 进 pool 的 carrier 总空间
    pool used (still live):        1.82MB   ← pool 里还在用的 block
    pool marked-reclaimable:       6.68MB   (madvise(MADV_FREE))   ← 已标记、内核可回收的部分
  OS VmRSS:                      156.20MB   ← 进程常驻（从目标节点 /proc 读取）
  erlang:memory(binary) live:      2.79MB   ← 真正在用的 binary 字节
  erlang:memory(total):          139.57MB   ← VM 自己记账的总内存

=== recommendation (based on detected OTP 24) ===
  This node runs OTP 24 ...
  +M<i>acful and +Mumadtn are NOT available. ...
  ...
```

**每列的含义：**

| 列 | 含义 |
|---|---|
| `home` | 该 allocator 各 instance 当前持有的 carrier 空间（地址空间，含 used 和 free block）。**这部分 free block 不被标记**，RSS 完全保留。 |
| `pool_carriers` | 被 abandon 进 pool 的 carrier 个数。 |
| `pool` | pool 里 carrier 的总空间。 |
| `pool_used` | pool 里仍在用的 block。**不标记**。 |
| `marked_reclaimable` | `pool − pool_used`。**这是"已经标记给内核、只是内核还没收"的量**。 |

**快速判读规则：**

1. **`pool` 大 + RSS 高** → 不是泄漏，是 MADV_FREE 惰性（见[第三节](#三为什么内存不还给操作系统核心问题)）。
2. **`pool` 接近 0 + RSS 高** → free block 压根没被标记。检查 carrier 迁移是否开着（`acul>0`、没设 `+M<i>t false` / `+M<i>as bf`），以及实际利用率是否真的降到 `acul%` 以下。
3. **`pool` 大 + RSS 低** → 内核已经回收了一部分，正常。
4. `--verbose` 显示每个 instance 一行，instance 0 恒为 `pool disabled`（主实例特性）。

---

## 五、vm.args 建议（按 OTP 版本）

脚本会**探测目标节点的 OTP 版本**（`erlang:system_info(otp_release)`）和是否支持 `acful`（检查 allocator options 里有没有 `acful` 字段），然后给建议。这里的 `<i>` 是 allocator 类型字母：`B`=binary、`E`=ets、`H`=eheap、`S`=sl、`D`=std 等。

### OTP 24（EMQX 4.4.x）

```vm.args
+M<i>as aoffcbf      # 已是有效默认（carrier 迁移开启时强制），显式写出便于文档化
+M<i>acul 60         # abandon 阈值，默认 60；调低=迁移少、RSS 更多，调高=迁移激进、标记更多
```

**局限**：OTP 24 **没有** `+M<i>acful` 和 `+Mumadtn`。abandon 的 free block 会用 `madvise(MADV_FREE)` 标记但**惰性回收**——RSS 要等内存压力才降。想主动降 RSS 只能升级 OTP。

### OTP 26（EMQX 5.x）

```vm.args
+M<i>acful de        # 关键！默认 0 = 完全不标记 free block；设 de 才启用标记
```

`+Mumadtn` 在 OTP 26 **没有**。

### OTP 27.3.4.x 之后 / OTP 28（EMQX 5.x 后期 / 6.x）

```vm.args
+M<i>acful de        # 启用标记（默认 0）
+Mumadtn true        # MADV_DONTNEED：标记的页立即归还 OS，RSS 立刻降（OTP-19739）
```

`+Mumadtn true` 需要包含 OTP-19739 补丁的版本（2025-09 合入 maint），老一点的 OTP 27.x 没有此选项。

> **检测到 OTP 28 的 6.2.0 上验证过**：脚本正确识别 `acful` 存在，推荐上述两组参数。

---

## 六、如何连接 EMQX 节点（原理）

这解释了为什么必须用 EMQX 自己的 erts：

1. **EMQX 不用系统 epmd**。它用 `-start_epmd false -epmd_module ekka_epmd` 注册节点。`ekka_epmd:port_please` 是**确定性映射**：节点 `xxx@host` 的 dist 端口 = `4370 + 名字尾号数字`。所以普通 `erl_call`/epmd 解析不到它的端口，连不上。
2. 客户端要连，必须也带上 `-epmd_module ekka_epmd`（wrapper 里通过 `ERL_FLAGS` 传给 escript）。
3. **OTP 28+ 的 escript 需要 `-boot_var RELEASE_LIB <rel>/lib`**，否则报 `cannot expand $RELEASE_LIB in bootfile`（wrapper 已处理）。
4. 节点名/cookie 探测顺序：生成的 `$REL/data/configs/vm.*.args`（节点实际启动用的，Docker 会改节点名）→ `emqx_ctl status` → `emqx.conf`。显式 `--node`/`--cookie` 优先。

---

## 七、Docker 使用

容器里 dist 端口一般不发布到宿主机，所以在容器内跑：

```bash
# 把脚本拷进容器
docker cp alloc_diag.sh  emqx:/tmp/
docker cp alloc_diag.escript emqx:/tmp/

# 在容器内运行（自动探测节点名/cookie/OTP 版本）
docker exec emqx bash /tmp/alloc_diag.sh --rel /opt/emqx
```

测试过的镜像：

- `emqx/emqx-ee:4.4.37`（OTP 24）—— 容器内节点名会被 Docker 改成容器 ID，wrapper 自动处理。
- `emqx/emqx-enterprise:6.2.0`（OTP 28）—— 验证了新版 OTP 检测和 `acful`/`+Mumadtn` 建议分支。

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `alloc_diag.sh` | wrapper：定位 release/erts、探测节点名与 cookie、设置 `ERL_FLAGS` |
| `alloc_diag.escript` | 主体：RPC 抓数据、解析、汇总、RSS/cgroup、OTP 探测与建议 |
| `README.md` | 本文档 |
