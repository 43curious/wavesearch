#!/usr/bin/env python3
"""Exercise the distribution barriers with disposable files and injected Apple tools."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("release_macos", Path(__file__).with_name("release-macos.py"))
release = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = release
spec.loader.exec_module(release)


class NativeTools:
    def __init__(self, *, rejected=None, team="ABCDEFGHIJ", architectures="arm64 x86_64"):
        self.calls = []
        self.rejected = rejected
        self.team = team
        self.architectures = architectures

    def run(self, args, name, **options):
        args = [str(arg) for arg in args]
        self.calls.append(name)
        stdout, stderr = "", ""
        if name.startswith("architectures-"):
            stdout = self.architectures
        elif name.startswith("signature-"):
            stderr = f"Authority=Developer ID Application: Fixture\nTeamIdentifier={self.team}\nflags=0x10000(runtime)\n"
        elif name == "entitlements":
            stdout = release.ENTITLEMENTS.read_text()
        elif name == "archive-app":
            Path(args[-1]).write_bytes(b"fixture archive")
        elif name in ("notary-app", "notary-dmg"):
            assert Path(args[3]).is_file(), "Notarization needs a built artifact"
            label = name.removeprefix("notary-")
            stdout = json.dumps({"id": "00000000-0000-0000-0000-00000000000" + ("1" if label == "app" else "2"),
                                 "status": "Invalid" if self.rejected == label else "Accepted"})
        elif name == "stage-app":
            shutil.copytree(args[1], args[2], symlinks=True)
        elif name == "create-dmg":
            Path(args[-1]).write_bytes(b"fixture disk image")
        elif name == "staple-dmg":
            with Path(args[-1]).open("ab") as output:
                output.write(b" stapled ticket")
        return subprocess.CompletedProcess(args, 0, stdout, stderr)


class DistributionCheck(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wavesearch-release-test-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.work = root / "work"
        self.output = root / "output"
        self.app = root / "WaveSearch.app"
        self.work.mkdir()
        self.output.mkdir()
        executable = self.app / "Contents/MacOS/WaveSearch"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(bytes.fromhex("cffaedfe") + b"fixture")
        (self.app / "Contents/Resources").mkdir()
        # Explicit fixture metadata exercises validation; it assigns no repo version.
        self.config = release.ReleaseConfig("1.2.3", "12", "2026-10-21", "a" * 40,
                                            "fixture identity", "ABCDEFGHIJ", "fixture profile")

    def test_accepted_artifact_checksum_includes_stapled_ticket(self):
        embedded = self.app / "Contents/Frameworks/libFixture.dylib"
        embedded.parent.mkdir()
        embedded.write_bytes(bytes.fromhex("cffaedfe") + b"fixture dependency")
        tools = NativeTools()
        result = release.distribute(self.app, self.work, self.output, self.config, tools)
        artifact = self.output / result["file"]
        self.assertTrue(artifact.read_bytes().endswith(b"stapled ticket"))
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        self.assertEqual(result["sha256"], digest)
        self.assertEqual((self.output / "SHA256SUMS").read_text(), f"{digest}  {artifact.name}\n")
        self.assertEqual(result["notarization"]["status"], "Accepted")
        self.assertEqual((self.work / "image/Applications").readlink(), Path("/Applications"))
        self.assertIn("gatekeeper-app", tools.calls)
        self.assertIn("gatekeeper-dmg", tools.calls)
        self.assertLess(tools.calls.index("sign-embedded-0"), tools.calls.index("sign-app"))

    def test_notary_rejection_cannot_promote_an_artifact(self):
        for label in ("app", "dmg"):
            with self.subTest(rejected=label):
                tools = NativeTools(rejected=label)
                with self.assertRaisesRegex(release.ReleaseError, "notarization was not Accepted"):
                    release.distribute(self.app, self.work, self.output, self.config, tools)
                self.assertFalse(list(self.output.iterdir()))
                self.assertNotIn(f"staple-{label}", tools.calls)
                self.assertIn(f"notary-{label}-details", tools.calls)
                if label == "app":
                    self.assertNotIn("create-dmg", tools.calls)

    def test_wrong_team_or_thin_binary_fails_before_notarization(self):
        for tools in (NativeTools(team="OTHERTEAM1"), NativeTools(architectures="arm64")):
            with self.subTest(team=tools.team, architectures=tools.architectures):
                with self.assertRaises(release.ReleaseError):
                    release.distribute(self.app, self.work, self.output, self.config, tools)
                self.assertNotIn("notary-app", tools.calls)

    def test_catalog_artifacts_are_rejected_before_signing(self):
        (self.app / "Contents/Resources/personal.db").write_bytes(b"fixture catalog")
        tools = NativeTools()
        with self.assertRaisesRegex(release.ReleaseError, "catalog"):
            release.distribute(self.app, self.work, self.output, self.config, tools)
        self.assertNotIn("sign-app", tools.calls)

    def test_explicit_version_and_credentials_are_required(self):
        self.config.validate()
        for field, value in (("version", "0.1_alpha"), ("build", "0"), ("release_date", "2026-02-30"),
                             ("commit", "main"), ("identity", ""), ("team", ""), ("profile", "")):
            with self.subTest(field=field):
                arguments = dict(vars(self.config), **{field: value})
                with self.assertRaises(release.ReleaseError):
                    release.ReleaseConfig(**arguments).validate()


if __name__ == "__main__":
    unittest.main()
