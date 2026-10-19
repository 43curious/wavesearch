# Continuous integration

[Checks](../.github/workflows/check.yml) runs on pushes, pull requests and manual
dispatch. It uses a read-only repository token, disables persisted checkout
credentials, and cancels superseded runs for the same branch or pull request.
The checkout action is pinned to a commit.

## Jobs

| Runner | Checks |
| --- | --- |
| `ubuntu-24.04` (x86_64) | `make check-core`: formatting, shell syntax, native Zig tests, compiled legacy/current C ABI contract, optional-harness compilation and native static library build. |
| `macos-26` | The same native core checks, then `make check-macos-headless`: universal core XCFramework, Debug Swift app build, refinement-policy, deterministic library-watching and app lifecycle checks. Swift checks link the native library rebuilt by `check-core` using `WS_CORE_LIBRARY`/`WS_CORE_HEADERS`. |

Linux tests execute on Linux; `make check-linux` separately cross-compiles the
library, Zig tests, audio-fuzz executable, C ABI executable and coverage harness
without running them. The macOS job selects Xcode 26.6 through
`DEVELOPER_DIR`, fails if it is unavailable, and logs Xcode/Swift versions. The
app uses ad-hoc signing and needs no signing certificate or Apple credentials.

Window chrome and Settings appearance checks are explicitly skipped in hosted
CI and listed in the job summary. They need a logged-in desktop with reliable
focus; a successful headless job does not validate those interactions. Run
`make check` locally to include them. It still runs the full core, app, policy,
lifecycle, watcher, window and Settings sequence on macOS. The watcher check
injects event bursts and uses disposable real files/catalogs; native FSEvents
delivery requires the separate opt-in `bash scripts/test-library-watching.sh --native`
probe on a working Mac. Hosted success does not establish external-drive,
cold-storage or foreground-latency acceptance.

## Toolchain and inputs

Each job reads the exact release from [`.zig-version`](../.zig-version), looks up
its platform archive in the [official Zig release index](https://ziglang.org/download/index.json),
verifies SHA-256 before extraction and checks the executable's version. Updating
the pin requires an available official release with the repository's build API.
The runner provides Bash, make, curl, Python 3, shasum and tar with xz support;
macOS additionally needs the selected Xcode, Swift, lipo and ranlib. Runner Xcode
availability is documented in the [official image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

Jobs start fresh and share no caches, generated frameworks, DerivedData or
catalogs. Vendored SQLite and ONNX headers come from checkout. Normal checks
never invoke optional model/runtime installers or real-audio fixture downloads;
model-dependent acceptance tests remain opt-in. Fixture catalogs and test audio
are disposable. No release artifacts are signed for distribution or published.

Core tests also run a deterministic, model-free audio mutation campaign over
WAV/AIFF preprocessing, duration and metadata readers, and query parsing. Inputs
are capped at 8 KiB, parser allocation uses a 4 MiB buffer, and the default
campaign checks its 30-second budget between cases. The current input is saved
before execution to `core/zig-out/audio-fuzz-current.bin` for crash replay.
Generated seeds include truncations, hostile chunk sizes, PCM/Float formats,
and metadata; duration-filter properties also run in the unit tests.

From `core/`, run a longer campaign or replay a saved input:

```bash
zig build audio-fuzz -- run 10000 0x5753 zig-out/audio-fuzz-current.bin 120
zig build audio-fuzz -- replay zig-out/audio-fuzz-current.bin
```

The run arguments are mutation count, seed, artifact path, and time budget in
seconds. Copy a failing artifact before starting another campaign, which
overwrites it. These bounded checks do not establish exhaustive parser safety.

## Local reproduction

```bash
make check-core                 # Execute portable checks on this host
make check-linux                # Compile Linux library + check executables only
make check-macos-headless       # macOS app + policy/watcher/lifecycle, rebuilt XCFramework
make check                      # Full local check, including desktop interaction
```

To reproduce CI's explicit native-library linkage, run `make check-core` first,
then set `WS_CORE_LIBRARY` to the absolute `core/zig-out/lib/libwavesearch.a`
path and `WS_CORE_HEADERS` to the absolute `core/include` path when running the
headless target. The default scripts instead link the freshly built universal
XCFramework. A hosted run can only validate committed work once it has been
pushed; local checks and workflow linting do not prove a hosted job succeeded.

The watcher script also accepts these native library/header overrides. Avoid
rebuilding the XCFramework concurrently with Swift compilation/linking against it.

Peak-RSS reporting uses Zig's libc `rusage` binding. Translated glibc headers
can place `ru_maxrss` inside an anonymous union, so directly accessing that
field in the generated C import is not portable. The helper still reports
bytes, converting Linux's KiB value and preserving macOS's byte value.
