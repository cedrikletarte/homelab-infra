# Host layer options for the new server

Research date: 2026-11-26. Status: findings only, no decision.

Question: which host layer fits this hardware and these principles (reliability and
low upkeep first, Docker Compose stays the unit of deployment, declarative and
reproducible host)? Candidates: Proxmox VE (Docker in a VM or in an LXC), bare
Debian/Ubuntu + Docker, TrueNAS (formerly SCALE, now "Community Edition"), Unraid,
NixOS. For each: ZFS support, NVIDIA RTX 2080 Ti access (containers or VM
passthrough), known IOMMU groups on the ASUS ROG Crosshair VIII Hero (X570), RAM
overhead on 32 GB, upkeep and update cost, declarative reproducibility of the host,
snapshots and rollback.

Every claim carries a numbered source (see "Sources" at the end). Statements marked
"estimate" or "inference" are reasoning on top of the sources, not quotes.

## TL;DR

- All five can run ZFS on the 4x 8 TB IronWolf. Proxmox, TrueNAS and Ubuntu ship
  ZFS as a first-class, prebuilt component; Debian builds it with DKMS from contrib;
  NixOS builds it in the system closure but pins you to a ZFS-compatible kernel;
  Unraid supports ZFS pools next to its own parity array.
- The 2080 Ti (Turing) is supported by every current NVIDIA branch, including the
  open kernel modules that TrueNAS 25.10+ requires (Turing and later only) [T3][T4].
- The decisive hardware fact: the 3900X has no iGPU, so the 2080 Ti is the only
  GPU. Passing it to a VM removes it from the host and every other guest [P5], and
  TrueNAS refuses to isolate the only GPU at all [T7]. GPU sharing between Plex,
  Immich ML and a local LLM is simplest when Docker runs directly on the host that
  owns the driver (bare metal, NixOS, TrueNAS apps, Unraid) or inside one VM that
  gets the whole card (Proxmox VM variant).
- IOMMU grouping on this board is good for the CPU-attached devices: two
  independent reports show the GPU, each NVMe drive, each NIC, and (on BIOS 1302)
  each SATA controller in their own group; the weak spot is the chipset USB
  controllers [I1][I2]. Groups change with AGESA/BIOS versions [I1][I3].
- With 32 GB and a stack that includes GitLab, Immich, Nextcloud and Postgres, the
  ZFS ARC must be capped on every option except Proxmox (which already defaults to
  10 % of RAM on new installs [P3]); upstream OpenZFS would let the ARC grow to
  about 31 GiB [Z1].
- Options that stand out (detailed at the end): bare Ubuntu LTS + Docker + Ansible
  (smallest change from today), NixOS + Docker (best declarative host and
  rollback, highest learning cost), Proxmox with a single Docker VM holding the GPU
  (best snapshot/backup tooling for the Docker layer, highest RAM cost).
  TrueNAS and Unraid fit the "appliance" goal but fight the existing
  git + Renovate + `docker compose up -d` pipeline.

## Hardware facts that matter for this decision

- CPU: Ryzen 9 3900X, no integrated graphics (inference from the product line; the
  board relies on a discrete GPU for display). The 2080 Ti will be the boot GPU.
- Board slots [I4]: two PCIe 4.0 x16 slots wired to the CPU (x16 or x8/x8), one
  PCIe 4.0 x16 (electrical x4) and one x1 slot on the X570 chipset. M.2_1 is
  CPU-attached, M.2_2 is chipset-attached. All 8 SATA ports hang off the X570
  chipset. NICs: Intel I211-AT and Realtek RTL8125 2.5G, plus Intel AX200 Wi-Fi.
- The RTX 20-series exposes four PCI functions (VGA, HD audio, USB-C xHCI, UCSI);
  on this board they appear together in one group (0c:00.0 to 0c:00.3 in [I2]).
  For VM passthrough all four go to the guest together.

## IOMMU groups on the Crosshair VIII Hero (shared by all options)

No ASUS document lists the groups; the evidence is two user reports with full
`lspci` group listings:

