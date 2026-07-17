# Algomim for Claude Code

Status: **Pilot**

This integration lets Claude Code run against the Algomim Model API. It is
non-invasive at install time: the installer never edits `~/.claude`, your
claude.ai login stays untouched, and normal `claude` keeps using your existing
Anthropic account. Algomim sessions are started explicitly with
`algomim run claude`. Those sessions use an integration-owned Claude config
directory, keeping their settings, history, plugins, credentials, and saved
model choices separate from plain Claude Code.

## What the installer writes

```text
~/.algomim/
├── credentials                        shared Algomim credential store (INI, 600)
└── integrations/claude-code/
    ├── settings.json                  Claude Code session settings (no secrets)
    ├── config/                        isolated Claude settings and session data
    ├── state.json                     installed version, base URL, profile
    ├── install.ps1 / install.sh       lifecycle copies for update/repair
    ├── update.ps1 / update.sh
    ├── doctor.ps1 / doctor.sh
    ├── uninstall.ps1 / uninstall.sh
    ├── release.json
    └── credential-store.ps1 / .sh
```

The API key is stored only in the shared credential store. It is never written
into `settings.json`, never passed on a command line, and never placed in any
Claude Code configuration file. `algomim run claude` injects it into the
session process environment as `ANTHROPIC_AUTH_TOKEN` at launch time.

## Install

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

macOS/Linux:

```sh
sh ./install.sh
```

The installer asks for your Algomim API key (input is hidden), verifies and
stores it in the shared credential store, writes the session settings, and
installs the `algomim` CLI. Re-running the installer is safe; it reuses the
stored credential and preserves the original installation timestamp.

## Start Claude Code with Algomim

```sh
algomim run claude
```

Everything after `--` is passed to Claude Code unchanged:

```sh
algomim run claude -- --resume
```

Normal `claude` (without the Algomim CLI) keeps using your own Anthropic
account and `~/.claude` directory. Both can be used side by side in different
terminals.

With the normal Claude configuration (no separate `availableModels` policy),
an Algomim session's `/model` picker shows `Algomim` as its only named model.
Claude Code retains its own `Default` entry; this integration neither removes
nor remaps that client-owned choice. Opus, Sonnet, Haiku, and Fable are hidden
from the named model list. Plain `claude` remains unaffected and continues to
use your own Anthropic account.

The normal user-level `~/.claude/settings.json` file is not loaded in Algomim
sessions. Project/local settings and an administrator's managed policy still
participate, as required by Claude Code. A project or managed `availableModels`
policy can therefore add or restrict picker entries; the integration does not
disable project instructions, hooks, skills, or policy to force a cosmetic
picker shape.

## Doctor

```sh
algomim doctor claude
```

Checks, without printing any secret:

- installation state, release contract, and lifecycle files
- `claude` binary availability on PATH
- session settings content, including the recorded base URL
- the isolated Claude config directory and its filesystem protection
- credential availability and file permissions
- live Model API reachability (skip with `--offline`)

## Update or repair

```sh
algomim update claude
```

Updates download the published release archive, verify its SHA-256 checksum
against the release manifest, stage the new files, run an offline doctor, and
restore the previous installation exactly if anything fails.

For v0.3.5, run the tag-pinned installer once even if an older Claude Code
integration is already installed. The isolation change lives in the Algomim
CLI launcher. `algomim update claude` deliberately owns only the active
integration directory, so an older CLI is rejected and the integration update
is rolled back instead of reporting a false success.

## Uninstall

```sh
algomim uninstall claude
```

Removes `~/.algomim/integrations/claude-code/`, including its isolated Claude
session history and plugins. The shared credential profile is preserved by
default. Use `algomim logout` when you explicitly want to remove that shared
credential. The installer does not add files to `~/.claude`.

## Minimum versions

- Algomim CLI 0.3.5 or newer. Existing users install the current tag once.
- Claude Code 2.1.200 or newer. Verify with `claude --version`.
- The recorded base URL is the service root, such as
  `https://api.algomim.com`, without a trailing `/v1`.
