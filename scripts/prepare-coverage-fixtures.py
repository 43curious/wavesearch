#!/usr/bin/env python3
"""Build opt-in coverage stress cases from an already installed ESC-50 subset."""

import argparse
from array import array
import hashlib
import json
from pathlib import Path
import shutil
import sys
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="installed .relevance/esc50 directory")
    parser.add_argument("destination", type=Path, help="new output directory (never replaced)")
    parser.add_argument("--folds", nargs="+", type=int, default=[1, 2, 3, 4, 5])
    args = parser.parse_args()
    if len(set(args.folds)) != len(args.folds) or any(f not in range(1, 6) for f in args.folds):
        parser.error("folds must be unique values from 1 through 5")
    if not any(f <= 2 for f in args.folds) or not any(f >= 3 for f in args.folds):
        parser.error("include tuning (1/2) and held-out (3/4/5) folds")
    sources = {}
    for line in (args.source / "manifest.tsv").read_text().splitlines():
        if line.startswith("#") or not line:
            continue
        name, original, category, fold, digest = line.split("\t")
        if category not in ("dog", "rain") or int(fold) not in args.folds:
            continue
        path = args.source / "audio" / name
        if path.name != name or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f"fixture identity mismatch: {name}")
        with wave.open(str(path), "rb") as reader:
            if reader.getnchannels() != 1 or reader.getsampwidth() != 2 or reader.getcomptype() != "NONE":
                raise ValueError("expected mono PCM16 ESC-50")
            rate = reader.getframerate()
            samples = array("h", reader.readframes(reader.getnframes()))
            if sys.byteorder != "little":
                samples.byteswap()
            if len(samples) != rate * 5:
                raise ValueError("expected five-second ESC-50 clips")
        sources[int(fold), category] = (samples, rate, original, digest)
    for fold in args.folds:
        if (fold, "dog") not in sources or (fold, "rain") not in sources:
            raise ValueError(f"missing installed sources for fold {fold}")
        if sources[fold, "dog"][1] != sources[fold, "rain"][1]:
            raise ValueError("incompatible source sample rates")
    args.destination.mkdir(parents=True, exist_ok=False)
    audio = args.destination / "audio"
    audio.mkdir()
    shutil.copyfile(args.source / "LICENSE", args.destination / "LICENSE")
    files, provenance, annotations = [], [], {}
    for fold in args.folds:
        dog, rate, original, dog_sha = sources[fold, "dog"]
        rain, _, rain_original, rain_sha = sources[fold, "rain"]
        background = array("h", (round(value * 0.10) for value in rain))
        for seconds, gain in ((5, 1), (60, 1), (180, 1), (300, 1), (300, 0.6)):
            name = f"asset-{len(files):03d}"
            # The event at 30 seconds falls between all five baseline windows
            # for 180/300-second recordings; 60 seconds is a covered control.
            event_start = 0 if seconds == 5 else 30
            samples = array("h", dog) if seconds == 5 else background * (seconds // 5)
            if seconds != 5:
                offset = event_start * rate
                for index, value in enumerate(dog):
                    samples[offset + index] = max(-32768, min(32767, round(value * 0.8) + samples[offset + index]))
            if gain != 1:
                # This deliberately creates a near duplicate within one split.
                samples = array("h", (round(value * gain) for value in samples))
            if sys.byteorder != "little":
                samples.byteswap()
            path = audio / f"{name}.wav"
            with wave.open(str(path), "wb") as writer:
                writer.setnchannels(1)
                writer.setsampwidth(2)
                writer.setframerate(rate)
                writer.writeframes(samples.tobytes())
            split = "tuning" if fold <= 2 else "held_out"
            files.append(dict(id=name, path=f"audio/{name}.wav", group=f"esc50-fold-{fold}", split=split))
            annotations[name] = (seconds, event_start)
            provenance.append(dict(id=name, fold=fold, dog=original, dog_sha256=dog_sha,
                                   rain=rain_original if seconds != 5 else None,
                                   rain_sha256=rain_sha if seconds != 5 else None,
                                   gain=gain, sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    queries = []
    for split in ("tuning", "held_out"):
        for kind, text in (("dog", "a dog barking"), ("synonym", "canine barks"),
                           ("spanish", "un perro ladrando"), ("rain", "steady rain falling"),
                           ("negative", "a helicopter rotor")):
            judgments = []
            for file in files:
                if file["split"] != split:
                    continue
                seconds, start = annotations[file["id"]]
                if kind in ("dog", "synonym", "spanish"):
                    grade = 3 if seconds == 5 else 2
                else:
                    grade = 3 if kind == "rain" and seconds > 5 else 0
                judgment = dict(file_id=file["id"], grade=grade)
                if kind in ("dog", "synonym", "spanish"):
                    judgment["interval"] = dict(start_ms=start * 1000, end_ms=(start + 5) * 1000)
                judgments.append(judgment)
            queries.append(dict(id=f"{split}-{kind}", text=text, split=split, judgments=judgments))
    (args.destination / "corpus.json").write_text(json.dumps(dict(files=files, queries=queries), indent=2) + "\n")
    (args.destination / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Prepared {len(files)} controlled recordings; generated judgments are provisional, not professional-library acceptance.")
    print(f"Corpus: {args.destination / 'corpus.json'}")


if __name__ == "__main__":
    main()