| Device | BIOS 0702 (2019) [I1] | BIOS 1302 (2020) [I2] |
|---|---|---|
| GPU in CPU slot | Own group (with its audio function) | Own group (all 4 functions) |
| NVMe (M.2_1 CPU / M.2_2 chipset) | Each alone | Each alone |
| Intel I211, Realtek 2.5G, Wi-Fi | Each alone | Each alone |
| SATA controllers | Grouped with USB/audio in one group, others paired with a bridge | Each in its own group |
| USB controllers | None alone ("none of the USB controllers are on their own IOMMU groups") | Two share a group with the "Reserved SPP" function; one is alone |

Takeaways:

- Passing the 2080 Ti to a VM works without the ACS override patch on both BIOS
  versions [I1][I2]. Passing an NVMe drive or a NIC is also clean.
- Passing a SATA controller (to hand the IronWolf disks to a NAS VM) looked
  possible on BIOS 1302 but not on 0702; the current BIOS must be checked on the
  real machine. All SATA ports are on the chipset, so the 870 EVO and the four
  IronWolf may sit on different controllers or the same one.
- USB controller passthrough is the known pain point on X570 [I1][I2]; it is
  irrelevant for a headless Docker host.
- BIOS/AGESA updates change grouping ("AGESA updates change this majorly") [I3].
  Proxmox's documentation treats the ACS override as a last resort with security
  risk [P5].
- Single-GPU caveat: when the only GPU is the boot GPU, its vBIOS may be shadowed
  at boot and a `romfile=` dump can be required for passthrough [P5]. The host
  also loses its local console once the GPU is bound to vfio-pci [P5].
- Action regardless of the option chosen: boot a live USB on the final BIOS,
  enable SVM + IOMMU (set "Enabled", not "Auto", per an X570 report [I1]) and dump
  `/sys/kernel/iommu_groups` before committing to a VM-passthrough design.

## Option 1: Proxmox VE (Docker in a VM or in an LXC)

Current release: Proxmox VE 9.3, released 2026-11-25, Debian 13.8 base, kernel 7.0
default, ZFS 2.4 [P1]. 9.x has no announced EOL yet; 8.x reaches EOL 2026-08 [P2].

- ZFS: first-class. The installer offers ZFS root (rpool/ROOT/pve-1, managed by
  proxmox-boot-tool) and ZFS storage for guests [P3]. New installs cap ARC at 10 %
  of RAM, max 16 GiB [P3]. Proxmox recommends ECC RAM for ZFS [P3]; this machine
  has non-ECC (same caveat applies to every ZFS option).
- GPU, VM variant: PCI passthrough of the 2080 Ti to one Docker VM; NVIDIA driver
  + NVIDIA Container Toolkit inside the guest [P5][N1]. The GPU is then
  unavailable to the host and to other guests [P5], so every GPU consumer (Plex,
  Immich ML, LLM) must live in that VM. Error 43 workarounds are no longer needed
  with NVIDIA drivers 465+ [P5].
- GPU, LXC variant: the host runs the NVIDIA driver and device nodes are passed into
  containers (devN options), so several containers can share the card. Caveats:
  Proxmox states "It is not recommended to run docker directly on your Proxmox VE
  host" and recommends a QEMU VM for application containers that need orchestration
  or live migration [P2][P4]; Docker inside unprivileged LXC broke in late 2025
  after the runc fix for CVE-2025-52881 (sysctl `ip_unprivileged_port_start`
  permission denied), with workarounds that disable AppArmor or pin containerd until
  a fixed lxc-pve shipped with 9.1 [P7]. The host NVIDIA driver must build against
  the Proxmox kernel (7.0), which moves faster than Debian's; Debian's own packaged
  550 driver no longer builds on kernels 6.16+ [D2], so NVIDIA's repository would
  be needed (inference). OCI-image "application containers" in LXC are still a
  tech preview; the roadmap mentions future declarative multi-guest support based
  on the Compose Specification [P1][P4].
- RAM overhead on 32 GB (estimate): host services about 2 GB [P6] + ARC 3.2 GB
  default [P3] + guest kernel and page cache. With a passed-through device the VM's
  RAM is effectively committed (VFIO pins guest memory for DMA, so ballooning cannot
  give it back; inference from how VFIO works). Realistically the Docker VM gets
  about 24 to 26 GB. Proxmox's rule of thumb is to leave at least 1 GB to the host
  [P8]. Double caching (host ARC + guest page cache) applies.
