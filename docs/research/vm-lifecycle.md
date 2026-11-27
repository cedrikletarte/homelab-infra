# Automating the lifecycle of the Role VMs on Proxmox VE

Research date: 2026-11-26. Status: findings only, no decision.

Question: which guest OSes and which tools can automate the whole lifecycle (create,
configure, update, rebuild) of the eight Role VMs fixed by ADR 0001 on Proxmox VE 9,
with Docker Compose inside each VM and the RTX 2080 Ti passed through to the GPU VM?
The note covers: automated install of the Hypervisor Host itself; VM creation
(OpenTofu/Terraform providers, cloud-init templates, Packer); guest OS candidates
(Debian 13, Ubuntu 26.04 LTS, NixOS, Flatcar, Fedora CoreOS) and their unattended
updates; the configuration tool (Ansible, Nix, Ignition/Butane); the NVIDIA driver
and Container Toolkit in each guest (Turing, compute capability 7.5); RAM cost per
guest; and how the host configuration itself can be kept declarative.

Context: Ryzen 9 3900X, ASUS ROG Crosshair VIII Hero (X570), 64 GB RAM planned, ZFS
pools owned by the host, one GPU passed to one VM. Principles: reliability and low
upkeep first, a dedicated tool beats a home-made script, complexity must be justified.
Related notes: `docs/research/host-layer.md` (branch `research/host-layer`) and
`docs/research/gpu-sharing.md` (branch `research/gpu-sharing`).

Every claim carries a source tag (list at the end). "Estimate" or "inference" marks
reasoning on top of the sources, not a quote. Placeholders such as `<pve-host>`,
`<vmid>` or `<admin-user>` stand for real values that do not belong in this public
repo.

## 1. Summary

- The lifecycle splits into stages that no single tool covers well: host install,
  host configuration, VM definition, first-boot provisioning, day-2 configuration,
  updates, rebuild. Each stage has a dedicated, maintained tool; the open question is
  how many of them to adopt.
- **Host install** is solved by Proxmox itself: the automated installer (since 8.2)
  reads a TOML answer file (disk layout incl. ZFS RAID level and `arc-max`, network,
  root SSH keys) from the ISO, a partition or HTTP, and can run a first-boot script
  (since 8.3) [P1].
- **VM definition:** the bpg/proxmox provider is the active choice for OpenTofu and
  Terraform. It targets PVE 9.x and is acceptance-tested against it, ships releases
  almost weekly, and covers VMs, cloud images (download and import), PCI resource
  mappings, storage, bridges, users, ACLs, backup jobs and more [B1][B2][B3]. It is
  still 0.x and breaks compatibility now and then (7 breaking releases between
  0.110.0 on 2026-06-18 and 0.124.0 on 2026-11-26) [B4]. Telmate/proxmox has had
  only release candidates since 2023 (last stable v2.9.14 in March 2023, now at
  v3.0.2-rc10 from August 2026) and has 5 resources [T1][T2].
- **Templates:** with bpg, a cloud image can be downloaded and imported straight into
  a VM disk (`download_file` with `content_type = "import"` plus `import_from`), so
  neither a hand-made template VM nor Packer is required [B5]. Packer (BUSL licence,
  Proxmox plugin v1.2.4) stays useful only to bake things in, such as the NVIDIA
  driver into a GPU VM image [K1][K2].
- **Guest OS:** Debian 13 and Ubuntu 26.04 work with cloud-init on Proxmox out of the
  box and with Ansible afterwards. NixOS builds a Proxmox image natively and is
  configured and updated from git, with rollback. Flatcar and Fedora CoreOS are
  provisioned once by Ignition and then updated atomically with A/B or OSTree
  rollback, but Flatcar on Proxmox is community-supported only [F1] and Fedora CoreOS
  has no official NVIDIA driver path.
- **NVIDIA in the GPU VM:** the 2080 Ti (Turing) is supported by every current branch,
  open modules included. Ubuntu has signed prebuilt modules through `ubuntu-drivers`
  [U1]. On Debian 13, the packaged 550 driver is unmaintained and has security issues
  [D1], so NVIDIA's own repository (DKMS) is the practical path [N1]. NixOS builds
  the driver with the system [X4]. Flatcar ships official driver sysexts, but only up
  to branch 570 [F3]. Fedora CoreOS has no first-party option.
- **RAM:** the OS choice moves the total by roughly 1 to 2 GB across eight guests
  (estimate). Docker workloads, the ARC and the pinned GPU VM matter far more.
- **Host config as code:** possible through Ansible (`community.proxmox`, 60+ modules)
  [A1] and/or bpg resources (bridges, storage, APT repositories, users, ACLs, backup
  jobs, PCI mappings) [B3]. Kernel command line, vfio binding and `/etc/modprobe.d`
  still need a file-level tool. A NixOS port of Proxmox exists but is flagged
  "experimental" by its authors [X7].

## 2. The lifecycle stages and the tools that can own them

