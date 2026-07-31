# ADR-0007: Shared devtainers — accept the IDE-sharing limitation, mandate disclosure

- **Status:** Accepted — disclosure UI not yet implemented on this branch.
- **Date:** 2026-07-31
- **Deciders:** Struan Bartlett

## Context

A devtainer can be shared: an owner adds developers/viewers
(`Container.vue`'s `UserTagsInput` on `form.developers`, with a
`# FIXME: Only owner or admin should be able to specify developers` already
sitting next to it), and `Reservation::exec`'s `@envSSH` block authorizes
SSH access for the owner plus named developers/role-holders when the `ssh`
router's access level is `developer`.

For `ide`-targeted env vars, this matters because of how delivery actually
works, traced through the code rather than assumed: there is exactly **one**
IDE server process per reservation. `Reservation::exec` always loads
`User->load($reservation->owner('username'))` and injects that one user's
`ide`-targeted vars into that one process's environment
(`apply_user_env` in `launch.sh`). Every terminal pane anyone opens in that
IDE — regardless of whose browser tab it is, owner or shared collaborator —
is a child of that same process tree, sharing one environment. There is no
per-tab, per-connection, or per-account identity inside a running Theia or
openvscode-server process to hang a different value on; it is not a gap in
today's implementation so much as a property of "one shared process serves
everyone with access to it."

A real fix would require distinct per-user IDE processes — e.g. separate
processes on separate internal ports, one per accessing account — which is a
speculative future architecture change, not close to available. Until then,
any technical claim of per-collaborator IDE env var isolation would be
false.

This is not a new problem this feature introduces. `GH_TOKEN`, git commit
identity, and the SSH authorized-keys pool already apply uniformly to
whoever has legitimate access to a shared devtainer, regardless of which
account is at the keyboard — Dockside's existing shared-devtainer model has
always had this property. What's new is the stakes: arbitrary user-chosen
`secret`-flagged values are a higher-value target than a git identity, and a
collaborator configuring env vars on their *own* account might reasonably
but wrongly assume they'll see their own values in a devtainer someone else
owns, when in fact they'll see none of theirs and potentially the owner's.

## Decision

**Do not attempt technical per-user isolation of `ide`-targeted env vars in
a shared devtainer.** Accept "if you don't trust a collaborator with these
values, don't share the devtainer with them" as the actual, current security
boundary — because it already is one, whether or not it's stated — and make
that boundary a first-class, unavoidable part of the sharing UX rather than
an implicit property a user has to already know.

Concretely: at the point an owner adds a developer/viewer
(`Container.vue`'s sharing UI, and the equivalent CLI share command), both
the UI and CLI must compute and display the **effective** set of env vars
(post profile-admission filtering per ADR-0006, since it varies devtainer to
devtainer) that granting this access will expose — not a generic warning,
the actual names and targets. This is real, scoped UI/CLI work: a
share-time preview, not a static disclaimer.

If/when distinct per-user IDE processes become feasible, this decision
should be revisited — it is a statement about the current architecture's
limits, not a permanent position that per-user isolation is undesirable.

## Consequences

- No code change to the delivery mechanism itself — `Reservation::exec`
  continues to resolve one owner and inject that owner's vars into the one
  IDE process, as built.
- Real, scoped product work is still required: a share-time effective-set
  preview in `Container.vue` (replacing/extending the existing
  `UserTagsInput`-adjacent UI) and the CLI's equivalent share command.
  Computing "effective set" depends on ADR-0006 landing first (profile
  admission), since the set is meaningless as "all of the owner's vars"
  once profiles can restrict it — this ADR's UI work is sequenced after
  ADR-0006.
- The pre-existing `Container.vue` FIXME about who may specify developers is
  adjacent but distinct — worth fixing in the same area of the UI, not
  conflated with this decision.
- Combined with ADR-0005: once secret vars are metadata-pull-only, a shared
  collaborator with SSH/IDE access can still retrieve the owner's secret
  values by querying the metadata server themselves (see ADR-0005's
  Consequences — the metadata server authenticates by reservation IP, a
  per-container grain, not per-account). This ADR's disclosure requirement
  applies equally to that case: the share-time preview should make clear
  that granting access includes the ability to retrieve secret vars via the
  metadata server, not just the auto-injected non-secret ones.
- This does not need to be, and is not, a blocker for anything else in this
  plan — it's a UX/transparency obligation, not an open technical question.

## Alternatives considered

- **Attempt partial isolation via separate IDE ports per user, now.** Real
  but large: needs the IDE launch/proxy path to support multiple concurrent
  processes per reservation, routed by accessing account, which touches
  `launch.sh`, `Reservation::exec`, and the router/proxy layer
  (`Proxy.pm`) simultaneously. Rejected for now as disproportionate to the
  problem — the social/consent boundary is a legitimate interim answer,
  provided it's actually surfaced to the owner, which is what this ADR
  requires.
- **Say nothing, leave it as an implicit property of sharing.** Rejected —
  this is exactly the "needs to be made very clear and transparent to avoid
  misunderstandings" concern that motivated this ADR; an undisclosed
  boundary is not a boundary a user can reasonably be expected to respect.
