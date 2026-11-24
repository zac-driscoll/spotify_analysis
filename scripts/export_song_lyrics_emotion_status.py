"""Export song-level listening counts, lyric lookup status, and emotion assignment."""

import csv
import json
import sqlite3
from collections import defaultdict
from contextlib import closing
from pathlib import Path
from tempfile import NamedTemporaryFile


def read_rows(path):
    with Path(path).open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def combine(statuses):
    values = sorted(set(statuses))
    return values[0] if len(values) == 1 else "Mixed: " + " / ".join(values)


def main():
    catalog = read_rows("data/processed/track_catalog.csv")
    emotions = {r["track_id"]: r["emotion"]
                for r in read_rows("data/emotion/track_primary_emotions.csv")}
    database = Path("data/lyrics/lyrics.sqlite3").resolve().as_uri()
    with closing(sqlite3.connect(f"{database}?mode=ro", uri=True)) as db:
        lyrics = {track: json.loads(result)["LRCLIB Status"]
                  for track, result in db.execute("SELECT track_id, result FROM lyrics")}
    songs = defaultdict(list)
    for row in catalog:
        songs[row["song_key"]].append(row)

    rows = []
    for versions in songs.values():
        lead = max(versions, key=lambda r: (int(r["plays_30s"]), float(r["hours_listened"])))
        ids = [r["track_id"] for r in versions]
        labels = [emotions.get(track_id, "Unscored") for track_id in ids]
        rows.append({
            "Song": lead["track_name"],
            "Artist": lead["artist_name"],
            "Plays (30s+)": sum(int(r["plays_30s"]) for r in versions),
            "Lyric download status": combine(lyrics.get(track_id, "Unchecked") for track_id in ids),
            "Emotion assignment status": combine(
                "Unscored" if label == "Unscored" else f"Assigned: {label}" for label in labels
            ),
        })
    rows.sort(key=lambda r: (-r["Plays (30s+)"], r["Song"].casefold(), r["Artist"].casefold()))
    path = Path("outputs/therapy/song_lyrics_emotion_status.csv")
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=path.parent, mode="w", encoding="utf-8-sig",
                            newline="", delete=False) as stream:
        temporary = Path(stream.name)
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)
    print(f"Exported {len(rows):,} songs to {path}.")


if __name__ == "__main__":
    main()
