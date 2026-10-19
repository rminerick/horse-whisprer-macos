# Security Policy

## Reporting a vulnerability

Please report security issues privately by emailing `support@boundarylabs.com`.

Do not open a public GitHub issue for vulnerabilities, leaked credentials, or reports that include private user data. Include enough detail to reproduce the issue, the affected version or commit, and any relevant logs or crash reports with secrets removed.

## Supported builds

Official Boundary Labs releases are Developer ID signed, notarized, and distributed from `boundarylabs.com`.

Community builds from this repository are supported on a best-effort basis. They do not use the official Boundary Labs update infrastructure unless configured by the maintainer for an official release.

## Secrets and release credentials

Release credentials must stay outside the repository:

- Apple Developer certificates and notary credentials belong in Keychain.
- Sparkle private keys belong outside the repo, such as `~/.config/horse-whisprer/sparkle-private-key.txt`.
- Machine-local build settings belong in ignored files such as `Config/LocalOverrides.xcconfig`.

Public verification keys, public update feed URLs, and test fixtures are not treated as secrets.
