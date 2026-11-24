library(ggplot2)

read_tracks <- function(path) {
  read.csv(path, fileEncoding = "UTF-8-BOM", check.names = FALSE,
           colClasses = "character", na.strings = NULL)
}

lyrics <- read_tracks("data/playlist/spotify_lrclib_lyrics.csv")
analysis <- read_tracks("data/playlist/lyric_semantic_analysis.csv")
stopifnot(!anyDuplicated(lyrics[["Spotify URL"]]),
          !anyDuplicated(analysis[["Spotify URL"]]),
          setequal(lyrics[["Spotify URL"]], analysis[["Spotify URL"]]))
joined <- match(analysis[["Spotify URL"]], lyrics[["Spotify URL"]])
dates <- as.Date(lyrics[["Date Added"]][joined], format = "%b %d, %Y")
keep <- !is.na(dates) & dates >= as.Date("2024-01-01") &
  dates < as.Date("2026-10-01") & nzchar(analysis$Cluster)
songs <- analysis[keep, ]
dates <- dates[keep]
quarter <- sprintf("%s Q%d", format(dates, "%Y"),
                   (as.integer(format(dates, "%m")) - 1L) %/% 3L + 1L)
quarters <- sort(unique(quarter))
totals <- table(factor(quarter, levels = quarters))
stopifnot(length(quarters) == 11L, all(totals >= 10), sum(totals) == nrow(songs))
quarter_names <- paste0(sub("^20", "’", quarters), "\nn = ", as.integer(totals))

themes <- songs[["Primary theme"]]
themes <- ifelse(nzchar(themes), tools::toTitleCase(themes), "Unassigned")
theme_order <- names(sort(table(themes[themes != "Unassigned"]), decreasing = TRUE))
if ("Unassigned" %in% themes) theme_order <- c(theme_order, "Unassigned")
group_key <- unique(songs[, c("Cluster", "Cluster label")])
group_key <- group_key[order(group_key$Cluster), ]
stopifnot(!anyDuplicated(group_key$Cluster))
cluster_order <- group_key[["Cluster label"]]
model_count <- sum(songs[["Analysis status"]] == "Model suggestion")

make_tiles <- function(categories, ordered_categories) {
  counts <- table(factor(categories, levels = ordered_categories),
                  factor(quarter, levels = quarters))
  stopifnot(all(colSums(counts) == totals))
  tiles <- as.data.frame(counts, responseName = "songs")
  names(tiles)[1:2] <- c("category", "quarter")
  tiles$category <- factor(tiles$category, levels = rev(ordered_categories))
  tiles$share <- tiles$songs / as.numeric(totals[as.character(tiles$quarter)])
  stopifnot(all(abs(tapply(tiles$share, tiles$quarter, sum) - 1) < 1e-10))
  tiles
}

theme_tiles <- make_tiles(themes, theme_order)
cluster_tiles <- make_tiles(songs[["Cluster label"]], cluster_order)
limit <- ceiling(10 * max(theme_tiles$share, cluster_tiles$share)) / 10

draw <- function(tiles, title, caption, output, height) {
  tiles$label <- ifelse(tiles$songs > 0, sprintf("%.0f%%", 100 * tiles$share), "")
  tiles$label_ink <- ifelse(tiles$share < 0.58 * limit, "#FFFFFF", "#132320")
  plot <- ggplot(tiles, aes(quarter, category, fill = share)) +
    geom_tile(width = 0.95, height = 0.88) +
    geom_text(aes(label = label, color = label_ink), size = 3.3, fontface = "bold") +
    scale_color_identity() +
    scale_fill_viridis_c(begin = 0.05, end = 0.92, limits = c(0, limit),
                        breaks = seq(0, limit, by = 0.1), labels = scales::label_percent(),
                        guide = guide_colorbar(title.position = "top",
                                               barwidth = grid::unit(72, "mm"))) +
    scale_x_discrete(labels = setNames(quarter_names, quarters), expand = expansion(add = 0.02)) +
    scale_y_discrete(expand = expansion(add = 0.02)) +
    labs(title = title, subtitle = sprintf("%d analyzed tracks · January 2024 to September 2026",
                                         nrow(songs)),
         x = "Quarter added", y = NULL, fill = "Share of analyzed tracks",
         caption = caption) +
    theme_minimal(base_size = 12) +
    theme(panel.grid = element_blank(), plot.background = element_rect(fill = "#FCFBF7", color = NA),
          plot.title.position = "plot", plot.caption.position = "plot",
          plot.title = element_text(face = "bold", size = 23, color = "#182824", margin = margin(b = 7)),
          plot.subtitle = element_text(color = "#465A54", margin = margin(b = 14)),
          plot.caption = element_text(hjust = 0, color = "#465A54", margin = margin(t = 8)),
          axis.text = element_text(color = "#283A36"),
          axis.text.y = element_text(face = "bold", margin = margin(r = 8)),
          axis.title.x = element_text(size = 10, margin = margin(t = 6)),
          legend.position = "bottom", legend.justification = "left",
          legend.title = element_text(size = 10, face = "bold"),
          plot.margin = margin(19, 20, 16, 20))
  ggsave(output, plot, width = 12.2, height = height, dpi = 170, bg = "#FCFBF7")
}

draw(theme_tiles, "Primary lyrical themes over time",
     sprintf("%d of %d labels are model suggestions. Blank tiles represent 0%%.", model_count, nrow(songs)),
     "data/playlist/visualizations/playlist_primary_themes_over_time.png", 10)
draw(cluster_tiles, "Lyrical clusters over time",
     "Cluster names summarize recurring patterns in the lyrics. Blank tiles represent 0%.",
     "data/playlist/visualizations/playlist_lyric_clusters_over_time.png", 5.9)
cat("Quarter counts:", as.integer(totals), "\n")
for (tiles in list(theme_tiles, cluster_tiles)) {
  print(tiles[as.character(tiles$quarter) %in% c("2025 Q1", "2026 Q1") &
                tiles$share >= .14, ], row.names = FALSE)
}
cat("Model suggestions:", model_count, "of", nrow(songs), "\n")