| Stage | What it means here | Candidate tools |
|---|---|---|
| 0. Host install | Bare metal to a Proxmox node with ZFS root | Proxmox automated installer + answer file [P1] |
| 1. Host config | IOMMU, vfio, ARC cap, bridges, storage, users, API token, backup jobs | Ansible (`community.proxmox`, `ansible.builtin`) [A1]; bpg resources [B3]; first-boot hook [P1] |
| 2. Image / template | A bootable OS disk to clone or import | Vendor cloud images + bpg `download_file` [B5]; Proxmox cloud-init template (`qm template`) [P2]; Packer `proxmox-iso` / `proxmox-clone` [K1]; `nixos-rebuild build-image` [X1] |
| 3. VM definition | CPU, RAM, disks, NIC, GPU, virtiofs, tags | OpenTofu/Terraform + bpg [B1] or Telmate [T1]; Ansible `proxmox_kvm` [A1] |
| 4. First boot | Hostname, user, SSH key, network, packages | cloud-init (NoCloud via Proxmox) [P2][C1]; Ignition/Butane [I1] |
| 5. Day-2 config | Docker, Compose, NVIDIA, mounts, hardening | Ansible; Nix (`nixos-rebuild`); none for Ignition OSes (rebuild instead) [I2] |
| 6. Updates | OS patches, reboots | unattended-upgrades [D2][U2]; `system.autoUpgrade` [X5]; Flatcar update_engine + locksmith [F4]; Zincati [R1] |
| 7. Rebuild | Throw the system disk away, recreate | `tofu apply -replace=...`; Ignition / NixOS / cloud-init re-provision |

## 3. Stage 0: automated install of the Hypervisor Host

Facts from the Proxmox wiki [P1]:

- Available since PVE 8.2-1. The answer file is TOML. The ISO is prepared with
  `proxmox-auto-install-assistant prepare-iso`. The answer comes from exactly one
  source: embedded in the ISO (`--fetch-from iso`), a partition labelled
  `PROXMOX-AIS`, or HTTP(S). For HTTP, the URL comes from the ISO, DHCP option 250 or
  a DNS TXT record. The installer POSTs the hardware inventory and can pin the
  server certificate fingerprint.
- `[global]`: keyboard, country, FQDN, timezone, mail, root password (plain or
  hashed), root SSH keys, reboot behaviour; `subscription-key` since 9.2-1.
- `[network]`: DHCP or static (`cidr`, `dns`, `gateway`); interface name pinning since
  9.1-1; management bond and VLAN since 9.3-1.
- `[disk-setup]`: `filesystem = "zfs"` with `zfs.raid`, `ashift`, `arc-max`,
  `compress`, `checksum`, `copies`, `hdsize`. Disks are chosen by `disk-list` or by a
  `filter` (udev properties). Since 9.3-1, `filter-match = "all"` no longer matches
  devices that lack a filtered property.
- `[first-boot]` (since 8.3-1): one script (max 1 MiB, with a shebang) from the ISO
  or a URL, run `before-network`, at `network-online` or when `fully-up`.
- `[post-installation-webhook]`: JSON POST with disks, NICs, machine-id and SSH host
  keys (an auth token is supported since 9.2-1).
- 9.0-1 deprecated `snake_case` keys in favour of `kebab-case`; they will become hard
  errors later.

Consequences (inference):

- The answer file can live in git as a template, with the password hash and
  subscription key injected at ISO build time. A plain password must never be
  committed, since the repo is mirrored publicly.
- The answer file covers only the root pool. The four IronWolf data pools are created
  after install, and they must never be recreated on a reinstall. Creating them
  belongs to a one-off documented step or a guarded task, not to an idempotent
  "apply everything" run. bpg even has a `node_disk_zfs` resource that creates zpools
  [B3]: on existing data disks it is a footgun.
- The first-boot hook is the natural place to bootstrap the next stage: install
  Ansible's SSH key, or create the API token that OpenTofu will use.

## 4. Stage 1: keeping the host configuration declarative

Proxmox is not declarative by design: its configuration lives in Debian files, in
`/etc/pve` (the cluster filesystem) and behind the API. The options:

| Option | What it covers | Limits |
|---|---|---|
| Ansible, `ansible.builtin` + `ansible.posix` | Files and packages: kernel cmdline (`amd_iommu`, `iommu=pt`), `/etc/modules-load.d/vfio.conf`, `vfio-pci` IDs, `/etc/modprobe.d/zfs.conf` (ARC), APT repositories, `sanoid`, monitoring agents, post-update `update-initramfs` | Imperative tasks written idempotently; drift outside Ansible possible |
| Ansible `community.proxmox` 2.1.0 (2026-10-06) | 60+ API modules: `proxmox_node_network`, `proxmox_storage`, `proxmox_user`/`role`/`access_acl`, `proxmox_backup_schedule`, `proxmox_kvm`, `proxmox_cluster`, firewall, SDN, plus a dynamic inventory plugin [A1] | Collection still migrating modules out of `community.general`; tested with ansible-core 2.17 to 2.20 [A1] |
| OpenTofu + bpg | API objects: bridges and VLANs, storage (ZFS pool, directory, PBS), APT repositories, users, roles, ACLs, tokens, backup jobs, PCI/USB/dir hardware mappings, node config, firewall, metrics server [B3] | Cannot touch files outside `/etc/pve` (kernel cmdline, modprobe); some calls need `root@pam` (section 5.3) |
| Answer file + first-boot hook | Install-time values only [P1] | Runs once; not a reconciler |
| NixOS port of Proxmox (proxmox-nixos) | Whole host from a Nix flake | "still **experimental** and we do not advise running it on production machines" [X7]; not by Proxmox |

