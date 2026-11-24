# Run from the project root after scripts/cluster_lyric_emotions.py.
suppressPackageStartupMessages({ library(ggplot2); library(readr) })

out <- "outputs/therapy"
profile <- read_csv(file.path(out, "lyric_emotion_cluster_profiles.csv"), show_col_types = FALSE)
tracks <- read_csv("data/emotion/track_emotion_clusters.csv", show_col_types = FALSE)
stopifnot(!anyDuplicated(tracks$track_id), all(table(profile$cluster) == 8L),
          setequal(profile$cluster, tracks$cluster))
profile$emotion <- factor(profile$emotion, levels = rev(unique(profile$emotion)),
                          labels = tools::toTitleCase(rev(unique(profile$emotion))))
limit <- max(abs(profile$z_score))
heatmap <- ggplot(profile, aes(cluster, emotion, fill = z_score)) +
  geom_tile(colour = "white", linewidth = 0.8) +
  geom_text(aes(label = sprintf("%.2f", rate),
                colour = abs(z_score) > 0.68 * limit), fontface = "bold") +
  scale_colour_manual(values = c("FALSE" = "#20313C", "TRUE" = "#FFFFFF"), guide = "none") +
  scale_fill_gradient2(low = "#236791", mid = "#F5F3EB", high = "#AA4834",
                       limits = c(-limit, limit)) +
  theme_minimal(base_size = 13) +
  theme(panel.grid = element_blank(), legend.position = "bottom") +
  labs(title = "Emotional language by song group",
       subtitle = "The numbers show emotion-associated words per 100 lyric words",
       x = "Song group", y = NULL, fill = "Standard deviations from track average")
ggsave(file.path(out, "lyric_emotion_cluster_profiles.png"), heatmap,
       width = 9, height = 6, dpi = 180, bg = "white")

points <- tracks[tracks$representative, ]
map <- ggplot(points, aes(pca_1, pca_2, colour = cluster)) +
  geom_point(size = 1.9, alpha = 0.67) +
  scale_colour_brewer(palette = "Dark2") +
  theme_minimal(base_size = 13) +
  labs(title = "Songs grouped by emotional language",
       subtitle = "Each point represents one distinct prepared lyric version",
       x = "Principal component 1", y = "Principal component 2", colour = "Group")
ggsave(file.path(out, "lyric_emotion_cluster_map.png"), map,
       width = 9, height = 6, dpi = 180, bg = "white")
cat("Wrote emotion profile heatmap and PCA map.\n")
