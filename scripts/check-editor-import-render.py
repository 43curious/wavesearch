#!/usr/bin/env python3
"""Check a native editor render against the synthetic import fixture samples."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--render", type=Path, required=True)
    args = parser.parse_args()
    if sys.version_info < (3, 12):
        parser.error("Python 3.12+ is required for WAVE_FORMAT_EXTENSIBLE renders")
    root = args.fixture.resolve()
    cases = json.loads((root / "payloads.json").read_text(encoding="utf-8"))
    if len(cases) not in (8, 12):
        raise ValueError("Expected WAV/AIFF and optional ALAC import cases")
    source = next(Path(case["source"]) for case in cases if Path(case["source"]).suffix == ".wav")
    with wave.open(str(source), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getnframes()) != (2, 2, 48000, 192000):
            raise ValueError("Expected the four-second stereo PCM16 fixture")
        pcm16 = audio.readframes(192000)
    # Exact PCM16 → PCM24 scaling; left/right bursts differ in the fixture.
    pcm24 = b"".join((int.from_bytes(pcm16[i:i + 2], "little", signed=True) * 256).to_bytes(3, "little", signed=True)
                     for i in range(0, len(pcm16), 2))
    total_frames = sum(case["facts"]["frames"] for case in cases)
    checked = []
    with wave.open(str(args.render), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getnframes()) != (2, 3, 48000, total_frames):
            raise ValueError("Render must contain every case, in order, as stereo PCM24 at 48 kHz")
        for case in cases:
            trimmed = case["behavior"] == "copyToExports" and case["scope"] == "selectedRange"
            frames = 72000 if trimmed else 192000
            start = 48000 if trimmed else 0
            if case["facts"]["frames"] != frames or audio.readframes(frames) != pcm24[start * 6:(start + frames) * 6]:
                raise ValueError(f"Rendered samples differ in case {case['id']}")
            for path, expected in ((case["source"], case["sourceSHA256"]), (case["path"], case["facts"]["sha256"])):
                if hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected:
                    raise ValueError(f"Source or supplied payload changed in case {case['id']}")
            checked.append({"id": case["id"], "frames": frames, "max_error_lsb24": 0})
    report = {"sample_rate": 48000, "channels": 2, "frames": total_frames,
              "seconds": total_frames / 48000, "source_and_payload_checksums_verified": True,
              "render_sha256": hashlib.sha256(args.render.read_bytes()).hexdigest(), "cases": checked}
    (root / "render-analysis.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {len(checked)} native rendered cases; exact source/range samples in both channels, unchanged sources and payloads")


if __name__ == "__main__":
    main()
