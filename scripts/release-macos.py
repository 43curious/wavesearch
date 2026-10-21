#!/usr/bin/env python3
"""Build a chosen clean commit into a signed/notarized universal DMG. Never publish."""
import argparse
from dataclasses import dataclass
from datetime import date, datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
ARCHITECTURES = {"arm64", "x86_64"}
ENTITLEMENTS = ROOT / "macos/WaveSearch/WaveSearch/WaveSearch.Release.entitlements"
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


class ReleaseError(Exception):
    pass


@dataclass(frozen=True)
class ReleaseConfig:
    version: str
    build: str
    release_date: str
    commit: str
    identity: str = ""
    team: str = ""
    profile: str = ""
    keychain: str = ""
    headless: bool = False

    def validate(self, signing=True):
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", self.version):
            raise ReleaseError("Version must be an explicit MAJOR.MINOR.PATCH value chosen by Jon")
        if not re.fullmatch(r"[1-9][0-9]{0,3}", self.build):
            raise ReleaseError("Build must be a positive integer of at most four digits")
        try:
            if date.fromisoformat(self.release_date).isoformat() != self.release_date:
                raise ValueError()
        except ValueError as error:
            raise ReleaseError("Release date must be YYYY-MM-DD") from error
        if not re.fullmatch(r"[a-f0-9]{40}", self.commit):
            raise ReleaseError("Commit must be the complete lowercase 40-character SHA")
        if signing and (not self.identity or not self.profile or not re.fullmatch(r"[A-Z0-9]{10}", self.team)):
            raise ReleaseError("Signing requires --identity, --team-id and an existing --notary-profile")

    def notary_auth(self):
        return ["--keychain-profile", self.profile] + (["--keychain", self.keychain] if self.keychain else [])


