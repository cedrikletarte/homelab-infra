# GitOps tools for deploying Docker Compose stacks

Research note, 2026-11-26. Question: which tools deploy Docker Compose stacks from a Git repository (Komodo, Doco-CD, Portainer GitOps, Arcane, Dockge, others), and how do they compare on burst behaviour, triggers, Renovate/CI integration, secrets, rollback, UI, maturity and footprint?

Facts below come from each project's own docs, source code (default branch as of the date above) and the GitHub API. Each claim cites its source in brackets; the list is at the end. Where a primary source said nothing, the note says "not found" rather than guessing.

## 1. The problem being solved

The current pipeline (read from `.gitlab-ci.yml`, `renovate.json` and `scripts/docker-pull-and-run/`):

- Renovate automerges a `non-major` branch straight to `main` between 02:00 and 05:00, and opens weekly merge requests for the rest. Several merges can land minutes apart.
- Every push to `main` runs the `deploy` job after `validate`. The job only starts `docker_pull_and_run.sh` through SSH as a detached `systemd-run` unit, then ends. The job has `resource_group: production`, but that lock is released as soon as the unit starts, so it does not cover the deploy itself.
- While a unit runs, `systemd-run` refuses a second one ("already loaded"). The job retries every 30 s for up to 20 minutes.
- The script fast-forwards the server clone, then runs `docker compose up -d` in **every** running stack. It also: refuses to run without a recent backup, skips stacks that are stopped and the ones in `SKIP_STACKS`, removes old images, and reports through n8n to Discord.

So a burst of N merges gives N jobs all polling the same lock. Each successful one walks every stack, even when the commit touched one file. What is needed: **serialize or coalesce the deploys, deploy only the stacks that changed, and keep the safety rails** (backup gate, stopped stacks left alone, Sunday backup window, notification).

## 2. Candidates at a glance

| | Komodo | Doco-CD | Arcane | Portainer (CE) | Dockge |
|---|---|---|---|---|---|
| Git-sourced Compose | Yes (Stack resource) | Yes, it is the whole product | Yes (GitOps sync) | Yes (Git stacks) | **No** |
| Trigger | Webhook (GitHub/GitLab signature) per resource; scheduled procedures | Webhook (provider payload) and/or polling; local-repo watcher | Polling (interval in minutes) and token webhook | Polling interval or webhook URL | Not applicable |
| Burst handling | Per-resource FIFO queue for webhooks; deploys only if the files changed | Per-stack lock; webhooks wait, polls skip; stale revisions skipped; global concurrency limit | Skips a run when the branch head equals the last synced commit; 30 s wait on the project lock | Polls are single-flight per stack; webhook runs start a goroutine each | Not applicable |
| "Only the changed stack" | Yes: `DeployStackIfChanged` diffs the compose (and tracked) files per stack | Yes: git diff of the files each stack resolves to | Yes: compares synced file contents per project | No: any new commit on the ref redeploys every stack that points at the repo | Not applicable |
| Secrets | Variables/secrets interpolated into `.env`; secrets can live in the Core or Periphery config file | SOPS, external providers (Vaultwarden via sidecar, OpenBao, Infisical, 1Password...), absolute host-path env files | Env content kept per project / in UI; no external provider found | Env vars in UI / `stack.env` | Not applicable |
| Rollback | Git revert (no stack rollback found) | Git revert; moving the branch back is skipped unless `force_recreate` | Git revert (no rollback found) | Git revert (version picker only for non-Git stacks) | Not applicable |
| UI | Full web UI | **None** (REST API, MCP, metrics, Git commit status) | Full web UI | Full web UI | Full web UI |
| Footprint | Core + MongoDB or FerretDB (Postgres) + Periphery agent | One distroless container | One container, SQLite by default | One container | One container |
| License | GPL-3.0 | Apache-2.0 | BSD-3-Clause | Zlib (CE) | MIT |
| Latest release | v2.3.4, 2026-10-22 | v0.138.0, 2026-11-26 | v3.1.1, 2026-11-19 | 2.45.4, 2026-11-18 | 1.5.0, 2025-03-30 |

Sources: [K1]-[K9], [D1]-[D12], [A1]-[A6], [P1]-[P3], [G1], [DG1].

## 3. Tool by tool

### 3.1 Komodo

