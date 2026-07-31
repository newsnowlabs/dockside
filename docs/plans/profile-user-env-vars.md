# Plan: taking per-user env vars from feature-complete to right-scoped

- **Branch:** `claude/user-env-vars-6cs63v`
- **Status:** Feature built, reviewed, and hardened. This plan covers the
  realignment work needed before the scope is right, not before the code
  works.
- **Date:** 2026-07-31
- **Related:** `claude/secrets-encryption-users-json-zghgcl` (users.json
  encryption at rest — a dependency for part of this plan, developed on a
  separate branch)

## Current state of this branch

`claude/user-env-vars-6cs63v` added a per-user `env` field
(`{ KEY: { value, secret, targets: { docker, ide, ssh } } }`) to the user
record, self- and admin-editable via the existing dotted-path `--set`/
`--unset` mechanism, with three delivery mechanisms:

- `docker` — baked into `docker create` (`Reservation::Launch::cmdline_user_env`).
- `ide` — bundled into a `docker exec`-time JSON blob (`Reservation::exec`),
  written to a file and exported into the IDE process's environment by
  `launch.sh` (`populate_user_env`, `apply_user_env`).
- `ssh` — the same blob's other half, sourced into SSH login shells via a
  marker-guarded `.bashrc`/`.profile` snippet (`install_user_env_notice`).

