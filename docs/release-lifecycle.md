# Release Lifecycle

Algomim client integrations are distributed as versioned GitHub Releases. The
hosted Model API and Inference services can change independently as long as
their public contract remains compatible.

## Version contract

The Algomim CLI, Codex integration, and Claude Code integration use semantic
versions such as `0.3.2` and immutable-by-policy Git tags such as `v0.3.2`.
Their source contracts are `cli/release.json`, `codex/release.json`, and
`claude-code/release.json`. A release tag must match all three files exactly.

Customer installation instructions use a tag-pinned raw URL. They never run a
mutable `main` installer:

```text
https://raw.githubusercontent.com/algomim/release/v0.3.2/codex/install.ps1
https://raw.githubusercontent.com/algomim/release/v0.3.2/claude-code/install.sh
```

Pushing a matching tag starts the release workflow. Windows, Ubuntu, and macOS
lifecycle tests must pass before the workflow publishes:

- a first integration release must install the candidate directly and exercise
  its same-version update, checksum rejection, and rollback paths;
- once an integration has a previous immutable release, that release's updater
  must install the candidate without changing the shared credential;
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
algomim-codex-windows-v0.3.2.zip
algomim-codex-posix-v0.3.2.tar.gz
algomim-claude-code-windows-v0.3.2.zip
algomim-claude-code-posix-v0.3.2.tar.gz
algomim-cli-windows-v0.3.2.zip
algomim-cli-posix-v0.3.2.tar.gz
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
~/.algomim/integrations/claude-code/state.json
```

The CLI state contains its installed version, release tag, and repository. The
Codex state contains the installed version, release tag, API base URL,
credential profile name, and Codex home path. Neither contains an API key.
Lifecycle scripts are installed beside the Codex state so update, doctor, and
uninstall use the same recorded configuration.

The CLI dispatcher is installed under `~/.algomim/bin`. On Windows that
directory is added idempotently to the user PATH. On macOS/Linux a managed,
replaceable PATH block is written to the active bash/zsh profile.

## Codex update transaction

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

## Claude Code update and repair

The Claude Code updater owns only the active integration directory. It verifies
the Claude Code artifact, installs with credential and CLI installation
disabled, runs the staged offline doctor, and restores the previous integration
on failure. The shared credential store and separately installed CLI remain
outside that rollback boundary.

Because v0.3.1 shipped an older CLI repair bundle, those users run the v0.3.2
tag-pinned installer once. The installer reuses the existing credential while
refreshing both the active Claude Code integration and its CLI repair bundle.
