# Join a local theme-scoring snapshot to the listening history for a therapy worksheet.
# Run from the repo root after scoring: Rscript scripts/summarize_lyric_listening.R

source("R/spotify_helpers.R")
source("R/eras.R")
suppressPackageStartupMessages({ library(arrow); library(readr) })

read_lyric_coverage <- function(path) {
  if (!file.exists(path)) stop("Lyrics database missing: ", path)
  db <- DBI::dbConnect(RSQLite::SQLite(), path, flags = RSQLite::SQLITE_RO)
  on.exit(DBI::dbDisconnect(db))
  DBI::dbExecute(db, "PRAGMA busy_timeout = 5000")
  DBI::dbGetQuery(db, "
    SELECT track_id,
           CASE WHEN length(trim(coalesce(json_extract(result, '$.\"Plain Lyrics\"'), ''),
                                 char(9, 10, 13, 32))) > 0
                  OR length(trim(coalesce(json_extract(result, '$.\"Synced Lyrics\"'), ''),
                                 char(9, 10, 13, 32))) > 0
                THEN 1 ELSE 0 END AS has_lyrics
    FROM lyrics
  ")
}

coverage <- function(plays, periods) {
  totals <- plays |>
    group_by(period) |>
    summarise(
      ms_listened = sum(ms_played), plays_30s = sum(is_play),
      lyric_ms = sum(ms_played[has_lyrics]), lyric_plays = sum(is_play[has_lyrics]),
      theme_ms = sum(ms_played[has_theme]), theme_plays = sum(is_play[has_theme]),
      .groups = "drop"
    )
  periods |>
    left_join(totals, by = "period") |>
    mutate(
      across(all_of(setdiff(names(totals), "period")), ~ coalesce(.x, 0)),
      hours_listened = ms_listened / 3.6e6,
      lyric_share_time = share(lyric_ms, ms_listened),
      lyric_share_plays = share(lyric_plays, plays_30s),
      theme_share_time = share(theme_ms, ms_listened),
      theme_share_plays = share(theme_plays, plays_30s)
    )
}

theme_distribution <- function(plays, totals) {
  plays |>
    filter(has_theme, ms_played > 0) |>
    group_by(period, primary_theme) |>
    summarise(theme_ms = sum(ms_played), theme_plays = sum(is_play), .groups = "drop") |>
    left_join(
      totals |> select(period, assigned_ms = theme_ms, assigned_plays = theme_plays,
                       ms_listened, plays_30s),
      by = "period"
    ) |>
    mutate(
      share_themed_time = share(theme_ms, assigned_ms),
      share_themed_plays = share(theme_plays, assigned_plays),
      share_all_time = share(theme_ms, ms_listened),
      share_all_plays = share(theme_plays, plays_30s)
    ) |>
    arrange(period, desc(theme_ms), primary_theme)
}

share <- function(numerator, denominator) {
  if_else(denominator > 0, numerator / denominator, NA_real_)
}

pct <- function(x) ifelse(is.na(x), "—", sprintf("%.0f%%", 100 * x))

escape_markdown <- function(x) {
  # Escape syntax from track metadata before including it in the private report.
  gsub("([][|*_<>~`])", "\\\\\\1", gsub("[\r\n]+", " ", x), perl = TRUE)
}

theme_path <- "data/emotion/track_themes.csv"
if (!file.exists(theme_path)) stop("Run scripts/score_lyrics.py before generating the summary")
themes <- read_csv(theme_path, col_types = cols(.default = col_character())) |>
  select(track_id, primary_theme, any_of(c("theme_source", "scored_at_utc")))
stopifnot(!anyNA(themes$track_id), all(nzchar(themes$track_id)), !anyDuplicated(themes$track_id))
snapshot <- tail(sort(themes[["scored_at_utc"]]), 1L)
if (!"theme_source" %in% names(themes)) themes$theme_source <- rep(NA_character_, nrow(themes))
themes <- themes |> select(-any_of("scored_at_utc"))

plays <- read_parquet("data/processed/music_plays.parquet")
daily <- read_csv(
  "data/processed/daily_listening.csv",
  col_types = cols(.default = col_skip(), date_local = col_date(),
                   hours_listened = col_double(), streams = col_double())
)
stopifnot(nrow(plays) > 0L, nrow(daily) > 0L)
lyrics <- read_lyric_coverage("data/lyrics/lyrics.sqlite3")
joined <- plays |>
  left_join(lyrics, by = "track_id", relationship = "many-to-one") |>
  left_join(themes, by = "track_id", relationship = "many-to-one") |>
  mutate(has_lyrics = coalesce(has_lyrics == 1L, FALSE),
         has_theme = !is.na(primary_theme) & nzchar(trimws(primary_theme)))
stopifnot(nrow(joined) == nrow(plays))

week_of <- function(date) floor_date(date, "week", week_start = 1)
weekly <- joined |> mutate(period = week_of(date_local))
weeks <- daily |> transmute(period = week_of(date_local)) |> distinct() |> arrange(period)
weekly_coverage <- coverage(weekly, weeks)
weekly_themes <- theme_distribution(weekly, weekly_coverage)

overall <- coverage(joined |> mutate(period = "All"), tibble(period = "All"))

# Use the existing estimator when the input contains any eligible weeks and songs.
eligible_weeks <- plays |>
  filter(is_play) |>
  mutate(week = week_of(date_local)) |>
  add_count(week, name = "week_plays") |>
  add_count(song_key, name = "song_plays") |>
  filter(week_plays >= 5L, song_plays >= 5L)
if (nrow(eligible_weeks)) {
  eras <- find_eras(plays)
} else {
  eras <- tibble(era = "E01", era_start = min(plays$date_local),
                 era_end = max(plays$date_local), active_weeks = 0L)
}
period_eras <- eras |> rename(period = era)
by_era <- joined |>
  mutate(period = eras$era[findInterval(date_local, eras$era_start)])
era_coverage <- coverage(by_era, period_eras)
era_themes <- theme_distribution(by_era, era_coverage)
song_themes <- by_era |>
  filter(has_theme, ms_played > 0) |>
  group_by(period, song_key, primary_theme, theme_source) |>
  summarise(ms_played = sum(ms_played), .groups = "drop") |>
  arrange(desc(ms_played), primary_theme, theme_source) |>
  distinct(period, song_key, .keep_all = TRUE) |>
  transmute(era = period, song_key, primary_theme, theme_source)
era_songs <- summarise_eras(eras, plays, daily)$songs |>
  left_join(song_themes, by = c("era", "song_key"))

top_themes <- era_themes |>
  group_by(period) |>
  slice_head(n = 3) |>
  summarise(
    themes = paste(sprintf("%s (%s)", escape_markdown(primary_theme),
                           pct(share_themed_time)), collapse = ", "),
    .groups = "drop"
  )

out <- "outputs/therapy"
dir.create(out, recursive = TRUE, showWarnings = FALSE)
write_csv(weekly_coverage |> rename(week_start = period), file.path(out, "lyric_week_coverage.csv"))
write_csv(weekly_themes |> rename(week_start = period), file.path(out, "lyric_week_themes.csv"))
write_csv(era_coverage |> rename(era = period), file.path(out, "lyric_era_coverage.csv"))
write_csv(era_themes |> rename(era = period), file.path(out, "lyric_era_themes.csv"))
write_csv(era_songs, file.path(out, "lyric_era_songs.csv"))

report_eras <- era_coverage |> left_join(top_themes, by = "period")
report <- c(
  "# Listening and lyrics discussion notes", "",
  sprintf("Listening from %s through %s. Report generated %s UTC.",
          min(daily$date_local), max(daily$date_local), format(Sys.time(), "%Y-%m-%d %H:%M", tz = "UTC")),
  if (length(snapshot)) paste("Theme-scoring snapshot", snapshot),
  "",
  sprintf("Lyrics cover %s of listening time and %s of 30-second plays. A primary theme is assigned to %s of listening time and %s of 30-second plays.",
          pct(overall$lyric_share_time), pct(overall$lyric_share_plays),
          pct(overall$theme_share_time), pct(overall$theme_share_plays)),
  "",
  "Theme percentages describe the listening time with an assigned theme. The coverage columns show how much listening that represents. The lyrics database may include tracks fetched after the theme-scoring snapshot. Theme labels are starting points for discussing the songs and what they meant to you.",
  "",
  "| Era | Dates | Hours | Time with lyrics | Time with a theme | Leading song themes |",
  "| --- | --- | ---: | ---: | ---: | --- |",
  sprintf("| %s | %s to %s | %.1f | %s | %s | %s |",
          report_eras$period, report_eras$era_start, report_eras$era_end,
          report_eras$hours_listened, pct(report_eras$lyric_share_time),
          pct(report_eras$theme_share_time), coalesce(report_eras$themes, "—")),
  "",
  "## Songs to discuss"
)

for (era_id in eras$era) {
  songs <- era_songs |> filter(era == era_id, rank <= 3)
  if (nrow(songs) > 0L) {
    source <- case_when(
      songs$theme_source == "close_reading" ~ "close reading",
      songs$theme_source == "model" ~ "model suggestion",
      .default = "theme"
    )
    annotation <- if_else(is.na(songs$primary_theme), "",
                          sprintf(". %s (%s)", escape_markdown(songs$primary_theme), source))
    report <- c(
      report, "", paste("###", era_id), "",
      sprintf("- %s — %s (%s, %d plays on %d days)%s",
              escape_markdown(songs$track_name), escape_markdown(songs$artist_name),
              songs$kind, songs$plays, songs$days, annotation),
      "", "What was happening then, and what did these songs give you at the time?"
    )
  }
}

writeLines(report, file.path(out, "lyric_listening_summary.md"), useBytes = TRUE)
cat("Wrote listening worksheet and five CSVs under", out, "\n")