The two boundaries split naturally (inference): files and packages fit Ansible, API
objects fit either Ansible or bpg. Having both tools manage the same object
(for example a bridge) would cause churn, so each object needs one owner.

Host updates: Proxmox requires `apt full-upgrade`, not `apt upgrade` ("performing an
apt upgrade may result in a partially upgraded or broken package state") [P3]. Plain
unattended-upgrades is therefore a poor fit for the host (inference: its default
behaviour is an upgrade, not a full-upgrade). The usual pattern is a scheduled or
manual `apt full-upgrade` driven by Ansible, with a reboot window.

## 5. Stages 2 and 3: images and VM definition

### 5.1 Cloud-init on Proxmox

- Proxmox generates a NoCloud (Linux) seed from `ciuser`, `sshkeys`, `ipconfigN`,
  `nameserver`, `searchdomain`, `ciupgrade` (default 1: upgrade packages on first
  boot) and attaches it as a CD-ROM [P2].
- `cicustom` replaces any of the user, network, meta or vendor parts with a file on
  a storage that supports snippets; the file must exist on every node the VM can run
  on [P2].
- Cloud-init's own modules cover APT sources, packages, `write_files`, `runcmd`, and an
  `ansible` module that runs `ansible-pull` from a repo once per instance [C1].
- Templates: import a cloud image as `scsi0`, add a cloud-init drive, set a serial
  console, `qm template`, then clone [P2].

### 5.2 OpenTofu/Terraform providers

| | bpg/proxmox | Telmate/proxmox |
|---|---|---|
| Latest release | v0.124.0, 2026-11-26; v0.120 to v0.124 all in November 2026 [B2] | v3.0.2-rc10, 2026-08-30; last non-RC v2.9.14, 2023-03-19 [T2] |
| PVE 9 | "targets Proxmox VE 9.x and is acceptance-tested against the current 9.x release"; 8.x best effort; 7.x unsupported [B1] | Documents a PVE 9 role (no `VM.Monitor`) [T3] |
| OpenTofu | Published to the OpenTofu registry; OpenTofu 1.6+ supported but not exercised in CI [B1][B6] | Not stated |
| Scope | ~100 resource docs: VM, cloned VM, LXC, files, download_file, cloud-init bootstrap, PCI/USB/dir mappings, storage, network, SDN, users/ACL/tokens, backup jobs, HA, ACME, firewall [B3] | 5 resources: `vm_qemu`, `cloud_init_disk`, `lxc`, `lxc_guest`, `pool` [T2] |
| PCI passthrough | `hostpci` with `mapping` (cluster resource mapping) or raw `id`; `pcie`, `rombar`, `rom_file`, `xvga` options; a raw `id` "is not compatible with `api_token`" [B7] | `pci`/`pcis` blocks with `mapping_id` or `raw_id`, `pcie`, `primary_gpu` [T4] |
| Known issues | 0.x: "not guaranteed to be backward compatible with all previous minor versions" [B1]; 7 breaking releases in 5 months [B4]; the new `proxmox_vm` resource is a "DO NOT USE" proof of concept, the production resource is `proxmox_virtual_environment_vm` [B8] | README: updates of `vm_qemu` "almost always result as a failed task within the Proxmox UI" (harmless per the README); disk size mismatch with the UI [T1] |
| Licence | MPL-2.0 | MIT |

Other bpg facts that matter for this design:

- **Cloud images without templates:** `proxmox_virtual_environment_download_file`
  with `content_type = "import"` fetches a qcow2 from the vendor onto a storage that
  has the Import content type enabled. The VM disk then uses `import_from` [B5]. A
  Debian or Ubuntu VM can thus be defined from the vendor URL alone.
- **SSH is optional:** most resources use the API only. SSH is needed to upload
  snippets (custom cloud-init files), import disks from a local path, and set LXC
  idmaps. The docs give an anchored sudoers rule for snippet uploads and warn that
  broad sudo on `qm` or `pvesm` "is equivalent to giving it root on the host" [B6].
- **`proxmox_cloudinit_bootstrap`** (new in 0.124.0, 2026-11-26) uploads a temporary
  NoCloud seed ISO through the API, boots the VM, waits for cloud-init to finish via
  the guest agent (including the reboots it triggers), then deletes the ISO. No SSH
  and no snippet storage are needed [B9][B4]. It is one day old at the time of
  writing.

### 5.3 What requires `root@pam`

Proxmox reserves some operations for `root@pam`, and an API token, even one with
Administrator rights, gets "Permission check failed" for them. Affected: "USB and PCI
passthrough without a resource mapping, virtiofs directories, serial ports pointing at
real devices, the VM CPU architecture" and container bind mounts [B6].

Consequence: defining the GPU as a **PCI resource mapping** (Datacenter > Resource
Mappings; bpg `hardware_mapping_pci`; Ansible has no dedicated module in the list
above) lets a non-root token attach it [B6][B10]. Proxmox's own rationale for mappings
is that "changing hardware can change ids and paths", and a mapping detects that
[P4]. The same goes for virtiofs: a **directory mapping** (`hardware_mapping_dir`)
avoids root for the media and photo datasets [B3]. The alternative is to let bpg mint
a short-lived `root@pam` ticket over SSH [B6].

### 5.4 Packer

- The Proxmox plugin (MPL-2.0, v1.2.4 from 2026-07-21, previous release a year
  earlier) has two builders: `proxmox-iso` (install from an ISO through an
  autoinstall/preseed) and `proxmox-clone` (start from an existing template) [K1].
- Packer itself is under the Business Source License [K2].
- Where it would add value here (inference): baking a GPU VM image with the NVIDIA
  driver and Container Toolkit already installed, so that a rebuild does not depend on
  NVIDIA's repositories being reachable. For the other seven VMs, vendor cloud images
  plus cloud-init already give a template, and Packer is one more tool and one more
  image to keep patched.

### 5.5 GPU VM specifics (all OSes)

- vfio modules (`vfio`, `vfio_iommu_type1`, `vfio_pci`) in
  `/etc/modules-load.d/`, then `update-initramfs -u -k all` [P5]. Host driver
  blacklisted; a `romfile` may be needed when the passed GPU is the boot GPU [P6].
  Section "IOMMU groups" of the host-layer note covers this board.
- "VMs with passed-through devices cannot be migrated" [P6]; irrelevant with one
  node.
- Memory: with ballooning, Proxmox moves memory between host and guests [P7]. A VM
  with a passed-through device has its whole RAM pinned for DMA (inference from how
  VFIO works, already noted in ADR 0001). The GPU VM should therefore get a fixed size.
- Rebuild of the GPU VM costs a driver install, plus a DKMS build on Debian (section
  7). A baked image or NixOS's cached build avoids that wait (inference).

## 6. Guest OS candidates

### 6.1 Debian 13 "trixie"

- Images: `generic` ("Should run in any environment using cloud-init") and
  `genericcloud` ("Identical to generic but with a reduced set of hardware drivers in
  the kernel") [D3]. Kernel 6.12 LTS (the NVIDIA support table lists Debian 13.3 with
  6.12.73) [N2].
- Config: cloud-init at first boot, then Ansible. This repo's current Ansible roles
  (`base`, `security`, `docker`, `maintenance`) target Ubuntu and would need small
  adaptations (inference).
- Updates: "the default configuration auto-installs security updates, but not new
  features" [D2]. Whether the cloud image enables it out of the box is not stated
  [D2]; cloud-init `packages: [unattended-upgrades]` or Ansible can make sure.
- Docker: Docker's apt repository supports Debian 13 and 12 [O1].
- Support: security support to 2028-08-09, LTS to 2030-06-30 (from the host-layer
  note, Debian release page).

### 6.2 Ubuntu 26.04 LTS

- Released 2026-04-23; "security updates and critical bug fixes for five years"
  (to April 2031), ten years with Ubuntu Pro ESM [U3]. Server minimum "as low as
  1.5 GB RAM" (for the installer) [U3].
- unattended-upgrades is installed and enabled by default; the default origins are
  the release and `-security`; `Automatic-Reboot` defaults to `false` [U2].
- NVIDIA through `ubuntu-drivers install --gpgpu`, which installs "pre-built, signed
  drivers" by default (`linux-modules-nvidia-<branch>-server-<flavour>`) [U1].
- Docker's apt repository supports 26.04 [O1]; the NVIDIA Container Toolkit lists
  Ubuntu 26.04 as tested [N3].
- Config: cloud-init then Ansible. Closest to the current host; the existing roles
  apply almost unchanged (inference).

### 6.3 NixOS (26.05, next 26.11)

- Image: since NixOS 25.05, `nixos-rebuild build-image` replaces nixos-generators
  (archived on 2026-01-30) [X1]. Its `proxmox` variant produces a VMA [X1]. The
  module enables cloud-init by default ("Whether the VM should accept cloud init
  configurations from PVE"), the QEMU guest agent and sshd [X2].
- Install alternative: nixos-anywhere installs over SSH via kexec and partitions with
  disko; the target needs "at least 1 GB of RAM" when kexec is used [X3].
- Config: the whole VM (Docker daemon, NVIDIA, mounts, users) in a flake in git;
  pushed with `nixos-rebuild switch --target-host` or a deploy tool, or pulled by
  `system.autoUpgrade` with `flake`, `allowReboot` and a `rebootWindow` [X5].
  Generations give a bootable rollback (see the host-layer note).
- NVIDIA: `hardware.nvidia.open` must be set explicitly for drivers 560 and newer
  (default `null`) [X4]; `hardware.nvidia-container-toolkit` generates CDI specs for
  Docker [X4b].
- Cost: Nix language learning curve, and a release upgrade every six months, each
  release getting about seven months of support (host-layer note).

### 6.4 Flatcar Container Linux

- Proxmox image `flatcar_production_proxmoxve_image.img` (qcow2). The Ignition config
  goes through the cloud-init drive (`--cicustom user=...`). The page is titled
  "community support": "Proxmox VE is not an officially supported platform at this
  time because the release tests don't run for it" [F1]. Current: Stable 4757.2.4
  (build 2026-11-21) [F1][F5].
- Docker and containerd ship as default sysexts. NVIDIA drivers, ZFS and Podman are
  opt-in official sysexts. Community sysexts (sysext-bakery) are "not tested in
  CI" [F2]. Docker Compose is not in the official list [F2] (inference: it comes from
  the bakery or as a binary).
- Updates: A/B partitions; "a reboot is the last step of the update". locksmith
  strategies are `reboot` (default, 5 min delay), `etcd-lock` and `off`, with optional
  reboot windows [F4]. There is an LTS channel [F4].
- NVIDIA: official prebuilt sysexts, signed with the kernel; on the current stable
  release the newest branch is 570 (`flatcar-nvidia-drivers-570-open.raw`, also 535
  and 550) [F3][F5]. Branch 570 sits below the 580 minimum for CUDA 13.x minor-version
  compatibility (gpu-sharing note), so CUDA 13 images would not run until Flatcar
  ships a newer branch (inference).

### 6.5 Fedora CoreOS

- Official `proxmoxve` platform and image (`coreos-installer download -p proxmoxve
  -f qcow2.xz`); Ignition through `--cicustom vendor=...` [R2][R3]. Ignition reads
  user data, then vendor data, from the config drive [I3].
- "Existing cloud-init configurations are not supported" [R4]. Docker (Moby) and
  Podman are included; the docs describe swapping Moby for Docker CE with a layered
  rpm-ostree install [R4][R5].
- Updates: Zincati + rpm-ostree, with strategies `immediate`, fleet lock or
  `periodic` maintenance windows, and manual rollbacks [R1].
- NVIDIA: no first-party path. The docs steer users to containers, with layering as
  the exception for drivers [R6]. Community route: uCore (ublue-os, Apache-2.0), an
  FCOS-based OCI image with `-nvidia` and `-nvidia-lts` tags, Docker Compose and ZFS
  included; its minimal image disables Zincati in favour of staged rpm-ostreed
  updates [R7].

### 6.6 Ignition versus configuration management

Ignition "runs only on the first boot" and "is designed to be used as a provisioning
tool, not as a configuration management tool ... machine modification requires that
users discard the old node and re-provision the machine" [I2]. With Flatcar or FCOS,
a configuration change (a new mount, a new daemon flag) means a VM rebuild. That
fits the Runner VM ("rebuilt at will", ADR 0001). It fits worse for VMs whose
Compose data lives on the system disk (inference), unless every piece of state sits
on a separate disk or a virtiofs share.

## 7. NVIDIA driver and Container Toolkit per guest OS

| OS | Driver source | Turing (SM 7.5) | Kernel coupling | Container Toolkit |
|---|---|---|---|---|
| Debian 13 | Packaged 550: "no longer maintained and contains several security issues"; the open flavour no longer compiles from kernel 6.12.100 [D1]. NVIDIA repo `debian13`: `nvidia-open`, or compute-only `nvidia-driver-cuda nvidia-kernel-open-dkms`; branch pinning packages [N1][N4] | Yes (550 proprietary, and open branches 580+) [D1][N1] | DKMS rebuild on each kernel update | NVIDIA's apt repo; tested list names Debian 11 only, "should work for any Debian-derived distribution" [N3] |
| Ubuntu 26.04 | `ubuntu-drivers install --gpgpu` (signed prebuilt modules), or NVIDIA repo `ubuntu2604` [U1][N2] | Yes | None with prebuilt modules; userspace/module mismatch until reboot after an upgrade [U1] | NVIDIA's apt repo; Ubuntu 26.04 tested [N3] |
| NixOS | nixpkgs, built with the system; `hardware.nvidia.open` explicit [X4] | Yes (open modules: Turing+) | Rebuilt with the kernel; rollback if broken | `hardware.nvidia-container-toolkit` (CDI) [X4b] |
| Flatcar | Official sysexts 535/550/570, open and proprietary [F3][F5] | Yes (570) | Built with the kernel, signed [F3] | `nvidia-runtime` sysext; docs show `ctr`, not Docker [F3] |
| Fedora CoreOS | None official; uCore `-nvidia` images (community) [R7] | Not stated | Image rebuild per kernel | Not documented by FCOS |

Notes:

- Compute-only installs drop the GL/Vulkan/X stack. NVIDIA notes that the full
  "Desktop and Compute" install "might be required ... for CUDA-accelerated video
  encoding/decoding" [N4], which is what Plex NVENC uses. To check on the real VM.
- Plex needs `NVIDIA_DRIVER_CAPABILITIES` to include `video` (gpu-sharing note).
- The toolkit's current version is 1.20.2 [N3].

## 8. RAM cost per guest

No vendor publishes an idle footprint for a cloud image running Docker. The table mixes
published minimums with estimates.

| OS | Published figure | Idle estimate with dockerd, no workload |
|---|---|---|
| Debian 13 | Installer: 512 MB minimum, 1 GB recommended without desktop; "actual minimum memory requirements are a lot less" [D4] | 0.3 to 0.5 GB (estimate) |
| Ubuntu 26.04 | Server "starting as low as 1.5 GB RAM" [U3] | 0.4 to 0.6 GB (estimate) |
| NixOS | 1 GB for a kexec install [X3] | 0.3 to 0.5 GB idle; evaluating nixpkgs during a local `nixos-rebuild` needs more (estimate; building on another machine avoids it) |
| Flatcar | None found | 0.2 to 0.4 GB (estimate) |
| Fedora CoreOS | Proxmox example uses 2048 MB [R2] | 0.3 to 0.5 GB (estimate) |

Cross-cutting:

- Per-VM overhead on the host (QEMU process, page tables, virtio queues) comes on
  top: about 0.1 to 0.3 GB per VM (estimate). Proxmox's rule of thumb is to leave 1 GB
  to the host [P7].
- KSM is enabled by default on Proxmox and merges identical pages across VMs "running
  similar operating systems". It carries a side-channel risk, which Proxmox raises for
  hosting providers, and can be disabled per VM [P8]. Eight guests on the same OS
  benefit more than a mix (inference).
- Over eight guests the spread between the lightest and heaviest OS is roughly 1 to
  2 GB (estimate). That is small next to the ARC cap and the pinned GPU VM in ADR
  0001's 52 GB budget.

## 9. Candidate combinations

Each option names one owner per stage. None is recommended here.

### A. OpenTofu (bpg) + Debian or Ubuntu cloud images + cloud-init + Ansible

- Stages: answer file for the host; Ansible for host files; bpg for VMs, mappings and
  storage; vendor cloud image imported by bpg; cloud-init for user, keys and
  network; Ansible for Docker, Compose, NVIDIA and mounts; unattended-upgrades for
  security patches.
- For: every piece is mainstream and documented by its vendor. Ansible is already in
  use. Ubuntu offers signed NVIDIA modules and the toolkit lists it as tested. Rebuild
  is `tofu apply -replace` followed by an Ansible run.
- Against: three tools (OpenTofu, cloud-init, Ansible) plus state handling. OpenTofu
  state holds secrets and must not land in the public repo; state and plan encryption
  exist in OpenTofu [O2]. The bpg provider is 0.x and breaks compatibility now and
  then [B4]. Configuration drift stays possible between Ansible runs.
- Variant A2: mix the distros. Ubuntu for the GPU VM (prebuilt driver), Debian for
  the rest. Two OS families to patch and know.

### B. Ansible only (`community.proxmox`) + cloud images + cloud-init

- `proxmox_kvm` creates and clones VMs; the same playbooks then configure the guests
  [A1].
- For: one tool fewer, no state file to protect.
- Against: no plan/diff of the VM layer, and no PCI or directory mapping module in
  the collection's module list [A1] (the GPU mapping would be a manual or `pvesh`
  step). Destroy and recreate are tasks to write, where OpenTofu derives them.

