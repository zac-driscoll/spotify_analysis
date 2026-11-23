# Helper functions for the Spotify Extended Streaming History export.
# Sourced by scripts/build_music_data.R. See AGENTS.md for field notes and decisions.

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(purrr)
  library(stringr)
  library(lubridate)
  library(tibble)
})

# Read every Streaming_History_Audio_*.json file in `dir` into one tibble.
# Spotify splits files by size, not calendar year, so file names are not date ranges.
read_audio_history <- function(dir) {
  files <- list.files(dir, pattern = "^Streaming_History_Audio_.*\\.json$", full.names = TRUE)
  if (length(files) == 0) stop("No Streaming_History_Audio_*.json files found in: ", dir)

  map(files, function(f) {
    as_tibble(fromJSON(f, simplifyDataFrame = TRUE)) |>
      mutate(source_file = basename(f))
  }) |>
    list_rbind()
}

# Label each stream as music / podcast / audiobook from which URI is populated.
classify_content <- function(df) {
  df |>
    mutate(content_type = case_when(
      !is.na(spotify_track_uri) ~ "music",
      !is.na(spotify_episode_uri) ~ "podcast",
      !is.na(audiobook_uri) ~ "audiobook",
      TRUE ~ "unknown"
    ))
}

# Map raw platform strings (old exports use e.g. "iOS 8.0.2 (iPhone5,3)") to a small set.
standardise_platform <- function(x) {
  x <- str_to_lower(x)
  case_when(
    is.na(x) | x %in% c("not_applicable", "unknown", "") ~ "unknown",
    str_detect(x, "ios|iphone|ipad") ~ "ios",
    str_detect(x, "android") ~ "android",
    str_detect(x, "windows") ~ "windows",
    str_detect(x, "os x|osx|mac") ~ "macos",
    str_detect(x, "linux") ~ "linux",
    str_detect(x, "web ?player|websocket|browser") ~ "web",
    str_detect(x, "xbox|playstation|ps4|ps5") ~ "console",
    str_detect(x, "cast|sonos|speaker|tv|alexa|echo") ~ "device",
    TRUE ~ "other"
  )
}

# Build the cleaned music play table.
#   tz           local time zone used for dates (ts in the export is UTC, at stream END)
#   min_play_ms  threshold for counting a stream as a "play" (Spotify convention: 30 s)
build_music_plays <- function(raw, tz = "America/Chicago", min_play_ms = 30000) {
  raw |>
    classify_content() |>
    filter(content_type == "music") |>
    # The export has no stable row id; drop exact duplicates (e.g. overlap between files)
    distinct(across(-source_file), .keep_all = TRUE) |>
    transmute(
      ts_end_utc   = ymd_hms(ts, tz = "UTC"),
      ts_start_utc = ts_end_utc - milliseconds(ms_played),
      ts_start_local = with_tz(ts_start_utc, tz),
      date_local   = as_date(ts_start_local),   # a play is assigned to the day it started
      hour_local   = hour(ts_start_local),
      ms_played,
      minutes_played = ms_played / 60000,
      is_play      = ms_played >= min_play_ms,
      track_uri    = spotify_track_uri,
      track_id     = str_remove(spotify_track_uri, "^spotify:track:"),
      track_name   = master_metadata_track_name,
      artist_name  = master_metadata_album_artist_name,
      album_name   = master_metadata_album_album_name,
      platform_raw = platform,
      platform     = standardise_platform(platform),
      conn_country,
      reason_start = na_if(reason_start, ""),
      reason_end   = na_if(reason_end, ""),
      shuffle, skipped, offline, incognito_mode,
      source_file
      # ip_addr deliberately dropped: personal data, not needed for analysis
    ) |>
    arrange(ts_start_utc) |>
    mutate(song_key = make_song_key(track_name, artist_name))
}

# One key per *song*, not per Spotify URI: the same song often has several URIs
# (single vs album vs re-release). Use song_key for counting songs; track_id for API lookups.
make_song_key <- function(track_name, artist_name) {
  paste(str_to_lower(clean_track_title(track_name)), str_to_lower(str_squish(artist_name)), sep = " | ")
}

# One row per calendar day (local) from `start` to the last day with data,
# including days with no listening (zeros), so gaps are visible in plots.
daily_listening <- function(plays, start, end = max(plays$date_local)) {
  by_day <- plays |>
    group_by(date_local) |>
    summarise(
      hours_listened   = sum(ms_played) / 3.6e6,
      streams          = n(),
      plays_30s        = sum(is_play),
      skips            = sum(skipped %in% TRUE),
      unique_tracks    = n_distinct(track_uri[is_play]),
      unique_artists   = n_distinct(artist_name[is_play]),
      first_play_local = min(ts_start_local),
      last_play_local  = max(ts_start_local),
      .groups = "drop"
    )

  tibble(date_local = seq(as_date(start), as_date(end), by = "day")) |>
    left_join(by_day, by = "date_local") |>
    mutate(across(c(hours_listened, streams, plays_30s, skips, unique_tracks, unique_artists),
                  ~ coalesce(.x, 0))) |>
    mutate(
      skip_rate = if_else(streams > 0, skips / streams, NA_real_),
      weekday   = wday(date_local, label = TRUE, abbr = TRUE, week_start = 1),
      week      = floor_date(date_local, "week", week_start = 1),
      month     = floor_date(date_local, "month")
    )
}

# Strip version/feature suffixes so titles match lyrics databases better.
# e.g. "Song - Remastered 2011" -> "Song"; "Song (feat. X)" -> "Song"
clean_track_title <- function(x) {
  x |>
    str_remove(regex("\\s+-\\s+(\\d{4}\\s+)?(remaster|remastered|live|mono|stereo|radio edit|single version|old version|acoustic|demo|bonus|edit|version|from ).*$", ignore_case = TRUE)) |>
    str_remove(regex("\\s*[\\(\\[](feat\\.?|ft\\.?|with) [^\\)\\]]*[\\)\\]]", ignore_case = TRUE)) |>
    str_squish()
}

# One row per unique track: the work queue for lyrics lookup and emotion scoring.
# `est_duration_s` is the longest observed play - a proxy for track length (the export has
# no duration field); useful for matching lyrics APIs that accept a duration (e.g. LRCLIB).
track_catalog <- function(plays) {
  plays |>
    group_by(track_uri, track_id) |>
    summarise(
      track_name     = first(track_name),
      artist_name    = first(artist_name),
      album_name     = first(album_name),
      plays_30s      = sum(is_play),
      streams        = n(),
      hours_listened = sum(ms_played) / 3.6e6,
      est_duration_s = round(max(ms_played) / 1000),
      first_played_local = min(date_local),
      last_played_local  = max(date_local),
      .groups = "drop"
    ) |>
    mutate(
      song_key            = make_song_key(track_name, artist_name),
      lyrics_query_title  = clean_track_title(track_name),
      lyrics_query_artist = artist_name
    ) |>
    arrange(desc(plays_30s))
}
