#!/usr/bin/env python3
"""Exercise verified CI compiler selection with local archives and no network."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
VERSION = (ROOT / ".zig-version").read_text().strip()


class CIToolchainCheck(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wavesearch-ci-toolchain-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.runner = self.root / "runner"
        self.runner.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env_file = self.root / "environment"
        self.path_file = self.root / "path"
        self.env_file.touch()
        self.path_file.touch()
        self.environment = dict(os.environ, RUNNER_TEMP=str(self.runner),
                                GITHUB_ENV=str(self.env_file), GITHUB_PATH=str(self.path_file),
                                WS_TEST_INPUT=str(self.root), WS_TEST_COMPILER_LOG=str(self.root / "compiler.log"),
                                PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        curl = self.bin / "curl"
        curl.write_text("""#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
root = Path(os.environ['WS_TEST_INPUT'])
if 'https://ziglang.org/download/index.json' in sys.argv:
    source = root / 'index.json'
elif 'https://example.invalid/zig.tar.xz' in sys.argv:
    source = root / 'archive.tar.xz'
else:
    raise SystemExit('Unexpected download')
shutil.copyfile(source, sys.argv[sys.argv.index('-o') + 1])
""")
        curl.chmod(0o755)
        self.archive(VERSION)

    def archive(self, version):
        compiler = ("#!/bin/sh\n"
                    "if [ \"$1\" = version ]; then\n"
                    "  echo '" + version + "'\n"
                    "elif [ \"$1\" = build ] && [ \"$2\" = xcframework ]; then\n"
                    "  mkdir -p WaveSearchKit.xcframework\n"
                    "  echo verified > \"$WS_TEST_COMPILER_LOG\"\n"
                    "else exit 2; fi\n").encode()
        archive = self.root / "archive.tar.xz"
        with tarfile.open(archive, "w:xz") as output:
            entry = tarfile.TarInfo("zig-release/zig")
            entry.mode, entry.size = 0o755, len(compiler)
            output.addfile(entry, io.BytesIO(compiler))
        self.release = {"tarball": "https://example.invalid/zig.tar.xz",
                        "shasum": hashlib.sha256(archive.read_bytes()).hexdigest()}
        self.write_index()

    def write_index(self):
        platforms = {key: self.release for key in ("x86_64-linux", "aarch64-macos", "x86_64-macos")}
        (self.root / "index.json").write_text(json.dumps({VERSION: platforms}))

    def setup(self):
        return subprocess.run(["bash", str(ROOT / "scripts/setup-ci-zig.sh")], env=self.environment,
                              capture_output=True, text=True)

    def test_verified_absolute_compiler_survives_build_path_changes(self):
        result = self.setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        published = dict(line.split("=", 1) for line in self.env_file.read_text().splitlines())
        compiler = self.runner / "wavesearch-zig/zig"
        self.assertEqual(published.get("ZIG"), str(compiler))
        self.assertEqual(self.path_file.read_text().strip(), str(compiler.parent))
        # Run the real build entry point in a disposable project. A wrong Zig
        # on PATH must not replace the executable verified by the setup step.
        shadow = self.bin / "zig"
        shadow.write_text("#!/bin/sh\nexit 99\n")
        shadow.chmod(0o755)
        project = self.root / "project"
        (project / "core/vendor").mkdir(parents=True)
        (project / "core/vendor/sqlite3.c").touch()
        (project / "macos/WaveSearch/WaveSearch").mkdir(parents=True)
        shutil.copyfile(ROOT / "build.sh", project / "build.sh")
        environment = dict(self.environment, **published)
        built = subprocess.run(["bash", str(project / "build.sh")], env=environment,
                               capture_output=True, text=True)
        self.assertEqual(built.returncode, 0, built.stderr)
        self.assertEqual((self.root / "compiler.log").read_text().strip(), "verified")
        self.assertTrue((project / "macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework").is_dir())

    def test_corrupt_archive_does_not_publish_compiler(self):
        self.release["shasum"] = "0" * 64
        self.write_index()
        self.assertNotEqual(self.setup().returncode, 0)
        self.assertEqual(self.env_file.read_text(), "")
        self.assertEqual(self.path_file.read_text(), "")

    def test_wrong_version_does_not_publish_compiler(self):
        self.archive("0.0.0")
        self.assertNotEqual(self.setup().returncode, 0)
        self.assertEqual(self.env_file.read_text(), "")
        self.assertEqual(self.path_file.read_text(), "")


if __name__ == "__main__":
    unittest.main()
