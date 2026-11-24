# Run from the project root after cluster_lyric_emotions.py.
suppressPackageStartupMessages({
  library(arrow); library(dplyr); library(ggplot2); library(readr)
  library(scales); library(slider); library(tidyr)
})
source("R/lyric_emotion_plays.R")

out <- "outputs/therapy"
emotions <- c("joy", "trust", "anticipation", "surprise", "sadness", "fear", "anger", "disgust")
unscored <- "Unscored"
labels <- c(tools::toTitleCase(emotions), unscored)
palette <- setNames(c("#E6AA26", "#3A9B76", "#DA7943", "#8EAE45", "#4076AC",
                      "#8067A7", "#B94D58", "#865C44", "#D4D8DD"), labels)
scores <- read_csv("data/emotion/track_emotion_clusters.csv", show_col_types = FALSE) |>
  select(track_id, representative, all_of(emotions))
stopifnot(!anyDuplicated(scores$track_id), all(complete.cases(scores)))
values <- as.matrix(select(scores, all_of(emotions)))
reference <- values[scores$representative, , drop = FALSE]
center <- colMeans(reference)
spread <- apply(reference, 2, sd)
stopifnot(all(is.finite(spread) & spread > 0))

# Compare each emotion with its own baseline and consider only emotions with a word hit.
relative <- sweep(sweep(values, 2, center), 2, spread, "/")
relative[values <= 0] <- -Inf
strongest <- max.col(relative, ties.method = "first")
has_emotion <- rowSums(values > 0) > 0
assigned <- tibble(
  track_id = scores$track_id,
  emotion = if_else(has_emotion, labels[strongest], unscored)
)
write_csv(assigned, "data/emotion/track_primary_emotions.csv")

plays <- read_lyric_emotion_plays()
dates <- read_csv("data/processed/daily_listening.csv", show_col_types = FALSE) |>
  select(date_local)
joined <- plays |>
  left_join(assigned, by = "track_id", relationship = "many-to-one") |>
  mutate(emotion = coalesce(emotion, unscored))
daily <- joined |>
  summarise(ms = sum(ms_played), .by = c(date_local, emotion)) |>
  complete(date_local = dates$date_local, emotion = labels, fill = list(ms = 0)) |>
  mutate(
    day_ms = sum(ms),
    hours = ms / 3.6e6,
    share = if_else(day_ms > 0, ms / day_ms, NA_real_),
    .by = date_local
  ) |>
  mutate(emotion = factor(emotion, levels = labels)) |>
  arrange(date_local, emotion)
daily_check <- daily |> summarise(total = sum(ms), share = sum(share), .by = date_local)
stopifnot(isTRUE(all.equal(sum(daily$ms), sum(plays$ms_played))),
          all(abs(daily_check$share[daily_check$total > 0] - 1) < 1e-9))
write_csv(select(daily, date_local, emotion, hours, share), file.path(out, "daily_listening_by_lyric_emotion.csv"))

# Put years on the same calendar axis, with a gap on days without listening.
display <- daily |>
  mutate(year = format(date_local, "%Y"),
         calendar_day = as.Date(paste0("2000-", format(date_local, "%m-%d"))))
base <- ggplot(display, aes(calendar_day, fill = emotion)) +
  facet_wrap(vars(year), ncol = 1) +
  scale_fill_manual(values = palette, drop = FALSE) +
  scale_x_date(limits = as.Date(c("1999-12-31", "2001-01-01")),
               breaks = seq(as.Date("2000-01-01"), by = "month", length.out = 12),
               date_labels = "%b", expand = expansion(mult = 0)) +
  theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), panel.grid.major.x = element_blank(),
        legend.position = "bottom", strip.text = element_text(hjust = 0, face = "bold"),
        plot.title.position = "plot") +
  guides(fill = guide_legend(nrow = 1)) +
  labs(x = NULL, fill = NULL)
hours <- base + geom_col(aes(y = hours), width = 1) +
  labs(title = "Daily hours listened by lyric emotion",
       subtitle = "Each scored track contributes its strongest relative NRC word association",
       y = "Hours listened")
