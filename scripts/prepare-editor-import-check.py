#!/usr/bin/env python3
"""Prepare disposable media and an unverified native-editor acceptance matrix."""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import uuid
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New fixture directory; existing paths are refused")
    args = parser.parse_args()
    root = args.output.expanduser().absolute()
    root.mkdir(parents=True, exist_ok=False)
    sources = root / "Sources café 東京"
    sources.mkdir()
    prefix = "WaveSearchInterop-" + uuid.uuid4().hex[:8]
    # Four bursts make a 1.0–2.5 s selection visibly/audibly distinct from the
    # complete 4 s file. Right channel differs so accidental downmix is evident.
    pcm = bytearray()
    for frame in range(192000):
        second = frame / 48000
        active = any(start <= second < start + 0.125 for start in (0.5, 1.25, 2.25, 3.5))
        left = int(8192 * math.sin(2 * math.pi * 750 * second)) if active else 0
        right = int(4096 * math.sin(2 * math.pi * 1500 * second)) if active else 0
        pcm.extend(struct.pack("<hh", left, right))
    wav = sources / f"{prefix} space café 東京.wav"
    with wave.open(str(wav), "wb") as output:
        output.setparams((2, 2, 48000, 192000, "NONE", "not compressed"))
        output.writeframes(pcm)
    aiff = sources / f"{prefix} space café 東京.aiff"
    big_endian = bytearray(pcm)
    big_endian[0::2], big_endian[1::2] = pcm[1::2], pcm[0::2]
    common = struct.pack(">hIhHQ", 2, 192000, 16, 0x400E, 48000 << 48)
    chunks = b"COMM" + struct.pack(">I", len(common)) + common
    chunks += b"SSND" + struct.pack(">III", len(big_endian) + 8, 0, 0) + big_endian
    aiff.write_bytes(b"FORM" + struct.pack(">I", len(chunks) + 4) + b"AIFF" + chunks)
    media = [wav, aiff]
    compressed = {"status": "unavailable", "reason": "afconvert is not installed"}
    converter = shutil.which("afconvert")
    if converter:
        alac = sources / f"{prefix} space café 東京.m4a"
        try:
            result = subprocess.run([converter, "-f", "m4af", "-d", "alac", str(wav), str(alac)],
                                    capture_output=True, text=True, timeout=20)
            if result.returncode == 0 and alac.is_file() and alac.stat().st_size:
                media.append(alac)
                compressed = {"status": "generated", "path": str(alac.relative_to(root))}
            else:
                compressed["reason"] = result.stderr.strip()[:1000] or f"afconvert returned {result.returncode}"
                alac.unlink(missing_ok=True)
        except subprocess.TimeoutExpired:
            compressed["reason"] = "afconvert timed out after 20 seconds"
            alac.unlink(missing_ok=True)
    editors = {
        "Pro Tools": ["Pro Tools.app"],
        "Logic Pro": ["Logic Pro.app", "Logic Pro Creator Studio.app"],
        "REAPER": ["REAPER.app"],
        "DaVinci Resolve": ["DaVinci Resolve/DaVinci Resolve.app"],
        "Premiere Pro": ["Adobe Premiere Pro 2026/Adobe Premiere Pro 2026.app", "Adobe Premiere Pro 2025/Adobe Premiere Pro 2025.app"],
    }
    inventory = {}
    for editor, candidates in editors.items():
        inventory[editor] = {"availability": "not found in standard application locations", "version": None}
        for base in (Path("/Applications"), Path.home() / "Applications"):
            for candidate in candidates:
                plist = base / candidate / "Contents/Info.plist"
                if plist.is_file():
                    with plist.open("rb") as source:
                        info = plistlib.load(source)
                    inventory[editor] = {"availability": "installed; timeline import unverified", "path": str(plist.parent.parent),
                                         "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion")}
    cases = []
    for editor in editors:
        for path in media:
            for behavior in ("keepInPlace", "copyToExports"):
                for scope in ("wholeFile", "selectedRange"):
                    for storage in ("internal", "external"):
                        trimmed = behavior == "copyToExports" and scope == "selectedRange"
                        cases.append({"id": len(cases) + 1, "editor": editor, "source": str(path.relative_to(root)),
                                      "source_storage": storage, "import_behavior": behavior, "scope": scope,
                                      "range_seconds": [1, 2.5] if scope == "selectedRange" else [0, 4],
                                      "expected": {"timeline_seconds": 1.5 if trimmed else 4,
                                                   "media_frames": 72000 if trimmed else 192000,
                                                   "sample_rate": 48000, "channels": 2,
                                                   "payload": "persistent PCM24 WAV" if trimmed else "original URL" if behavior == "keepInPlace" else "persistent unchanged copy"},
                                      "status": "unverified", "observed": {"editor_version": None, "media_copy_setting": None,
                                      "project_media_path": None, "timeline_seconds": None, "channels": None,
                                      "usable_after_wavesearch_quits": None, "source_unchanged": None, "notes": ""}})
    report = {"schema_version": 1, "prepared_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "fixture": prefix, "acceptance": "unverified; generated fixtures do not establish native import", "editors": inventory,
              "compressed_fixture": compressed,
              "sources": [{"path": str(path.relative_to(root)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in media],
              "cases": cases}
    (root / "acceptance.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    (root / "README.txt").write_text(
        "Disposable synthetic editor-import fixtures, not a real sound-library acceptance.\n"
        "Use documentation/EDITOR_IMPORT_ACCEPTANCE.md in the WaveSearch checkout.\n"
        "Index Sources in a disposable catalog. Whole files: 4 s, 48 kHz, stereo.\n"
        "Set In=1 s, Out=2.5 s. Only Copy files to Exports trims this to 1.5 s PCM24.\n"
        "Keep in place supplies the full 4 s original even with marks.\n"
        "Record actual timeline imports/settings in acceptance.json; every case starts unverified.\n"
        "For external cases copy Sources yourself to a disposable external-drive folder; record its path.\n"
        "Delete only these owned fixtures/projects/exports after finishing.\n")
    print(f"Prepared {len(media)} sources and {len(cases)} unverified cases in {root}")
    print(f"Compressed fixture: {compressed['status']}")


if __name__ == "__main__":
    main()
