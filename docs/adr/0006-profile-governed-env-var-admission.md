# ADR-0006: Profiles govern which env vars a devtainer admits (default-deny)

- **Status:** Accepted — not yet implemented on this branch.
- **Date:** 2026-07-31
- **Deciders:** Struan Bartlett

## Context

As built on `claude/user-env-vars-6cs63v`, a user's env var reaches a
devtainer whenever the user has flagged it for a given `target` (`docker`,
`ide`, `ssh`), full stop. `User.pm::env_vars_for_target($target)` returns
every matching var, unconditionally, for **any** devtainer that user
launches, regardless of which profile it's launched from. The set of vars a
devtainer receives is entirely a function of the launching user's account,
with no per-devtainer or per-profile control.

This is the wrong default. A user's env vars are account-scoped identity
data ("these are things I might want available"); whether a *given*
devtainer should actually receive them is a policy question that belongs to
whoever defines that devtainer's profile, not something the user's own
target checkboxes alone should decide. A profile already governs comparable
launch-time policy elsewhere in `Profile.pm::validate` — `ssh=b` (is SSH
access offered at all), `mounts` (what's mounted where), `access` (who may
reach which router at what level), `options` (what launch-time fields are
offered, becoming `DOCKSIDE_OPTION_*`) — env var admission is a gap in that
same family of profile-level policy, not a new category of control.

Concretely, without this, a var a user sets thinking "for my personal
scratch devtainer" is, as built, equally available to a shared production-like
devtainer profile they happen to launch from the same account — the user has
no way to scope a var to *some* of their devtainers and not others, and a
profile author has no way to declare "this class of devtainer does not admit
arbitrary user env vars at all," which will matter more once secret vars
route through the metadata server (ADR-0005) and a profile may want to
declare it doesn't support that retrieval pattern either.

**Project-scoped env vars** (values tied to a project/repo rather than a
user account) are a related but distinct future concept, explicitly out of
scope for this decision — noted here only so admission-policy design doesn't
implicitly foreclose it.

## Decision

**A profile must explicitly admit a launching user's env vars, per target;
absence of any declaration admits none.** The effective set of vars a
devtainer receives is the intersection of (the launching user's vars
declared for target T) and (target T's admission policy on the profile
actually used for this launch) — computed independently for each of
`docker`/`ide`/`ssh`.

This needs a new `Profile.pm` schema field (exact shape — boolean-per-target,
name-list-per-target, or a pattern allowlist — is an open implementation
question, not decided by this ADR) validated alongside the profile's
existing fields in `Profile.pm::validate`, and consulted at both current
call sites that currently call `env_vars_for_target` unfiltered:
`Reservation::Launch::cmdline_user_env` (docker target, at `docker create`
time) and `Reservation::exec` (ide/ssh targets, at `docker exec` time).

Default-deny mirrors `ssh=b`'s existing opt-in convention: a profile that
declares nothing about env var admission admits none of a launching user's
vars, for any target. An admin who wants a devtainer to inherit the
launching user's vars must say so explicitly in the profile.

## Consequences

- Every devtainer's effective env var set becomes profile-dependent, not
  purely account-dependent — the same user launching from two different
  profiles may see two different effective sets. This is deliberate (see
  ADR-0007, which depends on this varying devtainer-to-devtainer for its
  share-time disclosure UI to be meaningful) but is a genuine behavior
  change from what shipped in `ba6a022`/`c091aac`/`829ee99`: existing
  profiles, unless updated, will admit **no** user env vars at all once this
  lands, even if users have already configured some via `EnvVarsEditor.vue`.
  Existing/example profiles need updating (or an explicit decision that
  admins must opt in profile-by-profile as a deliberate migration step, not
  something to soften with a temporary default-allow grace period).
- `Reservation.pm`'s injection points gain a second data source (the
  reservation's `profileObject`) they don't currently consult for this
  purpose — a small, mechanical change at two call sites, not an
  architectural one.
- Validation errors need to distinguish "this var isn't targeted for this
  delivery mechanism" (user-side, existing) from "this profile doesn't admit
  this var" (profile-side, new) — the CLI/UI should be able to tell a user
  why a var they configured isn't reaching a particular devtainer.
- Test coverage: `t/integration/tests/14_user_env_vars.py`'s
  `EnvVarsInjectionTests` currently launches against a single test profile;
  new coverage needs a second profile with a deliberately restrictive (or
  absent) admission policy to assert vars are correctly excluded, not just
  correctly included.

## Alternatives considered

- **Keep the current user-target-flags-alone model.** Rejected — conflates
  account-level identity data with devtainer-level policy, and gives profile
  authors no lever at all, which becomes a real gap once some devtainer
  classes should plausibly refuse arbitrary user env vars entirely (e.g. a
  production-facing or compliance-relevant profile).
- **Default-allow, profile can restrict.** Rejected as the default: silently
  admitting all of a user's vars into any devtainer they can launch is the
  same "automatically added" behavior flagged as wrong, just with an opt-out
  instead of opt-in — worse for profiles nobody remembers to update, which is
  the common case, not the exception.
