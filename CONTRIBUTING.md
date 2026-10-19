# Contributing

Thanks for your interest in Horse Whisprer.

## Development setup

1. Clone the repository.
2. Install `xcodegen` if needed.
3. Run `./scripts/bootstrap_whisper.sh base.en` to build `whisper.cpp` and download a starter model.
4. Run `xcodegen generate`.
5. Open `HorseWhisprer.xcodeproj`, or build from the command line:

```bash
xcodebuild -project HorseWhisprer.xcodeproj -scheme HorseWhisprer -configuration Debug build
```

Public source builds default to the `community` distribution flavor. They do not require private signing or Sparkle release credentials.

## Regression tests

Run the macOS tests with `xcodebuild -project HorseWhisprer.xcodeproj -scheme HorseWhisprer test`.
The test scheme disables interactive app startup, and test settings use isolated defaults suites.

Run the runtime packaging regressions with `python3 -m unittest discover -s Tests/Scripts -v`.
These compile small Mach-O fixtures with Xcode's command-line tools and verify dependency rewriting,
missing-library failures, and incremental builds without using a local Whisper model.

## Local configuration

Use `Config/LocalOverrides.example.xcconfig` as a template for machine-local settings. Copy it to `Config/LocalOverrides.xcconfig`; that file is ignored by git.

Do not commit certificates, private keys, notary credentials, API tokens, generated release artifacts, downloaded models, or machine-local override files.

## Pull requests

- Keep changes focused.
- Add or update tests when changing behavior.
- Run relevant tests/builds before submitting.
- Preserve the community build path unless a change is explicitly official-release-only.

## Forks and redistribution

The source code is MIT licensed, but the Horse Whisprer name, icon, Boundary Labs branding, and official update channels are reserved. Forks and redistributed builds should rebrand clearly and use their own signing and update infrastructure.