This was built (`ba6a022`, `c091aac`, `829ee99`), deployed and verified
end-to-end against a live `:feature` container, and then put through an
automated PR review (newsnowlabs/dockside#45) that found and this branch
fixed eight real issues spanning shell-escaping, log-leak, validation, and
Vue-side bugs (`25403da`, `b89a3bf`, `f6ae71a`, `5234896`, `30ffa2a`) — see
the PR history for specifics. As of this plan, `./test.sh` passes in full
and the feature works as designed.

**What changed is the assessment of what "as designed" should mean.** Once
the feature worked, the harder question surfaced: should Dockside be
auto-populating secret values into a container's filesystem/process
environment at all, and should a user's env vars apply uniformly to every
devtainer they can launch. This plan and the accompanying ADRs are the
answer.

## The realignment, in one paragraph

Encryption at rest for `users.json` (separate branch) is necessary but not
sufficient — it protects the *server's* disk, not the *devtainer's*. Layered
on top: secret-flagged vars should never be auto-injected into a container
at all (ADR-0005) — Dockside should store them encrypted and serve them only
on request, via the metadata server (`App::Metadata.pm`, already
partially built). Which of a user's vars even reach a given devtainer should
be governed by that devtainer's profile, not decided unilaterally by the
user's own target flags (ADR-0006). And because a devtainer can be shared,
and there's no way — yet — to give different accounts different views of a
shared IDE process, the sharing UI needs to make that limitation an
explicit, visible fact rather than a silent one (ADR-0007).

## Scope boundaries

**In scope for this plan and its follow-on work:**

- Everything in ADR-0005, ADR-0006, ADR-0007.
- The SSH per-connection-identity question below (open, not yet decided).
- Defensible cleanups to this branch's existing code in light of the above
  (see "Cleanups" below) — documentation and light validation-tightening
  now; the larger structural changes (metadata endpoint, profile admission
  field, share-time UI) are follow-on implementation work, not part of
  landing this branch.

**Explicitly out of scope:**

- **Project-scoped env vars** (values tied to a project/repo rather than a
  user account) — a plausible future parallel axis to user-scoped vars, not
  designed here. Nothing in ADR-0006's profile-admission mechanism should
  foreclose it, but it is not being built now.
- **Per-user IDE processes** (distinct processes on distinct internal ports
  per accessing account) — the technical prerequisite that would let
  ADR-0007's decision be revisited. Not being built now; ADR-0007's decision
  stands until it is.
- **Extending this same push-vs-pull boundary to `gh_token` and SSH
  keypairs.** They have their own existing delivery models (`GH_TOKEN` via
  `docker exec` env, matching the `ide`-target shape; SSH private keys via a
  transient-tempfile-then-`ssh-add`-then-`rm` pattern in
  `populate_ssh_agent_keys`, which is already close to "never at rest" modulo
  a small window). Whether ADR-0005's reasoning should eventually apply to
  them too is a reasonable future question, not answered here.

## Staged roadmap

1. **Encryption at rest for `users.json`** — `claude/secrets-encryption-users-json-zghgcl`,
   independent branch, prerequisite for step 2.
2. **Metadata-server env-fetch endpoint** (ADR-0005) — new authenticated path
   on `App::Metadata.pm` serving a reservation owner's env vars, decrypted
   from at-rest storage on request. Should address the handler's existing
   `# FIXME` about hardening beyond `Metadata-Flavor` header + no-XFF +
   source-IP matching as part of this work, given the stakes of what it now
   serves.
3. **Flip secret-var delivery** (ADR-0005) — `User.pm::env_vars_for_target`
   excludes `secret=true`; `_validate_env_vars` rejects
   `secret=true`+`targets.docker=true`; `EnvVarsEditor.vue` disables
   docker/ide/ssh checkboxes when `secret` is set.
4. **Profile admission** (ADR-0006) — new `Profile.pm` schema field;
   `Reservation::Launch::cmdline_user_env` and `Reservation::exec` consult it
   alongside the user's own vars; existing/example profiles updated to
   opt in wherever the current unconditional behavior should be preserved.
5. **Share-time disclosure UI** (ADR-0007) — depends on step 4 (the
   effective set to display is post-admission-filter); `Container.vue`'s
   sharing flow and the CLI's equivalent gain an effective-env-var preview.
6. **SSH per-connection identity** (below) — depends on step 2 existing to
   have something to authenticate *to*; not yet decided between its two
   options, tracked here until it is.

Steps 3–5 can be sequenced independently of each other once 2 is done,
except where noted (5 depends on 4).

## Open question: SSH per-connection identity

Not yet a decision, so it isn't an ADR. Restated because it's a real,
scoped question once the metadata server (step 2) exists: today, the
metadata server authenticates purely by matching the caller's source IP to a
reservation — a per-*container* grain. Any account with legitimate SSH/IDE
access to a shared devtainer can query it and get the *owner's* vars; there
is no way for it to know *which* authorized account is actually asking, so
it can't yet scope a response to "just this collaborator's own vars."

`Proxy.pm::get_server_port` already resolves a real, authenticated `$User`
(via `Request->authenticate` against the session cookie) for every
router-proxied connection, including the SSH router — confirmed by reading
the code, not assumed. Per ADR-0004 (`0004-ssh-tunnel-credential-exposure.md`),
SSH access to devtainers is architecturally always wstunnel-mediated, so
this holds for every SSH session, not just some. The gap is that nothing
today carries that resolved identity from the proxy hop into the shell
`dropbear` spawns. Two options, not yet chosen between:

- **Server-side, via the proxy/wstunnel/dropbear path.** Mint a
  session-scoped token from the authenticated identity at the proxy hop and
  thread it through to land as an env var when the shell spawns. Requires
  new plumbing — nothing today passes metadata from the proxy hop into what
  `dropbear` hands its spawned shell.
- **Client-side, via the user's own SSH config.** OpenSSH's `SetEnv`/
  `SendEnv`, paired with dropbear-side acceptance of the forwarded variable
  (unconfirmed whether/how this dropbear build supports that — needs
  checking before this option can be committed to). This can plausibly reuse
  machinery ADR-0004 already built: `dockside ssh config`/`exec-proxy`
  already mints and refreshes a live, same-UID, 0600 credential tied to the
  authenticated session specifically to avoid a stale secret in a config
  file; emitting a second value (a `SetEnv` line) from that same mechanism
  is a smaller extension than building new server-side plumbing.

Once either lands, the metadata server gains a second factor beyond
reservation-IP, and can scope its response to the actual connecting account
— the missing piece for real per-collaborator secret-var isolation over
SSH. No equivalent path exists for `ide` (see ADR-0007) — this only ever
closes the `ssh` half of the sharing problem.

## Cleanups

Deliberately modest for this branch — the larger changes above are
follow-on implementation work, not something to rush into the branch that's
already landed and been reviewed once. What's reasonable to do now:

- Point `docs/developing/user-data-model.md` at the `env` field (it predates
  this feature and doesn't mention it) — a factual gap, not a design change.
- Cross-reference this plan and ADR-0005/0006/0007 from the PR description
  or a follow-up comment, so the "why does this feature push secrets today"
  question has a durable answer for anyone reading the history later rather
  than only living in conversation.
- No code changes as part of landing this plan doc — ADR-0005/0006/0007 are
  each real implementation work (metadata endpoint, profile schema field,
  share-time UI) appropriately sized as their own follow-on branches, not
  squeezed into this one after the fact.
