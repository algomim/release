# Algomim for Claude Code

Status: **Pilot**

This integration lets Claude Code run against the Algomim Model API. It is
non-invasive at install time: the installer never edits `~/.claude`, your
claude.ai login stays untouched, and normal `claude` keeps using your existing
Anthropic account. Algomim sessions are started explicitly with
`algomim run claude`. Claude Code itself still uses its normal config and
session-history directory while it runs.

## What the installer writes

```text
~/.algomim/
├── credentials                        shared Algomim credential store (INI, 600)
└── integrations/claude-code/
    ├── settings.json                  Claude Code session settings (no secrets)
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
account. Both can be used side by side in different terminals.

Inside an Algomim session, `/model` lists `Algomim` as a custom model option.
Claude Code's built-in Anthropic entries, including `Default`, remain visible;
do not switch to one from an Algomim session. Exit and start plain `claude`
instead.

## Doctor

```sh
algomim doctor claude
```

Checks, without printing any secret:

- installation state, release contract, and lifecycle files
- `claude` binary availability on PATH
- session settings content, including the recorded base URL
- credential availability and file permissions
- conflicts with your own `~/.claude/settings.json` env block
- live Model API reachability (skip with `--offline`)

## Update or repair

```sh
algomim update claude
```

Updates download the published release archive, verify its SHA-256 checksum
against the release manifest, stage the new files, run an offline doctor, and
restore the previous installation exactly if anything fails.

If you installed v0.3.1, run the v0.3.2 tag-pinned installer once instead of
relying only on `algomim update claude`. The integration updater deliberately
owns only the active Claude Code installation; the pinned installer also
refreshes the separately installed CLI and its bundled repair files.

## Uninstall

```sh
algomim uninstall claude
```

Removes `~/.algomim/integrations/claude-code/` only. The shared credential
profile is preserved by default. Use `algomim logout` when you explicitly want
to remove that shared credential. The installer does not add files to
`~/.claude`.

## Minimum versions

- Claude Code 2.1.200 or newer. Verify with `claude --version`.
- The recorded base URL is the service root, such as
  `https://api.algomim.com`, without a trailing `/v1`.
- The Algomim Model API must expose `POST /v1/messages`
  (Anthropic-compatible). `GET /v1/models` is used by `doctor` as a health
  check, not for Claude Code model discovery.

## How the session is configured

`algomim run claude` launches `claude --settings <settings.json>` with the
stored API key exported as `ANTHROPIC_AUTH_TOKEN` for that process only. The
settings file routes the session to Algomim:

- `ANTHROPIC_BASE_URL` — the Algomim Model API service root
- `model` / `ANTHROPIC_MODEL` — `algomim` for the main session
- `ANTHROPIC_CUSTOM_MODEL_OPTION` — adds `algomim` to `/model`, with the
  `_NAME` and `_DESCRIPTION` companions setting its Algomim label and summary
- `CLAUDE_CODE_SUBAGENT_MODEL` — `algomim` for subagents
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` — keeps the bearer token out of tool,
  hook, and stdio MCP child processes

The integration does not set any `ANTHROPIC_DEFAULT_*_MODEL` family override.
Algomim is exposed in the picker only through the custom model option, leaving
Claude Code's built-in model families unchanged.

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
| `[warn] ... env.ANTHROPIC_BASE_URL` from doctor | Your `~/.claude/settings.json` sets conflicting env values | Remove them or accept that they may fight Algomim sessions |

## Security

- Never write the API key into `settings.json`, TOML files, screenshots, Git,
  or support messages.
- Only use the public Model API address you were given; internal service
  addresses and keys never belong on an end-user machine.
- If a key leaks, it cannot be read back; revoke it and issue a new one.
- When reporting errors, share the response `x-request-id` value, not the key.

## Official Claude Code behavior used here

- `--settings <file>` overrides user settings for a single session.
- `env` in a settings file applies to the session and its subprocesses.
- `ANTHROPIC_AUTH_TOKEN` sends `Authorization: Bearer` and takes precedence
  over a saved login while set.
- `ANTHROPIC_CUSTOM_MODEL_OPTION` adds a custom `/model` entry; its `_NAME` and
  `_DESCRIPTION` companions control the picker label and description.
- `CLAUDE_CODE_SUBAGENT_MODEL` redirects subagent and agent-team requests.
