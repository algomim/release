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

The installer writes Codex integration files under `CODEX_HOME`, which defaults
to `~/.codex`:

```text
~/.codex/algomim.config.toml
~/.codex/algomim-models.json
~/.codex/algomim-models.lock.json
~/.codex/algomim-auth.ps1   # Windows
~/.codex/algomim-auth.sh    # macOS/Linux
```

Versioned lifecycle files and non-secret installation state are stored under:

```text
~/.algomim/integrations/codex/
  state.json
  release.json
  install.ps1 | install.sh
  update.ps1  | update.sh
  doctor.ps1  | doctor.sh
  uninstall.ps1 | uninstall.sh
```

The API key is shared across Algomim integrations and is stored separately:

```text
~/.algomim/credentials
```

On Windows this resolves to
`%USERPROFILE%\.algomim\credentials`. The file uses an INI-style profile:

```ini
[default]
api_key = sk-...
```

The installer does not edit the user's base `~/.codex/config.toml`.

The profile uses Codex's official custom provider auth command. Codex calls the
small auth helper, the helper resolves the shared Algomim credential, and Codex
sends that bearer token to the Algomim Model API. The auth helper contains no
API key.

The profile also disables Codex personality injection for Algomim. Algomim does
not advertise Codex personality templates; its behavior comes from the neutral
model metadata and the hosted Algomim model/kernel instead of a client-owned
identity prompt.

See the cross-client credential contract in
[`../docs/credentials.md`](../docs/credentials.md).

## Install

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.ps1 | iex
```

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.sh | sh
```

The installer uses `https://api.algomim.com/v1`. On the first install it asks
for an Algomim API key without displaying the input. Later installs reuse the
existing `default` credential automatically. Replace a key only by passing a
new key explicitly or by using a future login/rotation command.

Existing pilot installations are migrated automatically from
`~/.codex/algomim.key` to `~/.algomim/credentials`. The old file is deleted only
after the shared credential has been written and read back successfully. A
different legacy key is preserved with a warning rather than deleted.

For a pilot endpoint:
download the installer and pass the provided URL explicitly:

```powershell
irm https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.ps1 -OutFile install.ps1
.\install.ps1 -BaseUrl "https://example.ngrok-free.dev/v1"
Remove-Item .\install.ps1
```

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.sh -o install.sh
sh install.sh --base-url "https://example.ngrok-free.dev/v1"
rm install.sh
```

## Update or repair

Run the installed updater:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.algomim\integrations\codex\update.ps1"
```

```sh
sh "$HOME/.algomim/integrations/codex/update.sh"
```

The updater downloads the latest GitHub Release manifest, verifies the
platform archive with SHA-256, stages the files, and runs offline doctor. A
failed install or doctor check restores the exact previous Codex files and
state. Shared credentials are never changed by update.

Check without installing:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.algomim\integrations\codex\update.ps1" -CheckOnly
```

```sh
sh "$HOME/.algomim/integrations/codex/update.sh" --check
```

Re-running the same versioned installer repairs the current version without
selecting a newer release.

## Credential profiles and environment overrides

The default profile is named `default`. A separate named profile can be
installed without replacing it:

```powershell
irm https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.ps1 -OutFile install.ps1
.\install.ps1 -CredentialProfile "work"
Remove-Item .\install.ps1
```

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.sh -o install.sh
sh install.sh --credential-profile work
rm install.sh
```

Credential resolution order is:

1. `ALGOMIM_API_KEY` environment override.
2. The `ALGOMIM_PROFILE` environment selection.
3. The profile selected at install time.

`ALGOMIM_HOME` changes the shared credential directory. These variables are
mainly intended for CI, headless automation, and isolated testing. An
`ALGOMIM_API_KEY` value is used in memory and is not persisted by the installer.

## Non-interactive install

Prefer the interactive installer for humans, because command-line arguments can
land in shell history. Use non-interactive install only for controlled internal
automation.

