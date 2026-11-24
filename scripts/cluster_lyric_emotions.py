"""Cluster English lyrics by eight NRC EmoLex word-association rates."""

import argparse
import csv
import re
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from zipfile import ZipFile

import numpy as np
from langdetect import DetectorFactory, LangDetectException, detect_langs
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler
from threadpoolctl import threadpool_limits

from cluster_lyrics import track_label
from score_lyrics import lyric_sections, lyrics_snapshot


EMOTIONS = ("joy", "sadness", "anger", "fear", "anticipation", "disgust", "surprise", "trust")
MEMBER = "NRC-Emotion-Lexicon-v0.92/NRC-emotion-lexicon-wordlevel-alphabetized-v0.92.txt"
WORD = re.compile(r"[a-z]+(?:'[a-z]+)*")
DetectorFactory.seed = 24


def load_lexicon(path):
    lexicon = {name: set() for name in EMOTIONS}
    with ZipFile(path) as archive:
        for line in archive.read(MEMBER).decode("utf-8-sig").splitlines():
            fields = line.split("\t")
            if len(fields) == 3:
                word, emotion, associated = fields
                if emotion in lexicon and associated == "1":
                    lexicon[emotion].add(word)
    if not all(lexicon.values()):
        raise ValueError("Expected entries for all eight NRC emotions.")
    return lexicon


def english(text):
    try:
        guess = detect_langs(text)[0]
    except LangDetectException:
        return False
    return guess.lang == "en" and guess.prob >= 0.8


def lyric_tokens(text):
    clean = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    lines = (line for line in clean.splitlines() if not re.fullmatch(r"\s*\[[^]]+\]\s*", line))
    return tuple(word for line in dict.fromkeys(tuple(WORD.findall(line)) for line in lines)
                 for word in line)


def cluster(vectors):
    standard = StandardScaler().fit_transform(vectors)
    scores = {}
    best = None
    with threadpool_limits(limits=2):
        for k in range(3, min(9, len(standard))):
            fit = KMeans(n_clusters=k, random_state=24, n_init=30).fit(standard)
            if len(set(fit.labels_)) != k:
                continue
            scores[k] = silhouette_score(standard, fit.labels_, sample_size=3000, random_state=24)
            if best is None or scores[k] > scores[best.n_clusters]:
                best = fit
        if best is None:
            raise ValueError("At least four distinct emotion profiles are required.")
        pca = PCA(n_components=2)
        points = pca.fit_transform(standard)
    return best, scores, points, pca.explained_variance_ratio_.sum(), standard


