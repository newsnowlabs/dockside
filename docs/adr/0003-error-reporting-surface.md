# ADR-0003: Restrict client-facing error detail to a sanitised `msg`

- **Status:** Proposed (draft — part of the `OtdcG` curated merge)
- **Date:** 2026-06-14
- **Deciders:** Struan Bartlett

## Context

The server's `Exception` type has long carried two fields — `msg` (intended as
client-facing) and `dbg` (internal detail) — and a central handler in `App.pm`
turns a caught exception into the client's HTTP response. **This split and the
handler pre-date this work.** However, the handler previously concatenated *both*
into the client response (`"$msg - $dbg (at $Time)"`), and command-execution
failures (`run`/`run_system`) populated only `dbg`, built from the full command
line. The net effect: internal detail and full command lines — which can include
`--env=OWNER_DETAILS|SSH_AGENT_KEYS|GH_TOKEN` payloads, PEM private keys, and
`gh_token` values — could reach API clients.

## Decision

Client responses expose **only** a sanitised, client-safe `msg`; `dbg` is logged
server-side and never returned. Concretely:

- The `App.pm` handler returns `"$msg (at $Time)"` (no `dbg`) and runs **every**
  error's `msg`/`dbg` through **`sanitize_sensitive_text`** (new) — including
  `Exception` objects, whose own `msg`/`dbg` can also embed secrets.
- **`sanitize_sensitive_text`** (new, `Util.pm`) redacts `--env=` secret payloads,
  PEM private-key blocks, and JSON/Perl `gh_token` fields.
- **`run_system`** sets a client-safe `msg` built from **`_display_cmd`** (new) —
  an abbreviated, argument-free summary (binary + verb, plus the network action for
  `docker network …`) — while the full (sanitised) command goes only to `dbg`. (The
  legacy interpolated-string `run` path reports only the exit code in `msg` and does
  not surface the command at all, so `_display_cmd` applies to `run_system`, not both.)
- Command execution moves from interpolated string `run("… $cmd …")` to array-form
  `run_system($bin, @args)`, removing shell parsing (defence in depth).

This ADR records the decision to **stop leaking `dbg`/secret detail to clients**
and the sanitisation/abbreviation that backs it — not the invention of the
`msg`/`dbg` split, which already existed.

## Consequences

- Clients get actionable but non-sensitive error text; operators get full detail
  in the server logs (`flog`/`wlog`).
- Convention for new error sites: client-safe wording in `msg`, full detail in
  `dbg`, never interpolate secrets or raw commands into `msg`; use
  `_display_cmd` / `sanitize_sensitive_text`.
- Client errors carry slightly less detail — intentional; debugging uses logs.

## Alternatives considered

- **Keep returning `dbg` to clients** (status quo) — rejected: leaks internal
  detail and secrets.
- **Sanitise but still return `dbg`** — rejected: even sanitised, `dbg` exposes
  internal structure and command lines the client does not need.
