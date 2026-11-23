# my_spotify_data — Project Memory

Personal analysis of my Spotify Extended Streaming History. Not an MMSD project.

This file is the shared memory for every AI agent working here (Codex reads
`AGENTS.md`; Claude Code reads `CLAUDE.md`, which only imports this file).
Edit this file only. Update **Status** and **Decision log** at the end of each
session so the next agent (on either machine) can pick up where the last left off.

## Goal

Quantify music listening from **2023-01-01 to present** for discussion in therapy:
listening over time (hours/day, plays/day), then attach an emotion profile to each
song from its lyrics and track how the emotional tone of what I listen to changes.

Focus is **music**. Podcasts and audiobooks are excluded from the analysis tables.

## Layout

| Path | What | In git? |
|---|---|---|
| `Spotify Extended Streaming History/` | Raw Spotify export (JSON + ReadMe PDF) | **No** — contains IP addresses |
| `R/spotify_helpers.R` | Load, clean, summarise functions | Yes |
| `scripts/build_music_data.R` | Builds `data/processed/` from raw export | Yes |
| `data/processed/` | Derived tables (see below) | **No** — personal listening history |
| `data/lyrics/` | Fetched lyrics (planned) | **No** — copyrighted text |
| `data/emotion/` | Emotion scores per track (planned) | No |

Rebuild everything from the project root: `Rscript scripts/build_music_data.R`
(R 4.5; packages: jsonlite, dplyr, purrr, stringr, lubridate, tibble, arrow, readr).

## Derived tables (`data/processed/`)

**`music_plays.parquet`** (also `.rds`) — one row per music stream since 2023-01-01.
Key columns: `ts_start_local`, `date_local`, `hour_local`, `ms_played`,
`minutes_played`, `is_play` (≥30 s), `track_id`, `track_uri`, `track_name`,
`artist_name`, `album_name`, `platform`, `reason_start`, `reason_end`, `shuffle`,
`skipped`, `source_file`. `ip_addr` is dropped.

**`daily_listening.csv`** — one row per local calendar day from 2023-01-01 to the
last day with data, **including zero days**. Columns: `hours_listened`, `streams`,
`plays_30s`, `skips`, `skip_rate`, `unique_tracks`, `unique_artists`,
`first_play_local`, `last_play_local`, `weekday`, `week`, `month`.

**`track_catalog.csv`** — one row per unique track (join key `track_id`). Work queue
for lyrics. Columns: names, `plays_30s`, `streams`, `hours_listened`,
`est_duration_s` (longest observed play; proxy for track length), first/last played,
`lyrics_query_title` (title with "- Remaster", "(feat. …)" etc. stripped),
`lyrics_query_artist`. Sorted by `plays_30s` descending.

## Raw export: facts verified against the data

- Files are split by **size, not calendar year** (e.g. `2024.json` covers
  2023-12-30 → 2024-10-19, `2024_1.json` the rest; `2023.json` starts 2022-12-31).
  Always load all files and filter on `ts`.
- `ts` is ISO 8601 **UTC** (`2024-10-19T14:48:25Z`) and marks when the stream
  **ended**. Start = `ts − ms_played`.
- Actual schema differs from the ReadMe PDF: `ip_addr` (not `ip_addr_decrypted`);
  no `username` or `user_agent_decrypted`; four extra `audiobook_*` fields.
- Content type = whichever URI is non-null: `spotify_track_uri` (music),
  `spotify_episode_uri` (podcast), `audiobook_uri`.
- `reason_start`/`reason_end` use `""` for missing in older rows → converted to NA.
- Platform strings changed over time (2014: `iOS 8.0.2 (iPhone5,3)`; 2024: `ios`).
  Mapped by `standardise_platform()`.
- **Exact duplicate rows exist** (1,151 music rows across all years, all within a
  single file, mostly 2019–2022, many 0 ms). Removed. 69 near-duplicates (same end
  time + track, different other fields) since 2023 are kept.
- Many very short streams: ~37% of 2024 music streams are < 30 s; ~47% flagged
  `skipped`. Use `is_play` for "listens", `ms_played` for time.
- `offline` and `incognito_mode` were all FALSE in 2024.

## Decisions

- **Time zone:** `America/Chicago` for all local dates/hours (every stream is
  `conn_country = US`). Travel outside Central time is not adjusted.
