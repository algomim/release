# Algomim Credential Standard

Algomim integrations share one product-owned credential store. A client such
as Codex, Claude Code, or Cursor must not make its own directory the source of
truth for an Algomim API key.

## Location and format

The default credentials file is:

```text
Windows:     %USERPROFILE%\.algomim\credentials
macOS/Linux: ~/.algomim/credentials
```

`ALGOMIM_HOME` changes the `.algomim` directory. The file uses an INI-style
profile format, following the same broad shared-credentials convention used by
the AWS CLI:

```ini
[default]
api_key = sk-example

[work]
api_key = sk-example-work
```

The current schema permits one `api_key` entry per profile. Profile names must
start with a letter or number, contain only letters, numbers, dots,
underscores, or hyphens, and be at most 64 characters long.

The credentials file is not JSON. JSON adds no value for this flat secret
contract and makes safe manual inspection and profile updates less convenient.

## Resolution order

An installed integration resolves a credential in this order:

1. `ALGOMIM_API_KEY`, when set, is an ephemeral override for CI and headless
   automation.
2. The profile named by `ALGOMIM_PROFILE`, when set.
3. The profile selected when the integration was installed; `default` unless
   explicitly changed.

`ALGOMIM_HOME` changes the credential-store location at resolution time. An
environment override is never copied into the credentials file automatically.

## Security requirements

- Interactive setup reads the key without echoing it.
- Installers update the credentials file atomically in the same directory.
- macOS and Linux use directory mode `0700` and file mode `0600`.
- Windows removes inherited ACL entries and grants access to the current user.
- A credentials file that is a symbolic link or Windows reparse point is
  rejected.
- Auth helpers print only the selected bearer token to their client process;
  they never contain the token themselves.
- Diagnostics must not print, log, or commit credential values.

The shared file is appropriate for the manual API-key pilot. A future
interactive account login may replace local API-key entry with OAuth and an OS
credential vault without changing the hosted Model API contract.

## Ownership and lifecycle

The credential belongs to Algomim, not to an individual integration.
Therefore:

- Installing another integration reuses the same profile.
- Uninstalling Codex removes Codex files but preserves Algomim credentials.
- Credential deletion must be an explicit logout/removal action.
- Removing one named profile must preserve every other profile.
- Rotating a key updates its profile without rewriting unrelated profiles.

The Codex installer migrates the previous `~/.codex/algomim.key` file after a
verified write to the shared store. If the legacy key differs from an existing
shared profile, it is preserved and reported instead of being deleted
silently.
