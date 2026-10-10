"""Asks on Discord before Radarr/Sonarr settle for a release without French and English audio.

The "<name>" quality profiles only accept releases carrying the gate custom format (MULTI FR+EN),
through their minimum score. Each "<name>" profile has a "<name> VO" twin that accepts any language.
For every missing movie or series in a "<name>" profile, the bot runs a release search: when the only
releases left are rejected for their score alone and lack the gate custom format, it posts them on
Discord with two buttons. "Autoriser la VO" moves the item to the VO twin and starts a search,
"Attendre la VF" asks again after SNOOZE_DAYS (Radarr/Sonarr still grab a French release meanwhile).

python bot.py --dry-run [radarr:<id> | sonarr:<id>] analyses without Discord nor state changes.
"""

import argparse
import asyncio
import logging
import os
import re
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime

import aiohttp
import discord
from discord.ext import tasks

log = logging.getLogger("vo-approval")

RADARR_URL = os.environ.get("RADARR_URL", "http://radarr:7878")
SONARR_URL = os.environ.get("SONARR_URL", "http://sonarr:8989")
GATE_CUSTOM_FORMAT = os.environ.get("GATE_CUSTOM_FORMAT", "MULTI FR+EN")
VO_SUFFIX = os.environ.get("VO_SUFFIX", " VO")
CHECK_EVERY_MINUTES = float(os.environ.get("CHECK_EVERY_MINUTES", "15"))
GRACE_HOURS = float(os.environ.get("GRACE_HOURS", "2"))  # let Radarr/Sonarr's own search run first
RECHECK_HOURS = float(os.environ.get("RECHECK_HOURS", "24"))  # one release search per item and per day
SNOOZE_DAYS = float(os.environ.get("SNOOZE_DAYS", "14"))
SEARCH_PAUSE_SECONDS = float(os.environ.get("SEARCH_PAUSE_SECONDS", "30"))  # public indexers rate limit
STATE_DB = os.environ.get("STATE_DB", "/data/state.db")

# Radarr: "... have score 1150 below Movie's profile minimum 5000", Sonarr: "below Series profile minimum"
SCORE_REJECTION = re.compile(r"have score -?\d+ below .*minimum", re.IGNORECASE)
# "WEBDL-1080p is not wanted in profile": the quality is excluded by the profile
QUALITY_REJECTION = re.compile(r"is not wanted in profile", re.IGNORECASE)

COLOR_ASK = 0xE5A00D
COLOR_APPROVED = 0x2ECC71
COLOR_CLOSED = 0x95A5A6


# ─── Radarr / Sonarr ──────────────────────────────────────────────────────────


@dataclass
class Item:
    app: str  # "radarr" | "sonarr"
    id: int
    title: str
    profile: str
    poster: str | None
    detail: str  # what is missing, shown in the message
    season: int | None = None  # Sonarr: the season searched