- The Algomim Model API must expose `POST /v1/messages`
  (Anthropic-compatible). `GET /v1/models` is used by `doctor` as a health
  check, not for Claude Code model discovery.

## How the session is configured

`algomim run claude` launches `claude --settings <settings.json>` with the
stored API key exported as `ANTHROPIC_AUTH_TOKEN` and
`CLAUDE_CONFIG_DIR=~/.algomim/integrations/claude-code/config` for that process
only. The process-level config override is applied before Claude loads user
settings. The settings file then routes the session to Algomim:

- `ANTHROPIC_BASE_URL` — the Algomim Model API service root
- `model` / `ANTHROPIC_MODEL` — `algomim` for the main session
- `availableModels` — allows only the named `algomim` model
- `ANTHROPIC_CUSTOM_MODEL_OPTION` — adds `algomim` to `/model`, with the
  `_NAME` and `_DESCRIPTION` companions setting its Algomim label and summary
- `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=0` — prevents `/v1/models` from
  adding a second picker entry
- `CLAUDE_CODE_SUBAGENT_MODEL` — `algomim` for subagents
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` — keeps the bearer token out of tool,
  hook, and stdio MCP child processes

No `ANTHROPIC_DEFAULT_*_MODEL` family override is used, so Algomim is never
presented as a custom Haiku, Sonnet, Opus, or Fable model.

Token counting endpoints are not provided; Claude Code falls back to its local
context estimate, which is expected and harmless.

## Troubleshooting

| Symptom | Meaning | Action |
| --- | --- | --- |
| `algomim run claude` says the integration is not installed | Install has not run or was removed | Run `algomim install claude` |
| Auth conflict warning at startup | Your own Claude login coexists with the injected token | Expected; the Algomim token wins for this session |
| `401` | Key missing, invalid, or revoked | Run `algomim doctor claude`; re-run `algomim login` if needed |
| `403` | API user suspended or expired | Contact your Algomim administrator |
| `404` on requests | Model not available to this key | Check model permissions with your administrator |
| `429` | Token quota exhausted | Ask for a quota extension |
| Session uses your Anthropic account instead of Algomim | Plain `claude` was started instead of `algomim run claude` | Start with `algomim run claude` |
| Doctor requires a newer Algomim CLI | An integration-only update cannot replace the launcher that owns config isolation | Run the current tag-pinned installer once |
| Doctor says normal Claude still selects `algomim` | An older Algomim session saved its model before config isolation was installed | Remove only the top-level `"model": "algomim"` field from the reported normal Claude settings file |

## Security

- Never write the API key into `settings.json`, TOML files, screenshots, Git,
  or support messages.
- Claude transcripts are plaintext under the isolated `config/` directory;
  keep its permissions restricted and remove the integration to delete them.
- Only use the public Model API address you were given; internal service
  addresses and keys never belong on an end-user machine.
- If a key leaks, it cannot be read back; revoke it and issue a new one.
- When reporting errors, share the response `x-request-id` value, not the key.

## Official Claude Code behavior used here

- `--settings <file>` supplies the highest non-managed scalar settings for one
  session; array settings such as `availableModels` merge across non-managed
  scopes.
- `CLAUDE_CONFIG_DIR` replaces the user-level `~/.claude` settings, history,
  credentials, and plugins directory for the launched process.
- `env` in a settings file applies to the session and its subprocesses.
- `ANTHROPIC_AUTH_TOKEN` sends `Authorization: Bearer` and takes precedence
  over a saved login while set.
- `ANTHROPIC_CUSTOM_MODEL_OPTION` adds a custom `/model` entry; its `_NAME` and
  `_DESCRIPTION` companions control the picker label and description.
- `availableModels` restricts named picker entries but does not remove Claude
  Code's client-owned `Default` entry.
- Gateway model discovery is explicitly disabled so `/v1/models` does not add
  a second picker entry.
- `CLAUDE_CODE_SUBAGENT_MODEL` redirects subagent and agent-team requests.
