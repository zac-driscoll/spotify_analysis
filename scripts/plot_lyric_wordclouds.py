"""Render separate listening-time-weighted English lyric word clouds for 2024 and 2025."""

from collections import Counter
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from pyarrow import parquet
from sklearn.feature_extraction.text import ENGLISH_STOP_WORDS
from wordcloud import WordCloud

from cluster_lyric_emotions import english, lyric_tokens
from score_lyrics import lyric_sections, lyrics_snapshot


YEARS = (2024, 2025)
FILLER = {"yeah", "yea", "hey", "huh", "nah", "ooh", "aah", "woo", "whoa", "woah",
          "gonna", "wanna", "gotta", "la", "da", "na", "uh", "oh", "aye", "yo", "mm",
          "mmm", "em", "ya", "cause", "bout", "ain't"}


def yearly_time(path):
    weights = {year: Counter() for year in YEARS}
    plays = parquet.read_table(path, columns=["date_local", "track_id", "ms_played"])
    for row in plays.to_pylist():
        year = row["date_local"].year
        if year in weights and row["ms_played"] > 0:
            weights[year][row["track_id"]] += row["ms_played"]
    return weights


def content_words(text):
    tokens = lyric_tokens(text)
    if len(tokens) < 20 or not english("\n".join(section for _, section in lyric_sections(text))):
        return Counter()
    return Counter(word for word in tokens if len(word) >= 3 and "'" not in word
                   and word not in ENGLISH_STOP_WORDS and word not in FILLER)


def render(year, frequencies, coverage, path):
    cloud = WordCloud(width=1200, height=650, scale=2, background_color="#F8F5EE",
                      colormap="cividis", max_words=90, prefer_horizontal=0.93,
                      random_state=24).generate_from_frequencies(frequencies)
    image = Image.new("RGB", (2480, 1540), "#F8F5EE")
    image.paste(cloud.to_image().convert("RGB"), (40, 185))
    draw = ImageDraw.Draw(image)
    title = ImageFont.truetype("DejaVuSans-Bold.ttf", 78)
    body = ImageFont.truetype("DejaVuSans.ttf", 34)
    draw.text((58, 36), f"{year} listening · words from your lyrics", fill="#132B38", font=title)
    draw.text((62, 137), f"Weighted by listening time · English lyrics available for {coverage:.1%} of listening time",
              fill="#415662", font=body)
    image.save(path)


def main():
    times = yearly_time(Path("data/processed/music_plays.parquet"))
    stamp, snapshot = lyrics_snapshot(Path("data/lyrics/lyrics.sqlite3"))
    track_ids = set().union(*(weights.keys() for weights in times.values()))
    words = {track_id: content_words(snapshot[track_id][1])
             for track_id in sorted(track_ids & snapshot.keys())}
    output = Path("outputs/therapy")
    output.mkdir(parents=True, exist_ok=True)
    for year, weights in times.items():
        totals = Counter()
        covered = 0
        for track_id, listened in weights.items():
            counts = words.get(track_id)
            if not counts:
                continue
            covered += listened
            factor = listened / counts.total()
            totals.update({word: count * factor for word, count in counts.items()})
        if not totals:
            raise ValueError(f"No eligible lyric words for {year}")
        coverage = covered / weights.total()
        render(year, totals, coverage, output / f"lyric_wordcloud_{year}.png")
        print(f"{year}: {coverage:.1%} of listening, {len(totals):,} distinct content words ({stamp})")


if __name__ == "__main__":
    main()
