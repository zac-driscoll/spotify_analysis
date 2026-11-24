# Run from the project root after plot_daily_lyric_emotions.R.
suppressPackageStartupMessages({
  library(arrow); library(dplyr); library(ggplot2); library(lubridate); library(readr); library(tidyr)
})
source("R/lyric_emotion_plays.R")

start <- as.Date("2023-10-01")
palette <- c(Joy = "#E6AA26", Trust = "#3A9B76", Anticipation = "#DA7943",
             Surprise = "#8EAE45", Sadness = "#4076AC", Fear = "#8067A7",
             Anger = "#B94D58", Disgust = "#865C44", Unscored = "#6D747C")
plays <- read_parquet(
  "data/processed/music_plays.parquet",
  col_select = c(track_id, song_key, date_local, ms_played, is_play,
                 track_name, album_name, artist_name)
) |>
  filter(date_local >= start, !is_background_noise(track_name, album_name, artist_name))
scores <- read_csv("data/emotion/track_primary_emotions.csv", show_col_types = FALSE)
stopifnot(!anyDuplicated(scores$track_id), nrow(plays) > 0)

top <- plays |>
  filter(is_play) |>
  summarise(plays = n(), listened_ms = sum(ms_played), .by = song_key) |>
  arrange(desc(plays), desc(listened_ms), song_key) |>
  slice_head(n = 10) |>
  mutate(rank = row_number())
top_plays <- plays |> semi_join(top, by = "song_key")
names <- top_plays |>
  filter(is_play) |>
  count(song_key, track_name, artist_name, name = "version_plays") |>
  arrange(desc(version_plays), track_name, artist_name) |>
  slice_head(n = 1, by = song_key)
dominant <- top_plays |>
  inner_join(filter(scores, emotion != "Unscored"), by = "track_id", relationship = "many-to-one") |>
  summarise(scored_ms = sum(ms_played), .by = c(song_key, emotion)) |>
  arrange(desc(scored_ms), emotion) |>
  slice_head(n = 1, by = song_key)
top <- top |>
  left_join(names, by = "song_key", relationship = "one-to-one") |>
  left_join(dominant, by = "song_key", relationship = "one-to-one") |>
  mutate(emotion = coalesce(emotion, "Unscored"),
         panel = sprintf("%d. %s\n%s · %d plays · %s", rank, track_name, artist_name, plays, emotion))
months <- seq(start, as.Date(floor_date(max(plays$date_local), "month")), by = "month")
monthly <- top_plays |>
  mutate(month = as.Date(floor_date(date_local, "month"))) |>
  summarise(minutes = sum(ms_played) / 60000, .by = c(song_key, month)) |>
  complete(song_key = top$song_key, month = months, fill = list(minutes = 0)) |>
  left_join(top, by = "song_key", relationship = "many-to-one") |>
  mutate(panel = factor(panel, levels = top$panel))
stopifnot(nrow(monthly) == nrow(top) * length(months),
          isTRUE(all.equal(sum(monthly$minutes), sum(top_plays$ms_played) / 60000)))

chart <- ggplot(monthly, aes(month, minutes, colour = emotion)) +
  geom_area(aes(fill = emotion), colour = NA, alpha = 0.13) +
  geom_line(linewidth = 0.9) +
  geom_point(data = filter(monthly, minutes > 0), size = 1.1) +
  facet_wrap(vars(panel), ncol = 2) +
  scale_colour_manual(values = palette, aesthetics = c("colour", "fill")) +
  scale_x_date(date_breaks = "6 months", date_labels = "%b %y", expand = expansion(mult = 0.015)) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.07))) +
  theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), panel.spacing = grid::unit(1.1, "lines"),
        strip.text = element_text(face = "bold", hjust = 0, lineheight = 1.1),
        plot.title.position = "plot", plot.caption.position = "plot",
        plot.caption = element_text(hjust = 0), legend.position = "none",
        plot.margin = margin(14, 20, 14, 18)) +
  labs(title = "Listening time for your 10 most-played songs",
       subtitle = sprintf("Monthly minutes · October 2023 through %s · Same scale for every song",
                          format(max(plays$date_local), "%B %d, %Y")),
       x = NULL, y = "Minutes listened",
       caption = "Ranked by plays of at least 30 seconds across Spotify versions. Color follows the lyric label with the most scored time for that song.")
out <- "outputs/therapy"
dir.create(out, recursive = TRUE, showWarnings = FALSE)
ggsave(file.path(out, "top_10_song_playtime_by_emotion.png"), chart,
       width = 13, height = 12, dpi = 180, bg = "white")
print(select(top, rank, track_name, artist_name, plays, emotion), width = 140)
