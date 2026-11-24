library(ggplot2)

args <- commandArgs(trailingOnly = TRUE)
archive <- if (length(args) >= 1L) args[[1]] else tempfile(fileext = ".zip")
output <- if (length(args) >= 2L) args[[2]] else "data/playlist/visualizations/playlist_lyric_emotion_heatmap.png"

if (length(args) == 0L) {
  download.file("https://saifmohammad.com/Lexicons/NRC-Emotion-Lexicon-v0.92.zip",
                archive, mode = "wb", quiet = TRUE)
}

emotions <- c("Joy", "Sadness", "Anger", "Fear",
              "Anticipation", "Disgust", "Surprise", "Trust")
member <- "NRC-Emotion-Lexicon-v0.92/NRC-emotion-lexicon-wordlevel-alphabetized-v0.92.txt"
lexicon_lines <- readLines(unz(archive, member), encoding = "UTF-8")
entries <- strsplit(grep("^[^\t]+\t[^\t]+\t1$", lexicon_lines, value = TRUE), "\t")
terms <- vapply(entries, function(entry) entry[[1]], character(1))
associations <- vapply(entries, function(entry) entry[[2]], character(1))
emotion_words <- lapply(tolower(emotions), function(emotion) {
  unique(terms[associations == emotion])
})
stopifnot(all(lengths(emotion_words) > 0L))

read_tracks <- function(path) {
  read.csv(path, fileEncoding = "UTF-8-BOM", check.names = FALSE,
           colClasses = "character", na.strings = NULL)
}

tracks <- read_tracks("data/playlist/spotify_lrclib_lyrics.csv")
semantic <- read_tracks("data/playlist/lyric_semantic_analysis.csv")
stopifnot(!anyDuplicated(tracks$Position), !anyDuplicated(semantic$Position),
          setequal(tracks$Position, semantic$Position))
language <- semantic[["Estimated language"]][match(tracks$Position, semantic$Position)]
added <- as.Date(tracks[["Date Added"]], format = "%b %d, %Y")
eligible <- !is.na(added) & tracks[["LRCLIB Status"]] == "Lyrics found" & language == "en"
lyrics <- tracks[["Plain Lyrics"]][eligible]
quarter <- sprintf("%s Q%d", format(added[eligible], "%Y"),
                   (as.integer(format(added[eligible], "%m")) - 1L) %/% 3L + 1L)

score_track <- function(lyric) {
  lyric <- stringi::stri_trans_casefold(stringi::stri_trans_nfkc(lyric))
  lyric <- gsub("’", "'", lyric, fixed = TRUE)
  lines <- strsplit(lyric, "\r?\n")[[1]]
  lines <- lines[!grepl("^\\s*\\[[^]]+\\]\\s*$", lines, perl = TRUE)]
  tokens_by_line <- regmatches(lines, gregexpr("[a-z]+(?:'[a-z]+)*", lines, perl = TRUE))
  tokens <- unlist(unique(tokens_by_line), use.names = FALSE)
  if (length(tokens) < 20L) return(rep(NA_real_, length(emotions)))
  vapply(emotion_words, function(words) 100 * mean(tokens %in% words), numeric(1))
}

rates <- t(vapply(lyrics, score_track, numeric(length(emotions))))
colnames(rates) <- emotions
scorable <- complete.cases(rates)
quarter_counts <- table(quarter[scorable])
quarters <- names(quarter_counts[quarter_counts >= 10L])
stopifnot(length(quarters) > 0L)
averages <- vapply(quarters, function(period) {
  colMeans(rates[quarter == period & scorable, , drop = FALSE])
}, numeric(length(emotions)))
shown_tracks <- sum(quarter_counts[quarters])
values <- data.frame(
  quarter = factor(rep(quarters, each = length(emotions)), levels = quarters,
                   labels = sub("^20", "’", quarters)),
  emotion = factor(rep(emotions, times = length(quarters)), levels = rev(emotions)),
  rate = as.vector(averages)
)
limits <- c(floor(min(values$rate) * 2) / 2, ceiling(max(values$rate) * 2) / 2)
stopifnot(diff(limits) > 0)
values$label_color <- ifelse(values$rate < limits[1] + 0.58 * diff(limits),
                             "#FFFFFF", "#132320")

chart <- ggplot(values, aes(quarter, emotion)) +
  geom_tile(aes(fill = rate), width = 0.95, height = 0.89) +
  geom_text(aes(label = sprintf("%.2f", rate), color = label_color), size = 3.8,
            fontface = "bold") +
  scale_color_identity() +
  scale_fill_viridis_c(option = "D", begin = 0.05, end = 0.92, limits = limits,
                        breaks = seq(limits[1], limits[2], by = 0.5),
                        guide = guide_colorbar(title.position = "top",
                                                 barwidth = grid::unit(80, "mm"))) +
  scale_x_discrete(expand = expansion(add = 0.02)) +
  scale_y_discrete(expand = expansion(add = 0.02)) +
  labs(
    title = "Emotional language in your playlist",
    subtitle = sprintf("%d English-language tracks grouped by the quarter you added them",
                       shown_tracks),
    x = "Quarter added", y = NULL,
    fill = "Emotion-associated words per 100 lyric words",
    caption = paste(
      "Each tile is a quarterly average with each track weighted equally.",
      "Word associations from NRC EmoLex v0.92.",
      sep = "\n"
    )
  ) +
  theme_minimal(base_size = 12, base_family = "sans") +
  theme(
    panel.grid = element_blank(),
    plot.background = element_rect(fill = "#FCFBF7", color = NA),
    plot.title.position = "plot",
    plot.caption.position = "plot",
    plot.title = element_text(face = "bold", size = 24, color = "#182824",
                              margin = margin(b = 8)),
    plot.subtitle = element_text(size = 12, color = "#465A54", margin = margin(b = 17)),
    plot.caption = element_text(hjust = 0, size = 9, color = "#465A54",
                                 margin = margin(t = 10), lineheight = 1.15),
    axis.text = element_text(color = "#283A36"),
    axis.text.y = element_text(face = "bold", margin = margin(r = 10)),
    axis.text.x = element_text(margin = margin(t = 5)),
    axis.title.x = element_text(size = 10, margin = margin(t = 7)),
    legend.position = "bottom",
    legend.justification = "left",
    legend.box.margin = margin(t = 6),
    legend.title = element_text(size = 9, face = "bold"),
    legend.text = element_text(size = 9),
    plot.margin = margin(23, 23, 16, 23)
  )

ggsave(output, chart, width = 11, height = 7.1, dpi = 180, bg = "#FCFBF7")
cat(sprintf("Rendered %d quarterly emotion scores with ggplot2 %s.\n",
            nrow(values), packageVersion("ggplot2")))
