# Signed macOS distribution

The release script builds a chosen clean commit into a universal Developer ID
application and notarized DMG. It does not create a Git tag, edit the changelog's
version/date, or publish a GitHub release. `0.1_alpha` remains the historical
first version. Jon supplies the next version, build number, release date and
commit when he instructs an actual release.

This workflow is implemented for [issue #11](https://github.com/43curious/wavesearch/issues/11).
Actual signed/notarized release acceptance remains pending: no release metadata,
Developer ID credentials or notarization credentials were supplied during
implementation. The current restricted host also aborts during Xcode project
initialization. Tests inject native-tool results and validate orchestration;
they are not evidence that Apple accepted an artifact.

## Local command

Use macOS with Xcode 26.6, the repository's pinned Zig compiler, a clean checkout
at the selected commit, and an unlocked Keychain containing a Developer ID
Application certificate and its private key. The certificate team must match
the explicitly supplied team ID. Store notarization credentials with
`xcrun notarytool store-credentials`; use a named Keychain profile rather than
passing passwords/private keys to the release script. A custom Keychain can be
selected with `--keychain /path/to/release.keychain-db`.

Review the plan without accessing credentials, changing files or building:

```bash
python3 scripts/release-macos.py --plan \
  --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" \
  --release-date "$RELEASE_DATE" --commit "$RELEASE_COMMIT"
```

The version is `MAJOR.MINOR.PATCH`, the build a positive integer up to 9999, the
date `YYYY-MM-DD` and the commit the full lowercase SHA. These are operator
inputs, not inferred defaults. After Jon has chosen them and authorized the
release build, run:

```bash
python3 scripts/release-macos.py \
  --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" \
  --release-date "$RELEASE_DATE" --commit "$RELEASE_COMMIT" \
  --identity "$DEVELOPER_ID_IDENTITY" --team-id "$APPLE_TEAM_ID" \
  --notary-profile WaveSearchRelease
```

The command requires `HEAD` to match, including a clean untracked-file state,
and refuses an existing output directory. It runs `make check`, rebuilds the
universal Release app with Swift `-O`, and uses the core's pinned `safe`
optimization. `--headless-checks` explicitly selects the CI core/app/headless
checks and records desktop acceptance as pending. It does not bypass the Xcode
build. Normal developer builds retain their existing ad-hoc signing behavior.

The deployment target is macOS 14.0 for **arm64 and x86_64**; the resulting
executable and every embedded Mach-O dependency must contain both slices.
The optional pinned ONNX Runtime installer currently supports Apple silicon
only. Intel releases retain lexical/acoustic search and waveform functionality;
universal app support does not imply universal semantic-runtime support.

## Signing, notarization and outputs

The app's core is linked statically. The script signs embedded Frameworks code
inside out, then the app, with Developer ID, timestamping and Hardened Runtime.
It rejects unexpected executable locations, escaping bundle symlinks, catalogs,
model/runtime payloads, credential files and development libraries/headers.
Signing identity/team, architecture slices and the signed entitlements must
match the reviewed release policy before notarization starts.

`WaveSearch.Release.entitlements` retains sandboxing, explicit file grants,
app-scoped bookmarks and network-client access. It adds
`com.apple.security.cs.disable-library-validation` **only to the signed release
app**, because the optional separately downloaded ONNX Runtime cannot be assumed
to carry WaveSearch's signing team. This permits third-party library loading
inside this process. It does not add JIT, unsigned-executable-memory,
DYLD-environment or debugger entitlements. The installer still verifies its
pinned files and stays opt-in; models/runtime are excluded from the DMG.
Actual provider loading in a signed hardened build remains a required acceptance
item, with lexical fallback when unavailable.

The app is zipped and submitted with `notarytool --wait`; both a successful
command and an `Accepted` JSON status are required. Submission IDs and service
logs are retained. The app ticket is stapled/validated and Gatekeeper assesses
execution before packaging. The compressed DMG contains the app, an Applications
shortcut and English/Spanish installation instructions. The DMG is independently
signed, notarized, stapled, validated, Gatekeeper-assessed and image-verified.

Only then is the DMG promoted from the temporary workspace to
`dist/WaveSearch-VERSION-BUILD/`, followed by `SHA256SUMS` and `release.json`.
The checksum covers the final stapled bytes. The manifest records source,
chosen version/date/build, architectures, signing team, toolchains, optimization,
notarization IDs and verification results, source-check skips and pending manual
acceptance. Failures retain diagnostics while temporary app/image work is
removed. A failed submission never produces a promoted DMG or success checksum.
Keep the selected source/toolchain fixed to reproduce the procedure; signatures,
secure timestamps and Apple tickets mean this is not a byte-reproducible build.

## GitHub Actions

[Build and upload signed DMG](../.github/workflows/release.yml) is manual-only.
Run it only for Jon's instructed build/upload, with the selected commit and
release metadata. It uses a read-only repository token, pinned actions and the
same checksum-verified Zig setup as normal CI. It uploads verified DMG/checksum/
manifest files as an Actions artifact, plus separate diagnostics; it never
creates a tag or GitHub release. Artifact retention is finite, so retain an
approved distribution before it expires. Public release upload is a separate
instructed action.

Configure these secrets in the `release` environment:

| Secret | Content |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Base64 PKCS#12 export of the certificate and private key. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password protecting that export. |
| `DEVELOPER_ID_SIGNING_IDENTITY` | Developer ID Application identity name or certificate fingerprint. |
| `APPLE_TEAM_ID` | Matching ten-character team identifier. |
| `APPLE_API_PRIVATE_KEY` | App Store Connect team API private key, including its PEM header/footer. |
| `APPLE_API_KEY_ID` | That API key's identifier. |
| `APPLE_API_ISSUER` | Team API issuer UUID. |

The workflow imports credentials into a dedicated temporary Keychain and stores
a notarization profile there. It removes that Keychain and temporary credential files in an `always()`
step, and keeps credentials out of logs/artifacts. Source checks and packaging
run from the explicitly selected reviewed commit. GUI tests are not available
on hosted runners; the manifest preserves that limitation.

## Acceptance before public distribution

Run `python3 scripts/test-release-workflow.py` for credential-free failure-path
checks. They cover rejection of app/DMG submissions, wrong teams/thin binaries,
unexpected catalog payloads and final-ticket checksum ordering. These tests run
with portable checks; they do not sign or contact Apple.

For the actual release, retain the successful service IDs, signature/team/
entitlement/architecture reports, ticket validation, Gatekeeper results and
final checksum. Verify the selected source with local `make check`, then test
the **signed Release build**. Download the eventual distribution through a
browser onto a clean macOS installation so quarantine remains present, install
through the Applications shortcut and launch under normal Gatekeeper policy.
Do not strip quarantine or bypass assessment to count a pass.

Verify supported architectures, offline installation/launch, library permissions,
indexing/search, playback, range/whole-file editor imports and reopening existing
catalogs. Test optional real-model installation/loading on a supported Apple
silicon machine separately. Record host/OS, source/DMG checksum, results and
remaining gaps; an emitted URL is not a successful DAW import. The project license
decision remains tracked by #25; this workflow assigns none. Versioned
publication and app updates remain separate work.

The implementation follows Apple's
[notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
[notarization troubleshooting](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
and [library-validation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
documentation; the installed Xcode tools' help defines the command flags.