share <- base + geom_col(aes(y = share), width = 1, na.rm = TRUE) +
  scale_y_continuous(labels = label_percent(), breaks = seq(0, 1, by = 0.25)) +
  labs(title = "Daily listening share by lyric emotion",
       subtitle = "Includes unscored music. Background-noise recordings are excluded.",
       y = "Share of daily listening")
ggsave(file.path(out, "daily_lyric_emotion_hours.png"), hours, width = 14, height = 9, dpi = 180, bg = "white")
ggsave(file.path(out, "daily_lyric_emotion_percent.png"), share, width = 14, height = 9, dpi = 180, bg = "white")

line_data <- daily |>
  mutate(
    window_ms = slide_dbl(ms, sum, .before = 29, .complete = TRUE),
    window_total = slide_dbl(day_ms, sum, .before = 29, .complete = TRUE),
    rolling_hours = window_ms / (30 * 3.6e6),
    rolling_share = if_else(window_total > 0, window_ms / window_total, NA_real_),
    .by = emotion
  )
line_palette <- palette
line_palette[unscored] <- "#6D747C"
make_line_plot <- function(daily_value, rolling_value, title, y_label, y_format) {
  ggplot(line_data, aes(date_local, colour = emotion)) +
    geom_line(aes(y = {{ daily_value }}), linewidth = 0.25, alpha = 0.12,
              show.legend = FALSE, na.rm = TRUE) +
    geom_line(aes(y = {{ rolling_value }}), linewidth = 0.85, na.rm = TRUE) +
    scale_colour_manual(values = line_palette, drop = FALSE) +
    scale_x_date(date_breaks = "6 months", date_labels = "%b %Y") +
    scale_y_continuous(labels = y_format) +
    theme_minimal(base_size = 12) +
    theme(panel.grid.minor = element_blank(), legend.position = "bottom",
          plot.title.position = "plot") +
    guides(colour = guide_legend(nrow = 2)) +
    labs(title = title, subtitle = "Faint lines show daily values. Bold lines summarize the trailing 30 days.",
         x = NULL, y = y_label, colour = NULL)
}
hours_lines <- make_line_plot(hours, rolling_hours, "Listening hours by lyric emotion",
                              "Hours listened per day", label_number())
share_lines <- make_line_plot(share, rolling_share, "Share of listening by lyric emotion",
                              "Share of music listening time", label_percent())
ggsave(file.path(out, "daily_lyric_emotion_hours_lines.png"), hours_lines,
       width = 13, height = 6, dpi = 180, bg = "white")
ggsave(file.path(out, "daily_lyric_emotion_percent_lines.png"), share_lines,
       width = 13, height = 6, dpi = 180, bg = "white")

sadness <- daily |>
  filter(emotion == "Sadness") |>
  transmute(date_local, minutes = ms / 60000,
            trailing_30_day_mean = slide_dbl(minutes, mean, .before = 29, .complete = TRUE))
write_csv(sadness, file.path(out, "daily_sadness_minutes.csv"))
sadness_plot <- ggplot(sadness, aes(date_local)) +
  geom_col(aes(y = minutes, fill = "Daily minutes"), width = 1) +
  geom_line(aes(y = trailing_30_day_mean, colour = "30-day average"),
            linewidth = 0.9, na.rm = TRUE) +
  scale_fill_manual(name = NULL, values = c("Daily minutes" = "#8AA9C8")) +
  scale_colour_manual(name = NULL, values = c("30-day average" = "#173C63")) +
  scale_x_date(date_breaks = "6 months", date_labels = "%b %Y") +
  theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), legend.position = "bottom",
        plot.title.position = "plot") +
  labs(title = "Daily minutes listening to songs labeled Sadness",
       subtitle = "Sadness is the strongest relative emotion in each track’s scored lyrics",
       x = NULL, y = "Minutes listened")
ggsave(file.path(out, "daily_sadness_minutes.png"), sadness_plot,
       width = 12, height = 5, dpi = 180, bg = "white")
cat(sprintf("Assigned %d of %d scored tracks. Wrote %d days of listening data and five charts.\n",
            sum(has_emotion), nrow(scores), nrow(dates)))