### C. OpenTofu (bpg) + NixOS guests

- bpg creates the VMs from a NixOS image (`build-image --image-variant proxmox`) or
  installs them with nixos-anywhere. One flake describes all eight guests;
  `system.autoUpgrade` (or a push from CI) applies changes and patches.
- For: guests fully declarative with atomic rollback. The NVIDIA driver is built with
  the system. Little drift. The host stays plain Proxmox.
- Against: the Nix learning curve and a release bump every six months for eight VMs.
  The existing Ansible roles are not reused. Non-NixOS Proxmox cloud-init examples do
  not apply directly.

### D. OpenTofu (bpg) + Flatcar or Fedora CoreOS + Butane

- Butane files in git, transpiled to Ignition and passed via `cicustom` or a seed ISO.
  A change means rebuilding the VM. A/B or OSTree updates happen with reboot windows.
- For: minimal guests, atomic updates and rollback, no configuration management to
  maintain day to day.
- Against: Flatcar on Proxmox is community-supported [F1], and its newest NVIDIA
  branch is 570 [F5]. FCOS has no official NVIDIA path, so uCore would be a
  community dependency [R7]. Every config change is a rebuild, which requires that
  all state live outside the system disk. Possibly a fit for stateless VMs (Runner,
  Platform) inside a mixed fleet, at the cost of two models.

