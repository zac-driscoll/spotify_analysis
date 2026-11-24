"""Reuse local lyrics between Spotify IDs for the same song."""

import csv
import json
import re
import sqlite3
import unicodedata
from collections import defaultdict
from contextlib import closing
from difflib import SequenceMatcher
from pathlib import Path

from fetch_catalog_lyrics import export_csv


VERSION_IN_TITLE = re.compile(
    r"(?:\b(?:feat|ft|featuring)\.?\s|(?:\s[-–—]\s|[([]).*\b"
    r"(?:live|acoustic|remix|demo|instrumental|karaoke|sped up|slowed|radio edit)\b)",
    re.IGNORECASE,
)
VERSION_IN_ALBUM = re.compile(
    r"\b(?:live (?:at|from|in)|acoustic|remixes?|demos?|instrumental|karaoke|sped up|slowed|circle sessions)\b",
    re.IGNORECASE,
)


def key(text):
    return " ".join(unicodedata.normalize("NFKC", text).casefold().split())


def group_tracks(catalog):
    groups = defaultdict(list)
    for row in catalog:
        name, artist, album = row["track_name"], row["artist_name"], row["album_name"]
        if name and artist and not (VERSION_IN_TITLE.search(name) or VERSION_IN_ALBUM.search(album)):
            groups[(key(name), key(artist))].append(row)
    return groups


def lyric_words(text):
    text = re.sub(r"(?m)^\s*\[[^\]\n]+\]\s*$", "", text)
    return tuple(re.findall(r"[^\W_]+", key(text).replace("’", "'").replace("'", "")))


def choose_source(tracks, cache):
    originals = []
    for track in tracks:
        track_id = track["track_id"]
        origin, payload = cache.get(track_id, ("", {}))
        text = (payload.get("Plain Lyrics") or "").strip()
        if origin != "catalog_reuse" and payload.get("LRCLIB Status") == "Lyrics found" and text:
            originals.append((track, payload, lyric_words(text)))
    if not originals:
        return None
    lead, payload, reference = max(originals, key=lambda item: float(item[0]["hours_listened"]))
    if not reference or any(
        SequenceMatcher(None, reference, words, autojunk=False).ratio() < 0.96
        for _, _, words in originals
    ):
        return None
    return lead["track_id"], payload


def reuse_updates(groups, cache):
    for tracks in groups.values():
        if len(tracks) < 2:
            continue
        source = choose_source(tracks, cache)
        if source is None:
            continue
        source_id, payload = source
        for track in tracks:
            track_id = track["track_id"]
            _, existing = cache.get(track_id, ("", {}))
            if existing and existing["LRCLIB Status"] not in {"No match", "No lyrics in record"}:
                continue
            reused = {**payload, "LRCLIB Match Method": f"Reused same-song lyrics from Spotify ID {source_id}"}
            # Synced timestamps may differ between releases. Transfer only the plain text.
            reused["Synced Lyrics"] = ""
            yield track_id, json.dumps(reused), float(track["hours_listened"])


def main():
    with Path("data/processed/track_catalog.csv").open(encoding="utf-8-sig", newline="") as stream:
        groups = group_tracks(csv.DictReader(stream))
    directory = Path("data/lyrics")
    with closing(sqlite3.connect(directory / "lyrics.sqlite3")) as db:
        with db:
            db.execute("BEGIN IMMEDIATE")
            cache = {
                track_id: (origin, json.loads(payload))
                for track_id, origin, payload in db.execute("SELECT track_id, origin, result FROM lyrics")
            }
            updates = list(reuse_updates(groups, cache))
            db.executemany("""
                INSERT INTO lyrics (track_id, origin, result) VALUES (?, 'catalog_reuse', ?)
                ON CONFLICT(track_id) DO UPDATE SET origin = excluded.origin, result = excluded.result
                """, ((track_id, payload) for track_id, payload, _ in updates))
        export_csv(db, directory / "lyrics.csv")
    print(f"Reused lyrics for {len(updates):,} Spotify IDs representing "
          f"{sum(hours for _, _, hours in updates):.1f} hours of listening.")


if __name__ == "__main__":
    main()
