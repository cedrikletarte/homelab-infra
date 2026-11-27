# Storage layout options for the new server

Research date: 2026-11-26. Status: input for a decision, not a decision.

Question: how should the new server lay out its storage? Hardware: 4x Seagate IronWolf 8 TB,
2x Samsung 9100 PRO 1 TB NVMe, 1x Samsung 870 500 GB SATA SSD, 32 GB non-ECC DDR4. Options:
RAIDZ1, RAIDZ2, two ZFS mirrors, mergerfs + SnapRAID, btrfs. For each one: usable capacity,
fault tolerance, resilver time, how it grows, and how it performs for media, photos and
databases. Also covered: what the NVMe drives and the SATA SSD should do, how big the ARC
should be, and the real risk of ZFS without ECC. Constraint: 4.5 TB of existing data will be
restored onto the pool after it is created.

Sources are linked inline. "Computed" marks numbers derived here from the cited rules, not
quoted from a source.

## 1. Facts that frame every option

### Software versions (2026)

- Ubuntu 26.04 LTS ("Resolute") ships OpenZFS **2.4.1** (`2.4.1-1ubuntu5.1` in updates);
  Ubuntu 24.04 LTS ships **2.2.2**
  ([Launchpad zfs-linux](https://launchpad.net/ubuntu/+source/zfs-linux)). The latest upstream
  release is 2.4.4 ([OpenZFS releases](https://github.com/openzfs/zfs/releases)).
- RAIDZ expansion arrived in OpenZFS 2.3.0
  ([2.3.0 release notes](https://github.com/openzfs/zfs/releases/tag/zfs-2.3.0)). **Ubuntu
  24.04's 2.2.2 cannot do it**, so any plan that relies on expansion assumes 26.04 (or a
  backported module).
- `zfs rewrite` (rewrite blocks in place, "as if they were atomically read and written back")
  is in the 2.4 man pages; 2.4.0 added `-P`, which keeps birth times so snapshots and
  incremental sends do not grow
  ([zfs-rewrite(8)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man8/zfs-rewrite.8),
  [2.4.0 release notes](https://github.com/openzfs/zfs/releases/tag/zfs-2.4.0)).
- OpenZFS 2.2 added overlayfs support on ZFS (Linux container interfaces), so Docker's default
  `overlay2` driver can run with `/var/lib/docker` on ZFS
  ([2.2.0 release notes](https://github.com/openzfs/zfs/releases/tag/zfs-2.2.0)).
- btrfs docs are written against Linux 7.3 at the time of research
  ([btrfs Status](https://btrfs.readthedocs.io/en/latest/Status.html)). SnapRAID is at 15.2
  ([download](https://www.snapraid.it/download)); mergerfs is at 2.42.0
  ([docs](https://trapexit.github.io/mergerfs/latest/)).

### Hardware facts

- **IronWolf 8 TB has two models.** ST8000VN004 runs at 7200 rpm, 210 MB/s max sustained
  (outer tracks), with a URE rate of 1 per 10^15 bits. ST8000VN002 runs at 5400 rpm, 202 MB/s,
  with 1 per 10^14. Both are CMR, rated for 180 TB/year of workload and 1-8 bay systems
  ([Seagate IronWolf data sheet](https://www.seagate.com/content/dam/seagate/en/content-fragments/products/datasheets/ironwolf-12tb/ironwolf-16tb-DS1904-23-2509US-en_US.pdf)).
  Check which model the drives are: it changes the resilver estimates and the URE numbers below.
- **Samsung 9100 PRO 1 TB** is a PCIe 5.0 x4 client drive ("Client PCs, PlayStation 5").
  It has TLC NAND, 1 GB DRAM, a 600 TBW / 5-year warranty, and runs at PCIe 4.0 x4 in older
  slots. The data sheet lists no power-loss protection
  ([Samsung 9100 PRO data sheet](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_NVMe_SSD_9100_PRO_Datasheet_Rev.1.0.pdf)).
- **Motherboard (Crosshair VIII Hero WiFi, X570).** M.2_1 is wired to the CPU (PCIe 4.0 x4
  with Ryzen 3000). M.2_2 is wired to the X570 chipset (PCIe 4.0 x4). There are 8 SATA 6 Gb/s
  ports. "ECC Memory (ECC mode) support varies by CPU"
  ([ASUS spec page](https://rog.asus.com/motherboards/rog-crosshair/rog-crosshair-viii-hero-wi-fi-model/spec/)).
  The Ryzen 9 3900X is listed with unbuffered ECC support (secondary sources:
  [Puget Systems](https://www.pugetsystems.com/parts/CPU/AMD-Ryzen-9-3900X-3-8GHz-Twelve-Core-105W-13189/),
  [Tom's Hardware review](https://www.tomshardware.com/reviews/ryzen-9-3900x-7-3700x-review,6214.html);
  AMD's own page is rendered by JavaScript and could not be fetched). So **ECC UDIMMs are a
  possible upgrade on this platform**, not something it rules out.
- **The network is 1 Gbps** (about 115 MB/s). Any of the HDD layouts below can stream faster
  than that sequentially. Throughput differences between layouts only show up in local work
  (scrub, resilver, Immich imports and thumbnailing, Plex library scans, qBittorrent, copies
  between datasets), not for LAN or Internet clients. (Computed from the data sheet speeds.)

### ZFS rules that matter here

- A RAIDZ group of N disks of size X with P parity holds about (N-P)*X and survives P failures.
  A mirror of N disks holds X and survives N-1 failures. RAIDZ has no RAID-5/6 write hole
  ([zpoolconcepts(7)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man7/zpoolconcepts.7)).
- ZFS keeps the last 3.2% (1/32) of the pool unallocatable ("slop")
  ([zfs(4) spa_slop_shift](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man4/zfs.4)).
  OpenZFS also recommends keeping **more than 10% free** to avoid the CPU-heavy best-fit
  allocator
  ([Workload Tuning: Free Space](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html)).
- **A top-level vdev can only be removed if the pool has no raidz or draid top-level vdev.**
  This applies to special and dedup vdevs too
  ([zpool-remove(8)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man8/zpool-remove.8)).
  On a RAIDZ pool, anything added with `zpool add` (a special vdev, a wrong vdev added by
  mistake) is there for good.
- ZFS stores extra copies of metadata (`redundant_metadata=all` by default), so "if a single
  on-disk block is corrupt, at worst a single block of user data ... can be lost"
  ([zfsprops(7)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man7/zfsprops.7)). A read
  error during a degraded resilver therefore damages files, not the whole pool, unlike a
  classic RAID5 rebuild.
- Scrub and resilver have run in two phases since 0.8: first scan the metadata, then issue I/O
  "as sequentially as possible"
  ([0.8.0 release notes](https://github.com/openzfs/zfs/releases/tag/zfs-0.8.0)). Since 2.0,
  mirrors also support a **sequential resilver** (`zpool replace|attach -s`), which restores
  redundancy first and then scrubs
  ([2.0.0 release notes](https://github.com/openzfs/zfs/releases/tag/zfs-2.0.0),
  [zpool-attach(8)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man8/zpool-attach.8)).
  RAIDZ does not have the sequential mode.

## 2. Options for the 4x 8 TB HDDs

Capacities are computed. 8 TB = 7.28 TiB. "Usable" subtracts the 3.2% slop and, for RAIDZ, the
padding overhead that `zfs list` assumes for 128K blocks (section 2.6). Recommended fill is 90%
of usable.

| Layout | Raw data space | Usable (approx.) | 90% fill target | Survives | 4.5 TB restore uses |
|---|---|---|---|---|---|
| RAIDZ1, 4-wide | 21.8 TiB | ~20.5-21 TiB | ~18.5 TiB | any 1 disk | ~21% |
| RAIDZ2, 4-wide | 14.6 TiB | ~13.7-14 TiB | ~12.5 TiB | any 2 disks | ~32% |
| 2x 2-way mirror | 14.6 TiB | ~14.1 TiB | ~12.7 TiB | 1 per pair (2 if lucky) | ~32% |
| SnapRAID 3 data + 1 parity (+ mergerfs) | 21.8 TiB | ~21.5 TiB | n/a (per disk) | 1 disk, up to the last sync | ~21% |
| SnapRAID 2 data + 2 parity | 14.6 TiB | ~14.4 TiB | n/a | 2 disks, up to the last sync | ~31% |
| btrfs raid1 / raid10 (4 disks) | 14.6 TiB | ~14.3 TiB | n/a | any 1 disk | ~32% |
| btrfs raid1c3 | 9.7 TiB | ~9.5 TiB | n/a | any 2 disks | ~47% |
| btrfs raid5 / raid6 | 21.8 / 14.6 TiB | - | - | - | **not for production** (see 2.5) |

Rough resilver/rebuild times (computed). Assumptions: 4.5 TB restored now, and the pool about
80% full later. A 7200 rpm disk averages roughly 120-180 MB/s across the platter (210 MB/s is
the outer-track peak per the data sheet). Small or fragmented blocks are slower. The 5400 rpm
model is about 5-10% slower again.

| Layout | Written to new disk at 4.5 TB stored | Time | Written at ~80% full | Time |
|---|---|---|---|---|
| RAIDZ1 4-wide | ~1.5 TB (1/4 of data + parity) | ~2.5-3.5 h | ~5.5-6 TB | ~9-14 h |
| RAIDZ2 4-wide | ~2.25 TB | ~3.5-5 h | ~5.5-6 TB | ~9-14 h |
| 2x mirror | ~2.25 TB (only that pair's data) | ~3.5-5 h; faster with `-s` | ~5.5-6 TB | ~9-12 h |
| SnapRAID | the failed disk's files | ~same as a disk copy | up to 8 TB | ~12-18 h |
| btrfs raid1 replace | the failed disk's chunks | similar to a mirror | up to 8 TB | ~12-18 h |

A full 8 TB surface write at 210 MB/s takes about 10.6 h, the absolute floor for a full disk
(computed). ZFS resilvers only allocated blocks, so early resilvers are much faster than a
hardware RAID rebuild.

### 2.1 RAIDZ1 (4-wide)

- **Capacity:** best ZFS option (~21 TiB). Data efficiency is 75% at best.
- **Fault tolerance:** one disk. During a resilver the three remaining disks are read in full
  (for their allocated data). A second disk failure in that window loses the pool. A URE only
  loses the affected blocks or files, thanks to checksums and redundant metadata (section 1).
  At 1 per 10^15 bits, reading about 4.5 TB from three disks is about 3.6x10^13 bits, which
  gives an expected **~0.04 UREs** at today's fill and ~0.4 near full (computed; the data sheet
  rate is a worst-case spec, not a measurement). With the 10^14 model it is ten times higher.
  The real RAIDZ1 risk is a **correlated second failure**: same batch, same age, same enclosure,
  under resilver stress. Silent bit errors are a smaller risk.
- **Growth:** RAIDZ expansion adds one disk at a time (`zpool attach pool raidz1-0 newdisk`),
  online, with redundancy kept throughout; it can run several times. **Old blocks keep their
  old data-to-parity ratio**, and free space is under-reported for new blocks
  ([zpool-attach(8)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man8/zpool-attach.8)).
  `zfs rewrite` writes blocks again. Inferred from the man pages: rewritten blocks are new
  allocations, so they get the current width. Snapshots keep the old copies, so rewriting
  snapshotted data uses extra space. The other way to grow is to add a second vdev (another
  RAIDZ1). That is permanent, because removal is impossible on RAIDZ pools. The 8 SATA ports
  and the Define 7's bays allow growth either way.
- **Performance:** about one disk's worth of random IOPS per RAIDZ vdev; a random read touches
  all data disks of the stripe (inferred from the dRAID/raidz description in
  [zpoolconcepts(7)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man7/zpoolconcepts.7)
  and the [stripe width guidance](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html):
  "If you need more IOPS, use fewer disks per stripe"). Sequential throughput is about 3x one
  disk. Fine for media and photo archives, poor for databases and small random I/O (2.6).
  Those belong on NVMe anyway.

### 2.2 RAIDZ2 (4-wide)

- **Capacity:** ~14 TiB, the same as two mirrors but with RAIDZ padding (128K records reach
  ~48.5% efficiency instead of 50%; section 2.6).
- **Fault tolerance:** **any two disks**, the strongest of the ZFS options with four disks.
  Two failures inside one mirror pair would kill a mirror pool, but not RAIDZ2.
- **Growth:** the same RAIDZ expansion. Each added disk brings a full 8 TB of data space
  (4-wide 2:2 becomes 5-wide 3:2). The ratio gets better with each disk, but old blocks stay
  at 50% until rewritten.
- **Performance:** like RAIDZ1 for IOPS (one vdev), sequential about 2x one disk, more parity
  math (trivial for a 3900X). The worst choice for small blocks: 4K and 8K blocks reach 33%
  efficiency (2.6).
- Comparison: at four disks, RAIDZ2 trades the same capacity as mirrors for better fault
  tolerance and worse IOPS, slower resilvers (every disk is read) and less flexibility (no
  vdev removal).

### 2.3 Two 2-way mirrors (striped)

- **Capacity:** ~14.1 TiB, no padding overhead.
- **Fault tolerance:** one disk per pair. A second failure in the *same* pair during resilver
  loses the pool. The window is shorter, because only the surviving partner is read, and
  sequentially with `-s`.
- **Growth:** add another pair (`zpool add pool mirror a b`) or replace both disks of a pair
  with bigger ones. Because the pool has no raidz vdev, **vdevs can be removed** later
  (evacuated to the remaining vdevs), including a special vdev. A mirror can become 3-way with
  `zpool attach`, and a disk can be split off with `zpool split`/`detach`
  ([zpool-remove(8)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man8/zpool-remove.8),
  [zpool-attach(8)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man8/zpool-attach.8)).
  Mirrors are the most reversible ZFS layout.
- **Performance:** two vdevs means about 2x one disk for random writes and up to 4x for
  random reads; sequential reads are up to about 4x one disk. The best HDD option for
  databases or VM images. With the NVMe pool handling those, the gain mostly shows in scrubs,
  thumbnailing and concurrent Plex/Immich/qBittorrent access.
- Restore detail: if the 4.5 TB has to sit on one or two IronWolfs during the migration (see
  open question Q1), mirrors can be built one pair at a time. Create a single mirror from two
  empty disks, copy the data in, then add the second pair. Old data stays on the first vdev
  until rewritten (`zfs rewrite`), but nothing is ever unprotected for long.

### 2.4 mergerfs + SnapRAID

- **What it is:** each disk keeps its own filesystem (ext4/XFS, or btrfs/ZFS single-disk for
  checksums and snapshots). mergerfs is a FUSE union that shows them as one tree. Its stated
  non-features: "RAID like redundancy", "RAID like performance improvements", "Data integrity
  checks, snapshots, file versioning", "Splitting of files across branches", "Active
  rebalancing" ([mergerfs docs](https://trapexit.github.io/mergerfs/latest/)). SnapRAID
  computes parity **on demand** (`sync`); it is "a hybrid between a RAID and a backup program"
  ([SnapRAID manual](https://www.snapraid.it/manual)).
- **Capacity:** with 3 data + 1 parity, ~21.5 TiB (the best of all options). The parity disk
  must be at least as large as the largest data disk
  ([manual](https://www.snapraid.it/manual)). SnapRAID's own rule of thumb is one parity disk
  for 2-4 data disks ([FAQ](https://www.snapraid.it/faq)).
- **Fault tolerance:** as many disks as parity levels (up to six), **but only up to the last
  sync**: "Files added to the failed disk after the last 'sync' command are lost"
  ([FAQ](https://www.snapraid.it/faq)). If more disks fail than there are parities, only the
  failed disks' files are lost, because every disk is a normal filesystem. Upside: deleted
  files can be restored from the last sync, a little like a snapshot.
- **Fit:** "primarily intended for home media centers and large storage arrays containing files
  that don't change frequently (like movies, music, and photo archives)", and "primarily suited
  for data that rarely changes"; it should not hold `/home`, `/var` and similar
  ([home page](https://www.snapraid.it/), [manual](https://www.snapraid.it/manual)). A good fit
  for the re-downloadable media library. A poor fit for the critical, frequently written data
  in Immich uploads, Nextcloud files and GitLab repos: anything written since the last sync is
  unprotected. Docker app data and databases do not belong on a FUSE union over HDDs.
- **Growth:** the most flexible: add disks of any size at any time, start with disks that
  already hold data, stop using it at any time (FAQ).
- **Performance:** a single file is read from a single disk, so throughput per file equals one
  disk (still above 1 Gbps). Disks not in use can spin down. FUSE adds overhead. `sync` and
  `scrub` are scheduled jobs that must be set up, run and watched (a timer plus notification
  wiring, which runs against the "dedicated tool over home-made script" principle unless the
  SnapRAID daemon or UI is used; see [snapraid.it/ui](https://www.snapraid.it/ui)).
- **Upkeep:** more moving parts than one ZFS pool: per-disk filesystems, a mergerfs mount, the
  SnapRAID config, content files, sync/scrub scheduling.

### 2.5 btrfs

- **raid5/raid6: excluded.** Upstream says: "There are some implementation and design
  deficiencies that make it unreliable for some corner cases and the feature **should not be
  used in production, only for evaluation or testing**. The power failure safety for metadata
  with RAID56 is not 100%." The write hole is unsolved: "Write journal is not implemented"
  ([btrfs(5) RAID56 status](https://btrfs.readthedocs.io/en/latest/btrfs-man5.html)). The
  status table marks RAID56 "unstable"
  ([Status](https://btrfs.readthedocs.io/en/latest/Status.html)).
- **raid1 / raid10 / raid1c3: OK.** All are marked "OK" for stability. Read balancing across
  mirrors "can be optimized further" ([Status](https://btrfs.readthedocs.io/en/latest/Status.html)).
  raid1 on 4x 8 TB gives ~14.3 TiB and survives one disk. raid1c3 keeps three copies (~9.5 TiB)
  and survives two.
- **Strengths:** in-kernel (no DKMS or module-version coupling to the kernel), checksums,
  snapshots, send/receive. Mixed disk sizes and online add/remove/convert through `balance`
  ("OK"). Growing raid1 is the simplest of all options: add a disk of any size and rebalance.
- **Weaknesses here:** "Device replace" is only "mostly OK"
  ([Status](https://btrfs.readthedocs.io/en/latest/Status.html)). There is no equivalent of
  special vdevs or L2ARC for a mixed HDD/NVMe setup. Databases on btrfs usually need
  `nodatacow` for overwrite performance, and "Nodatacow implies nodatasum, and disables
  compression" ([btrfs mount options](https://btrfs.readthedocs.io/en/latest/ch-mount-options.html)):
  no checksums for exactly the data that matters most. At the same capacity as two ZFS mirrors, btrfs raid1 tolerates
  exactly one failure, never two.

### 2.6 RAIDZ padding and block size (why databases do not belong on 4-wide RAIDZ)

RAIDZ writes P parity sectors per row of (N-P) data sectors, and rounds each allocation up to a
multiple of (P+1) sectors (the mechanism is explained in the
[Delphix RAIDZ stripe width post](https://www.delphix.com/blog/delphix-engineering/zfs-raidz-stripe-width-or-how-i-learned-stop-worrying-and-love-raidz/)
linked from the OpenZFS docs). With ashift=12 (4 KiB sectors), computed:

| Block size | RAIDZ1 4-wide | RAIDZ2 4-wide | Mirror |
|---|---|---|---|
| 4K | 50% | 33% | 50% |
| 8K | 50% | 33% | 50% |
| 16K | 67% | 44% | 50% |
| 128K (default) | 73% | 48.5% | 50% |
| 1M | 75% | 50% | 50% |

Implications:

- Media and photo datasets should use `recordsize=1M`. The property allows up to 16 MiB with
  `large_blocks` ([zfsprops(7)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man7/zfsprops.7)).
- PostgreSQL guidance is a separate data/WAL dataset with `compression=lz4` and
  `recordsize=32K` (64K and 128K also fine), plus `full_page_writes=off` only on ZFS
  ([Workload Tuning: PostgreSQL](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html)).
  On 4-wide RAIDZ, small blocks lose the capacity advantage and suffer the IOPS limit, which is
  another reason to keep databases on the NVMe mirror.
- BitTorrent does 16 KB random I/O. Use a `recordsize=16K` download dataset and move finished
  files to the media dataset, which also removes fragmentation
  ([Workload Tuning: Bit Torrent](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html)).

## 3. Role of the two NVMe drives

The two 9100 PRO drives can be split with partitions. The options are not exclusive.

| Role | What it does | Fit here |
|---|---|---|
| **Separate fast mirror pool** (apps, Docker, databases) | Postgres, GitLab, Vaultwarden, n8n, Immich DB and thumbnails, Plex metadata, Nextcloud app data, LLM model files, `/var/lib/docker`. ~0.9 TiB mirrored. | **Strong.** Immich itself says its Postgres "should ideally use local SSD storage" ([Immich requirements](https://docs.immich.app/install/requirements/)). Simple, independent of the HDD pool, and the NVMe pool can be replaced or rebuilt on its own. |
| **Special vdev** (metadata + optional small blocks for the HDD pool) | Holds "all metadata, the indirect blocks of user data", the ZIL if there is no SLOG, and the DDT; with `special_small_blocks` also small file blocks. Spills back to HDD when full ([zpoolconcepts(7)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man7/zpoolconcepts.7), [zfsprops(7)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man7/zfsprops.7)). | **Possible, with sharp edges.** It must be redundant ("should match the redundancy of the other normal devices"); **losing it loses the whole pool**; on a RAIDZ pool it **can never be removed**. It only affects data written after it is added, so add it before the 4.5 TB restore (or run `zfs rewrite` later). Gains: faster directory walks, Immich/Plex scans, scrubs and small files. For a 1M-record media library the gain is modest. |
| **L2ARC** (read cache) | Second-level read cache; persistent across reboots since 2.0; cannot be mirrored, and losing it is harmless ([zpoolconcepts(7)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man7/zpoolconcepts.7), [2.0.0 notes](https://github.com/openzfs/zfs/releases/tag/zfs-2.0.0)). | **Weak.** Its sweet spot is "random read-workloads of mostly static content" larger than RAM. Media streaming is sequential and already faster than the LAN. Its headers consume ARC (up to `l2arc_meta_percent`=33% of ARC) ([zfs(4)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man4/zfs.4)), and RAM is the scarce resource here. |
| **SLOG** (separate intent log) | Only speeds up **synchronous** writes (fsync, O_SYNC, NFS); it does nothing for async writes ([zpoolconcepts(7)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man7/zpoolconcepts.7), [Workload Tuning: Synchronous I/O](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html)). | **Not needed** if the databases live on the NVMe pool: the HDD pool then gets few sync writes. OpenZFS prefers Optane or PLP drives for SLOG, and the 9100 PRO has no PLP. Since 2.4 the ZIL can also live on a special vdev ([2.4.0 notes](https://github.com/openzfs/zfs/releases/tag/zfs-2.4.0)). |

Notes:

- On power-loss protection, OpenZFS writes that manufacturers now claim firmware protection
  covers flushed data and drive metadata, "which is all that filesystems such as ZFS need".
  Those who want strong guarantees should still use hardware PLP
  ([Hardware: Power Failure Protection](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Hardware.html)).
  With the CyberPower UPS and a configured shutdown, client NVMe drives are acceptable for a
  data pool. This matters more for a SLOG, which exists only to hold sync writes.
- Endurance: 600 TBW per 1 TB drive. Postgres, GitLab, Docker layers and Immich thumbnails
  write steadily but not heavily. Watch `Percentage Used` through smartctl-exporter, which is
  already in the stack.
- M.2_2 sits behind the chipset and shares its x4 uplink with the SATA ports and USB
  ([ASUS spec](https://rog.asus.com/motherboards/rog-crosshair/rog-crosshair-viii-hero-wi-fi-model/spec/);
  the shared uplink is an inference from the X570 topology). That is irrelevant at homelab
  load.
- Hybrid layout: partition both NVMe drives into a small mirrored special vdev plus a large
  mirrored fast pool. This works, but it couples the two pools' fates and is harder to replace
  cleanly. OpenZFS generally prefers whole disks.

## 4. Role of the 500 GB SATA SSD

- **Boot/OS disk (ext4, or ZFS root)** is the natural role. The host is meant to be
  reproducible with Ansible, so a single non-redundant boot disk costs a reinstall plus
  playbook run, and no data, provided no app data lives on it. Keep Docker's data root and all
  volumes on the NVMe pool so the boot disk holds nothing that needs a backup.
- Booting from the NVMe mirror instead (ZFS root) gives boot redundancy but complicates the
  boot chain (ZFSBootMenu or GRUB with ZFS, EFI partitions on both drives) and takes space from
  the app pool. That is a host-layer decision; see the host-layer research.
- Other uses: scratch space for transcoding or `incomplete` torrents (spares NVMe wear), or a
  local landing zone for backup staging.

## 5. ARC sizing with 32 GB shared with services

- **The default changed in OpenZFS 2.3.** On Linux, `zfs_arc_max=0` now means "the larger of
  all_system_memory - 1 GiB and 5/8 x all_system_memory". On 32 GiB that is **~31 GiB**. In
  2.2 the Linux default was half of RAM
  ([zfs(4) 2.4.4](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man4/zfs.4),
  [zfs(4) 2.2.11](https://github.com/openzfs/zfs/blob/zfs-2.2.11/man/man4/zfs.4)). The
  Workload Tuning page still says "half of system memory on Linux", which is out of date. The
  default `zfs_arc_min` is RAM/32 (1 GiB), and `zfs_arc_sys_free` is RAM/64 (~0.5 GiB).
- `zfs_arc_max` "can be changed dynamically", but lowering it "will not cause the ARC to shrink
  without memory pressure" (zfs(4)). Set it as a module option at boot
  (`/etc/modprobe.d/zfs.conf`, managed by Ansible).
- Memory demand from the planned services, per their own docs: **GitLab: "16 GB is the
  baseline" for a single node, at least 8 GB in a memory-constrained setup**
  ([GitLab requirements](https://docs.gitlab.com/install/requirements/)). **Immich: minimum
  6 GB, recommended 8 GB** ([Immich requirements](https://docs.immich.app/install/requirements/)).
  Nextcloud AIO, shared Postgres, Plex, the *arr stack, qBittorrent, SearXNG (with its Valkey cache),
  Prometheus/Grafana and a local LLM runtime (host RAM while loading models, even when
  inference runs in VRAM) come on top. **Services alone can approach or exceed 32 GB**, so the
  ARC cap is a real trade-off, not a free win. GitLab also says to avoid swap where possible.
- What the ARC buys: metadata and hot small files of the HDD pool, and the NVMe pool's
  databases (Postgres also caches in its own `shared_buffers`, so part of that is
  double-caching). Media streams gain little from ARC.
- Ranges to weigh (judgement, not from a source): **4-8 GiB** cap if GitLab runs at its 16 GB
  baseline on this host; **8-12 GiB** if GitLab is trimmed (memory-constrained settings) or
  moved, for example to the old i5 server; never the 31 GiB default. Watch the hit rate with
  `zarcstat`/`zarcsummary` (renamed in 2.4,
  [2.4.0 notes](https://github.com/openzfs/zfs/releases/tag/zfs-2.4.0)) and with
  node-exporter's `zfs` collector, which is enabled by default
  ([node_exporter README](https://github.com/prometheus/node_exporter)).
- Related: `zfs_dirty_data_max` defaults to RAM/10 (zfs(4)), about 3.2 GiB of in-flight writes.
  This is fine as is; it is listed because it also takes RAM during large restores.

## 6. Real risks of ZFS without ECC

- OpenZFS: "No technique used in ZFS (or any other filesystem) is capable of protecting against
  bit flips. Consequently, ECC Memory is highly recommended." A flip before checksumming writes
  bad data that ZFS will not notice. A flip after checksumming is detected but may not be
  correctable. Worst case, corrupted metadata "could [render] a pool unimportable", but "such
  scenarios should be considered extraordinarily rare"
  ([Hardware: ECC Memory](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Hardware.html)).
- ZFS co-founder Matt Ahrens: "There's nothing special about ZFS that requires/encourages the
  use of ECC RAM more so than any other filesystem" (Ars Technica forum, 2014, as quoted by
  [JRS Systems](https://jrs-s.net/2015/02/03/will-zfs-and-non-ecc-ram-kill-your-data/); the
  original post was not fetched). The "scrub of death" story (a scrub with bad RAM destroying
  a pool) is the myth that post answers.
- Summary: non-ECC is **not a ZFS-specific danger**. Any filesystem on this box can write bad
  data from a flipped bit. ZFS at least detects corruption that happens on disk or in transit,
  which ext4/XFS under mergerfs do not (SnapRAID hashes catch it at the next `check`/`scrub`).
  The remaining risk is silent corruption of new writes and, rarely, of metadata. It applies to
  every option in this document.
- Mitigations: a long memtest86+ burn-in before trusting the box; no overclocked or XMP-unstable
  RAM settings (DDR4-3200 is the CPU's rated speed); scheduled scrubs with alerts; and above
  all the **off-site, versioned backup** (rclone crypt to OneDrive), which is what actually
  protects against both RAM and pool loss. The platform could take ECC UDIMMs later (section 1).

## 7. The 4.5 TB restore

- Build the final topology **before** restoring. On RAIDZ, data written before an expansion
  keeps the old ratio. Restoring 4.5 TB onto a 3-wide RAIDZ1 (2:1) and then expanding to
  4-wide uses ~6.75 TB raw instead of ~6.0 TB until rewritten (computed). On mirrors, data
  written before a second vdev is added stays on the first vdev.
- Set dataset properties before restoring (`recordsize=1M` for media/photos, `compression=lz4`
  or zstd, `atime=off`, plus a special vdev if one is chosen), because they apply at write time.
  `zfs rewrite` can apply compression or checksum changes later, but **not `recordsize`**
  ([zfs-rewrite(8)](https://github.com/openzfs/zfs/blob/zfs-2.4.4/man/man8/zfs-rewrite.8)).
- After restoring, run a scrub to read everything back once before deleting the source.
- 4.5 TB over a 1 Gbps link is at least ~11 h of pure transfer (computed). From OneDrive,
  expect much longer: provider throttling and the household upload/download line set the pace.

## 8. Implications for the decision

Options that stand out:

1. **Two ZFS mirrors on the HDDs + NVMe mirror pool for apps/DBs + SATA SSD for boot.** Best
   random performance, fastest and least stressful resilvers, and the only ZFS layout that stays
   reversible (vdevs and a special vdev can be removed; growth is one pair at a time). Costs
   ~7 TiB versus RAIDZ1 and tolerates two failures only if they hit different pairs. 14 TiB is
   about 3x the current 4.5 TB.
2. **RAIDZ2 + NVMe mirror pool + SATA boot.** The same ~14 TiB as mirrors but survives **any**
   two disks, which helps if all four drives come from one batch. Gives up IOPS (irrelevant
   once DBs are on NVMe), vdev removal and fast resilvers. RAIDZ expansion (2.3+, so Ubuntu
   26.04) makes each added disk worth a full 8 TB of space.
3. **RAIDZ1 + NVMe mirror pool + SATA boot.** The most space (~21 TiB) for the same disks. It
   relies on the off-site backup for the "second disk dies during resilver" case. Reasonable
   when the bulk of the pool is re-downloadable media, weaker for the irreplaceable photo
   library.
4. **mergerfs + SnapRAID** only makes sense for the media library, as a split design: SnapRAID
   media disks plus a separate redundant home for critical data. With only four disks, that
   split costs either redundancy or capacity, and it adds scheduling to maintain. It is the
   most flexible for mixed disk sizes later.
5. **btrfs raid1** is a valid, simpler, in-kernel alternative to ZFS mirrors, with no
   special-vdev or L2ARC equivalent and one-failure tolerance only. **btrfs raid5/6 is out**
   (upstream: not for production).

On the NVMe drives: a **separate mirrored fast pool** is the low-risk, high-value role.
Special vdev, L2ARC and SLOG each have a narrow benefit for this workload. The special vdev is
the only one worth debating, and only before the restore. On a RAIDZ pool it is a one-way door.

Questions for the owner:

- **Q1. Where does the 4.5 TB live during the migration?** If it sits on one or more of the
  four IronWolfs, the full pool cannot be created first. That pushes towards mirrors (built
  pair by pair) or towards 3-wide RAIDZ plus expansion plus `zfs rewrite`, or it means staging
  the data elsewhere first (the old server, the OneDrive backup).
- **Q2. Which IronWolf model** (ST8000VN004 7200 rpm, 10^15; or ST8000VN002 5400 rpm, 10^14),
  and are the four from one purchase or batch? Same batch argues for RAIDZ2 or for spreading
  purchases.
- **Q3. How much space is needed in 3-5 years?** If 14 TiB is enough, mirrors or RAIDZ2; if
  not, RAIDZ1, or plan to add disks (expansion or new pairs).
- **Q4. Which data is irreplaceable and how fresh is its off-site copy?** Immich photos and
  Nextcloud files tolerate RAIDZ1 only as long as the weekly off-site backup is trusted and
  tested.
- **Q5. Special vdev: yes or no, decided before the restore**, knowing it is permanent on RAIDZ
  and that its loss means loss of the pool.
- **Q6. Does GitLab stay on this host at its 16 GB baseline?** That decides whether the ARC gets
  4-8 GiB or 8-12 GiB, and whether 32 GB is enough at all.
- **Q7. ECC later?** The board and CPU allow ECC UDIMMs. Is it worth replacing the 32 GB kit,
  or is memtest + scrubs + off-site backup enough?
- **Q8. Ubuntu 26.04 (OpenZFS 2.4.1) or 24.04 (2.2.2)?** RAIDZ expansion, `zfs rewrite` and the
  new ARC default all depend on it.
