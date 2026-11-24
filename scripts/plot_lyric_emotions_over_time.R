# Run after cluster_lyric_emotions.py.
suppressPackageStartupMessages({
  library(arrow); library(dplyr); library(ggplot2); library(readr)
  library(scales); library(slider); library(tidyr)
})
source("R/lyric_emotion_plays.R")

out <- "outputs/therapy"
emotions <- c("joy", "sadness", "anger", "fear", "anticipation", "disgust", "surprise", "trust")
tracks <- read_csv("data/emotion/track_emotion_clusters.csv", show_col_types = FALSE) |>
  select(track_id, cluster, all_of(emotions))
stopifnot(!anyDuplicated(tracks$track_id), all(complete.cases(tracks)))
groups <- sort(unique(tracks$cluster))
plays <- read_lyric_emotion_plays()
dates <- read_csv("data/processed/daily_listening.csv", show_col_types = FALSE) |>
  select(date_local)
stopifnot(all(diff(dates$date_local) == 1))
joined <- plays |> left_join(tracks, by = "track_id", relationship = "many-to-one")
daily <- joined |>
  summarise(
    total_ms = sum(ms_played), scored_ms = sum(ms_played[!is.na(cluster)]),
    across(all_of(emotions), ~ sum(.x * ms_played, na.rm = TRUE)), .by = date_local
  )
by_cluster <- joined |>
  filter(!is.na(cluster)) |>
  summarise(ms = sum(ms_played), .by = c(date_local, cluster)) |>
  pivot_wider(names_from = cluster, values_from = ms, values_fill = 0)
daily <- dates |>
  left_join(daily, by = "date_local") |>
  left_join(by_cluster, by = "date_local") |>
  mutate(across(-date_local, ~ coalesce(.x, 0)))

divide <- function(x, y) if_else(!is.na(y) & y > 0, x / y, NA_real_)
rates <- function(sums) {
  sums |>
    mutate(coverage = divide(scored_ms, total_ms),
           across(all_of(groups), ~ divide(.x, scored_ms)),
           across(all_of(emotions), ~ divide(.x, scored_ms)))
}
rolling <- daily |>
  mutate(across(-date_local, ~ slide_dbl(.x, sum, .before = 29, .complete = TRUE))) |>
  rates()
annual <- daily |>
  mutate(year = format(date_local, "%Y")) |>
  summarise(across(-date_local, sum), .by = year) |>
  rates()
complete <- !is.na(rolling$coverage) & rolling$scored_ms > 0
stopifnot(all(abs(rowSums(rolling[complete, groups]) - 1) < 1e-9),
          sum(daily$scored_ms) <= sum(daily$total_ms))
write_csv(select(rolling, date_local, total_ms, scored_ms, coverage,
                 all_of(groups), all_of(emotions)), file.path(out, "lyric_emotions_rolling_30day.csv"))
write_csv(annual, file.path(out, "lyric_emotions_by_year.csv"))

theme <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), legend.position = "bottom",
        plot.title.position = "plot")
axis_dates <- scale_x_date(date_breaks = "6 months", date_labels = "%b %Y")
profiles <- read_csv(file.path(out, "lyric_emotion_cluster_profiles.csv"), show_col_types = FALSE)
stopifnot(setequal(profiles$cluster, groups))
labels <- profiles |>
  arrange(desc(z_score), emotion) |>
  summarise(
    label = if (any(z_score > 0)) paste(head(emotion[z_score > 0], 2), collapse = " and ")
            else "lower word rates",
    .by = cluster
  )
legend_names <- setNames(paste(labels$cluster, labels$label, sep = " · "), labels$cluster)
cluster_data <- rolling |>
  select(date_local, all_of(groups), coverage) |>
  rename("Scored coverage" = coverage) |>
  pivot_longer(-date_local, names_to = "series", values_to = "share")
cluster_plot <- ggplot(cluster_data, aes(date_local, share, colour = series, linetype = series)) +
  geom_line(linewidth = 0.9, na.rm = TRUE) +
  scale_colour_manual(values = setNames(c(hue_pal()(length(groups)), "#333333"),
                                       c(groups, "Scored coverage")),
                      labels = c(legend_names, "Scored coverage" = "Scored coverage")) +
  scale_linetype_manual(values = setNames(c(rep("solid", length(groups)), "dashed"),
                                         c(groups, "Scored coverage")),
                        labels = c(legend_names, "Scored coverage" = "Scored coverage")) +
  axis_dates + scale_y_continuous(labels = label_percent()) + theme +
  labs(title = "Which lyric groups you listened to over time",
       subtitle = "Trailing 30 days. The dashed line shows scored coverage after excluding background-noise recordings.",
       x = NULL, y = "Share of listening time", colour = NULL, linetype = NULL)
ggsave(file.path(out, "lyric_emotion_clusters_over_time.png"), cluster_plot,
       width = 11, height = 5.4, dpi = 180, bg = "white")

emotion_data <- rolling |>
  select(date_local, all_of(emotions)) |>
  pivot_longer(-date_local, names_to = "emotion", values_to = "score") |>
  mutate(emotion = factor(emotion, levels = emotions, labels = tools::toTitleCase(emotions)))
emotion_plot <- ggplot(emotion_data, aes(date_local, score)) +
  geom_line(linewidth = 0.75, colour = "#25646C", na.rm = TRUE) +
  facet_wrap(vars(emotion), ncol = 2) +
  axis_dates + theme +
  labs(title = "Eight lyric emotion scores over time",
       subtitle = "30-day trailing averages weighted by time spent listening to each scored track",
       x = NULL, y = "Associated words per 100 lyric words")
ggsave(file.path(out, "lyric_emotion_scores_over_time.png"), emotion_plot,
       width = 11, height = 9, dpi = 180, bg = "white")
cat("Wrote two time series charts, rolling rates, and annual rates.\n")
