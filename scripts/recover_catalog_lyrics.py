"""Retry high-play lyric misses using the typical duration of completed streams."""

import csv
import json
import re
import sqlite3
import unicodedata
from collections import Counter, defaultdict
from contextlib import closing
from difflib import SequenceMatcher
from pathlib import Path

from pyarrow import parquet

from fetch_catalog_lyrics import export_csv
from query_lrclib import USER_AGENT, normalize, request_json, result_columns


def typical_duration(counts):
    if not counts:
        return None
    seconds, _ = counts.most_common(1)[0]
    nearby = sum(counts[s] for s in range(seconds - 2, seconds + 3))
    return seconds if nearby >= 3 and nearby * 2 > counts.total() else None


def match(track, duration, records):
    title = normalize(track["track_name"])
    artist = normalize(track["artist_name"])
    album = normalize(track["album_name"])
    candidates = [
        record for record in records
        if record.get("plainLyrics")
        and normalize(record.get("trackName") or "") == title
        and normalize(record.get("artistName") or "") == artist
        and record.get("duration") is not None
        and abs(record["duration"] - duration) <= 4
    ]
    def distance(record):
        return abs(record["duration"] - duration)

    exact = [record for record in candidates
             if album and normalize(record.get("albumName") or "") == album]
    if exact:
        return min(exact, key=distance), "Exact album with typical completed-play duration"

    # Different album names are acceptable when the lyric text corroborates the recording.
    transcripts = []
    for record in candidates:
        label = normalize(record.get("albumName") or "")
        text = unicodedata.normalize("NFKC", record["plainLyrics"]).casefold()
        text = re.sub(r"(?m)^\s*\[[^\]\n]+\]\s*$", "", text)
        words = tuple(re.findall(r"[^\W_]+", text.replace("’", "'").replace("'", "")))
        if label and words:
            transcripts.append((record, label, words))
    album_count = len({label for _, label, _ in transcripts})
    corroborated = []
    for record, label, words in transcripts:
        support = {
            other_label for _, other_label, other_words in transcripts
            if SequenceMatcher(None, words, other_words, autojunk=False).ratio() >= 0.96
        }
        if len(support) >= 2 and len(support) * 2 > album_count:
            same_release_family = bool(album and label.startswith(album))
            corroborated.append((-len(support), not same_release_family, distance(record), record))
    if corroborated:
        best = min(corroborated, key=lambda candidate: candidate[:3])[3]
        return best, "Corroborated cross-album search with typical completed-play duration"
    return None, ""


def main():
    path = Path("data/lyrics")
    with Path("data/processed/track_catalog.csv").open(encoding="utf-8-sig", newline="") as stream:
        catalog = list(csv.DictReader(stream))
    song_plays = Counter()
    for row in catalog:
        song_plays[row["song_key"]] += int(row["plays_30s"])
    with closing(sqlite3.connect(path / "lyrics.sqlite3")) as db:
        misses = {
            track_id for (track_id,) in db.execute(
                """SELECT track_id FROM lyrics WHERE json_extract(result, '$."LRCLIB Status"') = 'No match'"""
            )
        }
        targets = [r for r in catalog if r["track_id"] in misses and song_plays[r["song_key"]] > 10]
        target_ids = {r["track_id"] for r in targets}
        plays = parquet.read_table("data/processed/music_plays.parquet",
                                   columns=["track_id", "reason_end", "ms_played"])
        completed = defaultdict(Counter)
        for row in plays.to_pylist():
            if row["track_id"] in target_ids and row["reason_end"] == "trackdone":
                completed[row["track_id"]][round(row["ms_played"] / 1000)] += 1
        ordered = sorted(targets, key=lambda r: -float(r["hours_listened"]))
        searches = {}
        recovered = 0
        attempted = 0
        try:
            for track in ordered:
                track_id = track["track_id"]
                duration = typical_duration(completed[track_id])
                if duration is None:
                    continue
                attempted += 1
                key = track["track_name"], track["artist_name"]
                if key not in searches:
                    searches[key] = request_json("search", {
                        "track_name": key[0], "artist_name": key[1],
                    }, USER_AGENT) or []
                record, method = match(track, duration, searches[key])
                if record is not None:
                    payload = result_columns(record, method)
                    with db:
                        db.execute("UPDATE lyrics SET origin = ?, result = ? WHERE track_id = ?",
                                   ("catalog_recovery", json.dumps(payload), track_id))
                    recovered += 1
            print(f"Recovered {recovered}/{attempted} checked variants. "
                  f"{len(targets) - attempted} lacked a reliable duration.", flush=True)
        finally:
            export_csv(db, path / "lyrics.csv")


if __name__ == "__main__":
    main()
