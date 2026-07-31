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
   on `App::Metadata.pm`, reached over a single shared Unix socket (not the
   existing TCP/source-IP-matching path — see ADR-0005's transport
   revision), serving a reservation's env vars, decrypted from at-rest
   storage on request, identified by the token described in step 6/ADR-0008.
   This retires the handler's existing `# FIXME` about hardening beyond
   `Metadata-Flavor` header + no-XFF + source-IP matching rather than just
   making it more urgent — the new transport replaces that mechanism
   outright.
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
6. **SSH per-connection identity** (ADR-0008) — depends on step 2 existing
   to have something to authenticate *to*; mechanism settled (patch
   dropbear; no viable no-patch fallback — see below).

Steps 3–5 can be sequenced independently of each other once 2 is done,
except where noted (5 depends on 4).

## SSH per-connection identity, and the metadata transport (ADR-0008, ADR-0005)

No longer open. The two options sketched when this plan was first written —
server-side identity injection via the proxy/wstunnel/dropbear path, or
client-side `SetEnv`/`SendEnv` — were both researched against the actual
bundled software rather than left as assumptions, and **both turned out to
be blocked**: the wstunnel→dropbear leg can't carry data into an
already-encrypted SSH session without a full SSH-terminating proxy (true
for OpenSSH too — checked, not dropbear-specific), and dropbear (2025.88, as
shipped) has never implemented the SSH `env` channel request server-side at
all. Swapping to OpenSSH's `sshd` would genuinely unlock this but was
rejected as disproportionate — `sshd` isn't currently bundled at all, and
dropbear's small footprint was very likely the reason it was chosen for a
per-devtainer daemon in the first place.

A third, no-patch option — a `command=` forced-command wrapper — was
initially kept as a fallback alongside patching dropbear, then **rejected
outright** once examined against the actual threat model: the wrapper runs
as the same shared `$IDE_USER` account every session lands as, and has no
way to prove it was genuinely invoked by dropbear for a real, distinct key
authentication versus manually re-run by an already-connected user with a
forged argument. If it can access the signing capability, any co-located
session can mint a token for any other identity — a complete bypass, not a
weaker version of the protection. **ADR-0008's decision is now singular:
patch dropbear** with a minimal, server-authored authorized_keys option
(`dockside-identity=`), applied at auth-success time (so it also covers
port-forwarding-only connections, unlike `command=`'s apply-point). The
patch is materially smaller than upstream's own general, still-unmerged
SendEnv/AcceptEnv PR, since Dockside only ever needs to deliver one
server-controlled value, never a client-proposed one.

The minted token now carries `reservation_id` alongside `account`,
`nonce`, and `expiry` — this does double duty for ADR-0005's transport
decision too. Investigating how a per-reservation metadata channel would
actually work in practice found the original per-reservation-Unix-socket
idea impossible (Docker can't attach a new volume to an already-running
container, and the Dockside server is one long-lived container serving
devtainers created long after its own startup), which forces a **single
shared Unix socket** for every devtainer instead — and that, in turn, means
the metadata server can no longer identify which reservation is asking from
the connection itself. Rather than adding a new mechanism for that
(`SO_PEERCRED` was considered and rejected — it would need the Dockside
server to share the host's PID namespace, a real new privilege grant, just
to identify *which container*, not *which account*), `reservation_id` in
the same token already being minted answers both questions from one
verified payload, treated as an untrusted lookup key the way a JWT's `kid`
header is — it only selects which reservation's key to verify the HMAC
against, so a forged value buys nothing.

The token also surfaces as an ordinary env var in the connecting user's
shell — there's nowhere else for a user's own later-invoked script to reach
it from. That means its confidentiality from *other* sessions sharing the
same container depends entirely on closing the `/proc/<pid>/environ`
cross-session read (governed by the host kernel's `ptrace_scope`, which
Dockside doesn't control) — ADR-0008 now makes wrapping every session in an
independent Landlock sandbox (`landrun`), fail-closed if unavailable, a
mandatory part of the mechanism rather than an optional hardening step, since
Landlock's ptrace-domain restriction closes this regardless of the host's
`ptrace_scope`. See ADR-0008 for the full mechanism and research.

Once built, the metadata server has both factors it needs — which
reservation, which account — and can scope its response accordingly for
`ssh`. No equivalent path exists for `ide` (see ADR-0007) — this only ever
closes the `ssh` half of the sharing problem.

## Cleanups

Deliberately modest for this branch — the larger changes above are
follow-on implementation work, not something to rush into the branch that's
already landed and been reviewed once. What's reasonable to do now:

- Point `docs/developing/user-data-model.md` at the `env` field (it predates
  this feature and doesn't mention it) — a factual gap, not a design change.
- Cross-reference this plan and ADR-0005/0006/0007/0008 from the PR
  description or a follow-up comment, so the "why does this feature push
  secrets today" question has a durable answer for anyone reading the
  history later rather than only living in conversation.
- No code changes as part of landing this plan doc — ADR-0005/0006/0007/0008
  are each real implementation work (metadata endpoint, profile schema
  field, share-time UI, `authorized_keys` restructuring) appropriately sized
  as their own follow-on branches, not squeezed into this one after the
  fact.
