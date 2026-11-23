# Listening plots for 2023-present. Run after build_music_data.R:
#   Rscript scripts/plot_listening.R
# Writes PNGs to outputs/figures/ (git-ignored: shows personal listening).

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(arrow); library(lubridate)
  library(ggplot2); library(scales); library(slider); library(stringr); library(forcats)
})

out_dir <- "outputs/figures"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

source("R/spotify_helpers.R")   # make_song_key(), clean_track_title()

daily <- read_csv("data/processed/daily_listening.csv", show_col_types = FALSE)
# Count *songs* (song_key), not Spotify URIs: one song can have several URIs.
plays <- read_parquet("data/processed/music_plays.parquet") |>
  mutate(song_title = clean_track_title(track_name))

# ---- Theme (reference palette, light mode) ----------------------------------
ink       <- "#0b0b0b"; ink2 <- "#52514e"; muted <- "#898781"
grid_col  <- "#e1e0d9"; surface <- "#fcfcfb"
blue_200  <- "#9ec5f4"; blue_450 <- "#2a78d6"; blue_600 <- "#184f95"
font      <- "Segoe UI"

theme_listen <- function(base = 11) {
  theme_minimal(base_size = base, base_family = font) +
    theme(
      plot.background  = element_rect(fill = surface, colour = NA),
      panel.background = element_rect(fill = surface, colour = NA),
      panel.grid.major = element_line(colour = grid_col, linewidth = 0.3),
      panel.grid.minor = element_blank(),
      axis.text        = element_text(colour = muted),
      axis.title       = element_text(colour = ink2),
      plot.title       = element_text(colour = ink, face = "bold", size = base + 4),
      plot.subtitle    = element_text(colour = ink2, margin = margin(b = 10)),
      plot.caption     = element_text(colour = muted, hjust = 0),
      strip.text       = element_text(colour = ink, face = "bold", hjust = 0, size = base + 1),
      plot.title.position = "plot", plot.caption.position = "plot",
      plot.margin      = margin(16, 20, 12, 16)
    )
}

# ---- Figure 1: hours per day ------------------------------------------------
daily <- daily |>
  arrange(date_local) |>
  mutate(roll30 = slide_dbl(hours_listened, mean, .before = 29, .complete = TRUE))

yearly <- daily |>
  mutate(year = year(date_local)) |>
  group_by(year) |>
  summarise(start = min(date_local), end = max(date_local),
            mean_h = mean(hours_listened), zero_days = sum(streams == 0), days = n(),
            .groups = "drop")

y_top <- quantile(daily$hours_listened, 0.995)   # keep a few extreme days from flattening the plot
n_clipped <- sum(daily$hours_listened > y_top)

last_pt <- daily |> filter(!is.na(roll30)) |> slice_tail(n = 1)

p1 <- ggplot(daily, aes(date_local)) +
  geom_col(aes(y = pmin(hours_listened, y_top)), fill = blue_200, width = 1) +
  geom_line(aes(y = roll30), colour = blue_600, linewidth = 0.9, na.rm = TRUE) +
  geom_segment(data = yearly, aes(x = start, xend = end, y = mean_h, yend = mean_h),
               colour = ink2, linewidth = 0.4, linetype = "22") +
  geom_text(data = yearly,
            aes(x = start + 6, y = y_top * 0.97,
                label = sprintf("%d  ·  avg %.1f h/day\n%d of %d days with no Spotify",
                                year, mean_h, zero_days, days)),
            hjust = 0, vjust = 1, size = 3.2, colour = ink2, family = font, lineheight = 1.1) +
  annotate("text", x = last_pt$date_local + 8, y = last_pt$roll30, label = "30-day\naverage",
           hjust = 0, size = 3.2, colour = blue_600, family = font, lineheight = 0.95) +
  geom_vline(xintercept = as_date(paste0(2024:2026, "-01-01")), colour = grid_col, linewidth = 0.4) +
  scale_x_date(date_breaks = "3 months", date_labels = "%b\n%Y", expand = expansion(mult = c(0.005, 0.05))) +
  scale_y_continuous(labels = label_number(suffix = " h"), expand = expansion(mult = c(0, 0.02))) +
  coord_cartesian(ylim = c(0, y_top)) +
  labs(
    title = "Hours of music per day, 2023 – present",
    subtitle = "Light bars = each day. Dark line = trailing 30-day average. Dashed line = yearly average.",
    x = NULL, y = NULL,
    caption = sprintf(paste0("Music only (podcasts excluded). Days in America/Chicago time. ",
                             "%d days above %.1f h are clipped at the top. Zero days = no Spotify use, not necessarily no music."),
                      n_clipped, y_top)
  ) +
  theme_listen()