### Cross-option add-ons

- Packer for a pre-baked GPU VM image (section 5.4).
- PCI and directory resource mappings so that the automation token needs no
  `root@pam` (section 5.3).
- A separate data disk or virtiofs share per VM, so that "rebuild" never touches
  Compose volumes (inference). Note the virtiofs limits from the host-layer note: no
  RAM snapshots or migration, and a hung mount if virtiofsd crashes [P5].

## 10. Pitfalls

- Public mirror: the answer file, cloud-init user data, Butane files and OpenTofu
  variables all tend to collect passwords, tokens and IPs. They need placeholders and
  a secret source (see the secrets research branch). OpenTofu state never goes in git
  unencrypted [O2].
- bpg's snippet upload over SSH needs a precise sudoers rule. A wildcard rule is a
  privilege escalation [B6]. The new `proxmox_cloudinit_bootstrap` avoids SSH but is
  brand new [B9].
- `ciupgrade` defaults to 1, so first boot upgrades packages and can reboot [P2]. That
  is fine for patching, but it makes the first boot of a rebuild slower and less
  reproducible.
- A DKMS driver (Debian with NVIDIA's repo) rebuilds on every guest kernel update. A
  failed build leaves the GPU VM without CUDA until fixed (inference from DKMS
  behaviour; the host-layer note documents the same coupling for the host).
- Pin the provider version (`required_providers`), and read the changelog before each
  bump: bpg is 0.x [B1][B4].
- Telmate's long RC phase means the docs and the latest release can disagree (2023 is
  the last stable release) [T2].

