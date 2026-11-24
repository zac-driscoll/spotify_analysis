library(ggplot2)

# Positive cases from a keyword screen followed by a close reading of the lyrics.
review <- read.delim("data/playlist/playlist_gender_review.tsv", quote = "",
                     stringsAsFactors = FALSE)

tracks <- read.csv("data/playlist/spotify_lrclib_lyrics.csv", fileEncoding = "UTF-8-BOM",
                   check.names = FALSE, stringsAsFactors = FALSE)
stopifnot(!anyDuplicated(tracks$Position), !anyDuplicated(review$Position),
          all(review$Position %in% tracks$Position[tracks[["LRCLIB Status"]] == "Lyrics found"]))
tracks$date <- as.Date(tracks[["Date Added"]], format = "%b %d, %Y")
range_start <- as.Date("2024-01-01")
range_end <- as.Date("2026-10-01")
songs <- tracks[!is.na(tracks$date) & tracks$date >= range_start & tracks$date < range_end &
                 tracks[["LRCLIB Status"]] == "Lyrics found", ]
songs$quarter <- sprintf("%s Q%d", format(songs$date, "%Y"),
                         1L + (as.integer(format(songs$date, "%m")) - 1L) %/% 3L)
songs$class <- review$Class[match(songs$Position, review$Position)]
quarters <- sort(unique(songs$quarter))
totals <- table(factor(songs$quarter, levels = quarters))
stopifnot(length(quarters) == 11L, sum(totals) == nrow(songs))
songs$class[is.na(songs$class)] <- "No confirmed case"

summarize <- function(label, positive_classes) {
  numerator <- as.integer(table(factor(songs$quarter[songs$class %in% positive_classes],
                                       levels = quarters)))
  data.frame(quarter = factor(quarters, levels = quarters), count = numerator,
             total = as.integer(totals), metric = label)
}
labels <- c("Explicit gender-identity references", "Gender identity, expression, or norms")
series <- rbind(summarize(labels[1], "Explicit"), summarize(labels[2], c("Explicit", "Broader")))
series$metric <- factor(series$metric, levels = labels)
series$share <- series$count / series$total
stopifnot(all(series$count <= series$total),
          all(series$count[series$metric == labels[1]] <= series$count[series$metric == labels[2]]))
series$annotation <- ifelse(series$count == 0L, "", as.character(series$count))
axis_labels <- paste0(sub("^20", "’", quarters), "\nn = ", as.integer(totals))

plot <- ggplot(series, aes(quarter, share, group = 1, color = metric)) +
  geom_hline(yintercept = 0, linewidth = .35, color = "#9CA9A0") +
  geom_line(linewidth = .9) +
  geom_point(size = 2.9) +
  geom_text(aes(label = annotation), vjust = -.85, size = 3.7, fontface = "bold") +
  facet_wrap(vars(metric), ncol = 1) +
  scale_color_manual(values = setNames(c("#126B60", "#8D3D68"), labels), guide = "none") +
  scale_x_discrete(labels = setNames(axis_labels, quarters)) +
  scale_y_continuous(labels = scales::label_percent(), limits = c(0, NA),
                     expand = expansion(mult = c(.05, .24))) +
  labs(title = "Gender in the lyrics you saved",
       subtitle = sprintf("%d songs with available lyrics · January 2024 to September 2026", nrow(songs)),
       x = "Quarter added", y = "Share of songs with available lyrics",
       caption = paste("Numbers above points show songs flagged. The broader measure includes the explicit references.",
                       "A zero means the screen and close reading confirmed no cases that quarter.", sep = "\n")) +
  theme_minimal(base_size = 12) +
  theme(plot.background = element_rect(fill = "#FCFBF7", color = NA),
        plot.title.position = "plot", plot.caption.position = "plot",
        plot.title = element_text(face = "bold", size = 24, color = "#182824", margin = margin(b = 6)),
        plot.subtitle = element_text(color = "#465A54", margin = margin(b = 12)),
        plot.caption = element_text(hjust = 0, color = "#465A54", margin = margin(t = 11)),
        panel.grid.major.x = element_blank(), panel.grid.minor = element_blank(),
        panel.grid.major.y = element_line(color = "#E6E9E1", linewidth = .35),
        strip.text = element_text(hjust = 0, face = "bold", color = "#182824", margin = margin(b = 7)),
        panel.spacing = grid::unit(1.05, "lines"),
        axis.text = element_text(color = "#283A36"),
        axis.title = element_text(size = 10, color = "#283A36"),
        plot.margin = margin(20, 20, 16, 20))
ggsave("data/playlist/visualizations/playlist_gender_lyrics_over_time.png", plot,
       width = 11, height = 7.3, dpi = 175, bg = "#FCFBF7")

cases <- merge(review, songs[, c("Position", "Title", "Artist", "date", "quarter")], by = "Position")
cases <- cases[order(cases$date, cases$Title), ]
stopifnot(nrow(cases) == nrow(review))
escape <- function(x) gsub("|", "\\|", x, fixed = TRUE)
header <- c(
  "# Gender references in the playlist lyrics",
  "",
  "Each quarterly score is the number of confirmed tracks divided by all tracks with available lyrics added that quarter.",
  "Each song counts once per series. The broader series includes every explicit case.",
  "The chart covers the same eleven quarters as the theme and cluster charts. Relative dates and tracks without lyrics have no plotted score.",
  "",
  "**Explicit** covers references to trans or nonbinary identities, questioning one's gender, or directly expressed gender-related discomfort.",
  "**Broader** adds lyrics that substantively address gendered presentation or social expectations.",
  "",
  "I screened titles and lyrics for English terms such as trans, nonbinary, gender, dysphoria, patriarchy and phrases about being or being seen as a boy or girl.",
  "I also checked tracks surfaced by searches for gendered roles and presentation and read the surrounding lyrics before assigning a label.",
  "A title alone, a word like girl or boy, a clothing reference alone, and references solely to sexual orientation were insufficient.",
  "This is a conservative first pass. Indirect imagery and non-English phrasing can be missed. The labels apply to the lyrics of the track.",
  "",
  "| Date added | Track | Artist | Evidence category | Reading note |",
  "|---|---|---|---|---|"
)
lines <- sprintf("| %s | %s | %s | %s | %s |", cases$date, escape(cases$Title),
                 escape(cases$Artist), cases$Class, cases$Reading)
writeLines(c(header, lines), "data/playlist/visualizations/playlist_gender_lyrics_notes.md")
print(series[, c("quarter", "count", "total", "metric")], row.names = FALSE)