ggsave(file.path(out_dir, "fig1_hours_per_day.png"), p1, width = 13, height = 5.5, dpi = 160,
       device = ragg::agg_png, bg = surface)

# ---- Shared: track labels ----------------------------------------------------
track_label <- function(track, artist, width = 48) {
  paste0(str_trunc(track, width), "  —  ", str_trunc(artist, 26))
}

# ---- Figure 2: #1 song each month ---------------------------------------------
top_month <- plays |>
  filter(is_play) |>
  mutate(month = floor_date(date_local, "month")) |>
  group_by(month, song_key) |>
  summarise(track_name = first(song_title), artist_name = first(artist_name),
            plays = n(), hours = sum(ms_played) / 3.6e6, days = n_distinct(date_local), .groups = "drop") |>
  group_by(month) |>
  mutate(month_plays = sum(plays)) |>
  slice_max(order_by = tibble(plays, hours), n = 1, with_ties = FALSE) |>
  ungroup() |>
  mutate(year = year(month),
         share = plays / month_plays,
         month_lab = format(month, "%b"),
         month_lab = factor(month_lab, levels = rev(month.abb)),
         label = track_label(track_name, artist_name))

p2 <- ggplot(top_month, aes(plays, month_lab)) +
  geom_col(fill = blue_450, width = 0.72) +
  geom_text(aes(label = label), hjust = 0, nudge_x = 1.2, size = 3.1, colour = ink, family = font) +
  geom_text(aes(x = 0, label = sprintf("%d plays · %d days", plays, days)),
            hjust = 1.05, size = 2.7, colour = muted, family = font) +
  facet_grid(year ~ ., scales = "free_y", space = "free_y", switch = "y") +
  scale_x_continuous(expand = expansion(mult = c(0.32, 0.9))) +
  labs(
    title = "My #1 song each month",
    subtitle = "Most-played track per month (plays of 30 s or more). Bar = number of plays that month; grey = plays and distinct days played.",
    x = NULL, y = NULL,
    caption = "Music only. Ties broken by hours listened."
  ) +
  theme_listen(10) +
  theme(axis.text.x = element_blank(), panel.grid = element_blank(),
        strip.placement = "outside", strip.text.y.left = element_text(angle = 0, vjust = 1),
        axis.text.y = element_text(colour = ink2))

ggsave(file.path(out_dir, "fig2_top_song_by_month.png"), p2,
       width = 12, height = 0.26 * nrow(top_month) + 2.2, dpi = 160, device = ragg::agg_png, bg = surface)

# ---- Figure 3: top 10 songs per year -------------------------------------------
top_year <- plays |>
  filter(is_play) |>
  mutate(year = year(date_local)) |>
  group_by(year, song_key) |>
  summarise(track_name = first(song_title), artist_name = first(artist_name),
            plays = n(), hours = sum(ms_played) / 3.6e6, days = n_distinct(date_local), .groups = "drop") |>
  group_by(year) |>
  slice_max(order_by = tibble(plays, hours), n = 10, with_ties = FALSE) |>
  mutate(rank = row_number()) |>
  ungroup() |>
  mutate(label = track_label(track_name, artist_name, 34))

p3 <- ggplot(top_year, aes(plays, fct_rev(factor(rank)))) +
  geom_col(fill = blue_450, width = 0.72) +
  geom_text(aes(label = label), hjust = 0, nudge_x = 2, size = 3, colour = ink, family = font) +
  geom_text(aes(label = plays), hjust = 1, nudge_x = -1.5, size = 2.7, colour = "#ffffff", family = font) +
  facet_wrap(~ year, ncol = 2) +   # shared x scale so years are comparable
  scale_x_continuous(expand = expansion(mult = c(0, 1.25))) +
  labs(
    title = "Top 10 songs each year",
    subtitle = "Ranked by plays of 30 s or more. Number in bar = plays that year. Same scale in every panel.",
    x = NULL, y = NULL,
    caption = sprintf("Music only. 2026 runs to %s.", format(max(plays$date_local), "%d %b %Y"))
  ) +
  theme_listen(10) +
  theme(axis.text.x = element_blank(), panel.grid = element_blank(),
        panel.spacing.y = unit(14, "pt"))

ggsave(file.path(out_dir, "fig3_top10_by_year.png"), p3, width = 13, height = 7.5, dpi = 160,
       device = ragg::agg_png, bg = surface)

# ---- Tables behind the figures (for review / the table view) -------------------
write_csv(top_month, file.path(out_dir, "top_song_by_month.csv"))
write_csv(top_year, file.path(out_dir, "top10_by_year.csv"))
cat("Wrote:", paste(list.files(out_dir), collapse = ", "), "\n")