Windows:

```powershell
irm https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.ps1 -OutFile install.ps1
.\install.ps1 -ApiKey "sk-..."
Remove-Item .\install.ps1
```

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/algomim/release/v0.1.1/codex/install.sh -o install.sh
sh install.sh --api-key "sk-..."
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
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.algomim\integrations\codex\doctor.ps1"
```

macOS/Linux:

```sh
sh "$HOME/.algomim/integrations/codex/doctor.sh"
```

Doctor checks:

- Codex is on PATH.
- Algomim profile exists.
- Algomim model catalog exists.
- The catalog SHA-256 matches its generated lock file.
- Auth helper exists.
- A credential resolves from `ALGOMIM_API_KEY` or the selected shared profile.
- Shared credential permissions are restricted.
- The profile selects Algomim and uses the Responses wire API.
- `/v1/models` responds and exposes `algomim` with the installed credentials.

Doctor exits with a failure status when the API key is rejected, the endpoint
cannot be reached, or the expected model is unavailable.

## Uninstall

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.algomim\integrations\codex\uninstall.ps1"
```

macOS/Linux:

```sh
sh "$HOME/.algomim/integrations/codex/uninstall.sh"
```

Uninstall removes the Algomim Codex profile, catalog, and auth helper. It does
not change the user's normal Codex/OpenAI configuration, and it preserves the
shared Algomim credential so another integration can continue to use it.

To explicitly remove the selected credential profile as well, download the
script and opt in:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "$HOME\.algomim\integrations\codex\uninstall.ps1" `
  -RemoveCredential
```

```sh
sh "$HOME/.algomim/integrations/codex/uninstall.sh" --remove-credential
```

With named credentials, pass `-CredentialProfile "work"` or
`--credential-profile work`. Only that profile is removed; other profiles are
preserved.

## Why there is a model catalog

`GET /v1/models` tells API clients which models exist. Codex also needs local
client metadata for its `/model` menu and local tool wiring. The
`algomim-models.json` file provides that Codex-specific metadata.

The catalog and adjacent checksum lock are generated from the canonical
Inference model definitions and versioned with this release. Install and update
verify the checksum before replacing local files. Do not edit either artifact
manually. Model metadata changes reach installed clients through the normal
Algomim update lifecycle.

The catalog is not the model. Algomim's actual behavior, AEC kernel, validation,
tool handling, and provider routing live behind the Algomim API.

## Troubleshooting

| Symptom                                | Meaning                                                                  | Fix                                                           |
| -------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------- |
| `/model` does not show Algomim         | Profile or catalog was not loaded                                        | Restart Codex with `codex --profile algomim`                  |
| `Model metadata for algomim not found` | Catalog path is wrong or missing                                         | Run installer again, then restart Codex                       |
| `Configured service tier priority...`  | A previous OpenAI tier leaked into the profile                           | Ensure `service_tier = "default"` is in `algomim.config.toml` |
| `tools must contain only...`           | Catalog/profile is stale or the backend is older than the Codex contract | Update Algomim setup and retry                                |
| `401`                                  | API key is missing, invalid, or revoked                                  | Rotate the selected Algomim credential and retry              |
| `403`                                  | API user is suspended or expired                                         | Contact the Algomim operator                                  |
| `404`                                  | Model is not visible for this key                                        | Check the key's allowed models                                |
| `429`                                  | Token quota or active request limit reached                              | Ask the operator to inspect usage                             |
| `502` / `504`                          | Upstream inference failed or timed out                                   | Share the request ID with the operator                        |

## Official Codex behavior used here

Codex profile files are separate files under `CODEX_HOME`, selected with
`codex --profile <name>`. The Algomim installer therefore creates
`algomim.config.toml` instead of editing the base user config.

Codex custom providers can use command-backed bearer auth. The Algomim profile
uses that mechanism so the API key does not need to be written into TOML.
