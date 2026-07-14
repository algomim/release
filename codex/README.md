# Algomim for Codex CLI

This folder installs Algomim as an isolated Codex profile.

After setup:

```sh
codex --profile algomim
```

uses Algomim, while:

```sh
codex
```

keeps using the user's normal Codex/OpenAI configuration.

## What the installer writes

The installer writes only Algomim-owned files under `CODEX_HOME`, which defaults
to `~/.codex`:

```text
~/.codex/algomim.config.toml
~/.codex/algomim-models.json
~/.codex/algomim.key
~/.codex/algomim-auth.ps1   # Windows
~/.codex/algomim-auth.sh    # macOS/Linux
```

It does not edit the user's base `~/.codex/config.toml`.

The profile uses Codex's official custom provider auth command. Codex calls the
small auth helper, the helper prints the Algomim bearer token, and Codex sends
that token to the Algomim Model API.

## Install

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/algomim/release/main/codex/install.ps1 | iex
```

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/main/codex/install.sh | sh
```

The installer uses `https://api.algomim.com/v1` and asks for an Algomim API
key. The key is entered without being displayed in the terminal.

When a usable key already exists, the installer asks:

```text
Existing Algomim key found. Reuse it? [Y/n]
```

Press `Enter` to keep the existing key. Enter `n` only when replacing it. A
new key prompt does not accept an empty value, so pressing `Enter` cannot
produce a broken keyless setup.

For a pilot endpoint:
download the installer and pass the provided URL explicitly:

```powershell
irm https://raw.githubusercontent.com/algomim/release/main/codex/install.ps1 -OutFile install.ps1
.\install.ps1 -BaseUrl "https://example.ngrok-free.dev/v1"
Remove-Item .\install.ps1
```

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/main/codex/install.sh -o install.sh
sh install.sh --base-url "https://example.ngrok-free.dev/v1"
rm install.sh
```

## Update or repair

Run the normal installer again. It overwrites only Algomim-owned profile,
catalog, and auth-helper files. It preserves the existing API key by default
and does not edit `~/.codex/config.toml`.

## Non-interactive install

Prefer the interactive installer for humans, because command-line arguments can
land in shell history. Use non-interactive install only for controlled internal
automation.

Windows:

```powershell
irm https://raw.githubusercontent.com/algomim/release/main/codex/install.ps1 -OutFile install.ps1
.\install.ps1 -BaseUrl "https://api.algomim.com/v1" -ApiKey "sk-..."
Remove-Item .\install.ps1
```

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/main/codex/install.sh -o install.sh
sh install.sh --base-url "https://api.algomim.com/v1" --api-key "sk-..."
rm install.sh
```

## Start Codex

```sh
codex --profile algomim
```

Use `/model` inside Codex to confirm `algomim` is selected.

## Doctor

Windows:

```powershell
irm https://raw.githubusercontent.com/algomim/release/main/codex/doctor.ps1 | iex
```

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/main/codex/doctor.sh | sh
```

Doctor checks:

- Codex is on PATH.
- Algomim profile exists.
- Algomim model catalog exists.
- Auth helper exists.
- API key file exists.
- The profile selects Algomim and uses the Responses wire API.
- `/v1/models` responds and exposes `algomim` with the installed credentials.

Doctor exits with a failure status when the API key is rejected, the endpoint
cannot be reached, or the expected model is unavailable.

## Uninstall

Windows:

```powershell
irm https://raw.githubusercontent.com/algomim/release/main/codex/uninstall.ps1 | iex
```

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/main/codex/uninstall.sh | sh
```

Uninstall removes the Algomim profile, catalog, auth helper, and API key file.
It does not change the user's normal Codex/OpenAI configuration.

To keep the local API key file:

```powershell
.\uninstall.ps1 -KeepKey
```

```sh
sh uninstall.sh --keep-key
```

## Why there is a model catalog

`GET /v1/models` tells API clients which models exist. Codex also needs local
client metadata for its `/model` menu and local tool wiring. The
`algomim-models.json` file provides that Codex-specific metadata.

The catalog is not the model. Algomim's actual behavior, AEC kernel, validation,
tool handling, and provider routing live behind the Algomim API.

## Troubleshooting

| Symptom | Meaning | Fix |
| --- | --- | --- |
| `/model` does not show Algomim | Profile or catalog was not loaded | Restart Codex with `codex --profile algomim` |
| `Model metadata for algomim not found` | Catalog path is wrong or missing | Run installer again, then restart Codex |
| `Configured service tier priority...` | A previous OpenAI tier leaked into the profile | Ensure `service_tier = "default"` is in `algomim.config.toml` |
| `tools must contain only...` | Catalog/profile is stale or the backend is older than the Codex contract | Update Algomim setup and retry |
| `401` | API key is missing, invalid, or revoked | Re-run install with a valid key |
| `403` | API user is suspended or expired | Contact the Algomim operator |
| `404` | Model is not visible for this key | Check the key's allowed models |
| `429` | Token quota or active request limit reached | Ask the operator to inspect usage |
| `502` / `504` | Upstream inference failed or timed out | Share the request ID with the operator |

## Official Codex behavior used here

Codex profile files are separate files under `CODEX_HOME`, selected with
`codex --profile <name>`. The Algomim installer therefore creates
`algomim.config.toml` instead of editing the base user config.

Codex custom providers can use command-backed bearer auth. The Algomim profile
uses that mechanism so the API key does not need to be written into TOML.
