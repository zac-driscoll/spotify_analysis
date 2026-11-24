# Spotify listening and lyrics analysis

Run commands from the repository root. See [AGENTS.md](AGENTS.md) for the listening window, repository layout, and analysis conventions.

## Build the listening catalog

Place the extracted Spotify Extended Streaming History directory at `Spotify Extended Streaming History/` or link it there. Then run:

```sh
Rscript scripts/build_music_data.R
```

The build writes listening events, daily totals, and a track catalog under `data/processed/`.

## Continue on another machine

Clone the repository, rebuild the listening tables using your local Spotify export, and restore the separately transferred SQLite snapshot at `data/lyrics/lyrics.sqlite3`. The NRC emotion workflow reads that database directly. It uses the NRC v0.92 ZIP and the Python dependencies in `requirements-lyrics.txt`. The MiniLM model files are only required for the theme-scoring and semantic similarity workflows.

## Fetch lyrics

```sh
python3 scripts/fetch_catalog_lyrics.py --limit 60
```

The fetcher seeds available lyrics and instrumental records from `data/playlist/spotify_lrclib_lyrics.csv` when that file is present. It checks remaining tracks in descending order of listening time. It saves each completed lookup by Spotify track ID in `data/lyrics/lyrics.sqlite3` and exports `data/lyrics/lyrics.csv`. Repeating the command continues with the next batch. Previously unresolved playlist tracks can be checked again against the catalog metadata. LRCLIB requests send track title, artist, album, and approximate duration.

Omit `--limit` to check the entire remaining catalog. The CSV is refreshed every 100 completed lookups and when the run ends.

The `est_duration_s` catalog field is the longest observed play. A partial play can therefore make a duration-based match fail. Keep unmatched rows visible when calculating lyric coverage.

Run `.venv/bin/python scripts/recover_catalog_lyrics.py` to retry saved no-matches for songs with more than 10 plays of at least 30 seconds. It requires normalized title and artist agreement and a consistent duration from completed streams. It prefers the same album and can accept a cross-album match when multiple album listings corroborate one lyric text. Successful recoveries update the lyrics cache and CSV. The command leaves unchecked tracks out of the queue.

Run `python3 scripts/reuse_catalog_lyrics.py` to share cached plain lyrics across identical titles and artists. It skips named alternate versions, existing matches, instrumental records, and groups with conflicting cached lyrics. Reuse is recorded in the lyrics CSV and does not make network requests.

## Previous playlist analysis

The local `data/playlist/` directory contains the original exports, lyric cache, semantic results, findings, and visualizations. `lyric_semantic_analysis.csv` carries Spotify URLs that can be joined to the listening catalog by track ID. The results describe the original playlist sample and its theme and similarity analyses. The method is documented in `lyric_semantic_findings.md`.

The R scripts in `scripts/playlist/` recreate the earlier playlist charts from the repository root. The emotion plot accepts an optional local NRC Emotion Lexicon ZIP as its first argument and downloads it if omitted.

## Score lyrics while fetching

Create a Python 3.12 environment and install the dependencies in `requirements-lyrics.txt`. Place the prior multilingual MiniLM ONNX model and tokenizer at `data/models/minilm/model.onnx` and `data/models/minilm/tokenizer.json`. The current workspace has both files.

```sh
.venv/bin/python scripts/score_lyrics.py
Rscript scripts/summarize_lyric_listening.R
```

The scorer reads a point-in-time view of the SQLite lyrics cache and runs locally. It splits plain lyrics into sections of up to four lines, removes repeated lines, and scores theme definitions against both the song and its best-matching section. Prior close readings take precedence for the same Spotify track ID. Run the scorer again to pick up new lyrics. Previously embedded sections are reused.

The listening summary joins primary themes to the playback history and writes `outputs/therapy/lyric_listening_summary.md` and its weekly and era tables. It reports coverage by listening time and by plays of at least 30 seconds. Model labels are suggestions about lyrics and are intended for review alongside your own interpretations.

## Cluster songs with similar lyrics

After generating the listening summary, run:

```sh
.venv/bin/python scripts/cluster_lyrics.py
Rscript scripts/plot_lyric_clusters.R
```

Clustering reuses the local MiniLM section embeddings and compares K-means solutions using cosine silhouette. Identical prepared lyrics contribute one point to the fit. All matching Spotify track IDs contribute their actual listening time to the era summaries. The report, PCA map, and era chart are under `outputs/therapy/`. Cluster IDs can change when the lyrics snapshot grows.

## Cluster songs by emotional language

Save the NRC Emotion Lexicon v0.92 ZIP at `data/models/nrc/NRC-Emotion-Lexicon-v0.92.zip` or pass its path with `--lexicon`.

```sh
.venv/bin/python scripts/cluster_lyric_emotions.py
Rscript scripts/plot_lyric_emotion_clusters.R
Rscript scripts/plot_lyric_emotions_over_time.R
Rscript scripts/plot_daily_lyric_emotions.R
```

The analysis reuses the earlier playlist's eight word-association rates and applies them to a fresh snapshot of English lyrics. It standardizes the eight rates before fitting song groups. See `outputs/therapy/lyric_emotion_clusters.md` for examples, coverage, and the clustering diagnostics.

The time series charts show trailing 30-day cluster shares and listening-time-weighted emotion scores. The cluster chart includes the share of all listening time with a score. Rolling and calendar-year figures are also available as CSVs.

The daily stacked charts assign each track its strongest relative emotion among categories with at least one NRC word hit. Each category is compared with its own baseline across the scored lyric versions. The charts show daily listening hours and percentages with unscored listening included. Days without listening have no percentage.

The same script writes `daily_sadness_minutes.png` and its CSV with daily minutes and a trailing 30-day mean for tracks assigned Sadness.

The unfaceted daily line charts are `daily_lyric_emotion_hours_lines.png` and `daily_lyric_emotion_percent_lines.png`. Faint lines show daily data. Bold lines show average hours per day and the share of all listening time over trailing 30-day windows.

The emotion time series exclude clearly labeled background-noise recordings using track and album metadata. The exclusion applies to both the listening totals and the percentage denominator.

Run `python3 scripts/export_song_lyrics_emotion_status.py` after updating the scores to refresh the song-level status CSV. Play counts are summed across Spotify versions, and mixed statuses list the differences.

Run `.venv/bin/python scripts/plot_lyric_wordclouds.py` to update the 2024 and 2025 lyric word clouds under `outputs/therapy/`. They use a fresh snapshot of English lyrics, count repeated lyric lines once per track, omit stop words and common vocal filler, and distribute each track's listening time over its retained words. Word sizes are scaled separately for each year.

Raw history, personal data and charts, and fetched lyrics stay local under the ignored paths.