class Arr:
    def __init__(self, app: str, url: str, key: str, session: aiohttp.ClientSession):
        self.app, self.url, self.key, self.session = app, url.rstrip("/"), key, session
        self.label = app.capitalize()

    async def call(self, method: str, path: str, timeout: float = 30, **kwargs):
        async with self.session.request(
            method,
            f"{self.url}/api/v3/{path}",
            headers={"X-Api-Key": self.key},
            timeout=aiohttp.ClientTimeout(total=timeout),
            **kwargs,
        ) as resp:
            resp.raise_for_status()
            return await resp.json() if resp.content_type == "application/json" else None

    async def profiles(self) -> tuple[dict[int, str], dict[str, int]]:
        """Profile names by id, and for each gated profile the id of its VO twin."""
        names = {p["id"]: p["name"] for p in await self.call("GET", "qualityprofile")}
        ids = {name: pid for pid, name in names.items()}
        twins = {name: ids[name + VO_SUFFIX] for name in ids if name + VO_SUFFIX in ids}
        return names, twins

    async def queued(self) -> set[int]:
        key = "movieId" if self.app == "radarr" else "seriesId"
        queue = await self.call("GET", "queue", params={"pageSize": 1000})
        return {r[key] for r in queue["records"] if key in r}

    async def candidates(self) -> dict[int, Item]:
        """Missing items of a gated profile, past the grace period and not downloading."""
        names, twins = await self.profiles()
        queued = await self.queued()
        cutoff = time.time() - GRACE_HOURS * 3600
        found = {}
        if self.app == "radarr":
            for m in await self.call("GET", "movie"):
                profile = names.get(m["qualityProfileId"])
                if (
                    profile in twins
                    and m["monitored"]
                    and not m["hasFile"]
                    and m.get("isAvailable")
                    and m["id"] not in queued
                    and _ts(m.get("added")) < cutoff
                ):
                    found[m["id"]] = Item(
                        "radarr", m["id"], f"{m['title']} ({m['year']})", profile, _poster(m), "Film manquant"
                    )
            return found

        series = {s["id"]: s for s in await self.call("GET", "series")}
        missing = await self.call(
            "GET", "wanted/missing", params={"pageSize": 1000, "monitored": "true", "sortKey": "airDateUtc"}
        )
        episodes: dict[int, list] = {}
        for e in missing["records"]:
            episodes.setdefault(e["seriesId"], []).append(e)
        for sid, eps in episodes.items():
            s = series.get(sid)
            profile = names.get(s["qualityProfileId"]) if s else None
            if profile not in twins or not s["monitored"] or sid in queued:
                continue
            eps.sort(key=lambda e: (e["seasonNumber"] == 0, e["seasonNumber"], e["episodeNumber"]))
            first = eps[0]
            if max(_ts(s.get("added")), _ts(first.get("airDateUtc"))) > cutoff:
                continue
            in_season = sum(e["seasonNumber"] == first["seasonNumber"] for e in eps)
            found[sid] = Item(
                "sonarr",
                sid,
                s["title"],
                profile,
                _poster(s),
                f"Saison {first['seasonNumber']} : {in_season} épisode(s) manquant(s)",
                first["seasonNumber"],
            )
        return found

    async def releases(self, item: Item) -> list[dict]:
        if self.app == "radarr":
            params = {"movieId": item.id}
        else:
            params = {"seriesId": item.id, "seasonNumber": item.season}
        return await self.call("GET", "release", timeout=300, params=params)

    async def search(self, item_id: int):
        if self.app == "radarr":
            body = {"name": "MoviesSearch", "movieIds": [item_id]}
        else:
            body = {"name": "SeriesSearch", "seriesId": item_id}
        await self.call("POST", "command", json=body)

    async def allow_vo(self, item_id: int) -> str:
        """Moves the item to the VO twin of its profile and searches. Returns the new profile name."""
        names, twins = await self.profiles()
        path = f"{'movie' if self.app == 'radarr' else 'series'}/{item_id}"
        obj = await self.call("GET", path)
        profile = names.get(obj["qualityProfileId"], "?")
        if profile not in twins:
            raise ValueError(f"le profil « {profile} » n'a pas de version VO (déjà autorisé ?)")
        obj["qualityProfileId"] = twins[profile]
        await self.call("PUT", path, json=obj)
        await self.search(item_id)
        return profile + VO_SUFFIX


def _ts(value: str | None) -> float:
    return datetime.fromisoformat(value).timestamp() if value else 0.0


def _poster(obj: dict) -> str | None:
    return next((i.get("remoteUrl") for i in obj.get("images", []) if i.get("coverType") == "poster"), None)


# ─── Release analysis ─────────────────────────────────────────────────────────


def _has_gate(release: dict) -> bool:
    return any(cf["name"] == GATE_CUSTOM_FORMAT for cf in release.get("customFormats", []))


def _best(releases: list[dict]) -> dict | None:
    return max(releases, key=lambda r: (r.get("qualityWeight", 0), r.get("customFormatScore", 0)), default=None)


