# Run after cluster_lyrics.py and summarize_lyric_listening.R.
suppressPackageStartupMessages({
  library(arrow); library(dplyr); library(ggplot2); library(readr); library(tidyr)
})

out <- "outputs/therapy"
clusters <- read_csv("data/emotion/track_lyric_clusters.csv", show_col_types = FALSE)
eras <- read_csv(file.path(out, "lyric_era_coverage.csv"), show_col_types = FALSE)
plays <- read_parquet("data/processed/music_plays.parquet", col_select = c(track_id, date_local, ms_played))
stopifnot(!anyDuplicated(clusters$track_id), all(diff(eras$era_start) > 0))
era_index <- findInterval(as.numeric(plays$date_local), as.numeric(eras$era_start))
stopifnot(all(era_index > 0), all(plays$date_local <= eras$era_end[era_index]))
exposure <- plays |>
  mutate(era = eras$era[era_index]) |>
  inner_join(select(clusters, track_id, cluster), by = "track_id", relationship = "many-to-one") |>
  summarise(cluster_ms = sum(ms_played), .by = c(era, cluster)) |>
  complete(era = eras$era, cluster = sort(unique(clusters$cluster)), fill = list(cluster_ms = 0)) |>
  left_join(select(eras, era, era_start, era_end, ms_listened), by = "era", relationship = "many-to-one") |>
  mutate(cluster_hours = cluster_ms / 3.6e6,
         share_all_time = if_else(ms_listened > 0, cluster_ms / ms_listened, NA_real_)) |>
  arrange(era, cluster)
stopifnot(isTRUE(all.equal(sum(exposure$cluster_hours), sum(clusters$hours_listened))))
write_csv(exposure, file.path(out, "lyric_clusters_by_era.csv"))

map <- clusters |>
  filter(representative) |>
  ggplot(aes(pca_1, pca_2, colour = cluster)) +
  geom_point(alpha = 0.7, size = 1.8) +
  theme_minimal(base_size = 12) +
  labs(title = "Groups of songs with similar lyrics",
       x = "Principal component 1", y = "Principal component 2", colour = "Group")
ggsave(file.path(out, "lyric_cluster_map.png"), map, width = 9, height = 6, dpi = 180)

bands <- ggplot(exposure, aes(era, cluster, fill = share_all_time)) +
  geom_tile(colour = "white") +
  scale_fill_viridis_c(labels = scales::label_percent()) +
  theme_minimal(base_size = 12) +
  theme(panel.grid = element_blank(), axis.text.x = element_text(angle = 50, hjust = 1)) +
  labs(title = "Lyric groups across listening eras",
       x = "Listening era", y = "Lyric group", fill = "Share of listening time")
ggsave(file.path(out, "lyric_clusters_by_era.png"), bands, width = 11, height = 5.5, dpi = 180)
cat("Wrote cluster map, era chart, and era coverage CSV.\n")