**Model.** Core (web UI + API, with MongoDB or FerretDB on Postgres) plus a small stateless Periphery agent on each server [K1][K2]. A `Stack` is one Compose project. Its files come from the UI, from files on the host, or from a git repo that Komodo clones onto the host [K3]. By default the clone goes under the agent's root directory (`/etc/komodo/stacks/<stack>`), or under a set `clone_path` [K4][K5]. v2.0 (March 2026) added outbound Periphery connections and PKI auth between Core and agents. It also stopped publishing a `latest` image tag in favour of semver tags [K6].

**Triggers.** Each resource has its own webhook URL `/listener/<github|gitlab>/<type>/<id>/<execution>`. The `gitlab` type checks `X-Gitlab-Token`, and Komodo acts only on pushes to the resource's configured branch [K7]. A Stack webhook can `/deploy` or `/refresh`. A Procedure webhook can listen on a branch and run any chain of executions [K7]. Procedures can also run on a schedule [K8].

**Burst behaviour.** This is the strongest point.
- The webhook listener takes a per-resource lock "to make a task queue for subsequent listener calls on same resource", because a call let through would otherwise fail with "action state busy" [K9]. A burst of N pushes therefore runs N times in a row, never in parallel. The runs are queued, not merged.
- By default a Stack webhook runs `DeployStackIfChanged`, not `DeployStack`. It "checks deployed contents vs latest contents, and only if any changes found will `docker compose up`" [K9][K10]. Queued runs after the first are therefore cheap no-ops when nothing changed for that stack. `webhook_force_deploy` turns the diffing off [K5].
- The diff covers the compose files, plus any `additional_env_files` / `config_files` declared on the Stack. A config file can be mapped to specific services, or to a restart instead of a redeploy [K5][K10]. Other files in the stack directory (a mounted `traefik.yml`, say) only count if they are declared.
- For a mono-repo with many stacks, there are two choices. You can give each stack its own GitLab webhook. Or one Procedure webhook on `main` can run `BatchDeployStackIfChanged` with a name pattern [K8]. The batch runs every matching stack concurrently [K11]. Order (network/Traefik/Postgres first) then needs separate procedure stages, or `after` dependencies in a Resource Sync [K12].

**Renovate / CI.** Komodo's docs point to Renovate for pinned tags in git stacks. Its own "auto update" mode only redeploys rolling tags whose digest changed [K13]. Komodo does not need the CI to deploy. To keep the "validate must pass first" gate, the CI deploy job can call Komodo instead of GitLab calling it directly (the API has `DeployStackIfChanged` / `RunProcedure`) [K10]. Reporting a commit status back to GitLab was not found in the docs.

**Secrets.** Variables and secrets are key/values interpolated with `[[KEY]]` into a stack's environment, which is written to a `.env` and passed with `--env-file` [K3][K14]. Values marked secret are hidden from logs and from non-admin users. Secrets can also sit in the Core config file (never exposed by the API) or in the Periphery config file (never sent over the network) [K14]. The docs say Komodo "is not intended as an enterprise level secret management solution" [K14].

**Declarative config.** A Resource Sync keeps Komodo's own resources (servers, stacks, procedures, non-secret variables) as TOML in git. It shows the diff and applies it on confirmation or on a webhook [K12]. This covers the "host reproducible/declarative" principle for the deploy tool itself.

**Rollback, UI, alerts.** No stack-level rollback was found; rollback means reverting the commit. The UI covers logs, terminals, server stats and an audit trail [K1]. Alerters include Discord, Slack, ntfy, Pushover and a custom webhook [K15], so n8n can receive events.

**Maturity.** About 13k stars, GPL-3.0, releases roughly monthly (v2.3.2 in Aug, v2.3.3 in Sep, v2.3.4 in Oct 2026), 729 open issues [G1]. Over the last six months, `main` received only squash-merged releases from the lead developer [G2], so the project depends heavily on one person.

**Pitfalls.**
- The checkout lives in Komodo's directory, not in today's clone. Relative bind mounts and the gitignored real `.env` files have to be moved: into Komodo variables/secrets, into absolute paths, or by pointing `clone_path` / "files on host" at a chosen directory [K4][K5].
- Komodo can be made to manage the stack that runs Komodo (and GitLab). Redeploying Core or Periphery from Komodo needs care.
- MongoDB/FerretDB is one more database to back up.

### 3.2 Doco-CD

