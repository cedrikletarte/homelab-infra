# Issue tracker: beads (br)

Issues and specs for this repo live in a local [beads_rust](https://github.com/Dicklesworthstone/beads_rust) workspace (`.beads/`), driven by the `br` CLI. Issue IDs look like `hl-a1b`.

`.beads/` is gitignored on purpose: the repo is mirrored publicly, so tickets never leave this machine. Nothing is backed up remotely; `br` keeps local snapshots under `.beads/.br_history/`.

`br` never commits, pushes or runs a daemon. Every command accepts `--json`; prefix agent calls with `RUST_LOG=error` to keep stderr quiet. `br robot-docs guide` prints the tool's own agent docs.

## Conventions

- **Create an issue**: `br create "Title" --type task|bug|feature|epic --priority 0-4 --description "..."`. For multi-line bodies write the text to a file and pass `--description-file <path>`. Labels at creation: `-l label1,label2`. Quick capture: `br q "Title"` (prints the ID only).
- **Read an issue**: `br show <id>` (includes comments). `br show <id> --json` for machine-readable output.
- **List issues**: `br list --json`, filtered with `--status open`, `--label <label>`, `--priority 0-1`, etc. `br list --tree` shows parent/child structure.
- **Ready work**: `br ready --json` (open, unblocked, not deferred).
- **Search**: `br search "text"` (title, description, id and comments).
- **Comment on an issue**: `br comments add <id> -m "..."` (or `-f <file>` for long text).
- **Apply / remove labels**: `br update <id> --add-label "..."` / `--remove-label "..."`.
- **Claim**: `br update <id> --claim` (assignee = actor, status = `in_progress`).
- **Close**: `br close <id> --reason "..."`. The reason is stored with the issue, so no separate comment is needed. Reopen with `br reopen <id>`.
- **Defer**: `br defer <id> --until <date>` / `br undefer <id>`.

Priorities: 0 = critical, 1 = high, 2 = normal (default), 3 = low, 4 = backlog.

Merge requests still live on the self-hosted GitLab (`glab mr ...`); only issues moved to beads.

## Merge requests as a triage surface

**MRs as a request surface: no.** _(Set to `yes` if this repo treats external merge requests as feature requests; `/triage` reads this flag.)_

## When a skill says "publish to the issue tracker"

Create a beads issue with `br create`.

## When a skill says "fetch the relevant ticket"

Run `br show <id>`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is an epic with **child** issues as tickets.

- **Map**: an epic labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `br create "..." --type epic -l wayfinder:map --description-file <path>`.
- **Child ticket**: `br create "..." --parent <map-id> -l wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
- **Blocking**: native dependency, `br dep add <child> <blocker>` (the child is blocked until the blocker closes). `br blocked` lists blocked issues; `br dep list <id>` shows an issue's links.
- **Frontier query**: `br ready --json`, keep only children of the map (their IDs are dotted under it: `<map-id>.1`, `<map-id>.2`, ...; `br list --tree` shows the hierarchy), drop any with an assignee; first in map order wins.
- **Claim**: `br update <id> --claim`, the session's first write.
- **Resolve**: `br comments add <id> -m "<answer>"`, then `br close <id> --reason "..."`, then append a context pointer (gist + issue ID) to the map's Decisions-so-far (`br update <map-id> --description-file <path>`).
