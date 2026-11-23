# Listening eras + therapy worksheet + custom tags.
# Run after build_music_data.R:   Rscript scripts/listening_eras.R
#
# Writes (all git-ignored):
#   outputs/therapy/eras_worksheet.html   printable worksheet, one block per era
#   outputs/therapy/eras.csv, era_songs.csv
#   outputs/figures/fig5_listening_eras.png
#   outputs/figures/fig6_tags_over_time.png   (once notes/song_tags.csv has tags)
# Reads private tags from notes/ (git-ignored):
#   notes/song_tags.csv   long format: track_name, artist_name, tag, source, added, note
#   notes/era_tags.csv    era_start, era_end, tag, note  (template created if missing)
#
# Eras are deterministic for the same data and settings. Era tags are stored by DATE,
# not era id, so they survive if eras are recomputed after new data arrives.

source("R/spotify_helpers.R")
source("R/eras.R")
suppressPackageStartupMessages({
  library(readr); library(arrow); library(ggplot2); library(scales); library(slider); library(forcats)
})

n_eras <- 24
fig_dir <- "outputs/figures"; ther_dir <- "outputs/therapy"
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(ther_dir, recursive = TRUE, showWarnings = FALSE)

plays <- read_parquet("data/processed/music_plays.parquet")
daily <- read_csv("data/processed/daily_listening.csv", show_col_types = FALSE)

eras <- find_eras(plays, n_eras = n_eras)
res  <- summarise_eras(eras, plays, daily)

# ---- Tags (private) -------------------------------------------------------------
song_tags_file <- "notes/song_tags.csv"
era_tags_file  <- "notes/era_tags.csv"
if (!file.exists(era_tags_file)) {
  write_csv(tibble(era_start = as_date(character()), era_end = as_date(character()),
                   tag = character(), note = character()), era_tags_file)
}
song_tags <- if (file.exists(song_tags_file)) read_csv(song_tags_file, show_col_types = FALSE) else
  tibble(track_name = character(), artist_name = character(), tag = character())
song_tags <- song_tags |> filter(!is.na(tag), tag != "") |>
  mutate(tag = str_to_lower(str_squish(tag)), song_key = make_song_key(track_name, artist_name))

unmatched <- anti_join(distinct(song_tags, song_key, track_name, artist_name),
                       distinct(plays, song_key), by = "song_key")
if (nrow(unmatched) > 0) {
  cat("WARNING: tagged songs not found in plays (check spelling of title/artist):\n")
  print(unmatched |> select(track_name, artist_name))
}

tags_by_song <- song_tags |> group_by(song_key) |> summarise(tags = paste(sort(unique(tag)), collapse = ", "))
res$songs <- res$songs |> left_join(tags_by_song, by = "song_key")

era_tags <- read_csv(era_tags_file, show_col_types = FALSE, col_types = cols(.default = "c")) |>
  mutate(era_start = as_date(era_start), era_end = as_date(era_end))

# ---- Figure 5: era timeline ------------------------------------------------------
ink <- "#0b0b0b"; ink2 <- "#52514e"; muted <- "#898781"; grid_col <- "#e1e0d9"; surface <- "#fcfcfb"
font <- "Segoe UI"
band_fill <- c("#f0efec", surface)

daily30 <- daily |> arrange(date_local) |>
  mutate(roll30 = slide_dbl(hours_listened, mean, .before = 29, .complete = TRUE))
e <- res$eras |> mutate(band = band_fill[(row_number() %% 2) + 1], mid = era_start + (era_end - era_start) / 2)
y_max <- max(daily30$roll30, na.rm = TRUE) * 1.18

p5 <- ggplot() +
  geom_rect(data = e, aes(xmin = era_start, xmax = era_end + 1, ymin = 0, ymax = y_max, fill = band)) +
  scale_fill_identity() +
  geom_line(data = daily30, aes(date_local, roll30), colour = "#184f95", linewidth = 0.9, na.rm = TRUE) +
  geom_text(data = e, aes(mid, y_max * 0.97, label = era), family = font, size = 3, colour = ink2, vjust = 1) +
  scale_x_date(date_breaks = "3 months", date_labels = "%b\n%Y", expand = c(0, 0)) +
  scale_y_continuous(labels = label_number(suffix = " h"), expand = c(0, 0)) +
  labs(title = "Listening eras, 2023 – present",
       subtitle = "Shaded bands = eras (stretches with a similar song mix). Line = hours of music per day, trailing 30-day average.",
       x = NULL, y = NULL,
       caption = "Eras found by clustering weekly song plays (weeks must be adjacent). See the worksheet for each era's songs.") +
  theme_minimal(base_size = 11, base_family = font) +
  theme(plot.background = element_rect(fill = surface, colour = NA), panel.grid = element_blank(),
        axis.text = element_text(colour = muted), plot.title = element_text(colour = ink, face = "bold", size = 15),
        plot.subtitle = element_text(colour = ink2), plot.caption = element_text(colour = muted, hjust = 0),
        plot.title.position = "plot", plot.caption.position = "plot", plot.margin = margin(16, 20, 12, 16))
