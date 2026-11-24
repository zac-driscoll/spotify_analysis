"""Suggest themes from a snapshot of locally cached lyrics using multilingual MiniLM."""

import argparse
import csv
import hashlib
import json
import re
import sqlite3
import unicodedata
from collections import Counter
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.parse import urlparse

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer


MODEL = "paraphrase-multilingual-MiniLM-L12-v2"
METHOD = "definition-cosine-v1"
DEFINITIONS = {
    "attraction": "Desire, romantic pursuit, tenderness, devotion or longing for intimacy with a specific person.",
    "autonomy": "Setting boundaries, asserting independence, rejecting control or choosing how to live on one's own terms.",
    "belonging": "Friendship, family, community, solidarity or attachment to a shared place and its people.",
    "breakup": "Ending a romantic relationship, dealing with an ex, betrayal by a partner or moving on from heartbreak.",
    "celebration": "Dancing, partying, pleasure, shared exhilaration or escape through a night out.",
    "change": "New beginnings, reinvention, taking a chance, leaving a familiar life or facing an uncertain future.",
    "conflict": "Rivalry, insults, anger at another person, a confrontation, threats or revenge.",
    "coping": "Seeking relief or finding ways to manage emotional pain through habits, treatment, substances, humor or companionship.",
    "distance": "Physical separation, travel to reach someone or a relationship maintained across places.",
    "identity": "Self-image, self-acceptance, gender expression, sexuality or the contrast between public persona and private self.",
    "inner struggle": "Anxiety, depression, intrusive thoughts, insecurity or emotional turmoil within the narrator.",
    "intensity": "Obsessive or overwhelming bodily desire, erotic surrender or dark seduction.",
    "loneliness": "Feeling alone, ignored, unseen or disconnected from others.",
    "loss": "Missing someone who is gone, grief, abandonment or a relationship remembered as irretrievable.",
    "memory": "Nostalgia, photographs, reminiscing, regret about missed moments or revisiting the past.",
    "mortality": "Death, dying, ghosts or coming to terms with human finitude.",
    "social critique": "Questioning public institutions, social norms, collective hypocrisy, oppression or widespread harm.",
    "spirituality": "Faith, prayer, curses, mystical practice or supernatural meaning as a sustained subject.",
    "status": "Fame, money, public image, prestige, wealth or competition for recognition.",
}
COLUMNS = [
    "track_id", "primary_theme", "secondary_themes", "theme_source",
    "model", "model_version", "method", "reference_scope",
    "model_primary_cosine", "model_margin", "evidence_sections",
    "unique_word_count", "scored_at_utc",
]


def lyrics_snapshot(path):
    with closing(sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True, timeout=30)) as db:
        rows = db.execute("SELECT track_id, origin, result FROM lyrics ORDER BY track_id").fetchall()
        timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    lyrics = {}
    for track_id, origin, payload in rows:
        plain = (json.loads(payload).get("Plain Lyrics") or "").strip()
        if plain:
            lyrics[track_id] = (origin, plain)
    return timestamp, lyrics


def close_readings(path):
    if not path.exists():
        return {}
    with path.open(encoding="utf-8-sig", newline="") as source:
        return {
            urlparse(row["Spotify URL"]).path.rsplit("/", 1)[-1]:
            (row["Primary theme"], row["Secondary themes"])
            for row in csv.DictReader(source)
            if row["Analysis status"] in {"Read in pilot", "Read in validation"}
        }


def lyric_sections(text):
    text = unicodedata.normalize("NFKC", text).replace("’", "'").replace("ʼ", "'")
    text = re.sub(r"(?m)^\s*\[[^\]\n]+\]\s*$", "", text)
    seen = set()
    sections = []
    section_index = 0
    for part in re.split(r"\n\s*\n", text):
        lines = [line.strip() for line in part.splitlines() if any(c.isalnum() for c in line)]
        for start in range(0, len(lines), 4):
            section_index += 1
            unique = []
            for line in lines[start:start + 4]:
                key = re.sub(r"[^\w]+", " ", line.casefold()).strip()
                if key and key not in seen:
                    seen.add(key)
                    unique.append(line)
            if unique:
                sections.append((section_index, "\n".join(unique)))
    return sections


