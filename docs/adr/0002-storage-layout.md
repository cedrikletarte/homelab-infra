# The host boots from an NVMe mirror and keeps all data on one RAIDZ2 pool

- **Date:** 2026-11-26
- **Status:** Accepted

## Context

ADR 0001 makes the Proxmox host the owner of every ZFS pool. The disks available are
four 8 TB IronWolf drives (three new from one purchase, one older, all ST8000VN004),
two 1 TB NVMe drives without power-loss protection, and a 500 GB SATA SSD. The host
has 64 GB of RAM shared with eight VMs.

Today's data: about 26 GB of irreplaceable data (photos, files, passwords, forge,
databases) and about 4 TB of re-downloadable media, expected to stay under 10 TB
within five years. The existing 4.5 TB is backed up elsewhere before the cutover, so
the pool is built on four empty disks. Buying disks is the expensive part of growing,
so adding space one disk at a time matters.

## Decision

- **Boot and VM disks:** Proxmox is installed with the installer's ZFS RAID1 on both
  NVMe drives, used whole. The host boots from either drive. Every VM disk (guest OS,
  Docker data, databases, thumbnails) lives on this pool. No special vdev, L2ARC or
  SLOG.
- **HDD pool:** one RAIDZ2 vdev of the four 8 TB drives (about 14 TiB usable). It
  survives any two disk failures and grows one disk at a time through RAIDZ expansion.
- **Datasets on the HDD pool**, created with their properties before any data is
  restored (`recordsize` only applies at write time):

  | Dataset | Holds | Properties | Mounted in |
  |---|---|---|---|
  | `media` | libraries and finished downloads, together so hardlinks work | `recordsize=1M` | Media VM (read-write), GPU VM (read-only) |
  | `media-incomplete` | torrents in progress, moved into `media` when finished | `recordsize=16K` | Media VM |
  | `immich` | photo originals | `recordsize=1M` | Personal Data VM |
  | `nextcloud` | user files | default | Personal Data VM |
  | `samba` | the file share | default | Samba LXC |

  All datasets use `compression=lz4` and `atime=off`.
- **Personal data split:** files live in host datasets on the HDD pool; the databases,
  thumbnails and small stores (passwords) stay in the Personal Data VM's disk on NVMe.
- **Quota:** the media branch (`media` and `media-incomplete`) gets a quota that keeps
  about 15% of the pool free, raised at each expansion, so downloads can never fill the
  pool under the photos and files.
- **ARC:** the Proxmox installer default, 10% of RAM (about 6.4 GiB on 64 GB).
- **No encryption at rest.** A failed disk is destroyed instead of being sent back
  under warranty.
- **The SATA SSD leaves the new server.**

## Consequences

- Nothing can ever be removed from the HDD pool. It only grows, by adding disks.
  Blocks written before an expansion keep the 2:2 data-to-parity ratio until rewritten.
- A resilver reads every HDD and takes from a few hours to about 14 hours near full.
- Reinstalling the host wipes the NVMe pool and therefore every VM disk: VM backups
  must be restorable, and the host's VM definitions (`/etc/pve`) must be backed up or
  declarative.
- The installer computes the ARC cap once, at install time: the host is installed with
  64 GB in place, or the cap is set explicitly in the answer file.
- The read-only mount of `media` in the GPU VM needs a mechanism that supports it
  (virtiofs has no read-only option).
- Pool fill and the media quota need alerts.
- The SATA SSD is free for the old server.

## Alternatives rejected

- **Two 2-way mirrors:** same capacity, faster resilvers, more IOPS and removable
  vdevs, but growing takes two disks at a time and two failures in the same pair lose
  the pool. With databases on NVMe, the extra IOPS are not needed.
- **RAIDZ1:** about 21 TiB, more space than needed, and one failure of tolerance for
  irreplaceable photos on three disks from the same batch.
- **Boot from the SATA SSD alone:** a host reinstall would leave the VM pool intact,
  but reinstalls are rare (Proxmox upgrades in place) and the boot disk would be a
  single point of failure.
- **Photos and files inside the VM disk on NVMe:** consistent VM snapshots and no
  shared mount, but personal files would compete with VM disks for 1 TB and lose
  file-level snapshots and restores on the host.
- **A second VM disk (zvol) on the HDD pool for personal files:** slow on HDDs and no
  file-level snapshots or restores on the host.
- **Special vdev, L2ARC, SLOG on the NVMe drives:** a lost special vdev loses the whole
  pool and is permanent on RAIDZ; L2ARC costs ARC memory and does not help sequential
  media reads; SLOG is useless once databases live on NVMe.
- **Native ZFS encryption:** the key must load at every boot, which either needs a
  person at the console or a key file on the boot pool that defeats theft protection.
  Off-site backups are encrypted on their own.