def write_csv(path, rows):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lexicon", type=Path, default=Path("data/models/nrc/NRC-Emotion-Lexicon-v0.92.zip"))
    args = parser.parse_args()
    lexicon = load_lexicon(args.lexicon)
    out = Path("outputs/therapy")
    emotion_data = Path("data/emotion")
    out.mkdir(parents=True, exist_ok=True)
    emotion_data.mkdir(parents=True, exist_ok=True)
    with Path("data/processed/track_catalog.csv").open(encoding="utf-8-sig", newline="") as stream:
        catalog = {r["track_id"]: r for r in csv.DictReader(stream)}
    hours = {t: float(r["hours_listened"]) for t, r in catalog.items()}
    stamp, lyrics = lyrics_snapshot(Path("data/lyrics/lyrics.sqlite3"))
    groups = defaultdict(list)
    skipped = Counter()
    for track_id in sorted(catalog.keys() & lyrics.keys()):
        text = lyrics[track_id][1]
        tokens = lyric_tokens(text)
        if len(tokens) < 20:
            skipped["under 20 words"] += 1
            continue
        if not english("\n".join(section for _, section in lyric_sections(text))):
            skipped["other or uncertain language"] += 1
            continue
        groups[tokens].append(track_id)
    counts = [Counter(tokens) for tokens in groups]
    rates = np.array([[100 * sum(freq[w] for w in freq if w in lexicon[e]) / len(tokens)
                       for e in EMOTIONS] for tokens, freq in zip(groups, counts)])
    fit, scores, points, variance, standardized = cluster(rates)
    group_hours = [sum(hours[t] for t in tracks) for tracks in groups.values()]
    cluster_hours = np.bincount(fit.labels_, weights=group_hours)
    order = sorted(range(fit.n_clusters), key=lambda label: (-cluster_hours[label], label))
    total_hours = sum(hours.values())
    track_sets = list(groups.values())
    examples = [track_label(catalog[max(tracks, key=hours.get)]) for tracks in track_sets]
    summary = []
    profiles = []
    track_rows = []
    for rank, label in enumerate(order, 1):
        code = f"E{rank:02}"
        members = np.flatnonzero(fit.labels_ == label)
        midpoint = rates[members].mean(axis=0)
        elevations = fit.cluster_centers_[label]
        prominent = ", ".join(EMOTIONS[i] for i in np.argsort(-elevations)[:2] if elevations[i] > 0)
        nearest = sorted(members, key=lambda i: np.linalg.norm(standardized[i] - elevations))[:3]
        popular = sorted(members, key=lambda i: -group_hours[i])[:3]
        central_titles = "; ".join(examples[i] for i in nearest)
        popular_titles = "; ".join(examples[i] for i in popular)
        summary.append(f"| {code} | {prominent or 'Across-the-board lower rates'} | {len(members)} | "
                       f"{cluster_hours[label] / total_hours:.1%} | {central_titles} | {popular_titles} |")
        for emotion, rate, z in zip(EMOTIONS, midpoint, elevations):
            profiles.append({"cluster": code, "emotion": emotion, "rate": rate, "z_score": z})
        for i in members:
            representative = max(track_sets[i], key=hours.get)
            for track_id in track_sets[i]:
                track_rows.append({
                    "track_id": track_id, "cluster": code, "hours_listened": hours[track_id],
                    "representative": track_id == representative, "pca_1": points[i, 0], "pca_2": points[i, 1],
                    **dict(zip(EMOTIONS, rates[i])),
                })
    write_csv(out / "lyric_emotion_cluster_profiles.csv", profiles)
    write_csv(emotion_data / "track_emotion_clusters.csv", track_rows)
    report = [
        "# Groups of songs by emotional language", "",
        f"Snapshot {stamp}. {len(track_rows):,} Spotify tracks representing "
        f"{cluster_hours.sum() / total_hours:.1%} of all listening time contributed "
        f"{len(groups):,} distinct prepared lyric versions.", "",
        f"Excluded {skipped['under 20 words']:,} tracks with fewer than 20 words and "
        f"{skipped['other or uncertain language']:,} with other or uncertain language. "
        "Tracks without plain lyrics were unavailable to this analysis.", "",
        "NRC EmoLex v0.92 measures eight emotion-associated word rates per 100 lyric words. "
        "Duplicate lyric lines are counted once. K-means compares standardized rates across songs. "
        "Cluster descriptions show the strongest above-average word associations. "
        "Word associations miss context such as negation, irony, and the sound of the recording.", "",
        f"Selected {fit.n_clusters} clusters. Silhouette scores "
        + ", ".join(f"{k} groups {v:.3f}" for k, v in scores.items()) + ". "
        f"The first two principal components explain {variance:.1%} of variance.", "",
        "| Group | Above-average associations | Lyric versions | Share of all listening | Typical examples | Most-listened examples |",
        "| --- | --- | ---: | ---: | --- | --- |", *summary,
    ]
    (out / "lyric_emotion_clusters.md").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(f"Clustered {len(track_rows):,} English tracks into {fit.n_clusters} groups "
          f"covering {cluster_hours.sum() / total_hours:.1%} of listening time. "
          f"Silhouette {scores[fit.n_clusters]:.3f}.", flush=True)


if __name__ == "__main__":
    main()
