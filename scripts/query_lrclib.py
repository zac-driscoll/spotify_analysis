"""Fetch LRCLIB lyrics for a Spotify CSV export."""

import argparse
import csv
import json
import random
import re
import sys
import time
import unicodedata
from http.client import RemoteDisconnected
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


BASE_URL = "https://lrclib.net"
USER_AGENT = "SemanticAnalysis/0.1 (local Spotify CSV lyrics analysis)"
FEATURE_SUFFIX = re.compile(r"\s*[\[(](?:feat\.?|ft\.?)\s+[^)\]]+[)\]]$", re.IGNORECASE)
RESULT_FIELDS = [
    "LRCLIB Status", "LRCLIB Match Method", "LRCLIB ID", "LRCLIB URL",
    "LRCLIB Title", "LRCLIB Artist", "LRCLIB Album", "LRCLIB Duration (s)",
    "Plain Lyrics", "Synced Lyrics",
]


def request_json(endpoint, params, user_agent):
    request = Request(
        f"{BASE_URL}/api/{endpoint}?{urlencode(params)}",
        headers={"User-Agent": user_agent},
    )
    for attempt in range(5):
        time.sleep(1.05)
        try:
            with urlopen(request, timeout=20) as response:
                return json.load(response)
        except HTTPError as error:
            if error.code == 404:
                return None
            if attempt == 4 or error.code not in (429, 500, 502, 503, 504):
                raise
            retry_after = error.headers.get("Retry-After", "")
            delay = int(retry_after) if retry_after.isdecimal() else 2 ** attempt
            time.sleep(delay + random.uniform(0, delay * 0.3))
        except (URLError, TimeoutError, RemoteDisconnected):
            if attempt == 4:
                raise
            time.sleep(2 ** attempt)


def normalize(value):
    value = unicodedata.normalize("NFKC", value).casefold()
    return "".join(char for char in value if char.isalnum())


def title_key(title):
    return normalize(FEATURE_SUFFIX.sub("", title))


def has_lyrics_or_instrumental(record):
    return record and (record.get("plainLyrics") or record.get("syncedLyrics")
                       or record.get("instrumental"))


def find_record(track, user_agent):
    minutes, seconds = map(int, track["Duration"].split(":"))
    duration = minutes * 60 + seconds
    params = {
        "track_name": track["Title"], "artist_name": track["Artist"],
        "album_name": track["Album"], "duration": duration,
    }
    record = request_json("get", params, user_agent)
    if has_lyrics_or_instrumental(record):
        return record, "Signature"

    primary_artist = track["Artist"].split(", ", 1)[0]
    search_title = FEATURE_SUFFIX.sub("", track["Title"])
    records = request_json("search", {
        "track_name": search_title,
        "artist_name": primary_artist,
    }, user_agent) or []
    match = best_search_match(track, duration, primary_artist, records)
    if match:
        return match, "Search"
    match = keyword_search(track, user_agent)
    if match:
        return match, "Keyword search"
    return record, "Signature" if record else ""


def keyword_search(track, user_agent):
    minutes, seconds = map(int, track["Duration"].split(":"))
    primary_artist = track["Artist"].split(", ", 1)[0]
    search_title = FEATURE_SUFFIX.sub("", track["Title"])
    records = request_json("search", {"q": f"{search_title} {primary_artist}"}, user_agent) or []
    return best_search_match(track, minutes * 60 + seconds, primary_artist, records)


def best_search_match(track, duration, primary_artist, records):
    candidates = []
    for candidate in records:
        if title_key(candidate["trackName"]) != title_key(track["Title"]):
            continue
        artists = re.split(r",\s*|\s+[&;]\s+|\s+feat\.?\s+",
                           candidate["artistName"], flags=re.IGNORECASE)
        if normalize(primary_artist) not in {
            normalize(artist) for artist in [candidate["artistName"], *artists]
        }:
            continue
        candidate_duration = candidate.get("duration")
        if candidate_duration is None:
            continue
        difference = abs(candidate_duration - duration)
        if difference > 4:
            continue
        if has_lyrics_or_instrumental(candidate):
            same_album = normalize(candidate.get("albumName") or "") == normalize(track["Album"])
            candidates.append(((not same_album, difference), candidate))
    if candidates:
        return min(candidates, key=lambda entry: entry[0])[1]
    return None


def result_columns(record, method):
    if not record:
        return {"LRCLIB Status": "No match"}
    plain = record.get("plainLyrics") or ""
    synced = record.get("syncedLyrics") or ""
    status = "Lyrics found" if plain or synced else "No lyrics in record"
    if record.get("instrumental") and not (plain or synced):
        status = "Instrumental"
    return dict(zip(RESULT_FIELDS, (
        status, method, record["id"], f"{BASE_URL}/api/get/{record['id']}",
        record["trackName"], record["artistName"], record["albumName"],
        record["duration"], plain, synced,
    )))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", type=Path)
    parser.add_argument("--limit", type=int, help="number of tracks to check")
    parser.add_argument("--output", type=Path, help="write or resume a CSV of results")
    parser.add_argument("--user-agent", default=USER_AGENT)
    args = parser.parse_args()
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be positive")

    limit = args.limit
    if args.output is None and limit is None:
        limit = 3
    with args.csv_path.open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        fields = reader.fieldnames + RESULT_FIELDS
        tracks = list(reader)[:limit]

    if args.output is None:
        for track in tracks:
            record, _ = find_record(track, args.user_agent)
            if record:
                print(json.dumps(record), flush=True)
            else:
                print(f"No match for {track['Title']} by {track['Artist']}.", file=sys.stderr)
        return

    completed = []
    if args.output.exists():
        with args.output.open(encoding="utf-8-sig", newline="") as source:
            reader = csv.DictReader(source, strict=True)
            if reader.fieldnames != fields:
                parser.error("Output CSV header does not match the expected columns")
            completed = list(reader)
        if len(completed) > len(tracks) or any(
            any(result[field] != value for field, value in track.items())
            or not result["LRCLIB Status"]
            or None in result.values()
            for result, track in zip(completed, tracks)
        ):
            parser.error("Output CSV rows do not match the input prefix")

    with args.output.open("a", encoding="utf-8-sig", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        if not completed and output.tell() == 0:
            writer.writeheader()
        for index, track in enumerate(tracks[len(completed):], len(completed) + 1):
            record, method = find_record(track, args.user_agent)
            writer.writerow(track | result_columns(record, method))
            output.flush()
            if index % 25 == 0 or index == len(tracks):
                print(f"Checked {index}/{len(tracks)} tracks.", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
