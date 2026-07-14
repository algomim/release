# Algomim Release

Public setup artifacts for connecting third-party AI clients to Algomim.

This repository does not contain Algomim product source code, private inference
configuration, provider credentials, hidden prompts, or customer data. It only
contains client-side setup assets such as profiles, model catalogs, install
scripts, uninstall scripts, and troubleshooting docs.

## Available integrations

| Integration | Status | Path |
| --- | --- | --- |
| Codex CLI | Pilot | [`codex/`](./codex/) |

Future integrations can live next to `codex/`, for example `claude-code/`,
`cursor/`, `windsurf/`, or `continue/`.

## Codex quick install

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/algomim/release/main/codex/install.ps1 | iex
```

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/main/codex/install.sh | sh
```

Then start Codex with the Algomim profile:

```sh
codex --profile algomim
```

Plain `codex` keeps using the user's existing OpenAI configuration.

## Repository rules

- Keep this repository public-safe.
- Never commit API keys, internal service keys, OpenRouter credentials, hidden
  kernel text, customer emails, or private deployment names.
- Do not put product backend code here.
- Prefer versioned release URLs for customer-facing instructions once a release
  is cut, for example `/v0.1.0/codex/install.ps1`.

