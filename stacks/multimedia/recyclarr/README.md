# Recyclarr

Syncs the custom formats and their scores to Radarr and Sonarr, once a day (00:00). The whole ranking of releases lives in this folder instead of the Radarr/Sonarr databases:

- `recyclarr.yml`: which custom formats are synced and their score in each quality profile
- `custom-formats/`: homemade custom formats (MULTI, HDR10, x265), one JSON file per format
- `settings.yml`: declares `custom-formats/` as a source next to TRaSH Guides

The other custom formats (DV without HDR fallback, BR-DISK, LQ, ...) come from [TRaSH Guides](https://trash-guides.info) and follow their updates.

## How the ranking works

- The quality profiles (`HD-1080p`, `Ultra-HD`) are referenced by name only: their qualities, cutoff and upgrade settings are still set in the Radarr/Sonarr UI, and Recyclarr leaves them alone.
- The quality always wins. The custom format score only decides between releases of the same quality: French audio +1000, x265 +100, HDR10 +50.
- A score of -10000 rejects the release (the profiles' minimum score is 0). This covers the known bad releases and Dolby Vision without an HDR10 layer, which only plays by transcoding and the server CPU cannot transcode 4K.

## Rules

- Recyclarr owns every custom format and score listed in `recyclarr.yml`: an edit made in the UI is overwritten at the next sync. Edit the files here.
- `reset_unmatched_scores` sets to 0 the score of any custom format not listed here, in the two profiles above.
- A homemade custom format needs a unique `trash_id` (32 hex characters, any value) in its JSON file, referenced from `recyclarr.yml`.

## First setup

1. Create the volume (before the stack is deployed, or `docker compose up` fails):

   ```bash
   docker volume create recyclarr
   ```

2. Add `RADARR_API_KEY` and `SONARR_API_KEY` to the stack `.env` (Settings > General > API Key in each app).

3. Check what would change, then apply:

   ```bash
   docker compose run --rm recyclarr sync --preview
   docker compose run --rm recyclarr sync
   ```

## Changing a custom format

1. Edit `recyclarr.yml` or the JSON file in `custom-formats/`
2. `docker compose run --rm recyclarr sync --preview` to check
3. `docker compose run --rm recyclarr sync` to apply now (otherwise at the next daily sync)

To find the `trash_id` of a TRaSH custom format: the JSON files in [docs/json/radarr/cf](https://github.com/TRaSH-Guides/Guides/tree/master/docs/json/radarr/cf) (or `sonarr/cf`) of the TRaSH Guides repository.
