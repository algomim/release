# Algomim Release

Public setup artifacts for connecting third-party AI clients to Algomim.

This repository does not contain Algomim product source code, private inference
configuration, provider credentials, hidden prompts, or customer data. It only
contains client-side setup assets such as profiles, model catalogs, install
scripts, uninstall scripts, and troubleshooting docs.

## Available integrations

| Integration        | Status | Path                             |
| ------------------ | ------ | -------------------------------- |
| Codex CLI          | Pilot  | [`codex/`](./codex/)             |
| Claude Code        | Future | [`claude-code/`](./claude-code/) |
| Visual Studio Code | Future | [`vscode/`](./vscode/)           |
| Cursor             | Future | [`cursor/`](./cursor/)           |
| Windsurf           | Future | [`windsurf/`](./windsurf/)       |

[`integrations.json`](./integrations.json) is the machine-readable integration
index. `Future` entries reserve a stable integration ID and directory only;
they are not installable or advertised as compatible yet.

Each integration is self-contained. Client-specific configuration, installers,
health checks, and uninstallers stay in that client's directory. Integrations
reuse the product-owned credential store documented in
[`docs/credentials.md`](./docs/credentials.md). API protocol compatibility
remains in Algomim's hosted services and is never implemented in this public
release repository. See
[`docs/integration-standard.md`](./docs/integration-standard.md).

## Codex quick install

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.ps1 | iex
```

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.sh | sh
```

Then start Codex with the Algomim profile:

```sh
codex --profile algomim
```

Plain `codex` keeps using the user's existing OpenAI configuration.

Release packaging, checksums, installed state, update, and rollback are
documented in
[`docs/release-lifecycle.md`](./docs/release-lifecycle.md).

Codex model cards are generated from canonical Inference model definitions.
`codex/algomim-models.json` and its SHA-256 lock are release inputs, not
hand-authored model metadata.

## Repository rules

- Keep this repository public-safe.
- Never commit API keys, internal service keys, OpenRouter credentials, hidden
  kernel text, customer emails, or private deployment names.
- Do not put product backend code here.
- Do not publish placeholder installers for `Future` integrations.
- Keep every integration isolated from the user's configuration for other AI
  clients.
- Keep API keys in the shared Algomim credential store, never in a
  client-owned directory.
- Prefer versioned release URLs for customer-facing instructions once a release
  is cut, for example `/v0.1.1/codex/install.ps1`.
- Never move an existing release tag or replace published release assets; ship
  a new semantic version instead.
