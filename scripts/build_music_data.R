# Build the cleaned music datasets from the raw Spotify export.
# Run from the project root:  Rscript scripts/build_music_data.R
#
# Outputs (data/processed/, git-ignored):
#   music_plays.parquet / .rds   one row per music stream, 2023-01-01 onward (local time)
#   daily_listening.csv          one row per day incl. zero days
#   track_catalog.csv            one row per unique track (lyrics work queue)

source("R/spotify_helpers.R")
suppressPackageStartupMessages({ library(arrow); library(readr) })

raw_dir     <- "Spotify Extended Streaming History"
out_dir     <- "data/processed"
local_tz    <- "America/Chicago"
start_date  <- as_date("2023-01-01")
min_play_ms <- 30000

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

raw <- read_audio_history(raw_dir)
cat("Raw audio rows (all years):", nrow(raw), "\n")
print(count(classify_content(raw), content_type))

# Load all files then filter by date: files are split by size, so early-2023 rows
# could sit in the "2022" file.
plays_all <- build_music_plays(raw, tz = local_tz, min_play_ms = min_play_ms)
plays <- plays_all |> filter(date_local >= start_date)

daily  <- daily_listening(plays, start = start_date)
tracks <- track_catalog(plays)

# ---- Validation -------------------------------------------------------------
cat("\nMusic rows all years:", nrow(plays_all),
    "| exact duplicates removed:", sum(classify_content(raw)$content_type == "music") - nrow(plays_all), "\n")
cat("Music rows since", format(start_date), ":", nrow(plays),
    "| range:", format(min(plays$date_local)), "to", format(max(plays$date_local)), "\n")
cat("Near-duplicates (same ts_end + track, kept):",
    sum(duplicated(plays[, c("ts_end_utc", "track_uri")])), "\n")
cat("Rows by source file:\n"); print(count(plays, source_file))
cat("Platform mapping:\n"); print(count(plays, platform, platform_raw, sort = TRUE), n = 20)
stopifnot(
  !anyNA(plays$track_uri),
  !anyNA(plays$date_local),
  nrow(daily) == as.integer(max(daily$date_local) - start_date) + 1,
  isTRUE(all.equal(sum(daily$hours_listened), sum(plays$ms_played) / 3.6e6))
)

cat("\nDays:", nrow(daily), "| days with no listening:", sum(daily$streams == 0),
    "| mean hours/day:", round(mean(daily$hours_listened), 2),
    "| median:", round(median(daily$hours_listened), 2), "\n")
cat("Unique tracks:", nrow(tracks), "| with >=1 play of 30s+:", sum(tracks$plays_30s > 0), "\n")
cat("Titles changed by clean_track_title():", sum(tracks$lyrics_query_title != tracks$track_name), "\n")

# ---- Write ------------------------------------------------------------------
write_parquet(plays, file.path(out_dir, "music_plays.parquet"))
saveRDS(plays, file.path(out_dir, "music_plays.rds"))
write_csv(daily, file.path(out_dir, "daily_listening.csv"))
write_csv(tracks, file.path(out_dir, "track_catalog.csv"))
cat("\nWrote:", paste(list.files(out_dir), collapse = ", "), "\n")
