# Integration Standard

This repository distributes public client-side setup artifacts. It does not
implement model API compatibility, inference behavior, account management, or
billing.

## Status lifecycle

- `future`: The integration ID and directory are reserved. It must not contain
  an installer or claim compatibility.
- `pilot`: The integration has an operator-supported setup flow and has passed
  its client contract smoke tests.
- `stable`: The integration has versioned artifacts, upgrade coverage, and
  supported rollback behavior.
- `deprecated`: The integration remains documented for migration or removal.

Only `pilot` and `stable` integrations may set `installable` to `true` in
`integrations.json`.

## Directory ownership

Every integration owns a top-level directory named by its stable integration
ID. A client directory may contain:

```text
<integration>/
  README.md
  install.ps1
  install.sh
  doctor.ps1
  doctor.sh
  update.ps1
  update.sh
  uninstall.ps1
  uninstall.sh
  templates/
```

Only files relevant to the client belong in that directory. Not every client
requires every operating-system script. Missing lifecycle commands must be
explained in the integration README.

## Promotion requirements

Before changing an integration from `future` to `pilot`:

1. The hosted API contract required by the client must exist and pass streaming,
   tool-call, error, and authentication tests.
2. Installation must be idempotent and must not overwrite unrelated user
   configuration.
3. Uninstall must remove only files owned by Algomim.
4. Doctor must diagnose the local configuration without printing secrets.
5. Supported operating systems and minimum client versions must be documented.
6. Downloaded artifacts must be pinned to a versioned release before customer
   distribution.

## Security boundary

Never commit API keys, customer data, private provider names, internal routing,
hidden prompts, or backend source code. Client secrets must not be embedded in
templates or command history. Logs and diagnostics must redact credentials.

Shared helpers should be extracted only after two integrations require the same
behavior. Client-specific configuration formats and secret-storage mechanisms
must remain separate.
