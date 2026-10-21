#!/usr/bin/env python3
"""Validate native tables against compiler-extracted UI keys and format types."""
import collections
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1] / "macos/WaveSearch/WaveSearch"


def plist(path):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))


def formats(text):
    return collections.Counter(re.findall(r"%(?:\d+\$)?(?:ll|l)?[@diufg]", text.replace("%%", "")))


tables = {language: plist(root / f"{language}.lproj/Localizable.strings") for language in ("en", "es")}
assert tables["en"].keys() == tables["es"].keys(), "Translation tables have different keys"
for key, english in tables["en"].items():
    spanish = tables["es"][key]
    assert spanish or not key, f"Empty Spanish translation: {key}"
    assert formats(english) == formats(spanish), f"Format arguments differ: {key}"

plurals = {language: plist(root / f"{language}.lproj/Localizable.stringsdict") for language in ("en", "es")}
assert plurals["en"].keys() == plurals["es"].keys(), "Plural tables have different keys"
for key, english in plurals["en"].items():
    spanish = plurals["es"][key]
    for form in ("one", "other"):
        assert formats(english["count"][form]) == formats(spanish["count"][form]), key
    assert english["count"]["NSStringFormatValueTypeKey"] == spanish["count"]["NSStringFormatValueTypeKey"] == "lld"

extracted = set()
for source in Path(sys.argv[1]).glob("*.stringsdata"):
    extracted.update(entry["key"] for entry in json.loads(source.read_text())["tables"].get("Localizable", []))
assert extracted, "Compiler did not extract localization keys"
missing = extracted - tables["en"].keys()
assert not missing, f"Untranslated compiler keys: {sorted(missing)}"
print(f"PASS: {len(extracted)} compiler keys, English/Spanish table parity and format arguments")