def normalize(values):
    norms = np.linalg.norm(values, axis=-1, keepdims=True)
    return values / np.maximum(norms, 1e-12)


def model_version(model_dir):
    fingerprint = hashlib.sha256()
    for name in ("model.onnx", "tokenizer.json"):
        with (model_dir / name).open("rb") as source:
            fingerprint.update(hashlib.file_digest(source, "sha256").digest())
    return fingerprint.hexdigest()[:16]


def embedding_key(text):
    return hashlib.sha256(text.encode("utf-8")).digest()


def embed_sections(texts, model_dir, cache_path, version, threads):
    keys = {text: embedding_key(text) for text in texts}
    with closing(sqlite3.connect(cache_path, timeout=30)) as db:
        db.execute(
            "CREATE TABLE IF NOT EXISTS embeddings "
            "(encoder TEXT NOT NULL, text_key BLOB NOT NULL, vector BLOB NOT NULL, "
            "PRIMARY KEY (encoder, text_key))"
        )
        encoder = f"{version}:mean-pool-l128-v1"
        cached = dict(db.execute(
            "SELECT text_key, vector FROM embeddings WHERE encoder = ?", (encoder,)
        ))
        missing = [text for text, key in keys.items() if key not in cached]
        print(f"{len(keys):,} sections and definitions, {len(missing):,} to embed.", flush=True)
        if missing:
            ort.disable_telemetry_events()
            tokenizer = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
            tokenizer.enable_truncation(max_length=128)
            tokenizer.enable_padding(pad_id=1, pad_token="<pad>", pad_to_multiple_of=8)
            options = ort.SessionOptions()
            options.intra_op_num_threads = threads
            model = ort.InferenceSession(
                str(model_dir / "model.onnx"), sess_options=options,
                providers=["CPUExecutionProvider"],
            )
            inputs = {value.name for value in model.get_inputs()}
            for start in range(0, len(missing), 32):
                batch = missing[start:start + 32]
                tokens = tokenizer.encode_batch(batch)
                arrays = {
                    name: np.array([getattr(entry, attr) for entry in tokens], dtype=np.int64)
                    for name, attr in (
                        ("input_ids", "ids"), ("attention_mask", "attention_mask"),
                        ("token_type_ids", "type_ids"),
                    )
                }
                hidden = model.run(None, {k: v for k, v in arrays.items() if k in inputs})[0]
                mask = arrays["attention_mask"][:, :, None]
                pooled = normalize((hidden * mask).sum(1) / mask.sum(1)).astype("<f4")
                updates = [(keys[text], vector.tobytes()) for text, vector in zip(batch, pooled)]
                with db:
                    db.executemany(
                        "INSERT OR IGNORE INTO embeddings VALUES (?, ?, ?)",
                        ((encoder, key, value) for key, value in updates),
                    )
                cached.update(updates)
                if start % 640 == 0 or start + len(batch) == len(missing):
                    print(f"Embedded {start + len(batch):,}/{len(missing):,}.", flush=True)
    return {text: np.frombuffer(cached[key], dtype="<f4") for text, key in keys.items()}


