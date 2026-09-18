# Mac App Store submission

This directory contains repository-ready drafts and a local packaging path. It does **not** mean
the app has been submitted or approved. App Store Connect records, legal answers, contracts,
certificates, and final review remain the account holder's responsibility.

## Ready in the repository

- Separate sandboxed app and inherited-helper entitlements.
- Apple privacy manifest declaring no tracking or collected data, the `CA92.1` UserDefaults use,
  and the container/user-selected file-metadata reasons used to age local caches.
- English metadata drafts, review notes, privacy-label draft, age-rating draft, export-compliance
  worksheet, screenshot specification, and third-party notice checklist.
- A Store-only package script that embeds a pinned `whisper-cli`, signs it before the app, and
  creates (but never uploads) a signed installer.
- Source and built-app preflight checks.

## Account-holder and legal decisions still required

- Create/confirm the App Store Connect app and registered explicit App ID.
- Confirm the final product name, SKU, primary category, price/availability, copyright, support
  contact, agreements, banking/tax status, and release method.
- Create a Mac App Distribution certificate, Mac Installer Distribution certificate, and matching
  provisioning profile; keep all credentials out of the repository.
- Confirm every App Privacy, age-rating, and export-compliance answer in App Store Connect.
- Review the exact whisper.cpp license, build flags, model terms, and compiled Swift dependencies,
  and provide required notices. `third-party-notices.md` is a checklist, not legal approval.
- Capture final screenshots from the signed Store build using only invented/demo call data.
- Exercise recording, microphone and Screen & System Audio Recording permissions, file selection,
  model download, transcription, transcript indexing, login item behavior, and Store-update behavior in
  a clean macOS account. Test App Store receipt/sandbox behavior through TestFlight or Apple
  distribution.
- Upload and submit manually with Xcode/Transporter after validation. These scripts never upload.

## Required package inputs

For the smallest dependency surface, download the official `whisper.cpp` v1.9.4 source archive
from `https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.4.tar.gz`, then run:

```sh
scripts/build-app-store-whisper.sh /path/to/v1.9.4.tar.gz
```

The builder accepts only the pinned source SHA-256, disables FFmpeg and non-system dynamic
dependencies, builds a generic arm64 helper, and produces the helper, exact license, build record,
and hashes together. It requires CMake and Xcode command-line tools but performs no network access.
Keep its `whisper-build.txt` and `INPUT-SHA256SUMS` with the release record.

Export these only in the release shell. Every path must point to a locally verified, prebuilt
input; the script never downloads executable code.

```sh
export CALL_RECORDER_APP_STORE_BUNDLE_ID='com.yourcompany.callrecorder'
export CALL_RECORDER_APP_STORE_COPYRIGHT='© 2026 Your Legal Name'
export CALL_RECORDER_APP_STORE_APPLICATION_IDENTITY='3rd Party Mac Developer Application: …'
export CALL_RECORDER_APP_STORE_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: …'
export CALL_RECORDER_APP_STORE_PROVISIONING_PROFILE='/secure/path/CallRecorder.provisionprofile'
export CALL_RECORDER_APP_STORE_WHISPER_CLI='/verified/path/whisper-cli'
export CALL_RECORDER_APP_STORE_WHISPER_CLI_SHA256='64-lowercase-hex-characters'
export CALL_RECORDER_APP_STORE_WHISPER_LICENSE='/verified/whisper.cpp/LICENSE'
export CALL_RECORDER_APP_STORE_WHISPER_LICENSE_SHA256='64-lowercase-hex-characters'
```

The `whisper-cli` input must be an executable arm64 Mach-O file whose SHA-256 matches the pinned
value. The license input must be the exact whisper.cpp license belonging to that build and must
match its pinned hash. Packaging also copies the license from the exact `libsql-swift` checkout
pinned by `Package.resolved`; packaging rejects a revision mismatch or tracked checkout changes and
records that revision/cleanliness proof in the app. Every non-system dynamic dependency must resolve to another file
inside the app. The Store build uses AVFoundation for audio processing and embeds no ffmpeg,
ffprobe, Bun, JavaScript indexer/MCP runtime, or Python diarization helper.

## Local flow

```sh
scripts/app-store-preflight.sh --source
scripts/package-app-store.sh
scripts/app-store-preflight.sh --app "dist/AppStore/Call Recorder.app"
```

The default outputs are `dist/AppStore/Call Recorder.app` and a versioned `.pkg`. Run Apple's
current upload validation in the account-holder environment, then upload the `.pkg` manually.
Archive the exact source revision, dependency lock files, input and signed-byte `SHA256SUMS` files,
whisper.cpp license/build flags, model terms, package hash, and App Store Connect version/build
number for rollback and auditability.

The script keeps the pinned, pre-signing whisper-cli hash and the exact bundled license hashes
under `Contents/Resources/Provenance`. Because code signing changes Mach-O bytes, it separately
creates `SHA256SUMS` beside the signed helper; built-app preflight verifies both manifests. It also
rejects symbolic links, unresolved/non-system dynamic dependencies, expired or mismatched app
profiles, and an installer certificate whose Team ID differs from the app profile.
Development-machine `LC_RPATH` entries are removed before dependency validation and signing; any
unsupported run path that remains is a packaging failure.

## Final release gate

- Source preflight passes; the exact signed app passes built-app preflight.
- Version/build is unique and matches App Store Connect.
- The Store build uses `CRDistributionChannel=app-store`; GitHub self-update is disabled and only
  the pinned whisper-cli helper is embedded.
- No quarantine attributes, download pointers, credentials, user data, development paths, or
  unlicensed artifacts are present.
- AVFoundation recording/finalization, local Whisper transcription, and native transcript indexing
  pass on a clean Store-distributed build. Transcript search, MCP, and speaker
  identification/review are unavailable in this distribution.
- On a Mac mini, connect a Bluetooth headset, choose it as the macOS input, leave Call Recorder's
  microphone on **System**, and record both local speech and system playback. The completed
  transcript must contain both sides and attribute the microphone side to the configured local
  participant. If macOS advertises that input but it produces no writable microphone samples,
  starting must show the microphone recovery error instead of entering the recording state with
  only system audio.
- Privacy policy is publicly reachable and matches the final binary and App Privacy answers.
- Review Notes give Apple a complete, reproducible test path with no private user data.
- A clean-machine functional pass and an Apple/TestFlight-distributed pass are recorded.
