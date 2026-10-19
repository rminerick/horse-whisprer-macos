# Public source and free distribution

Horse Whisprer is free to use, with MIT-licensed app code. Official downloads
remain Developer ID signed and notarized, with Sparkle updates. Source builds
work without an account, activation, purchase, or private release credentials.
Library and model licenses remain separate; see `THIRD_PARTY_NOTICES.md`.

## Preparing a source snapshot

Install `gitleaks`, then run from the repository root:

```sh
python3 scripts/export_public_source.py /tmp/horse-whisprer-source
```

The destination must not exist. `Config/PublicSourceFiles.json` is an explicit
list of reviewed files. New source files must be reviewed and added to that list
before export. The exporter refuses symlinks, sensitive paths, known private
infrastructure details, and secret-scanner findings. Scanner exclusions from
the environment or repository are not used. The export includes SHA-256 hashes
in `SOURCE_MANIFEST.json` and contains no Git directory or history.
Embedded PNG text and EXIF metadata are stripped; image pixels are unchanged.

This is a local preparation step. It does not create a repository, publish files,
change repository visibility, archive a repository, or deploy the website.
Secret scanning complements manual review; it cannot prove that every private
detail has been identified. Review the complete manifest and source diff before
publication. Regenerate the snapshot after any source changes.

## Validate the exported source

In the exported directory, run `xcodegen generate`, build the community scheme,
and run the macOS and Python tests described in `CONTRIBUTING.md`. Release-only
settings belong in ignored local configuration. Never copy private Git history,
local configuration, build outputs, session logs, recordings, or release credentials
into a new public repository.

## Website transition

- Offer a direct free download with no registration gate.
- Offer an optional product-update email subscription; name is optional.
- Clearly describe what subscribers receive, with explicit opt-in and unsubscribe.
- Keep the existing official Sparkle feed and verification key for upgrade continuity.
- Keep historical paid-customer records private and separate from public app source.
- Retire checkout and activation prompts when the free binary is released.
- Preserve model/library notices and distinguish forks from official builds.

Publish a reviewed snapshot with fresh history. Once the replacement is available,
archive the superseded public repository and link to its replacement rather than
deleting it. Keep the private archive private for historical recovery.
