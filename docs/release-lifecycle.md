# Release Lifecycle

Algomim client integrations are distributed as versioned GitHub Releases. The
hosted Model API and Inference services can change independently as long as
their public contract remains compatible.

## Version contract

The Algomim CLI and Codex integration use semantic versions such as `0.2.0`
and immutable-by-policy Git tags such as `v0.2.0`. Their source contracts are
`cli/release.json` and `codex/release.json`. A release tag must match both
files exactly.

Customer installation instructions use a tag-pinned raw URL. They never run a
mutable `main` installer:

```text
https://raw.githubusercontent.com/algomim/release/v0.2.0/codex/install.ps1
https://raw.githubusercontent.com/algomim/release/v0.2.0/codex/install.sh
```

Pushing a matching tag starts the release workflow. Windows, Ubuntu, and macOS
lifecycle tests must pass before the workflow publishes:

- the updater from the previous immutable release must install the candidate
  release without changing the shared credential;
- the versioned installer must install the shell CLI and add its bin directory
  to PATH without duplicate entries;
- the CLI must dispatch Codex lifecycle commands without duplicating their
  implementation;
- the candidate updater must still pass checksum rejection and exact rollback;
- the generated Codex catalog and profile contract must match the canonical
  Inference model definition.

```text
manifest.json
SHA256SUMS
algomim-codex-windows-v0.2.0.zip
algomim-codex-posix-v0.2.0.tar.gz
algomim-cli-windows-v0.2.0.zip
algomim-cli-posix-v0.2.0.tar.gz
```

Published tags and release assets must not be moved, replaced, or deleted. A
fix is always a new semantic version.

## Generated model catalog

`codex/algomim-models.json` is generated from the private platform's canonical
Inference model definitions. The adjacent `algomim-models.lock.json` records the
generator contract and catalog SHA-256. Release packaging fails when the lock
does not match, and the generated catalog is never edited manually.

After a GitHub Release is published, the `Published release smoke` workflow
downloads the immutable installer and artifacts on Windows, Ubuntu, and macOS.
It exercises install, offline doctor, update check, checksum-verified forced
update, CLI dispatch, uninstall, credential reuse, and explicit credential
removal using isolated home directories.

The tag workflow explicitly dispatches this smoke after creating the release.
Release events created with the workflow's `GITHUB_TOKEN` do not recursively
start another workflow, while `workflow_dispatch` is allowed.

## Installed state

The installer records non-secret state at:

```text
~/.algomim/cli/state.json
~/.algomim/integrations/codex/state.json
```

The CLI state contains its installed version, release tag, and repository. The
Codex state contains the installed version, release tag, API base URL,
credential profile name, and Codex home path. Neither contains an API key.
Lifecycle scripts are installed beside the Codex state so update, doctor, and
uninstall use the same recorded configuration.

The CLI dispatcher is installed under `~/.algomim/bin`. On Windows that
directory is added idempotently to the user PATH. On macOS/Linux a managed,
replaceable PATH block is written to the active bash/zsh profile.

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
   written or rotated by update, and the existing CLI/PATH installation is not
   modified inside the Codex rollback transaction.
8. Run offline doctor validation.
9. Keep the new version on success, or restore the exact previous files and
   state on any failure.

There is no background updater. Users or operators start updates explicitly.
Hosted service changes do not require a local update unless the Codex profile,
model catalog, auth adapter, or compatibility metadata changes.
