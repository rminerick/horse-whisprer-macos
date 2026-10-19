# Horse Whisprer

Horse Whisprer is a macOS menu bar dictation app that records local audio, transcribes it with Whisper, Parakeet Unified, or Nemotron, and inserts the resulting text into the active app using paste or typed fallback.

Horse Whisprer is free and open source. App code is MIT-licensed, and official signed/notarized downloads include automatic Sparkle updates. No account, email address, activation, or subscription is required to use the app. Third-party dependencies and model weights retain their own licenses.

## Current implementation

- Global trigger for dictation: a shortcut or a single key, press-to-toggle or hold-to-talk, with Escape to cancel
- Local microphone recording to 16 kHz mono WAV
- `whisper-cli` backend plus native Core ML Parakeet Unified and Nemotron engines
- Model downloads and selection; optional local Whisper paths
- Nemotron streaming during recording, with live text insertion at the cursor
- Paste, type, or copy-only insertion strategies; a finished transcript is copied instead of lost when it cannot be inserted
- Menu bar popover (start button, model/insert/language switches, recent transcripts) or the original plain menu, switchable in Settings → General
- Floating pill that shows recording, live insertion, transcribing and result states without taking focus
- Transcript history (in memory by default, optionally saved on this Mac), vocabulary hints and text replacements
- Tabbed settings window; the app stays out of the Dock unless the window is open

## Bootstrap whisper.cpp

Run this from the repo root:

```bash
./scripts/bootstrap_whisper.sh base.en
```

That clones `whisper.cpp` into `Vendor/whisper.cpp`, builds `whisper-cli`, and downloads the requested model.

## Build

Generate the Xcode project and open it:

```bash
xcodegen generate
open HorseWhisprer.xcodeproj
```

Or build from the command line:

```bash
xcodegen generate
xcodebuild -project HorseWhisprer.xcodeproj -scheme HorseWhisprer -configuration Debug build
```

Public repo builds default to the `community` distribution flavor:

- fully functional, like official builds
- no official Sparkle feed configured
- no private signing or release secrets required

Optional local overrides:

- Create `Config/LocalOverrides.xcconfig` for machine-local build settings that should not be committed.
- Typical values: `HORSEWHISPRER_DEVELOPMENT_TEAM`, `HORSEWHISPRER_SPARKLE_FEED_URL`, and `HORSEWHISPRER_SPARKLE_PUBLIC_ED_KEY`.
- The file is ignored by git and is loaded automatically for app and test builds.
- Use [LocalOverrides.example.xcconfig](Config/LocalOverrides.example.xcconfig) as the template.
- In `.xcconfig` files, URLs must be written as `https:/$()/example.com/...` because `//` starts a comment.

## Official releases

Official releases are separate from normal source builds. They are Developer ID signed, notarized, and can embed the official Sparkle feed.

Prerequisites:

1. A valid `Developer ID Application` certificate.
2. A `notarytool` profile for your Apple account.
3. A Sparkle EdDSA keypair for update signing.
4. Release metadata exported in the shell or injected by private release config:
   `TEAM_ID`, `SPARKLE_PUBLIC_ED_KEY`, `DOWNLOAD_BASE_URL`, `PRODUCT_PAGE_URL`, `RELEASE_NOTES_BASE_URL`, and `APPCAST_URL`.

Create the notary profile once:

```bash
xcrun notarytool store-credentials YOUR_NOTARY_PROFILE \
  --apple-id "<apple-id>" \
  --team-id "<team-id>" \
  --password "<app-specific-password>"
```

Create Sparkle keys once:

```bash
./scripts/setup_sparkle_keys.sh
```

That stores the private key at `~/.config/horse-whisprer/sparkle-private-key.txt` and prints the matching public key. Release scripts use this file to sign Sparkle update ZIPs by default; use `SPARKLE_PRIVATE_KEY_FILE` or `--sparkle-private-key-file` only when signing with a different key file.

Build an official signed release app:

```bash
export TEAM_ID="<developer-team-id>"
export SPARKLE_PUBLIC_ED_KEY="<sparkle-public-ed-key>"
export DOWNLOAD_BASE_URL="https://downloads.example.com/horse-whisprer"
export PRODUCT_PAGE_URL="https://example.com/horse-whisprer"
export RELEASE_NOTES_BASE_URL="https://example.com/horse-whisprer/release-notes"
export APPCAST_URL="https://downloads.example.com/updates/horse-whisprer.xml"
./scripts/distribute_macos.sh --notarize YOUR_NOTARY_PROFILE
```

That script forces the app into the `official` distribution flavor at build time and produces:

- `dist/export/Horse Whisprer.app`
- `dist/Horse Whisprer-<version>.dmg`
- `dist/Horse Whisprer-<version>.zip`
- `dist/horse-whisprer.xml`
- `dist/horse-whisprer-release.json`