def analyse(releases: list[dict]) -> dict:
    """Splits a search result.

    takeable: what the profile accepts now (Radarr/Sonarr only need a new search)
    vo:       releases without the gate custom format, rejected for their score alone
              and that the VO twin (minimum score 0) would accept
    refused:  releases with the gate custom format whose only fault is a quality the profile excludes
              (French and English exist, in another resolution)
    """
    takeable = [r for r in releases if r.get("approved") or r.get("temporarilyRejected")]
    vo = [
        r
        for r in releases
        if not _has_gate(r)
        and r.get("customFormatScore", 0) >= 0
        and r.get("rejections")
        and all(SCORE_REJECTION.search(x) for x in r["rejections"])
    ]
    refused = [
        r
        for r in releases
        if _has_gate(r) and r.get("rejections") and all(QUALITY_REJECTION.search(x) for x in r["rejections"])
    ]
    return {"takeable": takeable, "vo": vo, "refused": refused}


def _describe(release: dict) -> str:
    langs = ", ".join(lang["name"] for lang in release.get("languages", [])) or "langue inconnue"
    size = release.get("size", 0) / 1e9
    return f"{release['quality']['quality']['name']} · {langs} · {size:.1f} Go\n`{release['title'][:150]}`"


# ─── State ────────────────────────────────────────────────────────────────────


class State:
    """Per item: last release search, and the open Discord message (asked) or the snooze (waiting)."""

    def __init__(self, path: str):
        self.db = sqlite3.connect(path)
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS items (app TEXT, item_id INTEGER, checked_at REAL DEFAULT 0,"
            " status TEXT DEFAULT 'none', message_id INTEGER, until REAL DEFAULT 0, PRIMARY KEY (app, item_id))"
        )
        self.db.commit()

    def get(self, app: str, item_id: int) -> dict:
        row = self.db.execute(
            "SELECT checked_at, status, message_id, until FROM items WHERE app = ? AND item_id = ?", (app, item_id)
        ).fetchone()
        return dict(zip(("checked_at", "status", "message_id", "until"), row or (0, "none", None, 0)))

    def set(self, app: str, item_id: int, **fields):
        current = self.get(app, item_id) | fields
        self.db.execute(
            "INSERT OR REPLACE INTO items VALUES (?, ?, ?, ?, ?, ?)",
            (app, item_id, current["checked_at"], current["status"], current["message_id"], current["until"]),
        )
        self.db.commit()

    def delete(self, app: str, item_id: int):
        self.db.execute("DELETE FROM items WHERE app = ? AND item_id = ?", (app, item_id))
        self.db.commit()

    def open_items(self) -> list[tuple[str, int, dict]]:
        rows = self.db.execute("SELECT app, item_id FROM items WHERE status IN ('asked', 'waiting')").fetchall()
        return [(app, item_id, self.get(app, item_id)) for app, item_id in rows]


# ─── Discord ──────────────────────────────────────────────────────────────────


def _embed(item: Item, result: dict) -> discord.Embed:
    vo, refused = result["vo"], result["refused"]
    embed = discord.Embed(
        title=item.title,
        description=(
            f"Aucune version **anglais + français** trouvée. {len(vo)} version(s) sans le français disponible(s).\n"
            f"{item.detail}."
        ),
        color=COLOR_ASK,
    )
    embed.add_field(name="Meilleure version disponible", value=_describe(_best(vo)), inline=False)
    if refused:
        best = _best(refused)
        reason = next((x for x in best["rejections"] if x), "refusée")
        embed.add_field(
            name=f"Versions anglais + français dans une qualité exclue du profil : {len(refused)}",
            value=f"{_describe(best)}\n{reason}",
            inline=False,
        )
    if item.poster:
        embed.set_thumbnail(url=item.poster)
    embed.set_footer(text=f"{item.app.capitalize()} · profil {item.profile} · {item.app}:{item.id}")
    return embed


def _close(embed: discord.Embed, color: int, name: str, value: str) -> discord.Embed:
    embed.color = color
    embed.add_field(name=name, value=value, inline=False)
    return embed


