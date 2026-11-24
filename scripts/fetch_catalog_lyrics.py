"""Seed lyrics from the playlist cache and fetch missing Spotify catalog tracks."""

import argparse
import csv
import json
import re
import sqlite3
from contextlib import closing
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.parse import urlparse

from query_lrclib import RESULT_FIELDS, USER_AGENT, find_record, result_columns


def read_rows(path):
    with path.open(encoding="utf-8-sig", newline="") as source:
        return list(csv.DictReader(source))


def seed_cache(db, path):
    entries = []
    for row in read_rows(path):
        track_id = urlparse(row["Spotify URL"]).path.rsplit("/", 1)[-1]
        if not re.fullmatch(r"[A-Za-z0-9]{22}", track_id):
            raise ValueError("Invalid Spotify track ID in playlist cache")
        if row["LRCLIB Status"] in ("Lyrics found", "Instrumental"):
            result = {field: row[field] for field in RESULT_FIELDS}
            entries.append((track_id, "playlist_cache", json.dumps(result)))
    with db:
        db.executemany("INSERT OR IGNORE INTO lyrics VALUES (?, ?, ?)", entries)


def lookup(row):
    duration = int(row["est_duration_s"])
    minutes, seconds = divmod(duration, 60)
    track = {
        "Title": row["track_name"],
        "Artist": row["lyrics_query_artist"],
        "Album": row["album_name"],
        "Duration": f"{minutes}:{seconds:02d}",
    }
    record, method = find_record(track, USER_AGENT)
    if not record and row["lyrics_query_title"] != track["Title"]:
        track["Title"] = row["lyrics_query_title"]
        record, method = find_record(track, USER_AGENT)
        if record:
            method += " (cleaned title)"
    return result_columns(record, method)


def export_csv(db, output):
    # Publish a complete CSV while SQLite keeps each completed lookup durable.
    with db:
        db.execute("BEGIN IMMEDIATE")
        with NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="", dir=output.parent, delete=False
        ) as temporary:
            path = Path(temporary.name)
            writer = csv.DictWriter(
                temporary, fieldnames=["track_id", "cache_origin", *RESULT_FIELDS]
            )
            writer.writeheader()
            for track_id, origin, result in db.execute(
                "SELECT * FROM lyrics ORDER BY track_id"
            ):
                writer.writerow(
                    {"track_id": track_id, "cache_origin": origin, **json.loads(result)}
                )
        path.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=Path("data/processed/track_catalog.csv"))
    parser.add_argument("--seed", type=Path, default=Path("data/playlist/spotify_lrclib_lyrics.csv"))
    parser.add_argument("--output-dir", type=Path, default=Path("data/lyrics"))
    parser.add_argument("--limit", type=int, help="maximum number of new tracks to check")
    args = parser.parse_args()
    if args.limit is not None and args.limit < 0:
        parser.error("--limit must be nonnegative")

    catalog = read_rows(args.catalog)
    ordered = sorted(catalog, key=lambda row: -float(row["hours_listened"]))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(args.output_dir / "lyrics.sqlite3")) as db:
        db.execute(
            "CREATE TABLE IF NOT EXISTS lyrics "
            "(track_id TEXT PRIMARY KEY NOT NULL, origin TEXT NOT NULL, result TEXT NOT NULL)"
        )
        if args.seed.exists():
            seed_cache(db, args.seed)
        done = {track_id for (track_id,) in db.execute("SELECT track_id FROM lyrics")}
        pending = [row for row in ordered if row["track_id"] not in done]
        batch = pending[:args.limit]
        print(f"{len(pending):,} tracks pending. Checking {len(batch):,}.", flush=True)
        output = args.output_dir / "lyrics.csv"
        try:
            for index, row in enumerate(batch, 1):
                result = lookup(row)
                with db:
                    db.execute(
                        "INSERT OR IGNORE INTO lyrics VALUES (?, ?, ?)",
                        (row["track_id"], "catalog_lookup", json.dumps(result)),
                    )
                if index % 10 == 0 or index == len(batch):
                    print(f"Checked {index:,}/{len(batch):,} tracks.", flush=True)
                if index % 100 == 0 and index < len(batch):
                    export_csv(db, output)
        finally:
            export_csv(db, output)


if __name__ == "__main__":
    main()
