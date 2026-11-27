# Research: secrets management for a publicly mirrored infrastructure repo

Date: 2026-11-26
Status: research notes, no decision taken

## Question

How should the stack secrets (Compose environment variables, keys, tokens) of this repo be managed, given that
the repo is mirrored to a public GitHub repository? Options considered: SOPS + age, Ansible Vault, Infisical,
Bitwarden Secrets Manager (and whether the Vaultwarden instance already running can serve it), OpenBao/Vault,
Docker secrets, and the current gitignored `.env` files backed up out of band. Cross-cutting concerns: the risk
of committing encrypted secrets to a public repo ("harvest now, decrypt later", metadata leaks), key rotation,
integration with a Docker Compose GitOps tool (Komodo, Doco-CD, Portainer) and with GitLab CI, and cold restore
when the host that runs the secrets manager is down.

## Short answer

- **Vaultwarden does not support Bitwarden Secrets Manager and will not.** The maintainers closed the question
  in July 2026: "It's not on the roadmap and probably never will be due to licensing issues" and "this would not
  get implemented into Vaultwarden" [S1]. Vaultwarden can still hold secrets as ordinary vault items read
  through the `bw` CLI or a REST sidecar (Doco-CD documents this) [S2], but that needs a master password on
  the server.
- **Self-hosting real Bitwarden Secrets Manager requires an Enterprise organization** [S3]. The cloud Free plan
  (2 users, 3 projects, 3 machine accounts) is the only no-cost way to use it [S4], and it puts the secrets with
  a third party.
- **SOPS + age is the option that fits the "secrets in git" model best**: values are encrypted, file
  structure stays diffable, Ansible (`community.sops`) and Doco-CD read it natively, and the public mirror
  becomes an off-site copy of the encrypted secrets. Its upstream threat model still says "we recommend that
  users keep their encrypted files reasonably private" [S5]. Key names, value lengths and change history are
  public, and a leaked age key exposes every value still in git history.
- **Harvest now, decrypt later can be mitigated**: age 1.3 added hybrid post-quantum recipients
  (ML-KEM-768 + X25519, `age1pq1...`) [S6], and SOPS 3.12+ accepts them [S7]. SOPS keeps one key slot per
  recipient, so a single classic recipient on the same file cancels the protection.
- **Server-based managers (Infisical, OpenBao) keep secrets out of git** but bring a database or seal/unseal
  operations, and create a bootstrap problem on cold restore when they run on the host they serve.
- **Ansible Vault is the weakest fit for a public repo**: it is password based (PBKDF2-SHA256 with a fixed
  10,000 iterations, still the value in `devel`) [S8][S9], and hashcat has a dedicated mode for it [S10].
  An offline brute-force attack therefore depends only on how strong the password is.

## 1. Baseline (current setup)

What the repo does today (from the repo itself):

- Real values live in gitignored files (`.env`, `wg0.conf`, `middlewares.yml`, `traefik.yml`, SearXNG
  `settings.yml`, CrowdSec `http.yaml`, Ansible `host_vars`). Each has a committed `*.example` template.
- CI runs `docker compose config` against the examples, runs `gitleaks git` on the whole history, and keeps its
  own secrets (deploy SSH key, Renovate and GitHub tokens) as GitLab CI/CD variables.
- The deploy fast-forwards the server clone and runs `docker compose up -d`. Backups (tar of volumes, rclone crypt
  to OneDrive) cover the `.env` files only as far as they are included in the archive.

Strengths: nothing secret is ever in git, so the public mirror leaks nothing (apart from operator mistakes, which
gitleaks catches). Weaknesses: the files are not versioned, so there is no history or review of secret changes.
The server is their single source of truth, with only a weekly copy. Rebuilding a host means copying files by
hand, and a GitOps tool that deploys from git cannot produce them.

## 2. Risks of committing encrypted secrets to a public repo

### 2.1 Permanence

Once pushed and mirrored, ciphertext cannot be withdrawn: forks, caches and clones keep it. Every later
weakness therefore applies to the whole history:

- **Key compromise.** Rotating the encryption key protects new commits only. SOPS documents the order of
  operations after a compromised key (`sops updatekeys`, then `sops rotate`) and notes that a removed key "may
  have access to the data key in the past" [S11]. The old commits stay readable with the old key, so after
  a key leak every secret value that was ever committed must itself be changed, not just re-encrypted. Doco-CD
  makes the same point from the deploy side: "Revoking a key does not take effect for unchanged files" [S12].