def classify(groups, vectors, song_center, section_center, definitions):
    section_vectors = np.stack([vectors[text] for _, text in groups])
    song = normalize(normalize(section_vectors.mean(0)) - song_center)
    section_scores = normalize(section_vectors - section_center) @ definitions.T
    scores = 0.5 * ((song @ definitions.T) + section_scores.max(0))
    order = np.argsort(-scores, kind="stable")
    tags = [int(index) for index in order[:3] if scores[order[0]] - scores[index] <= 0.06]
    labels = list(DEFINITIONS)
    return {
        "primary_theme": labels[tags[0]],
        "secondary_themes": "; ".join(labels[index] for index in tags[1:]),
        "theme_source": "model",
        "model_primary_cosine": f"{scores[order[0]]:.4f}",
        "model_margin": f"{scores[order[0]] - scores[order[1]]:.4f}",
        "evidence_sections": "; ".join(
            f"{labels[index]}: {groups[int(section_scores[:, index].argmax())][0]}"
            for index in tags
        ),
    }


def score_rows(lyrics, reviews, vectors, sections, stamp, version):
    means = {
        track_id: np.stack([vectors[text] for _, text in groups]).mean(0)
        for track_id, groups in sections.items() if groups
    }
    reference = [mean for track_id, mean in means.items() if lyrics[track_id][0] == "playlist_cache"]
    reference_scope = "playlist_cache" if reference else "current_snapshot"
    reference = np.stack(reference or list(means.values())) if means else None
    if reference is not None:
        song_center = normalize(reference).mean(0)
        section_center = reference.mean(0)
        definitions = normalize(
            np.stack([vectors[text] for text in DEFINITIONS.values()]) - section_center
        )
    for track_id, groups in sections.items():
        text = "\n".join(value for _, value in groups)
        words = len(re.findall(r"\w+", text))
        has_cjk = re.search(r"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]", text)
        row = {
            "track_id": track_id, "theme_source": "unassigned",
            "model": MODEL, "model_version": version, "method": METHOD,
            "reference_scope": reference_scope, "unique_word_count": words,
            "scored_at_utc": stamp,
        }
        if track_id in reviews and lyrics[track_id][0] == "playlist_cache":
            primary, secondary = reviews[track_id]
            row.update(primary_theme=primary, secondary_themes=secondary, theme_source="close_reading")
        elif groups and len(text) >= 140 and (words >= 20 or has_cjk):
            row.update(classify(groups, vectors, song_center, section_center, definitions))
        yield row


def write_scores(path, rows):
    with NamedTemporaryFile(
        mode="w", encoding="utf-8", newline="", dir=path.parent, delete=False
    ) as stream:
        temp = Path(stream.name)
        writer = csv.DictWriter(stream, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(rows)
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=Path("data/lyrics/lyrics.sqlite3"))
    parser.add_argument("--reviews", type=Path, default=Path("data/playlist/lyric_semantic_analysis.csv"))
    parser.add_argument("--model-dir", type=Path, default=Path("data/models/minilm"))
    parser.add_argument("--output-dir", type=Path, default=Path("data/emotion"))
    parser.add_argument("--threads", type=int, default=6)
    args = parser.parse_args()
    if args.threads < 1:
        parser.error("--threads must be positive")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    stamp, lyrics = lyrics_snapshot(args.db)
    print(f"Read a snapshot of {len(lyrics):,} tracks with plain lyrics at {stamp}.", flush=True)
    reviews = close_readings(args.reviews)
    version = model_version(args.model_dir)
    sections = {track_id: lyric_sections(text) for track_id, (_, text) in lyrics.items()}
    texts = dict.fromkeys(DEFINITIONS.values())
    texts.update(
        (text, None) for groups in sections.values() for _, text in groups
    )
    vectors = embed_sections(
        texts, args.model_dir, args.output_dir / "section_embeddings.sqlite3", version, args.threads
    )
    rows = list(score_rows(lyrics, reviews, vectors, sections, stamp, version))
    output = args.output_dir / "track_themes.csv"
    write_scores(output, rows)
    counts = Counter(row["theme_source"] for row in rows)
    print(
        f"Wrote {len(rows):,} tracks to {output}. "
        f"{counts['close_reading']:,} close readings, {counts['model']:,} model suggestions, "
        f"{counts['unassigned']:,} unassigned.",
        flush=True,
    )


if __name__ == "__main__":
    main()