## Licensing and branding

- App code: MIT. See `LICENSE`.
- Third-party notices: see `THIRD_PARTY_NOTICES.md` and the in-app credits.
- The Horse Whisprer name, icon, and official update channels are reserved. See `TRADEMARKS.md`.
- Forks and redistributions should rebrand and provide their own update infrastructure.

## Notes

- New installs on Apple Silicon start with Parakeet Unified 0.6B selected; Intel Macs and existing installs keep their Whisper model. Parakeet and Nemotron Streaming 0.6B are English-only and require Apple Silicon. Download any model in Settings → Models. Whisper downloads are checked against pinned sizes and SHA-256 digests.
- Nemotron uses the 1.12-second Core ML streaming variant. Text appears at the cursor while speaking in supported accessible text fields. Settings → Dictation → Insert text while speaking disables this if preferred. After a manual edit, new speech resumes at the settled cursor, preserving the correction. An active selection is left untouched. Switching fields or an unverified insertion still pauses delivery; the complete transcript is retained according to the History setting. Startup capture retries briefly in the original field; unsupported fields fall back to insertion on stop, and copy-only mode continues to copy the final text. The model remains loaded between recordings.
- Native models are stored under `~/Library/Application Support/HorseWhisprer/Models/Native`. Downloads are staged and validated before installation; ordinary dictation loads local files without fetching models. The Whisper language picker does not change the language of the English-only native models.
- Native in-process linkage to `whisper.cpp` is not wired yet. The app currently invokes `whisper-cli`.
- Text insertion is best effort. Standard native fields, browsers, Electron apps, and editors should be the primary targets; secure inputs and protected contexts may not accept synthetic events.

## Native engine validation

The standard Xcode test suite includes download lifecycle, streaming order/cancellation, queue overflow, and continuous resampling regressions. Real-model inference is opt-in (approximately 1.2 GB of downloads). Provide a speech fixture containing “The quick brown fox jumps over the lazy dog”:

```bash
TEST_RUNNER_HORSE_NATIVE_SMOKE_ROOT="$PWD/tmp/native-smoke" \
TEST_RUNNER_HORSE_NATIVE_SMOKE_AUDIO="/absolute/path/to/speech.wav" \
xcodebuild -project HorseWhisprer.xcodeproj -scheme HorseWhisprer \
  -only-testing:HorseWhisprerTests/NativeModelSmokeTests test
```

This verifies local inference and streaming finalization; it is not a dictation accuracy benchmark or a physical microphone/route test.

## Startup and sound diagnostics

Nemotron prepares a stopped input queue while idle, then starts it on the trigger
without waiting for model loading or cue playback. Device startup and shutdown run
on a serial worker so a slow audio device cannot block the UI. It does not keep the microphone running between dictations. A brief
silent output warmup avoids cold Bluetooth playback setup. The cue runs independently
of capture and waits 300 ms for Bluetooth profile changes before playback.

To measure the current physical input and inspect the generated cue's digital output:

```bash
python3 scripts/diagnose_audio_startup.py
```

This requires Xcode and microphone/system-audio permission for the diagnostic's host.
It records only its own synthetic cue output, counts microphone samples without
saving them, and leaves system input/output selections unchanged. Reports and WAVs
go to `tmp/audio-startup-diagnostic`. It compares first-buffer latency against the
previous engine path, enforces a one-second ceiling, and verifies cue duration and
all three Bright cue frequencies. Use `--max-first-buffer-ms 250` for the stricter
Bluetooth/loopback target. USB devices can require roughly half a second to wake. This is a digital output measurement, not an
acoustic measurement inside headphones.

The opt-in `StartupAudioIntegrationTests` replays recorded speech through an existing
virtual device such as BlackHole, captures it with the production input queue, and
checks the opening words with the local Nemotron model. Supply a JSON array like
`[{"path":"/absolute/speech.wav","opening":"The quick brown fox jumps"}]`, with at
least five known opening words per fixture, and run:

```bash
TEST_RUNNER_HORSE_STARTUP_FIXTURES="/absolute/fixtures.json" \
TEST_RUNNER_HORSE_STARTUP_DEVICE_UID="BlackHole2ch_UID" \
TEST_RUNNER_HORSE_NATIVE_SMOKE_ROOT="$PWD/tmp/native-smoke" \
xcodebuild -project HorseWhisprer.xcodeproj -scheme HorseWhisprer \
  -configuration Release ENABLE_TESTABILITY=YES \
  -only-testing:HorseWhisprerTests/StartupAudioIntegrationTests test
```

This test requires an already-installed model; it does not download one or change
the system's default audio devices. Fixture leading silence is trimmed to 20 ms.