ggsave(file.path(fig_dir, "fig5_listening_eras.png"), p5, width = 13, height = 4.5, dpi = 160,
       device = ragg::agg_png, bg = surface)

# ---- Figure 6: tags over time (share of weekly plays) ------------------------------
if (nrow(song_tags) > 0) {
  wk_tot <- plays |> filter(is_play) |> mutate(week = floor_date(date_local, "week", week_start = 1)) |>
    count(week, name = "all_plays")
  wk_tag <- plays |> filter(is_play) |> mutate(week = floor_date(date_local, "week", week_start = 1)) |>
    inner_join(distinct(song_tags, song_key, tag), by = "song_key", relationship = "many-to-many") |>
    count(week, tag, name = "tag_plays")
  tag_series <- tidyr::expand_grid(week = wk_tot$week, tag = unique(song_tags$tag)) |>
    left_join(wk_tot, by = "week") |> left_join(wk_tag, by = c("week", "tag")) |>
    mutate(tag_plays = coalesce(tag_plays, 0L)) |>
    arrange(tag, week) |> group_by(tag) |>
    mutate(share4 = slide_dbl(tag_plays, sum, .before = 3) / slide_dbl(all_plays, sum, .before = 3)) |>
    ungroup()
  n_tags <- n_distinct(tag_series$tag)

  p6 <- ggplot(tag_series, aes(week, share4)) +
    geom_area(fill = "#9ec5f4") + geom_line(colour = "#184f95", linewidth = 0.5) +
    facet_wrap(~ tag, ncol = 1, strip.position = "left") +
    scale_y_continuous(labels = label_percent(accuracy = 1), n.breaks = 3) +
    scale_x_date(date_breaks = "3 months", date_labels = "%b\n%Y", expand = c(0, 0)) +
    labs(title = "My tags over time",
         subtitle = "Share of plays (30 s+) going to songs I gave each tag, rolling 4 weeks. Tags from notes/song_tags.csv.",
         x = NULL, y = NULL,
         caption = paste("Share, not count: in weeks of very heavy listening a tag's share can drop even if its songs were played more.",
                         "A song can carry several tags. Untagged songs count toward the total only, so shares rise as more songs are tagged.")) +
    theme_minimal(base_size = 10, base_family = font) +
    theme(plot.background = element_rect(fill = surface, colour = NA), panel.grid = element_blank(),
          strip.text.y.left = element_text(angle = 0, hjust = 1, colour = ink),
          panel.grid.major.y = element_line(colour = grid_col, linewidth = 0.3),
          axis.text = element_text(colour = muted), plot.title = element_text(colour = ink, face = "bold", size = 14),
          plot.subtitle = element_text(colour = ink2), plot.caption = element_text(colour = muted, hjust = 0),
          plot.title.position = "plot", plot.caption.position = "plot", panel.spacing.y = unit(4, "pt"))
  ggsave(file.path(fig_dir, "fig6_tags_over_time.png"), p6, width = 13, height = 1.0 + 0.7 * n_tags,
         dpi = 160, device = ragg::agg_png, bg = surface)
}

# ---- Worksheet (HTML, print-friendly) ---------------------------------------------
esc <- function(x) { x <- gsub("&", "&amp;", x, fixed = TRUE); x <- gsub("<", "&lt;", x, fixed = TRUE); gsub(">", "&gt;", x, fixed = TRUE) }
fmt <- function(d) format(d, "%d %b %Y")

song_rows <- function(df) {
  if (nrow(df) == 0) return("<li class='none'>—</li>")
  paste0("<li>", esc(df$track_name), " <span class='artist'>— ", esc(df$artist_name), "</span>",
         " <span class='n'>", df$plays, " plays · ", df$days, " days</span>",
         ifelse(is.na(df$tags), "", paste0(" <span class='tag'>", esc(df$tags), "</span>")), "</li>",
         collapse = "\n")
}