**Model.** One Go binary in a distroless image, with the Docker socket mounted, no shell and `cap_drop: ALL` in the example compose [D1][D2]. A `.doco-cd.yml` in the repo lists the stacks: one YAML document per stack, or `auto_discovery` of subdirectories containing compose files [D3]. Every revision is served from its own immutable copy of the source [D4].

**Triggers.** Webhooks carry the provider's push payload to `/v1/webhook[/<target>]`. By default the call returns at once with a `job_id`, or blocks with `?wait=true` [D5]. Polling works on an interval or a cron schedule [D1][D6]. A repository already on the local disk can be polled and watched for new commits with no SCM involved [D7]. It can also be fed by an SCM webhook through `SOURCE_URL_REWRITES`, which removes the "GitLab must be up to deploy GitLab" problem [D7].

**Burst behaviour.** Built for exactly this.
- "Only deployments of the *same* stack are ever serialized". Different stacks, even from the same repo and ref, run in parallel up to `MAX_CONCURRENT_DEPLOYMENTS` (default 4) [D3].
- On a busy stack lock, a webhook waits ("nothing repeats them") while a poll skips, because the next poll retries [D8].
- Per stack, it compares the deployed commit with the new one and maps the git diff to the files the compose project uses (compose files, `env_file`, configs, bind-mount sources, build contexts). With no change it logs "no changes detected, skipping deployment" [D9][D10].
- A "latest-revision-wins" guard skips a run whose revision is an ancestor of what is already deployed. An older queued webhook can therefore never roll back a newer deploy [D9][D11].
- Result for a Renovate burst: each changed stack deploys once per change, unrelated stacks are untouched, and late, out-of-order events are dropped.

**Safety rails that map to the current script.**
- **Sync windows:** cron-based allow/deny windows set on the instance, so "a commit can't lift the window", for example a deny window over the Sunday backup [D12].
- **Pause:** `pause: true` freezes a stack without stopping it [D3].
- **Stopped stacks:** the `cd.doco.deployment.autostart: "false"` label keeps a stopped service stopped [D3].
- **Retries:** an optional retry budget for failed deploys [D3].
- **Notifications:** sent through Apprise, which can target Discord or a generic webhook such as n8n [D13].
- **Metrics:** a Prometheus endpoint [D1].
- **Self-update:** off by default; doco-cd refuses to replace its own container unless enabled [D14].

**Renovate / CI.** The docs have a Renovate guide covering self-hosted GitLab CI [D15]. With `GIT_COMMIT_STATUS=true`, doco-cd posts each stack's deploy outcome to GitLab as a commit status: pending/queued, running, success, failed or skipped [D16]. The deploy result then shows on the commit next to the CI pipeline. The docs also flag one trap: a skipped status can make a pipeline "skipped", which matters with "Pipelines must succeed" [D16]. To keep "CI must pass first", let only CI trigger the deploy (through the REST API poll trigger [D5]) rather than a GitLab push webhook. Doing so loses the GitLab-payload webhook path.