class Decision(
    discord.ui.DynamicItem[discord.ui.Button],
    template=r"vo:(?P<action>allow|wait):(?P<app>radarr|sonarr):(?P<id>\d+)",
):
    """The two buttons. Everything they need is in their custom_id, so they keep working after a restart."""

    def __init__(self, action: str, app: str, item_id: int):
        allow = action == "allow"
        super().__init__(
            discord.ui.Button(
                label="Autoriser la VO" if allow else "Attendre la VF",
                style=discord.ButtonStyle.success if allow else discord.ButtonStyle.secondary,
                custom_id=f"vo:{action}:{app}:{item_id}",
            )
        )
        self.action, self.app, self.item_id = action, app, item_id

    @classmethod
    async def from_custom_id(cls, interaction, item, match):
        return cls(match["action"], match["app"], int(match["id"]))

    async def callback(self, interaction: discord.Interaction):
        bot: "Bot" = interaction.client
        if interaction.user.id not in bot.approvers:
            await interaction.response.send_message("Tu n'es pas autorisé à décider.", ephemeral=True)
            return
        await interaction.response.defer()
        embed = interaction.message.embeds[0] if interaction.message.embeds else discord.Embed()
        who = interaction.user.mention
        if self.action == "allow":
            try:
                profile = await bot.arrs[self.app].allow_vo(self.item_id)
            except Exception as exc:  # noqa: BLE001 - reported to the user, the message stays open
                log.exception("allow %s:%s failed", self.app, self.item_id)
                await interaction.followup.send(f"Échec : {exc}", ephemeral=True)
                return
            bot.state.delete(self.app, self.item_id)
            log.info("%s:%s moved to %s by %s", self.app, self.item_id, profile, interaction.user)
            embed = _close(embed, COLOR_APPROVED, "VO autorisée", f"par {who}, profil « {profile} », recherche lancée")
        else:
            until = time.time() + SNOOZE_DAYS * 86400
            bot.state.set(self.app, self.item_id, status="waiting", until=until)
            log.info("%s:%s snoozed by %s", self.app, self.item_id, interaction.user)
            embed = _close(embed, COLOR_CLOSED, "En attente de la VF", f"par {who}, nouvelle vérification <t:{int(until)}:R>")
        await interaction.edit_original_response(embed=embed, view=None)


def _buttons(item: Item) -> discord.ui.View:
    view = discord.ui.View(timeout=None)
    view.add_item(Decision("allow", item.app, item.id))
    view.add_item(Decision("wait", item.app, item.id))
    return view


