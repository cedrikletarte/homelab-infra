# Forge and CI options

Research for the ticket "Forge and CI options". Date: 2026-11-26.

Question: which forge and CI should host the personal projects (portfolio, school projects, dotfiles) and
this infrastructure repo on the new server (32 GB RAM shared with every other stack)? Options: self-hosted
GitLab EE/CE (current, 19.6), Forgejo or Gitea with Forgejo Actions or Woodpecker, GitHub (private repos)
with a self-hosted runner, and others.

This document lays out facts and trade-offs. It does not make the decision.

## What has to keep working

From `.gitlab-ci.yml`, `renovate.json` and `stacks/gitlab/docker-compose.yml` in this repo:

- **Validate stage** on every merge request, every push to `main`, and Renovate's automerge branch:
  `docker compose config` on every stack (needs only the Docker CLI, no daemon), `shellcheck`,
  `gitleaks git` on the full history (`GIT_DEPTH: 0`), and `renovate-config-validator` only when
  `renovate.json` changes. Each job runs in its own pinned image.
- **Deploy job** on push to `main`: SSH with a forced-command key that starts a detached
  `systemd-run` unit, serialised with `resource_group: production`, retry loop while a deploy is running.
  It is detached precisely so a deploy that recreates the forge or its runner does not kill itself.
- **Scheduled Renovate job**, hourly at night, using the `gitlab` platform, a bot token, a
  `GITHUB_COM_TOKEN` for release notes and a cached base dir.
- **Renovate config** relies on branch automerge (`automergeType: branch`) gated by a passing pipeline,
  weekly merge-request batches, and a GitLab-specific workflow rule
  (`$CI_OPEN_MERGE_REQUESTS == null`) so a Renovate branch is not tested twice.
- **Public mirror** to GitHub (the repo is mirrored publicly).
- GitLab is tuned for low memory: 2 Puma workers (single mode crashes 19.6 at boot), Sidekiq concurrency
  10, bundled Prometheus off. Renovate groups GitLab and its runner and treats GitLab majors as
  needing the documented upgrade path.
- `renovate.json` mentions a `portfolio-app` image "built locally by CI"; whether a container registry
  is used today is not visible in these files (question for the owner).

## Options at a glance

| | GitLab self-managed (current) | Forgejo + Forgejo Actions | Forgejo/Gitea + Woodpecker | Gitea + Gitea Actions | GitHub + self-hosted runner |
|---|---|---|---|---|---|
| Current version (Nov 2026) | 19.6.x | v17.0.2 stable, v15.0.12 LTS | Woodpecker 3.21.x | 28.4.0 | SaaS |
| Documented RAM | 16 GB baseline, 8 GB constrained minimum (requirements page); 2.5 GB + swap (memory-constrained guide) | no official figure; reports of well under 1 GB | Woodpecker adds a small server + agent | marked "low RAM/CPU" by Gitea | 0 on the server for the forge; runner only |
| CI syntax vs current | native, no rewrite | GitHub-Actions-like YAML, rewrite | Woodpecker YAML, rewrite | GitHub-Actions-like YAML, rewrite | GitHub Actions, rewrite |
| Scheduled jobs | pipeline schedules | `on.schedule` cron | cron in repo settings UI | `on.schedule` | `schedule` (can be delayed) |
| Renovate platform | `gitlab` | `forgejo` | `forgejo` / `gitea` | `gitea` | `github`, or the free Mend-hosted app |
| Container registry | built in | built in (OCI) | via the forge | built in | ghcr.io, currently free |
| Push mirror to GitHub | Free tier | built in | via the forge | built in | not needed (it is GitHub) |
| Import from GitLab | n/a | built-in migrator: issues, MRs, comments, labels, milestones, releases, wiki | same (forge side) | similar migrator | GEI targets Enterprise Cloud orgs |
| Goes down with the server | yes | yes | yes | yes | forge no, runner yes |

Details and sources follow.

## GitLab self-managed (current)