class Commands:
    def __init__(self, diagnostics):
        self.diagnostics = diagnostics

    def run(self, args, name, *, check=True, timeout=3600):
        # Only credential *references* reach this process; private keys/passwords
        # remain in the operator's Keychain. Do not echo command arguments.
        print(name, flush=True)
        result = subprocess.run([str(arg) for arg in args], cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        (self.diagnostics / f"{name}.log").write_text(result.stdout + result.stderr)
        if check and result.returncode:
            raise ReleaseError(f"{name} failed; inspect {self.diagnostics / (name + '.log')}")
        return result


def validate_source(config):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()

    if git("rev-parse", "HEAD") != config.commit:
        raise ReleaseError("HEAD must match the explicitly chosen release commit")
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ReleaseError("Release builds require a clean checkout, including untracked files")
    if not (ROOT / "core/vendor/sqlite3.c").is_file() or not (ROOT / "core/vendor/sqlite3.h").is_file():
        raise ReleaseError("Restore vendored SQLite from the release checkout before building")


def notarize(artifact, label, config, commands):
    result = commands.run(["xcrun", "notarytool", "submit", artifact, *config.notary_auth(),
                           "--wait", "--timeout", "30m", "--output-format", "json"],
                          f"notary-{label}", check=False, timeout=2100)
    try:
        submission = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ReleaseError(f"Notarization returned no valid {label} result; diagnostics retained") from error
    request_id = submission.get("id", "")
    try:
        uuid.UUID(request_id)
    except (ValueError, TypeError, AttributeError) as error:
        raise ReleaseError(f"Notarization returned no valid {label} submission ID") from error
    commands.run(["xcrun", "notarytool", "log", request_id, *config.notary_auth()],
                 f"notary-{label}-details", check=False, timeout=120)
    if result.returncode or submission.get("status") != "Accepted":
        raise ReleaseError(f"{label} notarization was not Accepted; submission {request_id}, diagnostics retained")
    return request_id


def sign_code(path, config, commands, label, entitlements=None, *, runtime=True):
    args = ["codesign", "--force", "--timestamp", "--sign", config.identity]
    if runtime:
        args += ["--options", "runtime"]
    if config.keychain:
        args += ["--keychain", config.keychain]
    if entitlements:
        args += ["--entitlements", entitlements]
    commands.run([*args, path], f"sign-{label}")


def verify_code(path, config, commands, label, *, app=False):
    commands.run(["codesign", "--verify", "--strict", "--verbose=2", *(["--deep"] if app else []), path],
                 f"verify-{label}")
    details = commands.run(["codesign", "-d", "--verbose=4", path], f"signature-{label}")
    metadata = details.stdout + details.stderr
    if "Authority=Developer ID Application:" not in metadata or f"TeamIdentifier={config.team}\n" not in metadata:
        raise ReleaseError(f"{label} is not signed with the intended Developer ID team")
    if app and not re.search(r"flags=.*\bruntime\b", metadata):
        raise ReleaseError("The app signature does not enable Hardened Runtime")
    if app:
        result = commands.run(["codesign", "-d", "--entitlements", "-", "--xml", path], "entitlements")
        try:
            actual = plistlib.loads(result.stdout.encode())
        except plistlib.InvalidFileException as error:
            raise ReleaseError("The app has no readable signed entitlements") from error
        expected = plistlib.loads(ENTITLEMENTS.read_bytes())
        if actual != expected:
            raise ReleaseError("Signed app entitlements differ from the reviewed release policy")


def verify_architectures(path, commands, label):
    architectures = set(commands.run(["lipo", "-archs", path], f"architectures-{label}").stdout.split())
    if architectures != ARCHITECTURES:
        raise ReleaseError(f"{label} must contain exactly arm64 and x86_64")


def sign_app(app, config, commands):
    main = app / "Contents/MacOS/WaveSearch"
    verify_architectures(main, commands, "app")
    embedded = []
    frameworks = set()
    for path in app.rglob("*"):
        if path.suffix.lower() in {".a", ".h", ".zig", ".xcframework", ".onnx", ".ort", ".sqlite", ".db", ".p12", ".p8", ".keychain-db"} or "onnxruntime" in path.name.lower():
            raise ReleaseError("App contains development, catalog, credential or optional-model/runtime artifacts")
        if path.is_symlink():
            # Framework internal links are allowed; bundled code cannot escape.
            if not path.resolve().is_relative_to(app.resolve()):
                raise ReleaseError("App bundle contains a link outside the bundle")
            continue
        if not path.is_file() or path == main:
            continue
        with path.open("rb") as source:
            is_code = source.read(4) in MACHO_MAGICS
        if not is_code:
            continue
        if not path.is_relative_to(app / "Contents/Frameworks"):
            raise ReleaseError("Embedded executable needs an explicit signing policy outside Frameworks")
        embedded.append(path)
        frameworks.update(parent for parent in path.parents if parent.suffix == ".framework")
    for index, path in enumerate(sorted(embedded, key=lambda p: len(p.parts), reverse=True)):
        verify_architectures(path, commands, f"embedded-{index}")
        sign_code(path, config, commands, f"embedded-{index}")
        verify_code(path, config, commands, f"embedded-{index}")
    for index, path in enumerate(sorted(frameworks, key=lambda p: len(p.parts), reverse=True)):
        sign_code(path, config, commands, f"framework-{index}")
        verify_code(path, config, commands, f"framework-{index}")
    sign_code(app, config, commands, "app", ENTITLEMENTS)
    verify_code(app, config, commands, "app", app=True)


def distribute(app, work, output, config, commands):
    """The acceptance barriers are shared by production and the failure-path checks."""
    sign_app(app, config, commands)
    archive = work / "WaveSearch.zip"
    commands.run(["ditto", "-c", "-k", "--keepParent", app, archive], "archive-app")
    app_submission = notarize(archive, "app", config, commands)
    commands.run(["xcrun", "stapler", "staple", app], "staple-app")
    commands.run(["xcrun", "stapler", "validate", app], "validate-app-ticket")
    commands.run(["spctl", "--assess", "--type", "execute", "--verbose=2", app], "gatekeeper-app")

    staging = work / "image"
    staging.mkdir()
    commands.run(["ditto", app, staging / "WaveSearch.app"], "stage-app")
    (staging / "Applications").symlink_to("/Applications")
    (staging / "INSTALL.txt").write_text(
        "WaveSearch · macOS 14 or later\n\n"
        "Drag WaveSearch.app to Applications, then open it and add a sound library.\n"
        "Installation and lexical search work offline. Optional semantic models/runtime\n"
        "are downloaded only when you explicitly choose them in Settings.\n\n"
        "Arrastra WaveSearch.app a Aplicaciones, ábrelo y añade una biblioteca de sonidos.\n"
        "La instalación y la búsqueda léxica funcionan sin conexión. Los modelos y el\n"
        "runtime opcionales solo se descargan cuando los eliges en Ajustes.\n")
    dmg = work / f"WaveSearch-{config.version}-{config.build}-universal.dmg"
    commands.run(["hdiutil", "create", "-volname", f"WaveSearch {config.version}", "-srcfolder", staging,
                  "-fs", "HFS+", "-format", "UDZO", dmg], "create-dmg")
    sign_code(dmg, config, commands, "dmg", runtime=False)
    verify_code(dmg, config, commands, "dmg")
    dmg_submission = notarize(dmg, "dmg", config, commands)
    commands.run(["xcrun", "stapler", "staple", dmg], "staple-dmg")
    commands.run(["xcrun", "stapler", "validate", dmg], "validate-dmg-ticket")
    commands.run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
                  "--verbose=2", dmg], "gatekeeper-dmg")
    commands.run(["hdiutil", "verify", dmg], "verify-dmg-image")
    digest = hashlib.sha256()
    with dmg.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    checksum = digest.hexdigest()
    dmg = dmg.rename(output / dmg.name)
    (output / "SHA256SUMS").write_text(f"{checksum}  {dmg.name}\n")
    return {"file": dmg.name, "sha256": checksum, "size_bytes": dmg.stat().st_size,
            "notarization": {"app": app_submission, "dmg": dmg_submission, "status": "Accepted"},
            "signatures": "verified Developer ID", "tickets": "app and DMG stapled and validated",
            "gatekeeper": "app execute and DMG open accepted"}