class Bot(discord.Client):
    def __init__(self, channel_id: int, approvers: set[int], keys: dict[str, str]):
        super().__init__(intents=discord.Intents.none())
        self.channel_id, self.approvers, self.keys = channel_id, approvers, keys
        self.arrs: dict[str, Arr] = {}
        self.state = State(STATE_DB)

    async def setup_hook(self):
        session = aiohttp.ClientSession()
        self.arrs = {
            "radarr": Arr("radarr", RADARR_URL, self.keys["radarr"], session),
            "sonarr": Arr("sonarr", SONARR_URL, self.keys["sonarr"], session),
        }
        self.add_dynamic_items(Decision)
        self.check.change_interval(minutes=CHECK_EVERY_MINUTES)
        self.check.start()

    @tasks.loop(minutes=15)
    async def check(self):
        channel = self.get_channel(self.channel_id) or await self.fetch_channel(self.channel_id)
        for arr in self.arrs.values():
            try:
                await self.check_app(arr, channel)
            except Exception:  # noqa: BLE001 - one app down must not stop the other
                log.exception("%s check failed", arr.label)

    @check.before_loop
    async def before_check(self):
        await self.wait_until_ready()

    async def check_app(self, arr: Arr, channel):
        candidates = await arr.candidates()
        await self.close_resolved(arr, channel, candidates)
        now = time.time()
        for item in candidates.values():
            st = self.state.get(arr.app, item.id)
            if st["status"] == "asked" or (st["status"] == "waiting" and now < st["until"]):
                continue
            if now - st["checked_at"] < RECHECK_HOURS * 3600:
                continue
            result = analyse(await arr.releases(item))
            self.state.set(arr.app, item.id, checked_at=time.time())
            if result["takeable"]:
                log.info("%s: %s has an acceptable release, starting a search", arr.label, item.title)
                await arr.search(item.id)
            elif result["vo"]:
                msg = await channel.send(embed=_embed(item, result), view=_buttons(item))
                self.state.set(arr.app, item.id, status="asked", message_id=msg.id, until=0)
                log.info("%s: asked about %s", arr.label, item.title)
            await asyncio.sleep(SEARCH_PAUSE_SECONDS)

    async def close_resolved(self, arr: Arr, channel, candidates: dict[int, Item]):
        """An asked or waiting item that is no longer missing: its message says so, the state is dropped."""
        for app, item_id, st in self.state.open_items():
            if app != arr.app or item_id in candidates:
                continue
            self.state.delete(app, item_id)
            if st["status"] != "asked" or not st["message_id"]:
                continue
            try:
                msg = await channel.fetch_message(st["message_id"])
                embed = _close(msg.embeds[0] if msg.embeds else discord.Embed(), COLOR_CLOSED, "Résolu", f"N'est plus manquant dans {arr.label} (trouvé, en téléchargement, retiré ou changé de profil)")
                await msg.edit(embed=embed, view=None)
            except discord.HTTPException:
                log.warning("could not update the message of %s:%s", app, item_id)


# ─── Entry points ─────────────────────────────────────────────────────────────


async def dry_run(keys: dict[str, str], only: str | None):
    async with aiohttp.ClientSession() as session:
        for app, url in (("radarr", RADARR_URL), ("sonarr", SONARR_URL)):
            arr = Arr(app, url, keys[app], session)
            if only and not only.startswith(app + ":"):
                continue
            items = await arr.candidates()
            if only:
                item_id = int(only.split(":")[1])
                items = {item_id: items.get(item_id) or await _forced_item(arr, item_id)}
            print(f"== {arr.label}: {len(items)} item(s) to check")
            for item in items.values():
                result = analyse(await arr.releases(item))
                verdict = "search" if result["takeable"] else "ASK" if result["vo"] else "nothing yet"
                print(f"- {item.title} [{item.profile}] {item.detail}: {verdict}")
                for key in ("takeable", "vo", "refused"):
                    best = _best(result[key])
                    if best:
                        print(f"    {key}: {len(result[key])}, best: {_describe(best).replace(chr(10), ' ')}")


async def _forced_item(arr: Arr, item_id: int) -> Item:
    """For --dry-run on an item that is not a candidate (has a file, unmonitored...)."""
    names, _ = await arr.profiles()
    if arr.app == "radarr":
        m = await arr.call("GET", f"movie/{item_id}")
        return Item("radarr", item_id, f"{m['title']} ({m['year']})", names[m["qualityProfileId"]], _poster(m), "test")
    s = await arr.call("GET", f"series/{item_id}")
    season = min((x["seasonNumber"] for x in s["seasons"] if x["seasonNumber"] > 0), default=0)
    return Item("sonarr", item_id, s["title"], names[s["qualityProfileId"]], _poster(s), "test", season)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", nargs="?", const="", metavar="APP:ID")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    keys = {"radarr": os.environ["RADARR_API_KEY"], "sonarr": os.environ["SONARR_API_KEY"]}
    if args.dry_run is not None:
        asyncio.run(dry_run(keys, args.dry_run or None))
        return
    approvers = {int(x) for x in os.environ["DISCORD_APPROVER_IDS"].replace(" ", "").split(",") if x}
    bot = Bot(int(os.environ["DISCORD_CHANNEL_ID"]), approvers, keys)
    bot.run(os.environ["DISCORD_BOT_TOKEN"], log_handler=None)


if __name__ == "__main__":
    main()