- Bulk storage into the VM: virtiofs is built in (no network stack), but VM
  snapshots with RAM state, live migration and hibernate are unavailable with
  virtiofs devices, and a crashed virtiofsd hangs the mount until the VM stops
  [P8]. Alternatives: NFS/SMB from the host, or a large zvol.
- Upkeep: two layers to patch (Proxmox host + guest OS), plus the guest NVIDIA
  driver. Major upgrades follow Debian (roughly every two years, three years of
  support per major) [P2].
- Declarative: the host is not declarative. An automated installer with a TOML
  answer file exists since 8.2 (disk layout incl. ZFS, network, first-boot hook)
  [P9]; post-install config would stay in Ansible. Guest definitions can be managed
  by third-party Terraform/OpenTofu providers (not evaluated here).
- Snapshots/rollback: strongest of the five for the Docker layer: VM disk
  snapshots before risky changes, vzdump backups (and Proxmox Backup Server if
  wanted). Bind mounts and device mounts are excluded from LXC vzdump backups and
  snapshots [P4]. Host root rollback is a manual ZFS snapshot of rpool/ROOT; there
  is no boot-environment tooling [P3] (absence noted, not a quote).

## Option 2: Bare Debian 13 or Ubuntu 26.04 LTS + Docker

Current: Debian 13.8 (2026-11-21), security support to 2028-08-09, LTS to
2030-06-30 [D1]. Ubuntu 26.04 LTS, kernel 7.0, standard support to May 2031 [U1][U2].

- ZFS:
  - Ubuntu: the ZFS kernel module ships with the Ubuntu kernel, tools via
    `zfsutils-linux` [U3]. No DKMS. Root-on-ZFS is not a supported installer path
    in recent releases (forum report, unverified [U3]); a data pool on the IronWolf
    with an ext4 root on NVMe avoids the question.
  - Debian: ZFS is in contrib, built with `zfs-dkms`; OpenZFS recommends the
    trixie-backports version and documents root-on-ZFS for trixie [D3].
  - Upstream default ARC max is max(RAM - 1 GiB, 5/8 RAM), so about 31 GiB here
    [Z1]; it must be capped (for example via `zfs_arc_max`) for this workload.
  - Docker can use overlay2 directly on ZFS datasets since OpenZFS 2.2 (overlayfs
    support) [Z2].
- GPU: driver on the host + NVIDIA Container Toolkit (`nvidia-ctk runtime configure
  --runtime=docker`) [N1]. The card is shared by any number of containers; no
  IOMMU concerns at all.
  - Ubuntu: `ubuntu-drivers install nvidia:595` is the supported path; only drivers
    installed that way are officially supported [U2]. Prebuilt, signed modules
    (inference: no DKMS rebuilds on kernel updates).
  - Debian: the packaged 550 driver is unmaintained, has known security issues and
    does not build on kernels 6.16+; current Turing-capable drivers come from
    NVIDIA's own Debian repository (590+, open flavor recommended) built with DKMS;
    Secure Boot needs a MOK enrolment [D2].
- RAM overhead: lowest of the five (no hypervisor, no guest kernel). Only the ARC
  cap needs a deliberate choice.
- Upkeep: one OS, unattended security updates, the existing Ansible roles and
  update scripts apply almost unchanged (this repo already targets Ubuntu + Docker +
  Ansible). Debian adds two DKMS modules (ZFS + NVIDIA) that can break on kernel
  updates [D2]; Ubuntu avoids both.
