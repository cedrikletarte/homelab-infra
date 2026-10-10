# vo-approval

Movies and series are only downloaded with French and English audio, unless allowed on Discord. When the only releases found lack French or English, a Discord bot posts the best one with two buttons:

- **Autoriser la VO**: moves the movie/series to the VO twin of its profile (`Ultra-HD` -> `Ultra-HD VO`) and starts a search
- **Attendre la VF**: asks again in 14 days. If a French + English release shows up meanwhile, Radarr/Sonarr grab it on their own and the message says so

## How it works

- `HD-1080p` and `Ultra-HD` only accept releases carrying the `MULTI FR+EN` custom format (minimum score 5000, set by [Recyclarr](../recyclarr/README.md)). Their `VO` twin has the same qualities and a minimum score of 0. Seerr requests go to `HD-1080p`/`Ultra-HD` as before.
- Every 15 minutes the bot lists the missing, monitored movies and series of a profile that has a `VO` twin, at least 2 hours after they were added or aired (Radarr/Sonarr search first).
- For each of them, at most once a day, it runs a release search through the Radarr/Sonarr API and sorts the results:
  - a release the profile accepts: nothing to ask, it starts a normal search
  - releases without `MULTI FR+EN` that are rejected for their score alone: it asks on Discord
  - nothing: it checks again the next day
- The message also lists the French + English releases that exist in a quality the profile excludes (only in 1080p for an Ultra-HD movie, for example).
- Searches are spaced by 30 seconds: the public indexers rate limit.
- Only the Discord users in `DISCORD_APPROVER_IDS` can click. The buttons keep working after a restart; the state (last search, open message, snooze) is in the `vo_approval` volume.

The movies/series already downloaded are left alone: an English-only file stays until Radarr/Sonarr find a French + English release of an equal or better quality.

## Setup

1. Create the bot: https://discord.com/developers/applications > New Application > Bot > Reset Token. No privileged intent is needed.
2. Invite it: OAuth2 > URL Generator, scope `bot`, permissions View Channels, Send Messages, Embed Links, Read Message History. Open the URL and pick the server.
3. In the stack `.env`: `DISCORD_BOT_TOKEN`, `DISCORD_CHANNEL_ID` and `DISCORD_APPROVER_IDS` (Discord developer mode, right click > Copy ID). `RADARR_API_KEY`/`SONARR_API_KEY` are the ones Recyclarr uses.
4. Create the volume before the stack is deployed: `docker volume create vo_approval`

## Commands

```bash
# What it would ask, without Discord (runs real release searches)
docker compose run --rm vo-approval --dry-run
docker compose run --rm vo-approval --dry-run radarr:194   # one movie, even if not missing

docker logs -f vo-approval
```

The image is built locally (`pull_policy: build`): every `docker compose up` rebuilds it from the cache, so a change to `bot.py` is deployed like any other change.

## Settings

Environment variables with a default, to add to the service if needed: `CHECK_EVERY_MINUTES` (15), `GRACE_HOURS` (2), `RECHECK_HOURS` (24), `SNOOZE_DAYS` (14), `SEARCH_PAUSE_SECONDS` (30), `GATE_CUSTOM_FORMAT` (`MULTI FR+EN`), `VO_SUFFIX` (` VO`).

Changing the qualities of `HD-1080p` or `Ultra-HD` in the UI: change their `VO` twin the same way.