## 11. Not covered

- Talos Linux and k3s-style OSes: Kubernetes-only, while ADR 0001 keeps Docker
  Compose.
- Proxmox Backup Server, and how VM backups interact with rebuilds (see the backup
  research branch).
- How the eight Docker hosts receive their Compose stacks (see the gitops-deploy
  research branch).
- Measured RAM numbers: to take with `free -m` and `smem` on the real VMs.

## Sources

Proxmox VE
- [P1] Automated Installation, Proxmox wiki: https://pve.proxmox.com/wiki/Automated_Installation
- [P2] Cloud-Init Support, Proxmox wiki: https://pve.proxmox.com/wiki/Cloud-Init_Support
- [P3] Admin guide, System Software Updates: https://pve.proxmox.com/pve-docs/chapter-sysadmin.html
- [P4] Admin guide, Resource Mapping: https://pve.proxmox.com/pve-docs/chapter-qm.html
- [P5] Admin guide, PCI passthrough and virtiofs: https://pve.proxmox.com/pve-docs/pve-admin-guide.html
- [P6] PCI Passthrough, Proxmox wiki: https://pve.proxmox.com/wiki/PCI_Passthrough
- [P7] Admin guide, VM Memory (ballooning, 1 GB rule of thumb): https://pve.proxmox.com/pve-docs/chapter-qm.html
- [P8] Admin guide, Kernel Samepage Merging: https://pve.proxmox.com/pve-docs/pve-admin-guide.html

