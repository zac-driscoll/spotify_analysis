# Run from the project root after plot_daily_lyric_emotions.R.
suppressPackageStartupMessages({
  library(arrow); library(dplyr); library(ggplot2); library(readr); library(tidyr)
})
source("R/lyric_emotion_plays.R")

start <- as.Date("2023-10-01")
emotions <- c("Joy", "Trust", "Anticipation", "Surprise", "Sadness", "Fear", "Anger", "Disgust")
bands <- c("One play", "Repeat plays on one day", "Played on 2–4 days", "Played on 5+ days")

plays <- read_parquet(
  "data/processed/music_plays.parquet",
  col_select = c(track_id, song_key, date_local, ms_played, is_play,
                 track_name, album_name, artist_name)
) |>
  filter(date_local >= start, is_play, !is_background_noise(track_name, album_name, artist_name))
scores <- read_csv("data/emotion/track_primary_emotions.csv", show_col_types = FALSE)
stopifnot(!anyDuplicated(scores$track_id), nrow(plays) > 0)
song_bands <- plays |>
  summarise(play_count = n(), play_days = n_distinct(date_local), .by = song_key) |>
  mutate(band = case_when(
    play_count == 1 ~ bands[1],
    play_days == 1 ~ bands[2],
    play_days <= 4 ~ bands[3],
    TRUE ~ bands[4]
  ))
joined <- plays |>
  left_join(song_bands, by = "song_key", relationship = "many-to-one") |>
  left_join(scores, by = "track_id", relationship = "many-to-one")
stopifnot(nrow(joined) == nrow(plays))
coverage <- joined |>
  summarise(songs = n_distinct(song_key), total_ms = sum(ms_played),
            scored_ms = sum(ms_played[emotion %in% emotions]), .by = band) |>
  mutate(row_label = sprintf("%s\n%s songs · %.0f%% scored",
                             band, format(songs, big.mark = ",", trim = TRUE),
                             100 * scored_ms / total_ms))
shares <- joined |>
  filter(emotion %in% emotions) |>
  summarise(emotion_ms = sum(ms_played), .by = c(band, emotion)) |>
  complete(band = coverage$band, emotion = emotions, fill = list(emotion_ms = 0)) |>
  left_join(coverage, by = "band", relationship = "many-to-one") |>
  mutate(share = if_else(scored_ms > 0, emotion_ms / scored_ms, NA_real_),
         emotion = factor(emotion, levels = emotions),
         row_label = factor(row_label, levels = coverage$row_label[order(match(coverage$band, rev(bands)))]))
checks <- shares |> summarise(total = sum(share), .by = band)
stopifnot(all(abs(checks$total[!is.na(checks$total)] - 1) < 1e-9),
          sum(coverage$total_ms) == sum(plays$ms_played))

chart <- ggplot(shares, aes(emotion, row_label, fill = share)) +
  geom_tile(colour = "#FFFFFF", linewidth = 1.8, width = 0.99, height = 0.97) +
  geom_text(aes(label = if_else(is.na(share), "—", scales::percent(share, accuracy = 0.1)),
                colour = coalesce(share >= 0.16, FALSE)), fontface = "bold", size = 5) +
  scale_colour_manual(values = c("FALSE" = "#142F46", "TRUE" = "#FFFFFF"), guide = "none") +
  scale_fill_gradient(low = "#EDF4F9", high = "#194A75", limits = c(0, max(0.20, shares$share, na.rm = TRUE)),
                      labels = scales::label_percent(), na.value = "#EEEEEE") +
  scale_x_discrete(position = "top", expand = expansion(add = 0.05)) +
  scale_y_discrete(expand = expansion(add = 0.05)) +
  theme_minimal(base_size = 13) +
  theme(panel.grid = element_blank(), legend.position = "bottom", axis.ticks = element_blank(),
        axis.text.x = element_text(face = "bold"), axis.text.y = element_text(lineheight = 1.12),
        plot.title.position = "plot", plot.caption.position = "plot",
        plot.caption = element_text(hjust = 0, colour = "#45576B", margin = margin(t = 8)),
        plot.margin = margin(20, 24, 16, 20)) +
  labs(title = "Which lyric emotions did you return to?",
       subtitle = sprintf("October 2023 through %s · Shares of scored listening time in each group",
                          format(max(plays$date_local), "%B %d, %Y")),
       x = NULL, y = NULL, fill = "Share of scored time",
       caption = "Only plays of at least 30 seconds count. Spotify versions are grouped by song. Background noise is excluded.")

dir.create("outputs/therapy", recursive = TRUE, showWarnings = FALSE)
ggsave("outputs/therapy/repeat_listening_by_emotion.png", chart,
       width = 12, height = 6.4, dpi = 180, bg = "white")
print(shares |> select(band, songs, emotion, share) |> pivot_wider(names_from = emotion, values_from = share),
      width = 140)
