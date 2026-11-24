"""Cluster a local snapshot of lyric embeddings and report listening coverage."""

import csv
import re
from collections import defaultdict
from pathlib import Path

import numpy as np
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.metrics import silhouette_score
from threadpoolctl import threadpool_limits

from score_lyrics import embed_sections, lyric_sections, lyrics_snapshot, model_version, normalize


def prepare_groups(lyrics, catalog):
    groups = defaultdict(list)
    for track_id in sorted(catalog.keys() & lyrics.keys()):
        sections = tuple(text for _, text in lyric_sections(lyrics[track_id][1]))
        if sections:
            groups[sections].append(track_id)
    return groups


def select_clusters(vectors):
    sizes = [k for k in (8, 10, 12, 14) if k < len(vectors)]
    if not sizes:
        raise ValueError("Clustering needs at least nine distinct prepared lyrics.")
    scores = {}
    fits = {}
    with threadpool_limits(limits=2):
        for k in sizes:
            fit = KMeans(n_clusters=k, n_init=20, random_state=24).fit(vectors)
            if 1 < len(set(fit.labels_)) < len(vectors):
                fits[k] = fit
                scores[k] = silhouette_score(
                    vectors, fit.labels_, metric="cosine", sample_size=3000, random_state=24
                )
        if not scores:
            raise ValueError("Clustering did not produce multiple distinct groups.")
        fit = fits[max(scores, key=scores.get)]
        projection = PCA(n_components=2, random_state=24)
        coordinates = projection.fit_transform(vectors)
    return fit, scores, coordinates, projection.explained_variance_ratio_.sum()


def track_label(row):
    return re.sub(r"([\\|`*_<>\[\]])", r"\\\1",
                  f"{row['track_name']} — {row['artist_name']}").replace("\n", " ")


def main():
    model = Path("data/models/minilm")
    data = Path("data/emotion")
    out = Path("outputs/therapy")
    out.mkdir(parents=True, exist_ok=True)
    with Path("data/processed/track_catalog.csv").open(encoding="utf-8-sig", newline="") as stream:
        catalog = {row["track_id"]: row for row in csv.DictReader(stream)}
    stamp, lyrics = lyrics_snapshot(Path("data/lyrics/lyrics.sqlite3"))
    groups = prepare_groups(lyrics, catalog)
    if len(groups) < 9:
        raise ValueError("Clustering needs at least nine distinct prepared lyrics.")
    texts = dict.fromkeys(text for sections in groups for text in sections)
    vectors = embed_sections(texts, model, data / "section_embeddings.sqlite3", model_version(model), 6)
    means = normalize(np.stack([np.mean([vectors[text] for text in sections], axis=0) for sections in groups]))
    centered = normalize(means - means.mean(0))
    fit, scores, coordinates, variance = select_clusters(centered)
    hours = {track_id: float(row["hours_listened"]) for track_id, row in catalog.items()}
    group_hours = [sum(hours[track] for track in tracks) for tracks in groups.values()]
    counts = np.bincount(fit.labels_, weights=group_hours, minlength=fit.n_clusters)
    order = sorted(set(fit.labels_), key=lambda label: (-counts[label], label))
    names = {label: f"C{rank:02}" for rank, label in enumerate(order, 1)}
    examples = defaultdict(list)
    records = []
    for i, (tracks, label, (x, y)) in enumerate(zip(groups.values(), fit.labels_, coordinates)):
        representative = max(tracks, key=hours.get)
        distance = float(np.linalg.norm(centered[i] - fit.cluster_centers_[label]))
        examples[label].append((distance, -group_hours[i], representative))
        records.extend(
            {"track_id": tid, "cluster": names[label], "lyric_group_size": len(tracks),
             "hours_listened": hours[tid], "pca_1": x, "pca_2": y,
             "centroid_distance": distance,
             "representative": tid == representative}
            for tid in tracks
        )

    with (data / "track_lyric_clusters.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    total = sum(hours.values())
    clustered = sum(counts)
    lines = [
        "# Listening groups based on lyrics", "",
        f"Snapshot {stamp}. {len(records):,} track IDs with usable lyrics represent "
        f"{clustered / total:.1%} of listening time. They form {len(groups):,} distinct "
        "prepared lyric groups after identical prepared lyrics are collapsed.", "",
        f"Selected {fit.n_clusters} clusters. Cosine silhouette by cluster count "
        + ", ".join(f"{k} = {score:.3f}" for k, score in scores.items()) + ". "
        f"The two-dimensional map shows {variance:.1%} of embedding variance. "
        "Treat groups as starting points for comparing songs; broad themes can overlap.", "",
        "Cluster IDs are ordered by listening time in this snapshot and can change on rerun.", "",
        "| Group | Distinct prepared lyrics | Share of all listening | Songs nearest the center | Most listened examples |",
        "| --- | ---: | ---: | --- | --- |",
    ]
    for label in order:
        members = examples[label]
        central = "; ".join(track_label(catalog[t]) for _, _, t in sorted(members)[:3])
        popular = "; ".join(track_label(catalog[t]) for _, _, t in sorted(members, key=lambda x: x[1])[:3])
        lines.append(f"| {names[label]} | {len(members)} | {counts[label] / total:.1%} | {central} | {popular} |")
    (out / "lyric_clusters.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Clustered {len(records):,} tracks ({len(groups):,} lyric groups); "
          f"listening time coverage {clustered / total:.1%}; "
          f"selected {fit.n_clusters}, silhouette {scores[fit.n_clusters]:.3f}.", flush=True)


if __name__ == "__main__":
    main()
