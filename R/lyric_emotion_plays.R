# Filter clearly labeled background recordings from lyric emotion time series.
is_background_noise <- function(track_name, album_name, artist_name) {
  metadata <- tolower(paste(track_name, album_name))
  title <- tolower(track_name)
  artist <- tolower(artist_name)
  noise <- "\\b(white noise|pink noise|brown noise|green noise|air condition(er|ing)|heat pump|desktop computer|computer hum|power line hum|electrical substations|ventilation units?|room ventilation|rumbling ac|rain sounds? for sleep)\\b"
  fan <- "\\b(box|cooling|ceiling|floor|table|standing|pedestal|bathroom|desk|heater) fans?\\b|\\bfans? (sounds?|noises?|asmr|for sleep|to make you rest|at (low|slow|high))\\b|\\b(calming|soothing|sleepy|rotating|sleep|fantastic) fans?\\b|\\b(fan of fan|étude for fan|chill with fans)\\b"
  ambient_artist <- artist %in% c("fan relax", "fan fans", "fan-tastic", "white noise radiance")
  known_song <- (artist == "diva bleach" & title == "white noise") %in% TRUE
  !known_song & (grepl(noise, metadata) | grepl(fan, metadata) | ambient_artist)
}

read_lyric_emotion_plays <- function() {
  plays <- arrow::read_parquet(
    "data/processed/music_plays.parquet",
    col_select = c(track_id, date_local, ms_played, track_name, album_name, artist_name)
  )
  background <- with(plays, is_background_noise(track_name, album_name, artist_name))
  message(sprintf("Excluded %.2f hours of background recordings across %d Spotify IDs.",
                  sum(plays$ms_played[background]) / 3.6e6,
                  length(unique(plays$track_id[background]))))
  plays[!background, c("track_id", "date_local", "ms_played")]
}
