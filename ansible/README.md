# Ansible — host configuration

Describes what lives on the server itself, outside Docker: users, network, disks, SSH, firewall, Docker, Samba and the maintenance crons. With the stacks in this repo and the data in the backup, it is what rebuilds the server from a fresh Ubuntu install.

The playbook runs on the server against itself (`ansible_connection: local`), so there is no SSH setup.

## Roles

| Role | Covers |
|---|---|
| `base` | Hostname, timezone, `media` user and group, groups of the admin user, static address (netplan), data disk mounted by UUID, swap file, SSH hardening, unattended upgrades |
| `security` | ufw (default policies; SSH, Samba and Webmin from the trusted networks; Plex), the sudoers rule and the restricted `authorized_keys` entry of the CI deploy key |
| `docker` | Docker's apt repository for the running Ubuntu release, the engine and compose plugin (installed, never upgraded by the playbook: an engine upgrade restarts every container), the admin user in the `docker` group |
| `samba` | `smb.conf` with the shares from `samba_shares`. Samba passwords are not managed: `sudo smbpasswd -a <user>` after a fresh install |
| `maintenance` | SMART monitoring with scheduled self-tests, Webmin and its repository, and the maintenance scripts' schedule in `/etc/cron.d/homelab-infra`, their output going to the journal (`journalctl -t <script>`) |

The ufw rules only list services listening on the host itself: ports published by Docker bypass ufw (Docker's iptables rules come first), so a rule for them would have no effect. The `ufw` module only adds rules, it never removes the ones it does not know.

Tags select a part of the playbook: one per role (`base`, `security`, `docker`, `samba`, `maintenance`), plus `firewall`, `deploy_key`, `smart`, `webmin` and `cron`. On a fresh install the deploy key is generated again: put the new private key in the `DEPLOY_SSH_KEY` CI/CD variable (root README, "One-time setup of the deploy on merge").

## Setup

```bash
sudo apt install ansible                     # bundles community.general and ansible.posix
cp host_vars/homelab.yml.example host_vars/homelab.yml
```

Fill in `host_vars/homelab.yml`. It is gitignored because the repo is mirrored publicly: addresses, disk UUIDs and account names stay out of git. It is still backed up, since `docker_backup.sh` copies the whole `homelab-infra/` directory, ignored files included.

With `ansible-core` instead of the Ubuntu package: `ansible-galaxy collection install -r requirements.yml`.

## Running

```bash
cd ansible
ansible-playbook site.yml --check --diff -K   # show what would change, change nothing
ansible-playbook site.yml -K                  # apply
```

The playbook describes the server as it is: on the running server, `--check --diff` must report `changed=0`. A change in it means the server drifted from the description (something was edited by hand) or the description is wrong; fix one or the other before applying.

## Rebuilding the server

1. Install Ubuntu Server 24.04, with the admin account
2. Clone the repo from the public GitHub mirror (GitLab runs on this server, so it is gone with it)
3. Restore `host_vars/homelab.yml`, the stacks' `.env` files and `~/.config/rclone/rclone.conf` from the backup
4. `ansible-playbook site.yml -K`
5. Restore the Docker volumes and data directories from the backup, then start the stacks