- Declarative: imperative OS, made reproducible by Ansible (today's approach).
  Drift outside Ansible is possible.
- Snapshots/rollback: ZFS snapshots of data datasets (sanoid or similar). No
  built-in rollback of the OS itself unless root is on ZFS with a boot-environment
  tool (not covered by the distro on Ubuntu; manual on Debian).

## Option 3: TrueNAS Community Edition (formerly SCALE)

Current stable: 25.10 "Goldeye" [T1]. The next release was tested as "26" and
renamed 27 from RC.1 (2026-10-06); 27.0 is planned for early December 2026 [T2].
27-RC.1 components: kernel 6.18.52, OpenZFS 2.4.4, Docker Engine 29.0.4, NVIDIA
580.173.02 (LTS branch, supported until August 2028) [T2][T6]. Annual release
cadence from now on [T6].

- ZFS: the core of the product; boot pool and data pools, scrubs, snapshots,
  replication through the UI.
- GPU: NVIDIA open kernel modules since 25.10, "These drivers work with Turing and
  later GPUs" [T3][T4], so the 2080 Ti is supported (Pascal and older are not). A
  GPU can be shared by multiple apps; GPU passthrough to LXC containers arrived in
  26-BETA.1 [T6]. VM passthrough requires at least two GPUs ("one available to the
  host ... and the other available to isolate") [T7], so with a single 2080 Ti a VM
  cannot get the GPU.
- Apps: since 24.10 apps are Docker Compose based; custom apps can be installed
  "via YAML" with a Compose editor [T5]; `include:` in custom Compose arrived in
  26-BETA.1 [T6]. Deployment is driven by the TrueNAS middleware (UI or its
  JSON-RPC API; the REST API is removed in 26+) [T6]. Running your own Docker or
  packages on the host is unsupported: rootfs and apt are locked, "developer mode"
  changes do not survive updates [T8], and manually installed Docker can conflict
  with TrueNAS Apps [T6]. Consequence (inference): the current git clone +
  `docker compose up -d` deployment would have to become API calls or a Compose UI
  (Dockge/Portainer) running as an app.
- RAM: minimum 8 GB, "RAM rarely goes unused on a TrueNAS system" [T9]; since
  24.04 the ARC may grow to almost all RAM, as on CORE [T10]. ARC shrinks under
  pressure, but early 24.04 releases had OOM reports [T10].
- Upkeep: appliance model; one update per year for features plus point releases.
  Feature changes can be disruptive (25.10 dropped pre-Turing NVIDIA GPUs, 26
  dropped legacy VMs with no migration tool and the REST API) [T3][T6].
- Declarative: configuration lives in the TrueNAS database (UI/API, config backup
  file). Not reproducible from git without writing API automation.
- Snapshots/rollback: boot environments are created automatically before each
  update and can be activated to roll back [T11]; they do not roll back pools or
  apps [T11]. Dataset snapshots and replication are built in.

## Option 4: Unraid

Current stable: 7.4.0 (2026-11-10), kernel 6.18.60, ZFS 2.4.4 [R1]. Unraid 8 was
announced on 2026-08-17: Fedora/uCore base, immutable design, Docker Compose
integrated into Community Apps templates, built-in backups; no GA date ("it'll ship
when it's ready") [R2].

- ZFS: ZFS pools (RAIDZ, mirrors) are supported, RAIDZ expansion in the UI since
  7.2, plus a hybrid mode where ZFS-formatted disks sit in the parity array [R3].
  Hot spares are not supported [R3]. Upgrading pool features can block a downgrade
  [R3][R5].
- GPU: NVIDIA drivers come from a community plugin (ich777's "Nvidia-Driver"),
  then containers get `--runtime=nvidia` and `NVIDIA_VISIBLE_DEVICES` [R6]
  (community source, not Lime Technology). VM passthrough through the built-in KVM
  works on this exact board for an RTX 2080 [I2].
- Docker: native management is DockerMan templates; Compose today needs a community
  plugin (Compose Manager Plus); native Compose is an Unraid 8 promise [R2][R7].
- RAM: the OS is loaded into RAM at boot; docs list 8 GB minimum, 16 GB+ with VMs
  [R4]. Small but non-zero overhead compared with bare metal.
- Licensing: proprietary, paid: Starter (6 devices; this build already counts 7
  storage devices), Unleashed (unlimited) or Lifetime; Starter and Unleashed
  include one year of updates [R8]. Boot from internal SSD/NVMe and TPM-based
  licensing arrived in 7.3, USB flash no longer mandatory [R9].
- Upkeep: GUI-first; plugins (NVIDIA, Compose) are third-party and tied to OS
  versions [R6]. The coming Slackware-to-Fedora switch in 8.x is a large platform
  change with no published migration path yet [R2].
- Declarative: no; configuration is GUI state on the boot device.
- Snapshots/rollback: Tools > Downgrade OS returns to the previously installed
  version [R5]; ZFS snapshots for pools.

## Option 5: NixOS + Docker

Current stable: 26.05 "Yarara", supported until 2026-12-31; 26.11 is in its release
cycle now [X1][X2]. Each release gets about seven months of support, so a major
upgrade is due every six months [X1].

- ZFS: supported through `boot.zfs` / `services.zfs` options (autoScrub, trim,
  autoSnapshot or sanoid); `networking.hostId` is mandatory [X3]. "ZFS often does
  not support the latest Kernel versions"; using an unsupported kernel makes the
  ZFS package evaluate as broken, so the host stays on an LTS kernel [X3]. ARC cap
  via `zfs.zfs_arc_max` [X3].
- GPU: `hardware.nvidia.open` must be chosen explicitly; open modules support
  Turing and newer [X4]. Docker GPU access via
  `hardware.nvidia-container-toolkit.enable` and CDI (`nvidia.com/gpu=all` in
  Compose `device_ids`) [X5]. GPU shared by all containers; no IOMMU concerns.
- Docker Compose: plain Docker with `docker compose` keeps working, so the current
  stacks and CI flow can stay; Nix-native alternatives (Arion, compose2nix) exist
  but are optional [X5].
- RAM: same as bare metal (no hypervisor). Nix store and build closures cost disk,
  not RAM.
- Upkeep: one declarative file set; `system.autoUpgrade` can run
  `nixos-rebuild switch --upgrade` unattended [X6]. Cost is the learning curve of
  the Nix language and the twice-yearly release bump [X1].
- Declarative: best of the five. The whole host (packages, services, users, ZFS,
  NVIDIA, Docker daemon config) lives in git and rebuilds identically.
- Snapshots/rollback: every rebuild creates a generation listed in the boot menu,
  "This allows you to easily roll back to a previous configuration" [X6];
  `nixos-rebuild test` activates without making it the boot default [X6]. Data
  rollback still relies on ZFS snapshots.

## Comparison

| Criterion | Proxmox (Docker VM) | Proxmox (Docker LXC) | Ubuntu 26.04 + Docker | Debian 13 + Docker | TrueNAS 25.10/27 | Unraid 7.4 | NixOS 26.05 |
|---|---|---|---|---|---|---|---|
| ZFS | Native, installer, root on ZFS | Same | Module in kernel | DKMS from contrib/backports | Core feature | Pools + hybrid array | Native, LTS kernel only |
| 2080 Ti for containers | Only inside the VM that owns it | Shared via host driver | Shared, signed driver | Shared, NVIDIA repo + DKMS | Shared by apps | Shared, community plugin | Shared, CDI |
| VM passthrough with one GPU | Yes (romfile may be needed) | n/a | Possible (libvirt) | Possible (libvirt) | No (needs 2 GPUs) | Yes | Possible (libvirt) |
| RAM overhead on 32 GB (estimate) | High (~2 GB host + ARC + pinned VM) | Low-medium | Lowest | Lowest | Medium (ARC greedy, middleware) | Low-medium | Lowest |
| Fit with git + Renovate + `docker compose up -d` | Unchanged inside VM | Unchanged, but unsupported by Proxmox | Unchanged | Unchanged | Must change (API/UI) | Must change (plugin) | Unchanged |
| Host declarative | No (answer file + Ansible) | No | Ansible | Ansible | No | No | Yes |
| Host rollback | Manual ZFS snapshot | Manual | None built in | None built in | Boot environments | Downgrade OS | Generations |
| Docker-layer rollback | VM snapshots/backups | CT snapshots (no bind mounts) | ZFS dataset snapshots | ZFS dataset snapshots | Dataset snapshots | ZFS snapshots | ZFS dataset snapshots |
| Cost | Free (subscription optional) | Free | Free | Free | Free | Paid license | Free |

## Cross-cutting pitfalls

- ARC versus 32 GB: upstream default lets ARC take about 31 GiB [Z1]; TrueNAS
  behaves the same [T10]; Proxmox caps at 10 % [P3]. GitLab, Immich (ML), Nextcloud
  and Postgres all compete for that RAM; decide a cap explicitly.
- NVIDIA driver versus kernel coupling: any host that builds the driver with DKMS
  (Debian, Proxmox host for the LXC variant) inherits breakage when the kernel moves
  ahead of the driver [D2]. Ubuntu (signed prebuilt modules), TrueNAS (bundled
  driver) and NixOS (driver built with the system, rollback if it fails) reduce this.
- Single GPU: any design that puts the GPU in a VM means one VM owns all GPU
  workloads and the host has no console [P5][T7].
- Non-ECC RAM with ZFS is discouraged by Proxmox and TrueNAS [P3][T9]; this is a
  hardware fact for every option, not a differentiator.
- BIOS updates can reshuffle IOMMU groups [I3]; a VM-passthrough design needs a
  re-check after each BIOS update.

## Implications for the decision

Options that stand out, and why:

1. Ubuntu 26.04 LTS + Docker + Ansible. Smallest change from today (same OS
   family, same roles, same deploy pipeline), lowest RAM overhead, ZFS module and
   signed NVIDIA driver shipped by the distro, five years of support. Weakness: the
   host is only as declarative as the Ansible coverage, and there is no built-in OS
   rollback.
2. NixOS + Docker. Meets the "reproducible/declarative host" principle best and
   adds atomic rollback of the host, while keeping Docker Compose as the deployment
   unit. Weakness: steep learning curve, twice-yearly major upgrades, ZFS pins the
   kernel, and the existing Ansible work would be replaced rather than reused.
3. Proxmox VE with one Docker VM holding the 2080 Ti. Best snapshot and backup
   story for the Docker layer, and room for future VMs (for example a test VM).
   Weakness: two OS layers to maintain, the largest RAM cost on 32 GB, and every
   GPU workload confined to the one VM. The LXC variant saves RAM but runs a
   configuration Proxmox itself does not recommend and has already broken once
   [P2][P7].

Less aligned with the stated principles: TrueNAS (excellent ZFS appliance, but
Docker is managed through its middleware, the host is locked, and the current
GitOps deploy would need rework [T6][T8]) and Unraid (paid, GUI state, Compose and
NVIDIA through community plugins today, major platform change pending in 8.x
[R2][R6][R7]).

Questions the owner needs to settle:

- Is host-level declarativeness (NixOS) worth replacing the Ansible investment and
  learning Nix, or is "Ansible-reproducible" good enough?
- Will this machine ever need VMs (Windows, Home Assistant OS, test environments)?
  If yes, Proxmox gains weight; if not, its cost buys little.
- Is it acceptable that all GPU workloads (Plex, Immich ML, LLM) live in one place
  (host or one VM)? With a single GPU there is no other way.
- How much of the 32 GB should ZFS ARC get (and is a RAM upgrade planned)?
- What role does the old i5-2400 play (backup target, Proxmox Backup Server, test
  host)? It changes how much rollback tooling the main host must provide itself.
- Before any VM-passthrough design: dump the IOMMU groups on the final BIOS.

## Sources

Proxmox
- [P1] Proxmox VE Roadmap (9.3 released 2026-11-25; 9.1 notes; OCI/Compose roadmap item): https://pve.proxmox.com/wiki/Roadmap
- [P2] Proxmox VE FAQ (support lifecycle table; "not recommended to run docker directly on your Proxmox VE host"): https://pve.proxmox.com/wiki/FAQ
- [P3] ZFS on Linux, Proxmox VE wiki (ARC 10 % / 16 GiB default, memory rule of thumb, ECC, proxmox-boot-tool): https://pve.proxmox.com/wiki/ZFS_on_Linux
- [P4] Proxmox Container Toolkit chapter and Linux Container wiki (application containers tech preview, VM recommended for isolation/live migration, bind mounts excluded from vzdump/snapshots): https://pve.proxmox.com/pve-docs/chapter-pct.html , https://pve.proxmox.com/wiki/Linux_Container
- [P5] PCI Passthrough, Proxmox VE wiki (IOMMU groups, ACS override as last resort, romfile, device unavailable to host, NVIDIA 465+): https://pve.proxmox.com/wiki/PCI_Passthrough
- [P6] Proxmox VE system requirements (2 GB for OS and services, ~1 GB per TB for ZFS): https://www.proxmox.com/en/products/proxmox-virtual-environment/requirements
- [P7] Proxmox forum, Docker inside LXC `ip_unprivileged_port_start` error (CVE-2025-52881, fixed lxc-pve in 9.1): https://forum.proxmox.com/threads/docker-inside-lxc-net-ipv4-ip_unprivileged_port_start-error.175437/ and https://forum.proxmox.com/threads/cve-2025-52881-breaks-docker-lxc-containers.175827/
- [P8] Qemu/KVM chapter, Proxmox VE admin guide (ballooning, leave 1 GB to host, virtiofs and its limitations): https://pve.proxmox.com/pve-docs/chapter-qm.html
- [P9] Automated Installation, Proxmox VE wiki (TOML answer file since 8.2): https://pve.proxmox.com/wiki/Automated_Installation

Debian / Ubuntu / OpenZFS / NVIDIA
- [D1] Debian 13 trixie release page (13.8, support dates): https://www.debian.org/releases/trixie/
- [D2] Debian wiki, NvidiaGraphicsDrivers (550 unmaintained, no build on 6.16+, NV DC 590+ for Turing, open flavor, MOK): https://wiki.debian.org/NvidiaGraphicsDrivers
- [D3] OpenZFS docs, Getting Started on Debian (contrib, trixie-backports, zfs-dkms, root on ZFS guide): https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html
- [U1] Ubuntu release cycle (5 years standard support, 26.04 to May 2031): https://ubuntu.com/about/release-cycle
- [U2] Ubuntu 26.04 LTS release notes, summary for LTS users (kernel 7.0, `ubuntu-drivers install nvidia:595`): https://documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users/
- [U3] Ubuntu wiki ZFS and Kernel/Reference/ZFS (module shipped with kernel, zfsutils-linux; dated pages) and Ubuntu Discourse "Install Ubuntu Server with ZFS" (installer root-on-ZFS removal, user report): https://wiki.ubuntu.com/ZFS , https://wiki.ubuntu.com/Kernel/Reference/ZFS , https://discourse.ubuntu.com/t/install-ubuntu-server-with-zfs/80119
- [Z1] zfs(4) man page, OpenZFS (zfs_arc_max default = larger of RAM - 1 GiB and 5/8 RAM): https://openzfs.github.io/openzfs-docs/man/master/4/zfs.4.html
- [Z2] OpenZFS 2.2.0 release notes (overlayfs and idmapped mount support for containers): https://github.com/openzfs/zfs/releases/tag/zfs-2.2.0
- [N1] NVIDIA Container Toolkit install guide (`nvidia-ctk runtime configure --runtime=docker`, host driver prerequisite): https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

TrueNAS
- [T1] TrueNAS 25.10 release notes: https://www.truenas.com/docs/scale/25.10/gettingstarted/scalereleasenotes/
- [T2] TrueNAS 27 version notes (27-RC.1 2026-10-06, component versions, Turing-and-later statement) and "TrueNAS 27 is here" blog (rename, 27.0 early December 2026): https://www.truenas.com/docs/scale/27/gettingstarted/versionnotes/ , https://www.truenas.com/blog/truenas-27-is-here/
- [T3] TrueNAS forum, NVIDIA Kernel Module Change in TrueNAS 25.10: https://forums.truenas.com/t/nvidia-kernel-module-change-in-truenas-25-10-what-this-means-for-you/51070
- [T4] TrueNAS 25.10 version notes: https://www.truenas.com/docs/scale/25.10/gettingstarted/versionnotes
- [T5] TrueNAS docs, Install Custom App screens ("Install via YAML" Compose editor): https://www.truenas.com/docs/scale/25.10/scaleuireference/apps/installcustomappscreens/
- [T6] TrueNAS 26 version notes (BETA.1 to BETA.3: Compose `include:`, LXC GPU passthrough, NVIDIA 580 LTSB to August 2028, REST API and legacy VMs removed, manual Docker conflicts, annual cadence): https://www.truenas.com/docs/scale/26/gettingstarted/versionnotes/
- [T7] TrueNAS docs, Managing GPUs (isolation requires at least two GPUs; isolated GPU unavailable to apps): https://www.truenas.com/docs/scale/25.10/scaletutorials/systemsettings/advanced/managegpuscale/ , https://www.truenas.com/docs/scale/27/systemsettings/advanced/managegpu/
- [T8] TrueNAS docs, Developer Mode (Unsupported): https://www.truenas.com/docs/scale/scaletutorials/systemsettings/advanced/developermode/
- [T9] TrueNAS hardware guide (8 GB minimum, ECC recommendation, 20 GB SSD boot, no USB sticks): https://www.truenas.com/docs/scale/gettingstarted/tnhardwareguide/
- [T10] TrueNAS SCALE 24.04 release notes (ARC behaves like CORE) and forum thread on 24.04 ARC/OOM: https://www.truenas.com/docs/scale/24.04/gettingstarted/scalereleasenotes , https://forums.truenas.com/t/zfs-arc-max-issue-out-of-memory-errors-in-kernel-with-scale-24-04-1-1/6271
- [T11] TrueNAS docs, Boot Pool Management (boot environments, rollback scope): https://www.truenas.com/docs/scale/scaletutorials/systemsettings/managebootenvironscale/

Unraid
- [R1] Unraid 7.4.0 release notes (2026-11-10, kernel 6.18.60, ZFS 2.4.4): https://docs.unraid.net/unraid-os/release-notes/7.4.0/
- [R2] Unraid blog, "Unraid 8 Announced" (2026-08-17): https://unraid.net/blog/unraid-8-announced
- [R3] Unraid docs, ZFS storage: https://docs.unraid.net/unraid-os/advanced-configurations/optimize-storage/zfs-storage/
- [R4] Unraid docs, VM overview and system prep (8 GB minimum, 16 GB+ with VMs): https://docs.unraid.net/unraid-os/using-unraid-to/create-virtual-machines/overview-and-system-prep/
- [R5] Unraid docs, Updating Unraid (Tools > Downgrade OS, ZFS feature caveat): https://docs.unraid.net/unraid-os/system-administration/maintain-and-update/upgrading-unraid/
- [R6] Unraid forum, Nvidia-Driver plugin support thread (community): https://forums.unraid.net/topic/98978-plugin-nvidia-driver/
- [R7] Unraid forum, Compose Manager Plus plugin (community): https://forums.unraid.net/topic/197334-plugin-compose-manager-plus
- [R8] Unraid license purchase page (tiers, device limits, one year of updates): https://account.unraid.net/buy
- [R9] Unraid 7.3.0 release notes (internal boot, TPM licensing): https://docs.unraid.net/unraid-os/release-notes/7.3.0/

NixOS
- [X1] NixOS 26.05 release announcement (support until 2026-12-31, seven months): https://nixos.org/blog/announcements/2026/nixos-2605/
- [X2] NixOS Discourse, 26.11 release cycle: https://discourse.nixos.org/t/let-s-have-a-great-26-11-release-cycle/80323
- [X3] NixOS wiki, ZFS (hostId, kernel compatibility, ARC, autoScrub/autoSnapshot): https://wiki.nixos.org/wiki/ZFS
- [X4] NixOS wiki, NVIDIA (`hardware.nvidia.open`, Turing and newer for open modules): https://wiki.nixos.org/wiki/NVIDIA
- [X5] NixOS wiki, Docker (nvidia-container-toolkit + CDI, Compose options): https://wiki.nixos.org/wiki/Docker
- [X6] NixOS manual 26.05 (boot menu generations, `nixos-rebuild test`, `system.autoUpgrade`): https://nixos.org/manual/nixos/stable/

Board / IOMMU
- [I1] Level1Techs forum, "X570 Taichi IOMMU groups" thread, Crosshair VIII Hero Wi-Fi listing on BIOS 0702 (2019-07-30) and X570 BIOS IOMMU tips: https://forum.level1techs.com/t/x570-taichi-iommu-groups/145762
- [I2] Unraid forum, "Problem passing through USB controller on X570" (Crosshair VIII Hero Wi-Fi, BIOS 1302, RTX 2080, 2020-04): https://forums.unraid.net/topic/91278-problem-passing-through-usb-controller-on-x570/
- [I3] Level1Techs forum, Crosshair VII Hero thread ("AGESA updates change this majorly"): https://forum.level1techs.com/t/need-module-driver-list-of-asus-crosshair-7-hero-wifi-mobo/140081
- [I4] ASUS ROG Crosshair VIII Hero (Wi-Fi) specifications: https://rog.asus.com/motherboards/rog-crosshair/rog-crosshair-viii-hero-wi-fi-model/spec/