def build_release(config, output):
    config.validate()
    if sys.platform != "darwin":
        raise ReleaseError("A release build requires macOS; --plan is portable")
    validate_source(config)
    if output.exists():
        raise ReleaseError("Output already exists; choose a new directory")
    output.mkdir(parents=True)
    diagnostics = output / "diagnostics"
    diagnostics.mkdir(mode=0o700)
    commands = Commands(diagnostics)
    zig = os.environ.get("ZIG", "zig")
    zig_version = commands.run([zig, "version"], "zig-version").stdout.strip()
    if zig_version != (ROOT / ".zig-version").read_text().strip():
        raise ReleaseError("Use this checkout's pinned Zig toolchain")
    xcode = commands.run(["xcodebuild", "-version"], "xcode-version").stdout.strip()
    swift = commands.run(["swiftc", "--version"], "swift-version").stdout.strip()
    host = commands.run(["sw_vers", "-productVersion"], "macos-version").stdout.strip()
    check_args = ["make", "check-core", "check-macos-headless"] if config.headless else ["make", "check"]
    checks = commands.run(check_args, "source-checks")
    skips = [line for line in (checks.stdout + checks.stderr).splitlines() if line.startswith("SKIP:")]
    with tempfile.TemporaryDirectory(prefix=".work-", dir=output) as directory:
        work = Path(directory)
        derived = work / "DerivedData"
        commands.run(["xcodebuild", "-quiet", "-project", ROOT / "macos/WaveSearch/wavesearch.xcodeproj",
                      "-scheme", "WaveSearch", "-configuration", "Release", "-sdk", "macosx",
                      "-destination", "generic/platform=macOS", "-derivedDataPath", derived,
                      "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "MACOSX_DEPLOYMENT_TARGET=14.0",
                      "SWIFT_OPTIMIZATION_LEVEL=-O", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                      "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", f"MARKETING_VERSION={config.version}",
                      f"CURRENT_PROJECT_VERSION={config.build}", "WS_SKIP_CORE_BUILD=1", "build"], "build-release")
        app = derived / "Build/Products/Release/WaveSearch.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"), info.get("LSMinimumSystemVersion")) != (config.version, config.build, "14.0"):
            raise ReleaseError("Built version/build/deployment metadata differ from the requested release")
        for language in ("en", "es"):
            for table in ("Localizable.strings", "Localizable.stringsdict"):
                if not (app / "Contents/Resources" / f"{language}.lproj" / table).is_file():
                    raise ReleaseError("Built app is missing native localization resources")
        distribution = distribute(app, work, output, config, commands)
    manifest = {"version": config.version, "build": config.build, "release_date": config.release_date,
                "commit": config.commit, "built_at_utc": datetime.now(timezone.utc).isoformat(),
                "architectures": sorted(ARCHITECTURES), "minimum_macos": "14.0", "team_id": config.team,
                "toolchain": {"zig": zig_version, "core_optimization": "safe", "swift_optimization": "-O",
                              "xcode": xcode, "swift": swift, "host_macos": host},
                "source_checks": {"command": check_args, "status": "passed", "skips": skips},
                "manual_acceptance": {"desktop_checks": "pending" if config.headless else "passed source checks",
                                      "browser_quarantine_install": "pending", "signed_app_library_playback_import": "pending",
                                      "optional_real_model_runtime": "not run"},
                "distribution": distribution}
    (output / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Verified artifacts: {output}. No tag or GitHub release was created.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--release-date", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--identity", default="")
    parser.add_argument("--team-id", default="")
    parser.add_argument("--notary-profile", default="")
    parser.add_argument("--keychain", default="")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--headless-checks", action="store_true", help="Use CI source checks; desktop acceptance remains pending")
    parser.add_argument("--plan", action="store_true", help="Print the chosen build plan without credentials or filesystem writes")
    args = parser.parse_args()
    config = ReleaseConfig(args.version, args.build, args.release_date, args.commit, args.identity,
                           args.team_id, args.notary_profile, args.keychain, args.headless_checks)
    try:
        config.validate(signing=not args.plan)
        if args.plan:
            print(json.dumps({"version": config.version, "build": config.build, "release_date": config.release_date,
                              "commit": config.commit, "architectures": sorted(ARCHITECTURES), "minimum_macos": "14.0",
                              "core_optimization": "safe", "swift_optimization": "-O",
                              "create_github_release": False, "create_tag": False,
                              "steps": ["clean source and checks", "universal Release build", "Developer ID + Hardened Runtime",
                                        "app notarization/stapling/Gatekeeper", "DMG packaging/signing",
                                        "DMG notarization/stapling/Gatekeeper", "final checksum and manifest"]}, indent=2))
        else:
            output = args.output or ROOT / "dist" / f"WaveSearch-{config.version}-{config.build}"
            build_release(config, output.resolve())
    except (ReleaseError, OSError, subprocess.SubprocessError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
