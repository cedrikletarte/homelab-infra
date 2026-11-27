# The new server runs Proxmox VE, with Docker only inside one VM per role

- **Date:** 2026-11-26
- **Status:** Accepted

## Context

The new server (Ryzen 9 3900X, no integrated GPU, one RTX 2080 Ti, 4x 8 TB disks,
two NVMe, one SATA SSD) replaces a single Ubuntu + Docker + Ansible host. That host
has no isolation between workloads: CI jobs holding the Docker socket, torrent
traffic, Internet-facing services and critical personal data all share one kernel
and one Docker daemon, and a GitLab upgrade or a memory spike hits everything at once.

The goals for the new host layer: isolation between workloads, VM-level snapshots and
backups, room to experiment in a fresh VM without touching the rest, and Docker
Compose staying the unit of deployment.

## Decision

- **Hypervisor:** Proxmox VE (9.x) on bare metal. The host runs Proxmox, ZFS and
  guests only; it runs no Docker workloads.
- **Docker only inside VMs:** every Docker daemon lives in a QEMU VM. Docker inside
  LXC is not used (not recommended by Proxmox, and broken once already by a runc
  security fix). LXC is allowed only for small non-Docker services that need direct
  access to a host dataset, such as the Samba share.
- **ZFS is owned by the host:** the host holds every pool; VMs get virtual disks, and
  shared datasets are mounted into the VMs that need them. No NAS VM, no SATA
  controller passthrough.
- **GPU:** the 2080 Ti is passed through (VFIO) to a single GPU VM. With no
  integrated GPU, only one VM can own it, so every GPU consumer lives there.
  Experiment VMs never get the GPU.
- **One VM per role.** A workload gets its own VM only when at least one of these
  holds; otherwise it joins an existing VM:
  1. it has a different exposure or trust level (Internet-facing, untrusted code,
     torrent traffic);
  2. it is a failure domain that must survive the others;
  3. it owns a piece of hardware;
  4. it has its own lifecycle or backup policy.
- **Initial topology:**

  | VM | Holds | Criterion |
  |---|---|---|
  | Platform | Platform Infrastructure: tunnel, DDNS, reverse proxy, intrusion prevention, VPN Server, local DNS | 1, 2 |
  | Monitoring | Metrics, dashboards, alerting | 2 |
  | Forge | The forge (repositories, registry) | 4 |
  | Runner | CI runners; holds no data and is rebuilt at will | 1 |
  | Media | VPN-tunneled downloads and the *arr automation | 1, 4 |
  | Personal Data | Photos, files, passwords (Immich server and database, Nextcloud, Vaultwarden) | 4 |
  | GPU | Media server, photo machine learning, local LLM | 3 |
  | Services | Everything else (automation, dashboard, search, portfolio) | none (the remainder) |

- **Memory:** the server goes to 64 GB before it enters service. The topology
  reserves about 52 GB (host, ARC and the eight VMs); the GPU VM's memory is pinned by
  VFIO and cannot be ballooned.
- **Automation:** creating, configuring and updating the VMs is automated. With eight
  guests, hand-maintained VMs would recreate the home-made scripts this effort
  replaces. The guest OS and the tooling are a separate decision.

## Consequences

- IOMMU groups must be dumped on the final BIOS before the GPU passthrough is relied
  on, and re-checked after every BIOS update.
- The reverse proxy can no longer discover services through Docker labels in other
  VMs: routing across VMs needs file-based rules or a proxy per VM.
- The deployment mechanism must target eight Docker hosts, not one.
- The media library is mounted in both the Media VM (read-write, with downloads on the
  same dataset so hardlinks keep working) and the GPU VM (read-only).
- The photo service splits across two VMs: its server and data in Personal Data, its
  machine learning in the GPU VM, reached over the network.
- A database shared by several stacks now crosses VM boundaries.
- Two OS layers to patch: the Proxmox host and every guest.
- The ZFS ARC must be capped deliberately; it competes with the guests for the 64 GB.

## Alternatives rejected

- **Ubuntu 26.04 LTS or Debian 13 + Docker + Ansible on bare metal:** lowest memory
  cost and the smallest change from today, but no isolation between workloads, no
  VM-level snapshots, and nowhere to experiment without touching production.
- **NixOS + Docker on bare metal:** best declarative host and rollback, but still one
  kernel and one Docker daemon for everything, so none of the isolation goals.
- **TrueNAS Community Edition:** locks the host and manages Docker through its
  middleware, and cannot give a VM the only GPU (it needs two).
- **TrueNAS in a VM on Proxmox:** needs SATA controller passthrough (all ports hang
  off the chipset, possibly with the boot disk), a fifth VM with 8 to 16 GB pinned,
  and a boot-order dependency where every other VM mounts its data over NFS. The only
  gain is a ZFS UI.
- **Unraid:** paid, configured through GUI state, and relies on community plugins for
  Compose and NVIDIA, with a platform change announced for 8.x.
- **Proxmox with Docker in LXC sharing the GPU through the host driver:** saves memory,
  but it is a setup Proxmox advises against and has already broken, and it ties the
  NVIDIA driver to the fast-moving Proxmox kernel.
- **Fewer VMs (one Docker VM, or platform + applications):** cheaper in memory and
  upkeep, but it keeps CI jobs, torrents and critical data in the same failure and
  trust domain.