**Resources.** GitLab's requirements page gives 8 vCPU and 16 GB as the single-node baseline and says
"GitLab can run with at least 8 GB of memory" in memory-constrained setups
([requirements](https://docs.gitlab.com/install/requirements/)). The memory-constrained guide goes as low
as "2 GB of RAM + 1 GB of SWAP, optimally 2.5 GB of RAM + 1 GB of swap", with Puma single mode
(saves 100-400 MB), Sidekiq concurrency 10 or 5, and monitoring off (saves about 300 MB)
([memory-constrained](https://docs.gitlab.com/omnibus/settings/memory_constrained_envs/)). Puma single
mode is not available here because of the 19.6 boot crash noted in the compose file, so the 100-400 MB
saving is lost. A user who migrated off GitLab reports it "had consistently been sat on at least 5GiB of RAM"
([bentasker.co.uk, Jul 2026](https://www.bentasker.co.uk/posts/blog/software-development/migrating-from-gitlab-to-forgejo.html),
secondary source, single-user experience). On 32 GB shared with Immich (machine learning), Nextcloud,
Plex, the arr stack, Postgres and a local LLM, GitLab is likely the largest non-media consumer.

**Upgrade burden.** GitLab 19 has required upgrade stops at 19.2, 19.5, 19.8 and 19.11, and 19.0 moved
the PostgreSQL minimum to 17 ([GitLab 19 upgrade notes](https://docs.gitlab.com/update/versions/gitlab_19_changes/)).
The same page lists 19.6.0-19.6.1 migration failures fixed in 19.6.2, which matches this repo's recent
"bump to 19.6.2" and "Puma clustered" fixes. Monthly releases plus stops mean regular attention.

**Mirroring.** Push mirroring is available on Free; pull mirroring and "mirror specific branches" are
Premium/Ultimate ([repository mirroring](https://docs.gitlab.com/user/project/repository/mirror/)). The
current GitHub mirror is a push mirror, so it works on Free.

**Registry.** Built in. Since 19.0 the registry metadata database defaults to "prefer" mode for existing
Linux-package installs, and 19.0.0-19.0.1 had a registry bug fixed in 19.0.2
([upgrade notes](https://docs.gitlab.com/update/versions/gitlab_19_changes/)).

**CE vs EE.** Both editions ship from the same package repo with the same version support
([package install](https://docs.gitlab.com/install/package/)). For a Free-tier user the choice changes
little in practice; this was not researched further.

**GitLab.com (SaaS) as a variant.** Free private namespaces are limited to five users and 400 compute
minutes per month on shared runners
([user limit](https://docs.gitlab.com/user/free_user_limit/),
[compute minutes](https://docs.gitlab.com/ci/pipelines/compute_minutes/)); a self-hosted runner would
still be needed for the LAN deploy. It keeps the pipeline unchanged and takes the forge off the server.

**Strengths:** zero migration, pipeline and Renovate config already tuned, richest feature set (merge
trains, environments, issue boards, registry).
**Weaknesses:** heaviest by far, frequent upgrades with mandatory stops, recent boot-loop incidents.

## Forgejo (+ Forgejo Actions)

**Project and releases.** Forgejo is a hard fork of Gitea since early 2024, under the non-profit
Codeberg e.V. ([Forgejo vs Gitea](https://forgejo.org/compare-to-gitea/), Forgejo's own account).
v9.0 and later are GPL v3+ ([FAQ](https://forgejo.org/faq/)). Stable releases are quarterly with about
3 months of support; LTS releases get about 15 months: v15.0 LTS until 15 July 2027, next LTS v19.0
planned 15 April 2027 ([release schedule](https://forgejo.org/docs/latest/admin/release-schedule/)).
Current: v17.0.2 stable and v15.0.12 LTS, both 18 November 2026 ([releases](https://forgejo.org/releases/)).
Docker image `codeberg.org/forgejo/forgejo` (also mirrored on `data.forgejo.org`), rootless variant,
SQLite by default or PostgreSQL/MySQL ([Docker install](https://forgejo.org/docs/latest/admin/installation/docker/)).
It can use the shared Postgres.

**Resources.** No official RAM figure. The migration report above says Forgejo "haven't even got as far
as 700MiB yet" after leaving GitLab, and disk use dropped from 7.9 GB to 3.4 GB (partly because issues
were not migrated) ([bentasker.co.uk](https://www.bentasker.co.uk/posts/blog/software-development/migrating-from-gitlab-to-forgejo.html)).
Gitea's own comparison marks only Gitea as "Low RAM/CPU usage" against GitLab and GitHub
([Gitea comparison](https://docs.gitea.com/installation/comparison)).

**Forgejo Actions.** Enabled by default since v1.21; the runner (`forgejo-runner`, v12.x in 2026) is
installed separately ([admin actions](https://forgejo.org/docs/latest/admin/actions/),
[monthly report Feb 2026](https://forgejo.org/2026-02-monthly-report/)). It is "designed to be familiar to
users of GitHub Actions, but it is not designed to be compatible"
([overview](https://forgejo.org/docs/latest/user/actions/overview/)). Documented differences: default
image is Debian with Node.js only, some `github` context keys missing, `permissions` and
`continue-on-error` ignored, OIDC via `enable-openid-connect`
([differences](https://forgejo.org/docs/latest/user/actions/github-actions/)). Supported and relevant:
`on.schedule` with an IANA `timezone`, `concurrency` (replaces `resource_group`), per-job `container:`,
`services`, `workflow_dispatch`, secrets and variables
([reference](https://forgejo.org/docs/latest/user/actions/reference/)).

**Mapping the current pipeline.** Every validate job already runs in a pinned image, so each becomes a
job with `container:`. `docker compose config` needs only the CLI, so job containers need no Docker
socket. `rules: changes` on `renovate.json` becomes a separate workflow with `on.push.paths`. The
GitLab-only `$CI_OPEN_MERGE_REQUESTS` rule has no equivalent and is replaced by triggers on
`push` to `main` and `renovate/**` plus `pull_request`. GitLab "File" variables become secrets written to
a file in the job. The Renovate job becomes a scheduled workflow; its cache becomes `actions/cache` or a
runner-local volume.

**Runner isolation.** The runner executes jobs through Docker-in-Docker, the host socket
(`docker_host: automount`, "no security isolation", can stop Forgejo itself, only advisable when only
trusted users have access), LXC, or inside a VM
([Docker access](https://forgejo.org/docs/latest/admin/actions/docker-access/)). The current GitLab
runner mounts the host socket too, so this is not a regression, but DinD or the old server are options.

**Renovate.** Native `platform=forgejo`; token scopes `repo` RW, `user` R, `issue` RW, `organization` R,
`read:packages` if packages are used; `platformAutomerge` is not supported
([Renovate Forgejo platform](https://docs.renovatebot.com/modules/platform/forgejo/)). The current config
uses branch automerge (`automergeType: branch`), not platform automerge, so it does not depend on that
feature. Branch automerge gates on commit statuses, which Forgejo Actions reports; this should be
confirmed in a trial.

**Registry.** OCI registry at `{host}/{owner}/{image}`, login with a personal access token; tag names are
case-insensitive ([container registry](https://forgejo.org/docs/latest/user/packages/container/)).

**Mirror to GitHub.** Push mirror with a fine-grained GitHub token (Contents, plus Workflows if the repo
has workflow files), optional "Sync when new commits are pushed", branch filter; it force-pushes
([repo mirror](https://forgejo.org/docs/latest/user/repo-mirror/)). Note: this repo would carry
`.forgejo/workflows`; Forgejo falls back to `.github/workflows` only if the former is absent
([overview](https://forgejo.org/docs/latest/user/actions/overview/)), so on the public GitHub mirror
the workflows stay inert unless placed in `.github/workflows`.

**Migration from GitLab.** The built-in migrator (GitLab downloader) fetches topics, milestones, labels,
releases, issues, comments, merge requests and approvals; it skips confidential issues and internal
notes, does not carry label descriptions/colors on issues, keeps only some system events, and offsets MR
numbers by the highest issue number
([source: services/migrations/gitlab.go](https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/services/migrations/gitlab.go)).
`forgejo dump-repo` / `restore-repo` cover wiki, issues, labels, releases, release assets, milestones,
pull requests and comments from a GitLab URL
([CLI](https://forgejo.org/docs/latest/admin/command-line/)). CI pipelines, schedules, CI variables and
registry images are not migrated by any of these and are recreated by hand. The migration report above
hit lowercased repo names, imported timestamps set to import time, and issues without comments when
using a third-party script ([bentasker.co.uk](https://www.bentasker.co.uk/posts/blog/software-development/migrating-from-gitlab-to-forgejo.html)).
Backup: `forgejo dump` produces one zip of files and database
([CLI](https://forgejo.org/docs/latest/admin/command-line/)).

**Strengths:** small footprint, LTS line, built-in Actions, registry, push mirror, native Renovate
platform, migrator that keeps issues and MRs.
**Weaknesses:** pipeline rewrite, Actions compatibility is "familiar" rather than exact, fewer
enterprise features, smaller ecosystem.

## Woodpecker CI (with Forgejo or Gitea)

Woodpecker is a Drone 0.8 fork, current docs at 3.21.x; only the latest stable gets bug fixes
([versions](https://woodpecker-ci.org/versions), [about](https://woodpecker-ci.org/about)). Supported
forges: GitHub, Gitea, Forgejo, GitLab, Bitbucket, Bitbucket Datacenter; multi-forge is experimental
([forges](https://woodpecker-ci.org/docs/administration/configuration/forges/overview)). Steps run in
containers ([home](https://woodpecker-ci.org/)). Cron jobs are defined in the repository settings UI, with
`when: event: cron` in the pipeline file ([cron](https://woodpecker-ci.org/docs/usage/cron)), so the
schedule is not in git. It adds a second service (server + agent, its own database and OAuth app) next to
the forge, and its YAML is a third syntax. It works the same whether the forge is Forgejo, Gitea or even
GitLab, which makes a later forge change cheaper; the migration report above moved Woodpecker from
GitLab to Forgejo by editing forge URLs in its database and using its repair function, and re-adding
repos wiped cron and secrets ([bentasker.co.uk](https://www.bentasker.co.uk/posts/blog/software-development/migrating-from-gitlab-to-forgejo.html)).
Codeberg runs Woodpecker as its hosted CI ([Codeberg FAQ](https://docs.codeberg.org/getting-started/faq/)).

**Strengths:** forge-independent CI, mature for container pipelines.
**Weaknesses:** one more service and database, schedules and secrets live outside git, no gain over
Forgejo Actions for a pipeline this size.

## Gitea (+ Gitea Actions)

Gitea dropped the `1.` prefix: 28.0.0 (30 Sep 2026) followed 1.27; 28.4.0 is from 15 Nov 2026, and Gitea
Runner reached 6.0.0 on 11 Nov 2026 ([Gitea blog](https://blog.gitea.com/),
[28.0.0](https://blog.gitea.com/release-of-28.0.0/)). 28.0 deletes completed Actions runs after 400
days by default and tightens workflow evaluation (job-level `if:` before matrix expansion, `fail-fast`
enforced) ([28.0.0](https://blog.gitea.com/release-of-28.0.0/)). Feature set is close to Forgejo:
built-in CI, package/container registry, push and pull mirrors, migration from other services
([comparison](https://docs.gitea.com/installation/comparison)). Several 2026 releases were security
batches ([1.26.3/1.26.4](https://blog.gitea.com/release-of-1.26.3-and-1.26.4/)). Governance: Forgejo
describes Gitea as controlled by a for-profit company, Open Core, with copyright assignment
([Forgejo vs Gitea](https://forgejo.org/compare-to-gitea/), a partisan source). Renovate supports it as
`platform=gitea`.

**Versus Forgejo:** technically similar; the differences are governance, licence (MIT vs GPL v3+),
release cadence (Gitea has no LTS line documented in the sources read), and the two codebases have
diverged since 2024 so moving between them later is a migration, not a swap.

## GitHub (private repos) + self-hosted runner

**Cost and limits.** GitHub Free gives unlimited private repos with "a limited feature set"; required
reviewers and protected branches in private repos come with Pro
([plans](https://docs.github.com/en/get-started/learning-about-github/githubs-plans)). Free includes
$12/month of hosted compute (about 2,000 Linux minutes), 500 MB artifact/package storage, and
self-hosted runner usage "remains free"
([Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)). A
$0.002/min platform charge on self-hosted runners was announced for 1 March 2026, then postponed "to
re-evaluate our approach" with no new date
([changelog](https://github.blog/changelog/2025-12-16-coming-soon-simpler-pricing-and-a-better-experience-for-github-actions/)).
This is a pricing risk to watch. Container registry storage and bandwidth "is currently free", with at
least one month's notice before a change
([Packages billing](https://docs.github.com/en/billing/concepts/product-billing/github-packages)).

**Runner.** Outbound HTTPS 443 only; auto-updates by default, and a runner more than 63 days behind
stops getting jobs ([self-hosted runners](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)).
GitHub says "self-hosted runners should almost never be used for public repositories" and that they can
be persistently compromised ([secure use](https://docs.github.com/en/actions/reference/security/secure-use)).
The deploy job must reach the server over SSH, so it needs the self-hosted runner (or exposing SSH).

**Public mirror pitfall.** Today the infra repo is private on GitLab and mirrored publicly. On GitHub,
either the infra repo itself becomes public (then a self-hosted runner on it is exactly the case GitHub
warns about) or it stays private and a second public repo is kept in sync by a workflow, since GitHub
has no built-in push mirroring (Gitea's comparison marks push mirror absent for GitHub
([comparison](https://docs.gitea.com/installation/comparison))).

**Scheduling and Renovate.** `schedule` runs only on the default branch, can be delayed or dropped under
load, and is disabled after 60 days without activity in public repos
([events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)).
Renovate could instead run as the Mend-hosted Community Cloud app: free for unlimited private repos,
jobs every 4 hours ([Mend-hosted](https://docs.renovatebot.com/mend-hosted/overview/)); the current
config's night-only automerge windows would need checking against that cadence.

**Migration.** GitHub Enterprise Importer migrates GitLab issues, MRs (as PRs), comments, milestones,
releases and wiki, but not CI/CD pipelines, schedules, variables or LFS objects, and its destination is
GitHub Enterprise Cloud organizations
([understand GitLab migrations](https://docs.github.com/en/migrations/using-github-enterprise-importer/migrate-from-gitlab/understand-migrations),
[about GEI](https://docs.github.com/en/migrations/using-github-enterprise-importer/understanding-github-enterprise-importer/about-github-enterprise-importer)).
For a GitHub Free personal account, plan on git-only import plus scripts for issues.

**Strengths:** no forge to run, back up or upgrade; forge survives a server outage; portfolio visibility;
best Actions ecosystem.
**Weaknesses:** private code on a third-party SaaS, pricing can change (self-hosted runner charge
postponed, not cancelled), Free limits on private repos, public-repo + self-hosted runner risk, pipeline
rewrite.

## Other hosted options

- **Codeberg** (hosted Forgejo): private content limited to about 100 MB for contributors to free/libre
  projects, no private hosting service, public works expected to carry a free licence
  ([Codeberg FAQ](https://docs.codeberg.org/getting-started/faq/)). Not a fit for the private infra repo
  or school work; possible for public portfolio projects.
- **GitLab.com Free**: see the GitLab section (5 users per private namespace, 400 compute minutes).

## A forge that goes down with the server it deploys

Facts from the current setup and the sources:

- While the forge is down there is no CI, no Renovate, no deploy, and no access to issues. The server
  clone is local, so manual `git pull` + `docker compose up -d` still works; the forge is not on the
  boot path of the other stacks.
- The deploy already survives the forge restarting (detached `systemd-run`), which any option keeps.
- Disaster recovery: on a dead server, the forge's own data (issues, MRs, CI variables, registry) is only
  as recent as the weekly backup. The public GitHub mirror keeps the code, not the issues or secrets.
  Forgejo's `forgejo dump` makes this a single artefact
  ([CLI](https://forgejo.org/docs/latest/admin/command-line/)); GitLab's backup is heavier (not
  researched here).
- GitLab upgrades are themselves a source of forge downtime (19.6.0-19.6.1 migration failures,
  [upgrade notes](https://docs.gitlab.com/update/versions/gitlab_19_changes/)), and Renovate updates the
  forge through the forge.
- Mitigations by option: a hosted forge (GitHub, GitLab.com) removes the forge from the blast radius but
  the self-hosted runner still lives on the server; a self-hosted forge on the old i5-2400 (16 GB, no
  disk after the move, so it would need one) separates forge and target but adds a machine to maintain
  and back up; a lightweight forge on the main server shortens recovery but does not remove the
  dependency.

## Implications for the decision

Options that stand out:

1. **Forgejo (LTS line) + Forgejo Actions on the new server.** Frees several GB of RAM against GitLab,
   keeps everything self-hosted (private infra repo, push mirror to GitHub, registry, native Renovate
   platform), the built-in migrator keeps issues and MRs, and the LTS line gives about 15 months per
   version. Cost: a one-time pipeline rewrite and a trial to confirm Renovate branch automerge on
   Forgejo commit statuses.
2. **Stay on GitLab.** No migration, but the heaviest footprint on a shared 32 GB host, mandatory
   upgrade stops, and recent boot-loop incidents. Makes sense only if GitLab-specific features matter.
3. **GitHub for personal projects (portfolio visibility), self-hosted forge for the infra repo** is a
   hybrid that splits by audience; a full move of the infra repo to GitHub runs into the public repo +
   self-hosted runner problem and pricing uncertainty.

Woodpecker adds value mainly if the owner wants CI independent of the forge; for one small pipeline it
is an extra service. Gitea is technically close to Forgejo; the choice between them is about governance,
licence and LTS.

Questions for the owner:

- Is private code on GitHub acceptable (school projects, the infra repo), or must everything private stay
  self-hosted?
- Which GitLab features are actually used today (issue boards, registry, environments, merge-request
  approvals)? Is the registry used, and for what (`portfolio-app`)?
- Must existing issues and merge-request history be migrated, or is code plus open issues enough?
- Should the forge run on the main server, on the old i5-2400 (needs a disk), or off-site, given that
  it deploys the server it runs on?
- Is a one-time rewrite of `.gitlab-ci.yml` (about five jobs) acceptable?
- Is an LTS line (fewer upgrades) preferred over the latest features?
- Should Renovate stay self-run from CI (current schedule and automerge windows) or use the Mend-hosted
  app where possible?
