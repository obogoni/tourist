# ADR-002: Repository layout

Status: accepted — Date: 2026-11-18

## Context

The repository has no application code yet, and the layout needs settling before the first Go package (#13). Architecture decisions also need a home and a common format.

## Decision

Follow the [official Go guidance for server projects](https://go.dev/doc/modules/layout):

- `cmd/`: one folder per executable, starting with the API.
- `internal/`: all application packages; nested `internal/` where a boundary inside the repo is worth enforcing.
- `migrations/`: SQL migrations (see ADR-003, #16).
- `deploy/`: deployment configuration.
- `docs/adr/`, `docs/research/`, `docs/learning/`. Learnings may reference ADRs, never the reverse.
- `.design/`: design docs. It stays where the tlc-discover skill writes them; `docs/README.md` points to it.

ADRs are numbered `NNN-title.md`. Once accepted they are not edited; a changed decision gets a new ADR and the old one is marked superseded. Template:

```
# ADR-NNN: <title>
Status: proposed | accepted | superseded by ADR-NNN — Date: YYYY-MM-DD

## Context
## Decision
## Alternatives considered
## Consequences
## Revisit when
```

## Alternatives considered

- **No `internal/`.** In an app nobody imports, it mostly signals intent. Rejected in favour of the official guidance.
- **Design docs in `docs/design/`.** The tlc-discover skill hardcodes `.design/`; changing it isn't worth the scope.

## Consequences

- One extra level in import paths.
- Design docs sit in a hidden folder outside `docs/`.

## Revisit when

- Code needs to be imported by another module.
- The tlc-discover output path becomes configurable, or the skill is no longer used.