blocks <- vapply(seq_len(nrow(res$eras)), function(i) {
  r <- res$eras[i, ]
  s <- res$songs |> filter(era == r$era)
  et <- era_tags |> filter(era_start <= r$era_end, era_end >= r$era_start)
  et_html <- if (nrow(et) == 0) "" else
    paste0("<p class='etags'>Era tags: ", esc(paste(unique(et$tag), collapse = ", ")), "</p>")
  sprintf(
    "<section class='era'>
      <h2>%s <span class='dates'>%s – %s</span></h2>
      <p class='stats'>%d weeks · %.1f h/day · %d plays · %d days with no Spotify · biggest single-song week: %d plays of %s</p>
      %s
      <div class='cols'>
        <div><h3>Most played</h3><ol>%s</ol></div>
        <div><h3>Distinctive to this era</h3><ol>%s</ol></div>
      </div>
      <div class='write'><p><b>What was going on:</b></p><p><b>Feelings:</b></p><p><b>Tags:</b></p></div>
    </section>",
    r$era, fmt(r$era_start), fmt(r$era_end), round(r$days / 7), r$hours_per_day, r$plays_30s,
    r$zero_days, r$peak_week_plays, esc(r$peak_song), et_html,
    song_rows(s |> filter(kind == "most played")), song_rows(s |> filter(kind == "distinctive")))
}, character(1))

html <- paste0(
"<!doctype html><html lang='en'><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<title>Listening Eras Worksheet</title>
<style>
  :root { --ink:#0b0b0b; --ink2:#52514e; --muted:#898781; --line:#e1e0d9; --surface:#fcfcfb; --accent:#2a78d6; }
  body { font-family: system-ui, -apple-system, 'Segoe UI', sans-serif; color: var(--ink); background: var(--surface);
         max-width: 960px; margin: 24px auto; padding: 0 16px; line-height: 1.4; }
  h1 { margin-bottom: 4px; } .intro { color: var(--ink2); }
  img { width: 100%; height: auto; border: 1px solid var(--line); margin: 12px 0 8px; }
  .era { border-top: 2px solid var(--ink); padding: 10px 0 14px; break-inside: avoid; page-break-inside: avoid; }
  h2 { margin: 0; font-size: 1.2rem; } .dates { font-weight: 400; color: var(--ink2); margin-left: 8px; }
  .stats { color: var(--ink2); font-size: .9rem; margin: 4px 0 8px; }
  .etags { font-size: .9rem; } .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  h3 { font-size: .85rem; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 4px 0; }
  ol { margin: 0; padding-left: 20px; font-size: .9rem; } li { margin: 2px 0; }
  .artist { color: var(--ink2); } .n { color: var(--muted); font-size: .8rem; white-space: nowrap; }
  .tag { font-size: .75rem; border: 1px solid var(--accent); color: var(--accent); border-radius: 4px; padding: 0 4px; margin-left: 4px; }
  .write p { border-bottom: 1px solid var(--line); min-height: 2.2em; margin: 6px 0; color: var(--ink2); font-size: .9rem; }
  @media (max-width: 640px) { .cols { grid-template-columns: 1fr; } }
  @media print { body { margin: 0; max-width: none; } .write p { min-height: 2.8em; } }
</style></head><body>
<h1>Listening eras</h1>
<p class='intro'>", nrow(res$eras), " eras from ", fmt(min(res$eras$era_start)), " to ", fmt(max(res$eras$era_end)),
". Each era is a stretch of weeks with a similar mix of songs. <b>Most played</b> = top songs in the era.
<b>Distinctive</b> = songs played much more in this era than in my listening overall (min 5 plays).
Plays count only listens of 30 seconds or more. Tags in blue come from my own notes.</p>
<img src='../figures/fig5_listening_eras.png' alt='Timeline of listening eras with hours per day'>
", paste(blocks, collapse = "\n"), "
</body></html>")
writeLines(html, file.path(ther_dir, "eras_worksheet.html"), useBytes = TRUE)

write_csv(res$eras, file.path(ther_dir, "eras.csv"))
write_csv(res$songs, file.path(ther_dir, "era_songs.csv"))
cat("Eras:", nrow(res$eras), "| tagged songs:", n_distinct(song_tags$song_key),
    "| tags:", paste(sort(unique(song_tags$tag)), collapse = ", "), "\n")
cat("Wrote", file.path(ther_dir, "eras_worksheet.html"), "and figures 5",
    if (nrow(song_tags) > 0) "and 6" else "", "\n")
