# Listening "eras": split the timeline into contiguous stretches with a similar song mix.
#
# Method (deterministic, no extra packages):
#   1. Week x track matrix of plays (>= 30 s), tracks with >= `min_track_plays` in the window.
#   2. TF-IDF weight: songs heard in nearly every week (comfort songs) count less, so eras are
#      defined by what was distinctive about them, not by songs that are always there.
#   3. Weeks with < `min_week_plays` plays carry too little signal; they are not clustered and
#      are absorbed into the surrounding era by date.
#   4. Contiguity-constrained agglomerative clustering: start with one segment per active week,
#      repeatedly merge the most similar *adjacent* pair (cosine of summed TF-IDF vectors)
#      until `n_eras` segments remain. Adjacent-only merges keep every era a single date range.

suppressPackageStartupMessages({ library(dplyr); library(lubridate); library(tidyr) })

cosine <- function(a, b) {
  d <- sqrt(sum(a^2)) * sqrt(sum(b^2))
  if (d == 0) 0 else sum(a * b) / d
}

find_eras <- function(plays, n_eras = 24, min_week_plays = 5, min_track_plays = 5) {
  wk <- plays |>
    filter(is_play) |>
    mutate(week = floor_date(date_local, "week", week_start = 1)) |>
    count(week, song_key, name = "plays")

  keep_tracks <- wk |> group_by(song_key) |> summarise(n = sum(plays)) |> filter(n >= min_track_plays)
  active_weeks <- wk |> group_by(week) |> summarise(n = sum(plays)) |> filter(n >= min_week_plays) |> pull(week)

  m <- wk |>
    filter(song_key %in% keep_tracks$song_key, week %in% active_weeks) |>
    pivot_wider(names_from = song_key, values_from = plays, values_fill = 0) |>
    arrange(week)
  weeks <- m$week
  x <- as.matrix(m[, -1])

  idf <- log(nrow(x) / pmax(colSums(x > 0), 1))
  x <- sweep(log1p(x), 2, idf, `*`)          # log-damp repeats, then down-weight ever-present songs

  seg_vec <- lapply(seq_len(nrow(x)), function(i) x[i, ])
  seg_wk  <- as.list(weeks)
  while (length(seg_vec) > n_eras) {
    # Ward-style cost: dissimilarity x size penalty. Without the size term, busy periods chain
    # into one giant era while sparse, eclectic weeks never merge.
    cost <- vapply(seq_len(length(seg_vec) - 1), function(i) {
      a <- length(seg_wk[[i]]); b <- length(seg_wk[[i + 1]])
      (1 - cosine(seg_vec[[i]], seg_vec[[i + 1]])) * (a * b / (a + b))
    }, numeric(1))
    i <- which.min(cost)
    seg_vec[[i]] <- seg_vec[[i]] + seg_vec[[i + 1]]
    seg_wk[[i]]  <- c(seg_wk[[i]], seg_wk[[i + 1]])
    seg_vec[[i + 1]] <- NULL
    seg_wk[[i + 1]]  <- NULL
  }

  starts <- as_date(vapply(seg_wk, function(w) min(w), numeric(1)))
  window_start <- min(plays$date_local)
  window_end   <- max(plays$date_local)
  # Era boundaries: each era runs from its first active week to the day before the next era starts,
  # so quiet weeks are absorbed and the eras tile the whole window.
  tibble(era_start = pmax(starts, window_start)) |>
    mutate(era_start = replace(era_start, 1, window_start),
           era_end   = lead(era_start) - 1,
           era_end   = replace(era_end, n(), window_end),
           era       = sprintf("E%02d", row_number()),
           active_weeks = lengths(seg_wk))
}

# Attach era to each play, then summarise eras for the worksheet.
summarise_eras <- function(eras, plays, daily, top_n = 6, min_distinct_plays = 5) {
  p <- plays |>
    filter(is_play) |>
    mutate(era = eras$era[findInterval(as.numeric(date_local), as.numeric(eras$era_start))])

  overall <- p |> count(song_key, name = "all_plays") |> mutate(all_share = all_plays / sum(all_plays))

  songs <- p |>
    group_by(era, song_key) |>
    summarise(track_name = first(clean_track_title(track_name)), artist_name = first(artist_name),
              plays = n(), days = n_distinct(date_local), .groups = "drop") |>
    group_by(era) |>
    mutate(era_share = plays / sum(plays)) |>
    ungroup() |>
    left_join(overall, by = "song_key") |>
    mutate(lift = era_share / all_share)   # how much more this era played it than usual

  top_played <- songs |> group_by(era) |> slice_max(tibble(plays, days), n = top_n, with_ties = FALSE) |>
    mutate(rank = row_number(), kind = "most played") |> ungroup()
  distinctive <- songs |> filter(plays >= min_distinct_plays) |>
    anti_join(top_played, by = c("era", "song_key")) |>
    group_by(era) |> slice_max(tibble(lift, plays), n = top_n, with_ties = FALSE) |>
    mutate(rank = row_number(), kind = "distinctive") |> ungroup()

  peak <- p |>
    mutate(week = floor_date(date_local, "week", week_start = 1)) |>
    group_by(era, week, song_key) |>
    summarise(wk_plays = n(), track_name = first(clean_track_title(track_name)),
              artist_name = first(artist_name), .groups = "drop") |>
    group_by(era) |> slice_max(wk_plays, n = 1, with_ties = FALSE) |>
    transmute(era, peak_week_plays = wk_plays, peak_song = paste0(track_name, " — ", artist_name))

  stats <- eras |>
    rowwise() |>
    mutate(
      days          = as.integer(era_end - era_start) + 1,
      hours_per_day = mean(daily$hours_listened[daily$date_local >= era_start & daily$date_local <= era_end]),
      zero_days     = sum(daily$streams[daily$date_local >= era_start & daily$date_local <= era_end] == 0)
    ) |>
    ungroup() |>
    left_join(p |> count(era, name = "plays_30s"), by = "era") |>
    left_join(peak, by = "era")

  list(eras = stats, songs = bind_rows(top_played, distinctive) |> arrange(era, kind, rank), era_of_play = p)
}