- **Weak passphrase-based schemes.** Ansible Vault derives its key from a password with PBKDF2-SHA256 and a hard
  coded 10,000 iterations [S8][S9]. OWASP recommends 600,000 for that function [S13], and hashcat ships mode
  16900 for Ansible Vault [S10]. A public repo hands attackers unlimited offline guesses.

### 2.2 Harvest now, decrypt later

SOPS encrypts each value with AES-256-GCM under a per-file data key. The data key is then encrypted to each
master key (age, PGP, KMS) [S5][S14]. AES-256 is not the weak point. The asymmetric wrapping is: classic age
recipients (X25519) and SSH recipients could be broken by a future quantum computer, and then every archived
copy of the repo opens.

Mitigation available today:

- age 1.3.0 added native hybrid post-quantum recipients (ML-KEM-768 combined with X25519), generated with
  `age-keygen -pq`. Recipients start `age1pq1...` and are about 2,000 characters long [S6][S15].
- SOPS 3.12.0 added "support hybrid post-quantum identities" [S7]. The current source parses `age1pq1` recipients
  and `AGE-SECRET-KEY-PQ-1` identities [S16], and the latest release is v3.13.3 (2026-07-23).
- Pitfall: the `age` tool itself refuses to mix classic and post-quantum recipients in one file ("or the file
  would be vulnerable to quantum computers") [S17]. SOPS does not have that guard: it stores one age master key
  per recipient and encrypts the data key to each separately [S16]. Adding a classic recipient (for example an
  SSH key for convenience) next to a PQ one silently reopens the harvest-now path.
- Pitfall: the default gitleaks rule only matches classic `AGE-SECRET-KEY-1...` keys [S18]. A leaked PQ identity
  (`AGE-SECRET-KEY-PQ-1...`) would not be caught without a custom rule.

### 2.3 Metadata that stays in clear

With SOPS on structured files (dotenv, YAML, JSON, INI):

- **Key names are in clear.** The design states "We expect that keys do not carry sensitive information, and
  keeping them in cleartext allows for better diff and overall readability" [S14]. A public reader learns which
  services exist, which providers are used (`CLOUDFLARE_API_TOKEN`, `PIA_USER`...), and how stacks are wired.
- **Value lengths leak.** GCM is a stream mode and SOPS calls `gcm.Seal` with no padding [S19], so ciphertext
  length equals plaintext length. A short password and a 64-character token can be told apart.
- **Timing and recipients.** The `sops` metadata block holds a `lastmodified` timestamp and the recipients' public
  keys [S14]. Git history adds exactly when each secret changed.
- **Comments** are encrypted by default [S20].
- Mitigation: encrypting a whole file as `binary` stores everything under a single `data` key [S21]. The names
  are hidden, but diffs become unreadable and per-key tooling (Doco-CD format detection, `exec-env`) changes.
  Ansible Vault offers the same choice: `encrypt_string` keeps names visible, and whole-file encryption hides
  "not only sensitive values but the names of the variables you use" [S22].

### 2.4 Context

These risks only apply to the options that put ciphertext in git (SOPS, Ansible Vault). Server-based managers
and gitignored files leak no ciphertext. Their risks are availability and bootstrap (section 6).

## 3. Options

### 3.1 Gitignored `.env` + backup (current)

- Fits Compose natively. No new tooling.
- Rotation: edit the file and `up -d`. No audit trail.
- GitOps: Komodo, Portainer and Doco-CD can each hold these values in their own store instead (section 4), which
  moves the "source of truth" into that tool's database.
- Cold restore: depends entirely on the backup containing the files and on the rclone crypt password being
  available off the server.

### 3.2 SOPS + age

- Project: CNCF Sandbox (donated by Mozilla in 2023), MPL-2.0, v3.13.3 latest [S23]. Formats: YAML, JSON, ENV
  (dotenv), INI, binary [S23].
- Mechanics: `.sops.yaml` `creation_rules` select recipients per path. `sops edit` for changes,
  `sops updatekeys` to change recipients, `sops rotate` to renew the data key ("Running `sops rotate`
  periodically is recommended anyways") [S11].
- Compose integration without a GitOps tool: `sops exec-env file 'docker compose up -d'` places the values only in
  the child's environment, "never written to disk", and can drop privileges with `--user` [S24]. Alternatively
  decrypt to a gitignored `.env` at deploy time.
- Key on the server: default `~/.config/sops/age/keys.txt`, or `SOPS_AGE_KEY_FILE`, `SOPS_AGE_KEY`,
  `SOPS_AGE_KEY_CMD` (a command that prints the key, which can fetch it from elsewhere) [S25]. SSH ed25519/RSA keys
  can also be recipients [S25] (classic crypto only, see 2.2).
- Ansible: `community.sops` 2.5.1 has a vars plugin, a lookup and `load_vars`, so host variables and stack secrets
  could share one mechanism [S26].
- CI: the existing `compose-config` job needs no key, because the dotenv key names are in clear. Only the server
  (and the operator's workstation) need the private key, and the self-hosted GitLab never needs it.
- Strengths: versioned, reviewable diffs of which keys changed, offline tooling, no server to run. The public
  mirror is an off-site copy of the ciphertext.
- Weaknesses: metadata leaks (2.3), permanence (2.1), upstream advises keeping files "reasonably private" [S5].
  Recent releases also had MAC regressions (3.13.2 computed a wrong MAC for YAML lists with comments, fixed in
  3.13.3) [S7], so pin and test the version, which Renovate can handle.

### 3.3 Ansible Vault

- AES256 is the only cipher (AES-CTR + HMAC-SHA256), with the key derived by PBKDF2 at 10,000 iterations [S8][S9].
- `encrypt_string` variables "cannot be rekeyed" with `ansible-vault rekey`. Whole files can [S22].
- Compose integration only through Ansible templating `.env` files on the host, so every secret change becomes
  an Ansible run instead of a git-driven Compose deploy. No GitOps tool reads it.
- Main risk for a public repo: the security of all committed secrets equals the strength of one password (2.1).

### 3.4 Docker Compose secrets

- Not a secret store: a delivery mechanism. Secrets are mounted at `/run/secrets/<name>`. In plain Compose the
  source is a host file or a host environment variable ("only supported by Docker Compose") [S27][S28].
- Docker's own guidance: environment variables "risk unintentional information exposure" and "are often
  available to all processes" [S27]. The `_FILE` convention is supported by some images (Docker docs name
  MySQL and PostgreSQL) [S27].
- Combines with any option above: SOPS, Infisical or OpenBao produce the file, and Compose mounts it. Useful for
  the shared PostgreSQL and other `_FILE`-aware images, irrelevant for images that only read env vars.

### 3.5 Vaultwarden (already running)

- Vaultwarden implements the Bitwarden client API (personal vault, organizations, collections, personal API key...)
  [S29]. **Secrets Manager is not supported, and the maintainers say it will not be** (licensing, test burden),
  pointing instead to `bw serve` and tools built on the `bw` CLI [S1].
- Usable path: a dedicated Vaultwarden account or organization collection holding "secret" items, read by the
  `bw` CLI or by Doco-CD's documented webhook provider with the `bitwarden-rest-api-server` sidecar. That sidecar
  needs `BW_CLIENTID`, `BW_CLIENTSECRET` **and `BW_PASSWORD` (the master password)** on the server [S2].
- Weaknesses: a master password stored on the server unlocks the whole account (so a dedicated low-privilege
  account is mandatory). There is no machine-account scoping. Vaultwarden runs on the same host as the stacks it
  would feed, so it is a circular dependency at boot (it would need its own secrets from elsewhere).
- Strength for cold restore: "Any unlocked Bitwarden app can be used offline in read-only mode", including when
  the self-hosted server is unreachable [S30]. A human can read bootstrap secrets from a phone or laptop while
  the server is down.

### 3.6 Bitwarden Secrets Manager (upstream)

- Machine accounts, projects, `bws run` to inject secrets as environment variables, `bws config server-base` for
  self-hosted servers [S31]. The CLI keeps encrypted state files with tokens, but no offline mode is documented
  [S31].
- Self-hosting: "Enterprise organizations can self-host Bitwarden Secrets Manager" [S3]. Enterprise is USD 12 per
  user per month, and the cloud Free tier allows 2 users, 3 projects and 3 machine accounts [S4].
- Doco-CD has a native Bitwarden Secrets Manager provider [S32].
- Trade-off: free only as a cloud service (third-party dependency, internet required at deploy), or a paid
  self-host that runs the full Bitwarden server next to (or instead of) Vaultwarden.

### 3.7 Infisical

- Core is MIT. Code under `ee/` is under a commercial license, and some features need a license key
  [S33][S34]. Version line v0.167.x in November 2026.
- Self-hosting needs PostgreSQL (tested on 16, 14+ recommended) and Redis 6/7, which Infisical treats as a
  "required, persistent datastore" with `noeviction` [S35]. Sizing guidance starts at 2 cores / 4 GB per
  container [S35]. Minimum config includes `ENCRYPTION_KEY` and `AUTH_SECRET` [S36], which must be backed up
  separately from the database.
- Compose: `infisical run -- docker compose up -d` or fetch at container start [S37]. The CLI reuses previously
  fetched secrets when offline. `infisical login`/`logout` wipes that cache [S38]. An "Infisical Proxy" can also
  cache and serve secrets while Infisical is unreachable [S39].
- Doco-CD has a native Infisical provider [S32].
- Strengths: good UI, environments, audit log, versioning. Weaknesses: one more stateful app (and Redis) to run,
  upgrade and back up, for a single-operator homelab.

### 3.8 OpenBao (Vault fork)

- Linux Foundation fork of HashiCorp Vault, v2.7.3 (2026-11-19) [S40].
- "When an OpenBao server is started, it starts in a sealed state", and it must be unsealed again after every
  restart. The default is a Shamir seal [S41]. Auto-unseal needs a KMS, transit, or the built-in "static" seal,
  whose docs warn to "carefully evaluate" it and recommend it mainly when chaining to another trusted secret
  store [S42]. Recovery keys "cannot decrypt the root key" [S41].
- Compose integration via OpenBao Agent templates or a CLI fetch before `up`. Doco-CD has a native OpenBao
  provider [S32]. SOPS can also use OpenBao transit as a master key [S43].
- GitLab note: the GitLab Secrets Manager is built on OpenBao and has been GA since 19.5, but it is **Premium
  or Ultimate only** [S44]. It is not available on an unlicensed EE instance.
- Strengths: dynamic secrets, leases, policies, audit. Weaknesses: the most operations of all the options
  (unseal on every reboot, or an auto-unseal that moves the root of trust elsewhere). Most of its features
  (dynamic DB credentials, PKI) go beyond what a Compose homelab uses.

## 4. GitOps tool integration (Docker Compose)

| Tool | Native SOPS | External secret managers | Where secrets otherwise live |
|---|---|---|---|
| Doco-CD (v0.138.0) | Yes: decrypts every SOPS file in the fetched revision (content-based detection, age recommended, key via `SOPS_AGE_KEY_FILE` as a Docker secret) [S12] | Bitwarden SM, Bitwarden Vault/Vaultwarden (via webhook sidecar), Infisical, OpenBao, 1Password, AWS, Azure, generic webhook [S32] | `.env` on the host. External secrets override `.env` values [S32] |
| Komodo (v2.3.x) | No. Community PR #1053 adding sops/age to Periphery is still open (Nov 2026), and users run a pre-deploy decrypt step [S45] | None built in. Docs say to use "a dedicated secret management tool" alongside and admit it is "not intended as an enterprise level secret management solution" [S46] | Variables/secrets in the Komodo DB (masked for non-admins), or `[secrets]` in the Core or Periphery config file, interpolated with `[[KEY]]` [S46] |
| Portainer | Not documented [S47] | Not documented | Stack environment variables stored in Portainer, or an uploaded `.env`. The compose file keeps `${VAR}` placeholders [S47] |
| Current script | Possible with `sops exec-env` or decrypt to `.env` before `up -d` [S24] | Possible with `infisical run`, `bws run` or `bao` CLI | Host `.env` |

Doco-CD caveats from its docs: unchanged encrypted files reuse cached plaintext, so revoking a key does not
affect them. A file with no matching key is left encrypted and fails only when used. Missing-key messages are
logged at debug level [S12].

## 5. CI integration (self-hosted GitLab)

- GitLab CI/CD variables are encrypted in the GitLab database, and masking "is not a guaranteed way to prevent
  malicious users from accessing variable values". "Masked and hidden" variables cannot be shown again in the UI
  [S48]. This remains the right place for CI-only credentials (deploy key, Renovate token).
- With SOPS, CI can validate stacks without any decryption key (key names are in clear), and Renovate does not
  touch encrypted files. The decryption key stays off GitLab, which matters because GitLab runs on the same
  host it deploys to.
- With a server-based manager, CI would only need a machine identity if it rendered or deployed secrets.
  The current design (CI triggers a server-side script) avoids that.
- GitLab Secrets Manager (OpenBao-backed, `secrets:` keyword) needs Premium or above [S44].

## 6. Cold restore (secrets host down)

Every option ends in a small set of **bootstrap secrets** that cannot live only on the server:

| Option | Bootstrap secrets needed to rebuild from scratch | Available while the server is down? |
|---|---|---|
| `.env` + backup | rclone crypt passwords, OneDrive access | Only if stored off-host |
| SOPS + age | the age private key (one line), git access | Repo: yes, via the public GitHub mirror even if GitLab is down. Key: wherever it is kept off-host |
| Ansible Vault | vault password | Same as above |
| Vaultwarden items | Vaultwarden backup + master password, or any unlocked client offline [S30] | Read-only on unlocked clients |
| Bitwarden SM cloud | machine access token | Yes (cloud), needs internet |
| Infisical self-hosted | DB + Redis backup, `ENCRYPTION_KEY`, `AUTH_SECRET` [S36] | Only CLI caches on machines that fetched before [S38] |
| OpenBao self-hosted | storage backup + unseal key shares (or auto-unseal source) [S41] | No |

Observations:

- A self-hosted manager on the same host as its consumers means restoring in a fixed order: restore the
  manager, unseal or decrypt it, then deploy the rest. Its own secrets must come from outside, which brings back
  one of the simpler options anyway.
- SOPS reduces bootstrap to one small key that can be printed, stored in the existing Vaultwarden (readable
  offline on a phone), and kept in a second place. Losing every copy of that key loses every secret in git.
- The backup encryption password (rclone crypt) is already a bootstrap secret of the same kind, whatever the
  choice.

## 7. Comparison

| | Secrets in public git | Extra service to run | Compose fit | GitOps fit | Rotation story | Cold restore |
|---|---|---|---|---|---|---|
| `.env` + backup (current) | No | No | Native | Weak (values outside git) | Manual, no history | Depends on backup |
| SOPS + age (PQ) | Yes (values encrypted, names/lengths visible) | No | `exec-env` or decrypt to `.env` | Doco-CD native, Komodo via hook | `updatekeys` + `rotate`. History stays readable with old keys | One key off-host |
| Ansible Vault | Yes (password-based) | No | Via Ansible only | None | `rekey` (files only) | One password off-host |
| Docker secrets | n/a (delivery) | No | Native | Neutral | n/a | n/a |
| Vaultwarden + `bw` | No | Already running | Sidecar or CLI | Doco-CD via webhook | Edit item | Unlocked clients, read-only |
| Bitwarden SM | No | Cloud, or Enterprise self-host | `bws run` | Doco-CD native | Per secret, audit | Cloud: yes |
| Infisical | No | Yes (+Postgres, Redis) | `infisical run` | Doco-CD native | Versioned, audit | Needs DB + keys restored first |
| OpenBao | No | Yes (+unseal) | Agent / CLI | Doco-CD native | Leases, dynamic | Needs unseal material |

## 8. Implications for the decision

Options that stand out:

1. **SOPS + age with post-quantum recipients**, possibly with Docker secrets for `_FILE`-aware images. It is the
   only option that versions secrets in git without running a new service. It works with Ansible, with Doco-CD
   natively and with the current script. Bootstrap shrinks to one key. The cost is accepting public metadata
   and permanent ciphertext, against upstream's "keep reasonably private" advice.
2. **Keep secrets out of git, but in a store with history**: either the current `.env` approach formalised (with
   the GitOps tool's own variable store, Komodo or Portainer), or Vaultwarden items read at deploy time. Nothing
   leaks publicly. The Vaultwarden route reuses an existing service, but puts a master password on the server
   and creates a boot-order dependency.
3. **A server-based manager (Infisical or OpenBao)** only pays off if features like audit, per-app machine
   identities or dynamic credentials are wanted. Both add a stateful service whose own restore becomes the
   first step of every disaster recovery.

Ansible Vault and Bitwarden Secrets Manager self-hosted look weak here: the first because of password-based
encryption in a public repo, the second because of the Enterprise licence requirement.

Questions for the owner:

- Is publishing **key names, value lengths and change dates** acceptable, given that the repo already shows the
  service list? If not: SOPS binary mode (hides names, loses diffs), or a split where only some secrets go in git.
- Is the residual risk of **permanent public ciphertext** acceptable, knowing that a key leak means changing every
  secret ever committed, not just rotating the key?
- Which **GitOps tool** is chosen? Doco-CD favours SOPS or external providers natively. Komodo favours its own
  variable store (SOPS only through a pre-deploy step for now). Portainer favours its own UI variables.
- Where do the **bootstrap secrets** live (age key or vault password, rclone crypt password, Vaultwarden master
  password), and in how many independent places? Paper, Vaultwarden offline clients, a second device?
- Should **Vaultwarden** stay a human password manager only, or also serve machines (needs a dedicated account
  and a master password on the server)?
- Rotation policy: periodic `sops rotate` and changing the secrets themselves at a set interval, or only on
  suspicion of compromise?
- If SOPS is chosen: add a gitleaks rule for `AGE-SECRET-KEY-PQ-1` keys, and enforce PQ-only recipients in
  `.sops.yaml` (no SSH or classic age recipient on the same files).

## Sources

- [S1] Vaultwarden discussion #7457 "Adding the Secrets Manager to Vaultwarden" (2026-07-23), replies by stefan0xC and BlackDex: https://github.com/dani-garcia/vaultwarden/discussions/7457
- [S2] Doco-CD docs, "Bitwarden Vault / Vaultwarden": https://github.com/kimdre/doco-cd/blob/main/wiki/docs/External-Secrets/Bitwarden-Vault-Vaultwarden.md
- [S3] Bitwarden, Secrets Manager FAQs: https://bitwarden.com/help/secrets-manager-faqs/
- [S4] Bitwarden, Secrets Manager product and pricing page: https://bitwarden.com/products/secrets-manager/
- [S5] SOPS docs, Security / Threat Model: https://getsops.io/docs/security/ (source: https://github.com/getsops/docs/blob/main/content/en/docs/security/_index.md)
- [S6] age v1.3.0 release notes: https://github.com/FiloSottile/age/releases/tag/v1.3.0
- [S7] SOPS CHANGELOG (3.10.0 to 3.13.3): https://github.com/getsops/sops/blob/main/CHANGELOG.md
- [S8] Ansible docs, "Using encrypted variables and files" (vault format): https://docs.ansible.com/ansible/latest/vault_guide/vault_using_encrypted_content.html
- [S9] ansible-core source, `lib/ansible/parsing/vault/__init__.py` (`iterations=10000`, `CIPHER_ALLOWLIST`): https://github.com/ansible/ansible/blob/devel/lib/ansible/parsing/vault/__init__.py
- [S10] hashcat example hashes, mode 16900 Ansible Vault: https://hashcat.net/wiki/doku.php?id=example_hashes
- [S11] SOPS docs, Key management (updatekeys, rotate, compromised key): https://getsops.io/docs/usage/key-management/
- [S12] Doco-CD docs, SOPS encryption: https://doco.cd/latest/Advanced/Encryption/
- [S13] OWASP Password Storage Cheat Sheet (PBKDF2-HMAC-SHA256: 600,000 iterations): https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
- [S14] SOPS docs, Reference (encryption protocol, cleartext keys as AAD): https://getsops.io/docs/reference/
- [S15] age README, "Post-quantum keys": https://github.com/FiloSottile/age/blob/main/README.md
- [S16] SOPS source, `age/keysource.go` (one recipient per master key, `age1pq1` / `AGE-SECRET-KEY-PQ-1` parsing): https://github.com/getsops/sops/blob/main/age/keysource.go
- [S17] age source, `age.go` ("can't mix post-quantum and classic recipients"): https://github.com/FiloSottile/age/blob/main/age.go
- [S18] gitleaks default config, rule `age-secret-key`: https://github.com/gitleaks/gitleaks/blob/master/config/gitleaks.toml
- [S19] SOPS source, `aes/cipher.go` (`gcm.Seal` without padding): https://github.com/getsops/sops/blob/main/aes/cipher.go
- [S20] SOPS docs, Reference, `.sops.yaml` options ("Comments are always encrypted"): https://getsops.io/docs/reference/
- [S21] SOPS source, `stores/json/store.go` (binary store uses a single `data` key): https://github.com/getsops/sops/blob/main/stores/json/store.go
- [S22] Ansible docs, "Encrypting content with Ansible Vault": https://docs.ansible.com/ansible/latest/vault_guide/vault_encrypting_content.html
- [S23] SOPS README (formats, licence, CNCF Sandbox) and release v3.13.3: https://github.com/getsops/sops
- [S24] SOPS docs, Advanced usage, "Passing Secrets to Other Processes": https://getsops.io/docs/usage/advanced/
- [S25] SOPS docs, Identities / age: https://getsops.io/docs/usage/identities/age/
- [S26] Ansible docs, `community.sops` collection index (2.5.1): https://docs.ansible.com/ansible/latest/collections/community/sops/index.html
- [S27] Docker docs, "Secrets in Compose": https://docs.docker.com/compose/how-tos/use-secrets/
- [S28] Docker docs, Compose file reference, `secrets`: https://docs.docker.com/reference/compose-file/secrets/
- [S29] Vaultwarden README (features, current release 1.37.5): https://github.com/dani-garcia/vaultwarden
- [S30] Bitwarden help, "Using Bitwarden offline": https://bitwarden.com/help/using-bitwarden-offline/
- [S31] Bitwarden help, Secrets Manager CLI: https://bitwarden.com/help/secrets-manager-cli/
- [S32] Doco-CD docs, External Secrets index: https://github.com/kimdre/doco-cd/blob/main/wiki/docs/External-Secrets/index.md
- [S33] Infisical LICENSE: https://github.com/Infisical/infisical/blob/main/LICENSE
- [S34] Infisical docs, Enterprise licensing: https://github.com/Infisical/infisical/blob/main/docs/self-hosting/ee.mdx
- [S35] Infisical docs, Hardware requirements: https://github.com/Infisical/infisical/blob/main/docs/self-hosting/configuration/requirements.mdx
- [S36] Infisical docs, Environment variables (`ENCRYPTION_KEY`, `AUTH_SECRET`): https://github.com/Infisical/infisical/blob/main/docs/self-hosting/configuration/envars.mdx
- [S37] Infisical docs, Docker / Docker Compose integration: https://github.com/Infisical/infisical/blob/main/docs/integrations/platforms/docker.mdx
- [S38] Infisical docs, CLI FAQ (offline use): https://github.com/Infisical/infisical/blob/main/docs/cli/faq.mdx
- [S39] Infisical docs, CLI reference (Infisical Proxy cache): https://github.com/Infisical/infisical/blob/main/docs/cli/reference.mdx
- [S40] OpenBao releases (v2.7.3, 2026-11-19): https://github.com/openbao/openbao/releases
- [S41] OpenBao docs, Seal/Unseal concepts: https://openbao.org/docs/concepts/seal/
- [S42] OpenBao docs, static seal: https://openbao.org/docs/configuration/seal/static/
- [S43] SOPS docs, Identities / HashiCorp Vault and OpenBao: https://getsops.io/docs/usage/identities/hashicorp-vault-openbao/
- [S44] GitLab docs, GitLab Secrets Manager (tier, GA in 19.5): https://docs.gitlab.com/ci/secrets/secrets_manager/
- [S45] Komodo PR #1053 "feat: Add SOPS and Age support to Periphery" (open): https://github.com/moghtech/komodo/pull/1053
- [S46] Komodo docs, Variables and Secrets: https://github.com/moghtech/komodo/blob/main/docsite/docs/configuration/variables.md
- [S47] Portainer docs, Add a new stack (repository method): https://docs.portainer.io/user/docker/stacks/add
- [S48] GitLab docs, CI/CD variables: https://docs.gitlab.com/ci/variables/

Version checks (git tags, 2026-11-26): sops v3.13.3, age v1.3.2, OpenBao v2.7.3, Infisical v0.167.16,
Komodo v2.3.4, Doco-CD v0.138.0, Vaultwarden 1.37.5.
