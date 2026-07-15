# Release Lifecycle

Algomim client integrations are distributed as versioned GitHub Releases. The
hosted Model API and Inference services can change independently as long as
their public contract remains compatible.

## Version contract

Codex uses semantic versions such as `0.1.0` and immutable-by-policy Git tags
such as `v0.1.0`. The source contract is `codex/release.json`. A release tag
must match that file exactly.

Customer installation instructions use a tag-pinned raw URL. They never run a
mutable `main` installer:

```text
https://raw.githubusercontent.com/algomim/release/v0.1.0/codex/install.ps1
https://raw.githubusercontent.com/algomim/release/v0.1.0/codex/install.sh
```

Pushing a matching tag starts the release workflow. Windows, Ubuntu, and macOS
lifecycle tests must pass before the workflow publishes:

```text
manifest.json
SHA256SUMS
algomim-codex-windows-v0.1.0.zip
algomim-codex-posix-v0.1.0.tar.gz
```

Published tags and release assets must not be moved, replaced, or deleted. A
fix is always a new semantic version.

## Installed state

The installer records non-secret state at:

```text
~/.algomim/integrations/codex/state.json
```

It contains the installed version, release tag, API base URL, credential
profile name, and Codex home path. It never contains an API key. Lifecycle
scripts are installed beside it so update, doctor, and uninstall use the same
recorded configuration.

## Update transaction

The updater performs these steps:

1. Read and validate installed state.
2. Download the requested or latest release manifest over HTTPS.
3. Reject malformed versions, downgrades, unsafe artifact names, and unknown
   contracts.
4. Download the platform archive and verify its SHA-256 digest.
5. Extract into a temporary staging directory and validate `release.json`.
6. Back up only Codex-owned files and integration state.
7. Run the staged installer with `SkipKey`; shared credentials are never
   written or rotated by update.
8. Run offline doctor validation.
9. Keep the new version on success, or restore the exact previous files and
   state on any failure.

There is no background updater. Users or operators start updates explicitly.
Hosted service changes do not require a local update unless the Codex profile,
model catalog, auth adapter, or compatibility metadata changes.