bpg/proxmox provider
- [B1] README: https://github.com/bpg/terraform-provider-proxmox/blob/main/README.md
- [B2] Releases (GitHub API, read 2026-11-26): https://github.com/bpg/terraform-provider-proxmox/releases
- [B3] Resource docs index: https://github.com/bpg/terraform-provider-proxmox/tree/main/docs/resources
- [B4] CHANGELOG: https://github.com/bpg/terraform-provider-proxmox/blob/main/CHANGELOG.md
- [B5] `virtual_environment_download_file` and `virtual_environment_vm` (`import_from`): https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/virtual_environment_download_file.md
- [B6] Provider docs (requirements, authentication, root@pam operations, SSH, sudoers): https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/index.md
- [B7] `virtual_environment_vm` (`hostpci`): https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/virtual_environment_vm.md
- [B8] `proxmox_vm` (experimental): https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/vm.md
- [B9] `proxmox_cloudinit_bootstrap`: https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/cloudinit_bootstrap.md
- [B10] `proxmox_hardware_mapping_pci`: https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/hardware_mapping_pci.md

Telmate/proxmox provider
- [T1] README: https://github.com/Telmate/terraform-provider-proxmox/blob/master/README.md
- [T2] Releases and resource docs: https://github.com/Telmate/terraform-provider-proxmox/releases, https://github.com/Telmate/terraform-provider-proxmox/tree/master/docs/resources
- [T3] Provider docs (PVE 9 privileges): https://github.com/Telmate/terraform-provider-proxmox/blob/master/docs/index.md
- [T4] `vm_qemu` (PCI block): https://github.com/Telmate/terraform-provider-proxmox/blob/master/docs/resources/vm_qemu.md