**Secrets.** SOPS-encrypted files in git, decrypted at deploy time [D17]. External providers include Bitwarden/**Vaultwarden** (through a sidecar REST server), OpenBao, Infisical, 1Password and AWS/Azure [D18][D19]. `env_files` can also be absolute paths to files mounted into the doco-cd container [D3].

**Rollback.** Revert in git. Moving the branch back to an older commit is treated as stale and skipped, unless `force_recreate` is set [D11][D9].

**UI.** None. Operation goes through logs, the REST API, an MCP server, metrics and commit statuses [D1].

**Maturity.** About 1.8k stars, Apache-2.0, 20 open issues [G1]. The release pace is very high: v0.136.0 to v0.138.0 between 2026-11-21 and 2026-11-26 [G1]. Over six months, `main` had 784 commits, of which 370 were Renovate's and about 364 the main author's [G2]. It is still 0.x and essentially a one-maintainer project, so expect frequent behaviour changes. Pin a version and read the release notes.

**Pitfalls.**
- The docs warn: "Never keep persistent data behind a relative bind mount". Since every revision gets its own directory, relative data mounts must become named volumes or absolute paths before the first deploy [D4]. Relative mounts of config files and relative `env_file`s are fine [D4].
- The real `.env` files that are gitignored today would have to move to SOPS, a secret provider, or absolute mounted paths.

### 3.3 Arcane

**Model.** A Docker management UI (Go backend, Svelte frontend), one container, SQLite by default (`ARCANE_DATABASE_URL`), with optional remote agents [A1][A2]. A "GitOps sync" links one project (a compose file, or a directory with directory sync) to a repo path. Modes include a "backup to Git" and a bidirectional mode [A3][A4].

**Triggers.** Each sync is a scheduled job `@every <interval>m`, default 60 minutes [A3]. Inbound webhooks are secret-token URLs whose targets can be containers, projects, the updater, or `gitops` with a `sync` action [A5]. They are not GitLab-signed push payloads, so one webhook triggers one sync.

**Burst behaviour.**
- `Unchanged()` skips a sync when the remote head equals the last synced commit and the last run succeeded. The changelog lists this as "skip gitops sync runs when the remote branch is unchanged" under v3.2.0, which is not yet released (latest release is v3.1.1) [A3][A6].
- A run copies the changed files into the project and redeploys only if contents changed (or a redeploy was pending) and the project is running [A3].
- Operations take a project lock and wait up to 30 s. Past that they fail with "another operation on this project is still running" [A2]. A long deploy hit by a second trigger can therefore fail instead of queueing. The next scheduled sync would catch up.

**Secrets.** A local `.env` is kept across git syncs (changelog #4783), and env content can be set per sync [A6][A3]. No SOPS or external secret-provider integration was found in the source tree (only Podman secrets) [A1].

**Rollback, UI.** No rollback for git projects found. The UI is polished and broad (containers, images, volumes, projects, swarm, podman).

**Maturity.** About 10.6k stars, BSD-3-Clause, 13 open issues [G1]. Very fast-moving: majors v1 to v3 within about a year, and 2037 commits in six months, about 1268 of them by one maintainer [G2]. GitOps is one feature among many, and it is still changing in recent releases [A6].

**Pitfalls.** Files are copied into Arcane's own projects directory. As with the others, relative data mounts and today's server-side `.env` files have to be planned for.

### 3.4 Portainer CE (already installed)

**Model and triggers.** A Git stack has a compose path plus extra `-f` files. "GitOps updates" use either polling (a fetch interval) or a webhook URL. "Force redeployment" redeploys on every trigger even without changes; otherwise "automatic updates will only trigger if Portainer detects a change in the remote Git repository" [P1].

**Change detection is per repository commit, not per file.** `UpdateGitObject` compares the latest commit ID of the ref with the stored hash. If it differs, the repo is re-cloned and the stack redeployed [P2][P3]. With ten stacks pointing at the same mono-repo, a commit to one stack's compose file makes all ten redeploy. Compose still recreates only the containers that changed.

**Burst behaviour.** Polling runs go through a per-stack `singleflight`. Webhook runs are started in a new goroutine with no such guard [P2]. Several webhooks in a row can therefore overlap on the same stack; the source shows no queue.

**Other.** "Relative path volumes" (compose files that reference repo-relative paths) are Business Edition only [P1]. For a repo whose compose files use `./config` style mounts, that alone rules out CE. Git stacks have no rollback or version picker; the version dropdown only applies to editor/upload stacks [P4]. Big, mature project (about 39k stars, frequent 2.x releases) [G1].

### 3.5 Dockge

A nice compose manager: it keeps the compose files on disk and lets you edit, start, stop and update them. Its feature list has no Git, webhook or polling deploy [DG1]. The last release is 1.5.0 from 2025-03-30 [G1]. It is not a GitOps tool. Mentioned only to rule it out.

### 3.6 Others looked at

- **Dokploy, Coolify.** Self-hosted PaaS platforms. Dokploy's installer runs `docker swarm init`, sets up Traefik and creates its own Postgres [O1]. Coolify's installer pulls Coolify, Postgres, Redis and a helper, and manages its own proxy directory [O2]. Each brings its own reverse proxy and database, which clashes with the existing Traefik and with the "Compose stays the unit" principle. Out of scope.
- **Native GitLab fix (no new tool).** `resource_group` supports `process_mode` `newest_first` / `newest_ready_first`, which pick the newest waiting job (free tier). Combined with GitLab's "prevent outdated deployment jobs", older queued deploys are dropped [GL1]. This only helps if the job holds the lock for the whole deploy. Today the job ends as soon as `systemd-run` starts the unit, so the lock does not cover the deploy (section 1). Deploying only changed stacks would still have to be scripted (for example `rules:changes` or a `git diff` in the script). This is the "keep the bash script" path that the principles move away from. It is listed as a baseline.

## 4. Cross-cutting points

1. **Where the checkout lives.** Every tool deploys from its own copy: Komodo's stack/repo directory, Doco-CD's per-revision artifacts, Arcane's project directory, Portainer's project path. Doco-CD is the strictest, because relative data mounts break across revisions [D4]. Before any switch, list the relative bind mounts that hold data, and where the real `.env` files will come from.
2. **CI gating vs push webhooks.** A GitLab push webhook deploys `main` whatever its pipeline says. Renovate's automerge branch only reaches `main` after a green pipeline, but hand pushes to `main` do not. Having the CI `deploy` job call the tool keeps the gate. The tool then owns queueing and change detection, and the job still ends right away. Komodo (API), Doco-CD (REST poll trigger), Arcane (token webhook) and Portainer (webhook URL) all allow this [K10][D5][A5][P1].
3. **Bootstrapping GitLab.** If GitLab is down, push webhooks stop. Doco-CD's local-repo polling [D7] and polling in general are fallbacks. A tool that recreates GitLab must not depend on GitLab to finish that deploy.
4. **Backup gate.** None of the tools has an equivalent of "refuse to deploy unless the last backup is recent". Doco-CD sync windows [D12] or Komodo schedules/procedures [K8] can keep deploys out of the backup window. A hard backup check would need a pre-deploy hook: Komodo `pre_deploy` [K5]; Doco-CD only through init containers or compose lifecycle hooks, since it has no shell [D20].
5. **Footprint.** Doco-CD runs a single distroless container [D1]. Arcane and Portainer run a single container each. Komodo runs Core, a database and an agent [K1][K2]. No vendor publishes RAM figures in the sources read, so this needs measuring if it matters. On the new server (12 cores, 32 GB), any of them is small next to GitLab.

## 5. Implications for the decision

**Options that stand out**

- **Doco-CD** fits the stated problem most directly. It serializes per stack only, drops stale revisions, diffs per stack, posts GitLab commit statuses, has sync windows for the backup slot, integrates SOPS and Vaultwarden, and runs as one small container. Costs: no UI, a 0.x project with a very high change rate and one main maintainer, and a strict "no relative data mounts" rule.
- **Komodo** is the "dedicated tool with a UI" option. Webhooks queue per resource, `DeployStackIfChanged` is the default, Resource Sync keeps the tool's own config declarative, and it has alerters, terminals and server monitoring. It could also replace Portainer as the admin UI. Costs: a database plus an agent, a mono-repo that needs per-stack webhooks or a batch procedure with explicit ordering, GPL-3.0, and one main developer.
- **Arcane** is attractive as a modern UI. Its GitOps is hourly-polling by default, a second trigger during a deploy fails after 30 s instead of queueing, and the "skip when unchanged" fix is not released yet. It has weaker burst handling and no external secrets.
- **Portainer CE** is already installed. It redeploys every stack of the repo on any commit, webhook runs are unguarded, and repo-relative volumes need BE. It is a poor fit for this repo layout.
- **Dockge, Dokploy, Coolify:** not suitable (no GitOps, or a PaaS with its own proxy and database).

**Questions for the owner**

1. Is a web UI for deployments a requirement, or are Discord notifications plus GitLab commit statuses enough? This mostly decides Komodo vs Doco-CD.
2. Should deploys stay gated by the CI pipeline (CI calls the tool), or may the tool react to every push to `main` (GitLab webhook or polling)?
3. Where should secrets live: SOPS-encrypted in git, Vaultwarden through a provider, the tool's own secret store, or plain files on the host?
4. Is moving relative data bind mounts to named volumes or absolute paths acceptable as part of the new-server migration?
5. How much maintainer risk is acceptable? All three serious candidates rely heavily on one developer; Doco-CD and Arcane also release very often.
6. Should the tool also replace Portainer (Komodo or Arcane), or sit next to it (Doco-CD)?
7. Should the backup gate stay a hard check (pre-deploy hook), or become a time-window rule?
8. Should the new tool deploy GitLab, Traefik and itself, or should those stay outside it (Ansible or by hand)?

## Sources

GitHub data (stars, last release, open issues) from the GitHub REST API on 2026-11-26; commit counts from `git shortlog` on the default branch since 2026-05-26.

- [G1] GitHub API `repos/{owner}/{repo}` and `/releases` for moghtech/komodo, kimdre/doco-cd, getarcaneapp/arcane, portainer/portainer, louislam/dockge, Dokploy/dokploy, coollabsio/coolify.
- [G2] `git shortlog -sn --since=2026-05-26` on the default branches of moghtech/komodo, kimdre/doco-cd, getarcaneapp/arcane.

Komodo (github.com/moghtech/komodo, branch `main`)
- [K1] docsite/docs/intro.md
- [K2] docsite/docs/setup/index.mdx, setup/ferretdb.mdx
- [K3] docsite/docs/deploy/compose.md
- [K4] config/periphery.config.toml (`root_directory`, `stack_dir`, `repo_dir`)
- [K5] client/core/rs/src/entities/stack.rs (`clone_path`, `webhook_force_deploy`, `additional_env_files`, `config_files`, `pre_deploy`, `StackFileDependency`)
- [K6] docsite/docs/releases/v2.0.0.md
- [K7] docsite/docs/automate/webhooks.md
- [K8] docsite/docs/automate/procedures.md
- [K9] bin/core/src/api/listener/resources.rs (per-resource listener locks; default `DeployStackIfChanged`)
- [K10] client/core/rs/src/api/execute/stack.rs; bin/core/src/api/execute/stack.rs (`resolve_deploy_if_changed_action`)
- [K11] bin/core/src/api/execute/mod.rs (`batch_execute`)
- [K12] docsite/docs/automate/sync-resources.md
- [K13] docsite/docs/deploy/auto-update.md
- [K14] docsite/docs/configuration/variables.md
- [K15] client/core/rs/src/entities/alerter.rs

Doco-CD (github.com/kimdre/doco-cd, docs at doco.cd, sources in `wiki/docs/`)
- [D1] README.md
- [D2] docker-compose.yml (example)
- [D3] wiki/docs/Deploy-Settings.md
- [D4] wiki/docs/Migrating-from-Docker-Compose.md (relative bind mounts, per-revision artifacts)
- [D5] wiki/docs/Endpoints/Webhook-Listener.md
- [D6] wiki/docs/Core-Concepts.md
- [D7] wiki/docs/Advanced/Local-Filesystem-Polling.md
- [D8] internal/stages/stack_lock.go
- [D9] internal/stages/stage_2_pre-deploy.go (`isStaleDeployment`, change detection)
- [D10] wiki/docs/Advanced/Notifications.md (files a stack resolves to)
- [D11] wiki/docs/Migrating-from-Docker-Compose.md ("Moving the branch back to an older commit is skipped")
- [D12] wiki/docs/Advanced/Sync-Windows.md
- [D13] wiki/docs/Advanced/Notifications.md (Apprise)
- [D14] wiki/docs/Advanced/Self-Updating.md
- [D15] wiki/docs/Advanced/Renovate.md
- [D16] wiki/docs/Git-Settings.md (Commit Status Reporting)
- [D17] wiki/docs/Advanced/Encryption.md
- [D18] wiki/docs/External-Secrets/ (index and providers)
- [D19] wiki/docs/External-Secrets/Bitwarden-Vault-Vaultwarden.md
- [D20] wiki/docs/Known-Limitations.md

Arcane (github.com/getarcaneapp/arcane, branch `main`)
- [A1] repository tree (`backend/`, `docker/examples/`)
- [A2] backend/internal/config/config.go (SQLite default); backend/internal/project/service.go (`LockProject`, 30 s `leaseWaitTimeout`); backend/internal/common/errors.go
- [A3] backend/internal/gitops/service.go (`registerSyncJob`, default interval 60); backend/internal/gitops/children/sync/service.go (`Unchanged`, redeploy after sync)
- [A4] backend/internal/project/model.go (`GitOpsPushModes`)
- [A5] backend/internal/webhook/model.go, service.go, handler.go (token webhooks, `gitops`/`sync` target)
- [A6] CHANGELOG.md

Portainer (github.com/portainer/portainer, branch `develop`; docs.portainer.io)
- [P1] https://docs.portainer.io/user/docker/stacks/add
- [P2] api/stacks/deployments/deploy.go (`RedeployWhenChanged`, singleflight for polling, goroutine for webhook)
- [P3] api/git/update/update.go (`UpdateGitObject`, latest commit ID comparison)
- [P4] https://docs.portainer.io/user/docker/stacks/edit

Others
- [DG1] github.com/louislam/dockge README.md
- [O1] https://dokploy.com/install.sh
- [O2] https://cdn.coollabs.io/coolify/install.sh
- [GL1] https://docs.gitlab.com/ci/resource_groups/ (process modes)