- **A play counts on the day it started** (local), even if it ends after midnight.
- **"Listen" = stream ≥ 30 s** (Spotify's convention). Hours use all streams.
- **Analysis window:** 2023-01-01 onward.
- Zero days are kept in `daily_listening` so gaps show up.
- **Count songs by `song_key`, not `track_id`.** One song often has several URIs
  (e.g. one comfort song has two, 178 + 98 plays). `song_key` = lower-cased cleaned
  title + artist (`make_song_key()`). Use `track_id` only for per-URI API lookups.
  (Figs 2–3 grouped by URI until 2026-11-23 and undercounted such songs.)

## Caveats for interpretation

- **2023 is sparse:** only 186 days in 2023 have *any* Spotify activity (music or
  podcast); 201 days have no music. Mean hours/day: 2023 0.90, 2024 1.65,
  2025 1.48, 2026 1.69 (to 2026-11-17). A zero day means "no Spotify", not
  "no music" — other services/radio are not captured.
- Longest gaps: 2023-08-01→08-18 (18 d), 2023-10-09→10-20, 2024-05-17→05-28.

## Lyrics + emotion: plan and conventions (not built yet)

1. Fetch lyrics for `track_catalog.csv`, highest `hours_listened` first (≈11,100
   tracks with a 30 s+ play). Listening is spread out: top 250 tracks by hours =
   32% of listening time, 500 = 45%, 1,000 = 59%, 2,000 = 72%, 4,000 = 83%.
   Candidate API: LRCLIB (`lrclib.net`, no key; accepts track, artist, album,
   duration → use `est_duration_s`). Genius needs a token and HTML scraping.
2. Save to `data/lyrics/lyrics.csv` (git-ignored), one row per `track_id`:
   `track_id, lyrics_source, matched_title, matched_artist, match_status`
   (`found` / `not_found` / `instrumental` / `error`), `lyrics_text`, `language`,
   `fetched_at`. Keep not-found rows so they are not re-queried. Make the fetcher
   resumable (skip `track_id`s already present) and rate-limited.
3. Score emotion per track → `data/emotion/track_emotion.csv`, one row per
   `track_id`, with `model`, `model_version`, and one column per emotion score.
   Record the model and label set here when chosen.
3b. Also tag **themes** per track (multi-label, alongside emotion) →
   `data/emotion/track_themes.csv`. Emotion alone (sad/angry/…) can flatten what
   makes a period distinct; the theme list to use is in `notes/personal_context.md`.
4. Join to `music_plays` on `track_id`, then aggregate to day/week weighted by
   `ms_played` (time-weighted mood) and by plays. Report lyric coverage per period
   so tracks without lyrics (instrumental, non-English, not found) don't silently
   bias results.

## Therapy tagging loop

1. `Rscript scripts/listening_eras.R` → `outputs/therapy/eras_worksheet.html`
   (print it; one block per era with top + distinctive songs and blank lines for
   "what was going on / feelings / tags") and figures 5 (era timeline) and 6 (tags
   over time).
2. In therapy, I tag songs and eras with my own feelings/themes.
3. Enter them in the private files (git-ignored, see below):
   - `notes/song_tags.csv` — one row per song × tag:
     `track_name, artist_name, tag, source, added, note`. Matched to plays by
     `song_key`, so the title can omit "- Remastered"/"(feat. …)"; the script
     warns about tags that match no song.
   - `notes/era_tags.csv` — `era_start, era_end, tag, note`, stored by **date**
     (era ids can shift if eras are recomputed).
4. Re-run the script; tags appear in the worksheet and fig 6.

Era method (`R/eras.R`): week × song TF-IDF matrix (comfort songs heard most weeks
are down-weighted), contiguity-constrained agglomerative clustering with a
Ward-style size penalty, 24 eras. Without the size penalty busy periods chained
into one 856-day era — keep it. Deterministic for the same data.

## Private context

`notes/` is git-ignored. **Read `notes/personal_context.md` before interpreting
results.** It holds my own meaning for specific songs and periods, which is the
reference check for the emotion model. Never copy its contents into tracked files
(this one included), commit it, or push it.

## Status

_Last updated: 2026-11-23 (Claude Code, Windows laptop)_

- Done: profiled export; built `R/spotify_helpers.R` and `scripts/build_music_data.R`;
  generated `data/processed/` (57,212 music streams, 2023-01-03 → 2026-11-17;
  1,417 days; 12,567 unique tracks).
- Done: `scripts/plot_listening.R` → `outputs/figures/` (git-ignored):
  fig1 hours/day (daily bars + trailing 30-day mean + yearly mean),
  fig2 #1 song each month, fig3 top 10 songs per year (shared x scale so years
  compare), plus CSVs behind figs 2–3. Chart colours follow the reference palette
  (blue ramp, light mode).
- Observed (not yet interpreted): biggest listening surge Dec 2023 → Feb 2024
  (30-day mean ~4 h/day); second rise Jun–Sep 2026. 2024 has the most concentrated
  repeat listening (top track 128 plays vs 87 in 2025, 71 in 2026, 40 in 2023).
  Some songs recur in the top 10 across 2024–2026 (details in `notes/`).
- fig4 repeat listening: weekly plays of each week's top song, plus a weekly
  timeline for the anchor songs listed in `notes/personal_context.md`
  (matched by title + artist in `plot_listening.R`). I confirmed that heavy repeat
  listening = an emotionally charged period, so repetition is a valid signal.
- Hypothesis to test with lyrics: music in 2024–2025 is more emotionally charged
  than 2023/2026. Play counts and titles alone do not test this.
- Done: listening eras + therapy worksheet + tag loop (`R/eras.R`,
  `scripts/listening_eras.R`); seed song tags entered from my own descriptions.
- Next: tag songs/eras in therapy, enter into `notes/`, re-run.
- Next: lyrics fetcher (step 1 above) — planned for the home machine with Codex.
  My therapy tags are the ground truth to compare the lyric emotion/theme scores to.
- Git repo initialised locally, no commits or remote yet. Verified only code and
  docs are untracked-but-addable; raw export and `data/` are ignored.
- Not yet: `renv` (packages listed above).

## Decision log

- 2026-11-23 — Project set up. Music only, 2023+, America/Chicago, 30 s play
  threshold, exact duplicates dropped, `ip_addr` dropped, raw and derived data
  git-ignored.