# ---- Figure 4: repeat listening + anchor songs ---------------------------------
# Weekly repeat-listening view; anchor songs highlighted (see notes/, private).
# Anchor songs are matched by title + artist so re-releases with new URIs still count.
suppressPackageStartupMessages({ library(patchwork); library(ggrepel) })

# Anchor list is private: notes/anchor_songs.csv (git-ignored; columns track_name, artist_name).
# Max 3 songs: the first three palette slots are the ones validated for all-pairs use.
anchor_file <- "notes/anchor_songs.csv"
if (!file.exists(anchor_file)) stop("Missing ", anchor_file, " (private, not in git). See AGENTS.md.")
anchors <- read_csv(anchor_file, show_col_types = FALSE) |>
  slice_head(n = 3) |>
  mutate(anchor_col = c("#2a78d6", "#eb6834", "#1baf7a")[row_number()],   # blue, orange, aqua
         anchor = factor(track_name, levels = track_name),
         song_key = make_song_key(track_name, artist_name))
other_col <- "#c3c2b7"

weekly_song <- plays |>
  filter(is_play) |>
  mutate(week = floor_date(date_local, "week", week_start = 1)) |>
  group_by(week, song_key) |>
  summarise(track_name = first(song_title), artist_name = first(artist_name), plays = n(), .groups = "drop")

weekly_top <- weekly_song |>
  group_by(week) |>
  slice_max(plays, n = 1, with_ties = FALSE) |>
  ungroup() |>
  left_join(select(anchors, song_key, anchor), by = "song_key") |>
  mutate(fill_group = if_else(is.na(anchor), "Other song", as.character(anchor)),
         fill_group = factor(fill_group, levels = c(levels(anchors$anchor), "Other song")))

peaks <- weekly_top |> slice_max(plays, n = 8) |>
  mutate(label = paste0(str_trunc(track_name, 28), "\n", format(week, "%b %Y")))

fill_vals <- c(setNames(anchors$anchor_col, anchors$track_name), "Other song" = other_col)
x_lim <- c(as_date("2022-12-28"), max(plays$date_local) + 7)   # room for the first week's bar

p4a <- ggplot(weekly_top, aes(week, plays, fill = fill_group)) +
  geom_col(width = 6) +
  geom_text_repel(data = peaks, aes(label = label), family = font, size = 2.9, colour = ink2,
                  lineheight = 0.95, nudge_y = 4, direction = "x", segment.colour = muted,
                  segment.size = 0.3, min.segment.length = 0, seed = 1) +
  scale_fill_manual(values = fill_vals, name = NULL, drop = FALSE) +
  scale_x_date(limits = x_lim, date_breaks = "3 months", date_labels = "%b\n%Y", expand = c(0, 0)) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.25))) +
  labs(title = "When I played one song on repeat",
       subtitle = "Each bar = one week; height = plays of that week's most-played song. Coloured if it was an anchor song.",
       x = NULL, y = "plays of top song") +
  theme_listen() +
  theme(legend.position = "top", legend.justification = "left",
        legend.text = element_text(colour = ink2), panel.grid.major.x = element_blank())

anchor_weekly <- weekly_song |>
  select(-track_name, -artist_name) |>
  inner_join(anchors, by = "song_key")

p4b <- ggplot(anchor_weekly, aes(week, fct_rev(anchor))) +
  geom_point(aes(size = plays, colour = anchor), alpha = 0.85, stroke = 0) +
  scale_colour_manual(values = setNames(anchors$anchor_col, anchors$track_name), guide = "none") +
  scale_size_area(max_size = 7, breaks = c(1, 5, 10, 20), name = "plays that week") +
  scale_x_date(limits = x_lim, date_breaks = "3 months", date_labels = "%b\n%Y", expand = c(0, 0)) +
  labs(subtitle = "Anchor songs: every week each was played (dot size = plays that week)",
       x = NULL, y = NULL,
       caption = "Music only, plays of 30 s or more, weeks start Monday (America/Chicago).") +
  theme_listen() +
  theme(axis.text.y = element_text(colour = ink, size = 10), legend.position = "right",
        legend.text = element_text(colour = ink2), legend.title = element_text(colour = ink2, size = 9),
        panel.grid.major.x = element_blank())

p4 <- p4a / p4b + plot_layout(heights = c(2.2, 1))
ggsave(file.path(out_dir, "fig4_repeat_listening.png"), p4, width = 13, height = 8, dpi = 160,
       device = ragg::agg_png, bg = surface)
write_csv(weekly_top, file.path(out_dir, "weekly_top_song.csv"))
cat("Wrote fig4_repeat_listening.png\n")