Packer, OpenTofu, Ansible, cloud-init, Docker
- [K1] Packer Proxmox plugin (builders, releases): https://github.com/hashicorp/packer-plugin-proxmox
- [K2] Packer licence (BUSL): https://github.com/hashicorp/packer/blob/main/LICENSE
- [O1] Docker Engine install, Debian / Ubuntu: https://docs.docker.com/engine/install/debian/, https://docs.docker.com/engine/install/ubuntu/
- [O2] OpenTofu state and plan encryption: https://opentofu.org/docs/language/state/encryption/
- [A1] community.proxmox collection (modules, inventory plugin, README): https://github.com/ansible-collections/community.proxmox
- [C1] cloud-init module reference: https://docs.cloud-init.io/en/latest/reference/modules.html

Debian and Ubuntu
- [D1] Debian wiki, NvidiaGraphicsDrivers: https://wiki.debian.org/NvidiaGraphicsDrivers
- [D2] Debian wiki, UnattendedUpgrades: https://wiki.debian.org/UnattendedUpgrades
- [D3] Debian cloud images: https://cloud.debian.org/images/cloud/
- [D4] Debian 13 installation guide, minimum requirements: https://www.debian.org/releases/trixie/amd64/ch03s04.en.html
- [U1] Ubuntu Server docs, NVIDIA drivers: https://ubuntu.com/server/docs/how-to/graphics/install-nvidia-drivers/
- [U2] Ubuntu Server docs, automatic updates: https://ubuntu.com/server/docs/how-to/software/automatic-updates/
- [U3] Ubuntu 26.04 LTS release notes: https://documentation.ubuntu.com/release-notes/26.04/

NVIDIA
- [N1] Driver Installation Guide, Debian: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/debian.html
- [N2] Driver Installation Guide, introduction (supported distributions and kernels): https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/introduction.html
- [N3] Container Toolkit, install guide, platform support, release notes: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html, https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/supported-platforms.html
- [N4] Driver Installation Guide, kernel modules and compute-only install: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/kernel-modules.html, https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/compute-only-and-desktop-installation.html

NixOS
- [X1] nixos-generators (deprecated, upstreamed as `nixos-rebuild build-image`): https://github.com/nix-community/nixos-generators
- [X2] nixpkgs `proxmox-image.nix` (nixos-26.05): https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/virtualisation/proxmox-image.nix
- [X3] nixos-anywhere README: https://github.com/nix-community/nixos-anywhere
- [X4] nixpkgs `nvidia.nix` (`hardware.nvidia.open`): https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/hardware/video/nvidia.nix
- [X4b] nixpkgs `nvidia-container-toolkit` module: https://github.com/NixOS/nixpkgs/tree/nixos-26.05/nixos/modules/services/hardware/nvidia-container-toolkit
- [X5] nixpkgs `auto-upgrade.nix` (`system.autoUpgrade`): https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/tasks/auto-upgrade.nix
- [X7] proxmox-nixos README: https://github.com/SaumonNet/proxmox-nixos

Flatcar
- [F1] Flatcar on Proxmox VE: https://www.flatcar.org/docs/latest/deploy/virt-options/proxmoxve/
- [F2] Flatcar system extensions: https://www.flatcar.org/docs/latest/sys-ext/
- [F3] Using NVIDIA GPUs on Flatcar: https://www.flatcar.org/docs/latest/os-config/host-config/using-nvidia/
- [F4] Flatcar update strategies: https://www.flatcar.org/docs/latest/updates-releases/releases/update-strategies/
- [F5] Flatcar stable release files (version.txt, sysext list): https://stable.release.flatcar-linux.net/amd64-usr/current/

Fedora CoreOS and Ignition
- [R1] FCOS docs, auto-updates and rollbacks: https://github.com/coreos/fedora-coreos-docs/blob/main/modules/ROOT/pages/auto-updates.adoc
- [R2] FCOS docs, provisioning on Proxmox VE: https://github.com/coreos/fedora-coreos-docs/blob/main/modules/ROOT/pages/provisioning-proxmoxve.adoc (published at https://docs.fedoraproject.org/en-US/fedora-coreos/provisioning-proxmoxve/)
- [R3] FCOS docs, platforms: https://github.com/coreos/fedora-coreos-docs/blob/main/modules/ROOT/pages/platforms.adoc
- [R4] FCOS docs, FAQ: https://github.com/coreos/fedora-coreos-docs/blob/main/modules/ROOT/pages/faq.adoc
- [R5] FCOS docs, installing Docker CE: https://github.com/coreos/fedora-coreos-docs/blob/main/modules/ROOT/pages/docker-ce.adoc
- [R6] FCOS docs, OS extensions (layering): https://github.com/coreos/fedora-coreos-docs/blob/main/modules/ROOT/pages/os-extensions.adoc
- [R7] uCore images: https://projectucore.org/docs/images/, https://github.com/ublue-os/ucore
- [I1] Ignition README (Butane transpiling): https://github.com/coreos/ignition
- [I2] Ignition rationale ("runs only on the first boot"): https://github.com/coreos/ignition/blob/main/docs/rationale.md
- [I3] Ignition supported platforms (Proxmox VE): https://github.com/coreos/ignition/blob/main/docs/supported-platforms.md
