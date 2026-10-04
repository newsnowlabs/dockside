# Encrypt `gh_token` / SSH private keys at rest in `users.json`

## Context

`/data/config/users.json` currently stores two secret fields in plaintext: `gh_token`
(GitHub PAT) and `ssh.keypairs.*.private` (SSH private keys), for every user. Anyone
with read access to that file on disk — a stolen backup, a misconfigured copy, a
support-ticket attachment, or (currently) any UID inside the container, since the
file is mode 644 — gets every user's credentials outright. The server already loads
these into memory and only actually *uses* them at one narrow point (injecting them
into a `docker exec` call when launching/refreshing a devtainer's IDE), so there's no
functional need for them to sit in plaintext on disk between writes.

This change encrypts both fields at rest using a server-configured master key, and
decrypts them lazily, only at the point of use, shrinking both the on-disk and the
in-memory plaintext-exposure window versus today's behavior.

Scope, as decided:
- **UID/GID provisioning (prerequisite, independent change)**: `dockside`'s
  in-container uid:gid is currently whatever `useradd` assigns at image-build time
  (`Dockerfile:476` has no `-u`/`-g`, so it lands on the first available uid, typically
  1000 on a Debian base) — a value with a real chance of coinciding with an unrelated
  real account on the host, via the `/data` bind mount. Before any of the secret
  encryption work lands, `entrypoint.sh` is extended to let the host admin choose a
  dedicated, non-colliding uid:gid for `dockside` to run as (no user-namespace
  remapping — direct passthrough), defaulting to a safely-generated value if unset.
  This closes the read-exposure risk for **all** of `/data` (not just a new key file),
  with no changes needed to nginx or `docker-event-daemon` at all. See §0. This lands
  first, as its own independently-testable commit (and likely its own short-lived
  branch), before any of the encryption-specific work below.
- **Key storage**: inside `/data/config/config.json` (alongside the existing
  `uidCookie.salt` precedent), `dockside`-owned, permissions tightened to `0600`. (An
  earlier iteration of this plan explored root-owning a dedicated key file instead,
  which would have required reworking `docker-event-daemon`'s privilege model — that
  approach is dropped now that §0 closes the underlying collision risk more
  completely, without touching either process's privilege model at all.)
- **Crypto**: `Crypt::CBC` (new, small, pure-Perl dependency) wrapping the existing
  `Crypt::Rijndael`, encrypt-then-MAC with HMAC-SHA256 via `Digest::SHA` (already a
  dependency).
- **Migration**: lazy only — a user's secrets get encrypted the next time their
  record is written for any reason. No bulk migration command.
- **Key rotation**: explicitly deferred (no precedent anywhere in this codebase;
  the envelope format's `v1` version tag leaves room for a future scheme).
- **Opt-out**: a global `config.json` toggle, `$CONFIG->{'secrets'}{'encryption'}`
  (default `true`), for operators who judge the feature isn't worth its cost on
  their instance. Settable live via the existing `--config-set` mechanism, no
  restart needed.
  - **This must be a host/container-access-only control, never exposed through the
    CLI or API.** Reachable only via the host bind mount (`~/.dockside:/data`) or
    `docker exec`/`--config-set` at container start — i.e. only someone who already
    has host- or container-level access to the Dockside deployment, and who could
    already read the plaintext master key sitting in the same file regardless. A
    CLI/API-reachable version of this toggle was considered and **rejected
    outright**: it would let a purely in-app `admin` role — a role with no implied
    host or Docker access under Dockside's own RBAC — disable at-rest encryption
    remotely, a genuinely new capability rather than a convenience, especially on a
    managed/hosted instance where the host operator and the tenant's Dockside admin
    are different trust levels. No CLI flag or API field for this exists or should
    exist.
  - A finer-grained per-field/per-write override was also considered and deferred
    for the same reason, compounded by extra CLI/API surface it would need.
- **Bundled adjacent fixes** (same code paths, found during research):
  1. Tighten `users.json`/`passwd`/`config.json` to `0600` (currently `0644`,
     world-readable inside the container).
  2. Fix `OWNER_DETAILS` leaking SSH private keys into a container env var via
     `User::details_full` when only name/email are ever consumed.
  3. Sanitize the two unredacted `docker create` command log lines in
     `Reservation::launch`, matching the redaction `run_system` already does for
     `docker exec`.

## Design

### 0. UID/GID provisioning (independent prerequisite — lands first)

**Goal**: let the host admin pick a `dockside` uid:gid known not to collide with any
real host account (direct, unremapped passthrough — not Docker `--userns-remap`),
defaulting to a safe value if they don't, so a fresh install is safe with zero admin
action. This protects **all** of `/data` uniformly (config, db, cache, certs), not
just one new file, and requires no changes to nginx or `docker-event-daemon` — both
continue to run exactly as today, simply resolving `dockside` to a different number.

- **`Dockerfile` change: bake in a better built-in default, `65532:65532`, as a
  fallback only — not the primary defense** (currently `useradd -l -U -m $USER ...`
  at `:476` has no `-u`/`-g`, so it lands on the first available uid — typically
  1000 on a Debian base, exactly the collision-prone value this feature exists to
  avoid). `65532:65532` matches Google distroless's well-known `nonroot` user
  convention, sitting in a pocket above the human-account range (1000 up to a
  distro's `UID_MAX`), above distro-installed system-service accounts (100–999,
  which is *not* actually safer despite being the traditional Unix "service
  account" range — that range is exactly where other host-installed daemons
  already cluster, so it shifts collision risk rather than reducing it), and above
  systemd's `DynamicUser=` pool (61184–65519) — while staying below the reserved
  sentinels 65534 (`nobody`/`nogroup`) and 65535. `useradd -u 65532 -g 65532`
  (`useradd -U` already creates a matching-numbered group; make it explicit).
  - **Important limitation, raised on review: a well-known fixed value doesn't
    protect against convergence with *other* software making the same choice.**
    The original concern was an unrelated *human* host account coincidentally
    sharing dockside's uid. A fixed, increasingly-popular convention like 65532
    doesn't address a different risk: another container on the same host — quite
    possibly one that *also* adopted the distroless convention, for the same good
    reasons — bind-mounting its own data at the identical uid. Two services
    independently doing "the right thing" can still collide with each other
    precisely because they did the same right thing. Only genuine randomization
    protects against that; a fixed pocket, however well-chosen, cannot.
  - So `65532:65532` is kept only as the `Dockerfile`'s static fallback — what
    `dockside` resolves to under `--no-uidgid-remap`, or if `entrypoint.sh` is
    bypassed entirely. It is **not** what a fresh install actually ends up running
    as by default; see step 4 below, which reinstates randomization for that case
    and gives up last iteration's "zero remap needed on fresh install"
    simplification in exchange for closing this gap.
- **Verified groundwork**: `Dockerfile:477`'s `usermod -a -G docker,bind ...` records
  supplementary group membership in `/etc/group` by **username**, not by uid/gid
  number — so renumbering `dockside` via `usermod -u`/`groupmod -g` leaves `docker`/
  `bind` group membership (needed for `/var/run/docker.sock` access,
  `entrypoint.sh:196-203`) completely intact. No supplementary-group logic to
  hand-roll, unlike the dropped `docker-event-daemon` privilege-drop approach.
  `entrypoint.sh` already re-chowns the few non-`/data` runtime-writable paths on
  every boot (`:324` for `/var/log/$APP`, `:688` for `$APP_HOME/.vscode`) using the
  symbolic `$USER` name, so they transparently follow a uid/gid change.
- **`/data` vs. `$HOME` — the overlay-churn distinction.** `/data` is a bind mount
  (`docker-compose.yml`), so it passes straight through to the host filesystem with
  no overlay layer involved — `chown -R $USER $DATA_DIR` (`entrypoint.sh:685`,
  unchanged by any of this) never causes overlay copy-up, regardless of uid/gid
  changes. `$HOME` (`useradd -m`'s baked-in content) is different: it lives on the
  container's own overlay-backed root filesystem, where **any** metadata write to a
  file that currently exists only in a lower (image) layer — a `chown`, *and
  equally a `chmod`* — forces the overlay driver to copy that file up into the
  writable upper layer first. Blanket-chowning (or retroactively chmod-ing) all of
  `$HOME` at container start therefore generates real upper-layer churn (every file
  moved up), which is fine for a short-lived container but undesirable for a
  long-running one. This distinction matters for how `$HOME` specifically is
  handled below; it never applied to `/data`, which was always safe to chown.
- **Flags**, following the existing `--flag) shift; OPT_X="$1"; shift; continue;
  ;;`/`--flag) shift; OPT_X="1"; continue; ;;` idioms (`entrypoint.sh:168-179`,
  alongside `--run-dockerd`/`--lxcfs-available`/`--passwd-file`/etc.), all sharing
  a common `--uidgid-remap*` family name so they read as one feature:
  - **`--uidgid-remap <uid>:<gid>`** (`OPT_UIDGID_REMAP`): the explicit admin
    choice/override (renamed from an earlier `--uid-gid` draft). The same flag also
    accepts the keywords `default`, `noremap`, or `none` as synonyms for disabling
    remapping entirely — equivalent to `--no-uidgid-remap` below, offered as
    alternate spellings for scripts/wrappers that always pass this flag with a
    templated value and want "disable" to be just one more value that variable can
    hold, rather than requiring a separately-conditioned flag.
  - **`--no-uidgid-remap`** (`OPT_NO_UIDGID_REMAP`, renamed from an earlier
    `--no-uid-remap` draft): a dedicated, argument-less spelling of the same
    disable behavior — inhibits the entire mechanism, skipping uid/gid resolution,
    persistence, and `usermod`/`groupmod` entirely, leaving `dockside` at whatever
    uid/gid the image was built with (today's behavior, unchanged). For a use case
    where the collision risk doesn't apply or isn't wanted (e.g. a trusted
    single-developer host), this sidesteps the whole ownership-mismatch question
    for `$HOME` by never creating a mismatch in the first place.
  - **`--uidgid-remap-home`** (`OPT_UIDGID_REMAP_HOME`, renamed from an earlier
    `--chown-home` draft): only meaningful when remapping is active (i.e. not
    disabled by either spelling above). Opts into `chown -R` on the entire home
    folder to match the new uid:gid, accepting the overlay churn, for cases where
    `$HOME` must stay fully editable by the running identity — e.g. a development
    instance of Dockside itself (per `CLAUDE.md`'s `mountIDE: false` own-IDE
    setups) where a human is actively working under that home directory and a
    permission mismatch on pre-existing dotfiles/config would be disruptive.
    Without this flag (the default), `$HOME`'s pre-existing content is left at its
    original build-time ownership and **not** touched at runtime at all.
  - **Default (remapping active, `--uidgid-remap-home` not set)**: `$HOME` is left
    alone.
    This only works — avoiding both a permissions problem *and* runtime churn — if
    `$HOME`'s content is already world-readable/executable. **Verified: it already
    is.** No `umask` override exists anywhere in the `Dockerfile`, so the default
    build umask (644 files / 755 dirs) applies throughout, and no `chmod 700`/`600`
    scopes anything under `$HOME` — the same pattern this `Dockerfile` already uses
    deliberately elsewhere when broader access is needed (e.g. `chmod -R o+rx
    $PLAYWRIGHT_BROWSERS_PATH`, `:634`). So no `Dockerfile` change is needed for
    this; the default path genuinely never touches `$HOME` at runtime — no `chown`,
    no `chmod`, no copy-up. Worth one explicit implementation-time check rather than
    assuming it holds forever (`find $HOME -not -perm -o+r` / `-not -perm -o+rX` for
    dirs) so a future change to the image doesn't silently reintroduce a gap here;
    if that check ever finds one, fix it as a targeted, scoped `chmod` in the
    `Dockerfile` at build time (never a runtime `chmod -R` in `entrypoint.sh`, which
    would reintroduce exactly the churn this avoids) rather than a blanket sweep.
  - All three spellings need to be testable independently per your request: verify
    (a) `--no-uidgid-remap` (and separately, `--uidgid-remap none`/`noremap`/
    `default`) all reproduce today's exact behavior (built-in uid, no persisted
    mapping file, no `usermod`/`groupmod`); (b) `--uidgid-remap-home` alone (with
    remapping active) results in `$HOME` fully owned by the new uid:gid and freely
    editable; (c) the default (remapping active, home-chown not requested) leaves
    `$HOME`'s ownership untouched while remaining readable/executable via the
    build-time permissions.
  - A persisted mapping file, e.g. `/data/config/uidgid` (`root:root`, `0600` —
    consulted and written only by `entrypoint.sh` while still root; the numbers
    themselves aren't sensitive, the file just shouldn't be casually editable),
    remembers the resolved value across boots so `--uidgid-remap` only needs to be
    supplied once (or on a deliberate change), not on every container recreation.
    Chosen over env vars (`DOCKSIDE_UID`/`DOCKSIDE_GID`, considered and dropped)
    for the explicit-choice input itself, specifically for consistency: every other
    admin-facing `entrypoint.sh` setting (`--run-dockerd`, `--ssl-zone`,
    `--config-set`, `--passwd-file`) is a CLI flag, none are env-var driven, and a
    flag works equally well from `docker run` or a `docker-compose.yml` `command:`
    list.
- **Resolution order, each boot** (root, before any privilege drop or `chown`):
  0. If remapping is disabled (`--no-uidgid-remap`, or `--uidgid-remap` given one
     of `default`/`noremap`/`none`), skip straight to launching `s6-svscan` — none
     of steps 1-7 run, `dockside` stays at the image's built-in uid:gid, `/data`/
     `$HOME` are handled exactly as they are today.
  1. If `--uidgid-remap <uid>:<gid>` was passed this boot with an actual uid:gid
     pair (`OPT_UIDGID_REMAP` set to something other than the disable keywords),
     use it (explicit admin choice/override).
  2. Else if `/data/config/uidgid` already exists, reuse the persisted value
     (steady state for an already-provisioned instance).
  3. Else if `/data/config` already exists and is populated (**upgrade path**):
     adopt whatever uid:gid is already in use (e.g. `stat -c %u/%g` on
     `users.json`) as the persisted baseline — an upgrade must never force a
     surprise re-chown of an already-working install.
  4. Else (**brand new install**, no explicit choice): generate a genuinely random
     uid:gid — e.g. uniformly from 40000–65533 — rather than reusing the
     `Dockerfile`'s fixed `65532:65532` default. A wide range (not the narrow
     ~14-value distroless pocket) is deliberate: the goal here is specifically to
     avoid convergence with *other* software on the same host that also picked a
     "safe-looking" value, which a fixed pocket cannot do no matter how well
     chosen, only genuine randomness can. This means `usermod`/`groupmod` (step 6)
     will fire on essentially every fresh install, not just explicit-override ones —
     giving up the earlier "zero remap needed by default" simplification is the
     accepted cost of closing this gap.
  5. Persist the resolved value to `/data/config/uidgid` (idempotent no-op if
     unchanged).
  6. If `dockside`'s current uid/gid (`id -u dockside`/`id -g dockside`) doesn't
     match, `groupmod -g $TARGET_GID dockside; usermod -u $TARGET_UID -g $TARGET_GID
     dockside`, run **before** the existing `chown -R $USER $DATA_DIR` step
     (`entrypoint.sh:685`) — that line already uses the symbolic name, so it
     transparently re-chowns `/data` to whatever `dockside` now resolves to, with no
     changes needed to that line itself.
  7. If `OPT_UIDGID_REMAP_HOME` (`--uidgid-remap-home`) is set, additionally
     `chown -R $TARGET_UID:$TARGET_GID $HOME` — otherwise leave `$HOME` untouched,
     relying on the `Dockerfile`'s build-time world-readable permissions.
- **Verification**: fresh install (confirm `/data` and the freshly-generated
  random uid:gid are consistent, dockside processes function normally — container
  create/start, `/var/run/docker.sock` access, `users.json` read/write); upgrade of
  an existing install (confirm the pre-existing uid:gid is detected and adopted with
  no disruptive re-chown); explicit override via `--uidgid-remap <uid>:<gid>`
  (confirm a deliberate change re-chowns `/data` correctly). Additionally, all
  three flag spellings need their own pass: `--no-uidgid-remap` and
  `--uidgid-remap none`/`noremap`/`default` (confirm each is a true no-op —
  built-in `65532:65532` uid, no `uidgid` file written, no `usermod`/`groupmod`
  invoked); `--uidgid-remap-home` (confirm `$HOME` ends up fully owned by the
  target uid:gid and is freely writable — e.g. create/edit a file under it as
  `dockside` post-boot); the default (remapping active, home-chown not requested;
  confirm `$HOME` is left at its original ownership but still
  readable/traversable/executable by the new uid via the `Dockerfile`'s build-time
  permissions, and that nothing under `$HOME` needed write-via-ownership access that
  the default path would have silently broken). Land as its own commit/branch and
  get this fully green before starting the encryption-specific work, since
  everything else in this plan assumes `dockside` is now safe to own
  `config.json`/`users.json` directly.

### 1. Master key: generation, storage, access

With §0 in place, `dockside`'s uid:gid is no longer a collision risk, so the key can
live directly inside `config.json` as originally intended — no dedicated file, no
change to `Data.pm`'s hot-reload registry, no `docker-event-daemon` changes.

- New `config.json` field: `$CONFIG->{'secrets'}{'key'}` — a base64-encoded 256-bit
  random key.
- `app/scripts/entrypoint.sh`:
  - Extend `init_config()` (currently generates `uidCookie.salt`/`name`, lines ~40-51)
    to also generate the secrets key on fresh installs, in the same `jq` invocation:
    `local secretsKey="$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 -w0)"`,
    `jq '.uidCookie.salt = $salt | .uidCookie.name += $name | .secrets.key = $secretsKey' ...`.
  - Add a standalone upgrade-path check (mirroring the existing
    `if ! [ -f $DATA_DIR/config/config.json ]` pattern at lines ~466-471): if
    `config.json` exists but has no `.secrets.key` (`jq -e '.secrets.key // empty'`
    fails), generate and `jq`-set one, so existing installations get a key without
    manual operator action.
  - Add `chmod 600 $DATA_DIR/config/config.json $DATA_DIR/config/users.json
    $DATA_DIR/config/passwd` next to the existing `chown -R $USER $DATA_DIR` (line
    ~685), run unconditionally on every boot so it self-heals for upgraders.
- `app/server/lib/Data.pm`: add `$CONFIG->{'secrets'}{'key'} //= '';` alongside the
  other `config.json` defaults in the `process` sub (~lines 86-96). This is a
  defensive default only — `Util::encrypt_secret` (below) must throw rather than
  silently write plaintext if the key is empty, so a missing key fails loudly instead
  of failing open.
- No new import cycle: `Util.pm`'s existing `generate_auth_cookie_values`/
  `validate_auth_cookie` already take the key as a parameter rather than reaching
  into `Data::$CONFIG` themselves (`Util.pm:540,582`) — the new
  `encrypt_secret`/`decrypt_secret` follow the same shape. Callers that already
  import `$CONFIG` from `Data.pm` (`User.pm:9` already does) pass it in.

### 2. Crypto primitives — `app/server/lib/Util.pm`

- Add `libcrypt-cbc-perl` to the Dockerfile's apt package list (`Dockerfile:460`,
  alongside the existing `libcrypt-rijndael-perl`).
- `use Crypt::CBC;` and extend `use Digest::SHA qw(sha256_hex hmac_sha256);`
  (`Util.pm:30`).
- Derive two domain-separated subkeys from the master key rather than reusing it
  directly: `hmac_sha256($key, "dockside-secrets-enc-v1")` for encryption,
  `hmac_sha256($key, "dockside-secrets-mac-v1")` for the MAC.
- `sub encrypt_secret ($plaintext, $key)`:
  - Return `$plaintext` unchanged if it's empty/undef, or already `enc:v1:`-prefixed
    (idempotency — required so re-encrypting an already-encrypted value on every
    write, per the migration design, never double-wraps it).
  - Die if `$key` is empty (fail loud on misconfiguration).
  - `Crypt::CBC->new(-key => $enc_key, -cipher => 'Rijndael', -iv => <fresh random 16
    bytes>, -header => 'none', -padding => 'standard')`, fresh random IV every call.
  - Compute `$mac = hmac_sha256($mac_key, "v1:" . $iv . $ciphertext)`.
  - Return `"enc:v1:" . b64($iv) . ":" . b64($ciphertext) . ":" . b64($mac)`.
- `sub decrypt_secret ($value, $key)`:
  - Return `$value` unchanged if it doesn't start with `enc:v1:` (tolerates legacy
    plaintext — this is what makes lazy migration transparent to every existing
    caller).
  - Parse the three base64 segments, recompute the MAC, compare with a constant-time
    comparison (not `eq`), die on mismatch (tampered/corrupt ciphertext or wrong key)
    rather than returning garbage.
  - Decrypt and return the plaintext.
- Export both from `@EXPORT_OK` (`Util.pm:6-19`).

### 2a. Opt-out toggle

- `Data.pm`: `$CONFIG->{'secrets'}{'encryption'} //= 1;` alongside the key default
  (§1).
- `User/Manage.pm`'s `_encrypt_user_secrets` (§3) checks this flag first and, if
  falsy, returns without touching `$record` — so a disabled instance stores
  plaintext exactly as it does today. No change needed anywhere else: `decrypt_secret`
  already tolerates non-`enc:v1:` values unconditionally (required for lazy
  migration regardless of this toggle), so the read path behaves identically either
  way.

### 3. Write path — `app/server/lib/User/Manage.pm`

- Add `$CONFIG` to the existing `use Data qw($USERS_FILE $ROLES_FILE $PASSWD_FILE);`
  (line 15), and `encrypt_secret decrypt_secret` to the `use Util qw(...)` (line 16).
- New private helper `_encrypt_user_secrets ($record)`: checks
  `$CONFIG->{'secrets'}{'encryption'}` first (§2a) and returns early if disabled;
  otherwise encrypts `$record->{'gh_token'}` and every
  `$record->{'ssh'}{'keypairs'}{*}{'private'}` via
  `Util::encrypt_secret(..., $CONFIG->{'secrets'}{'key'})`, skipping empty/undef
  values.
- Call it as the last step before persisting, in all three write paths:
  `createUser` (~line 275, before `$users->{$username} = $new_user`), `updateUser`
  (~line 336, after the existing `_restore_redacted_ssh`/`_restore_redacted_gh_token`
  calls), `updateSelf` (~line 409, same position).
- **Interaction with the existing redaction round-trip logic**
  (`_restore_redacted_ssh`/`_restore_redacted_gh_token`, lines 75-100): no changes
  needed to those functions themselves. They compare the client-submitted value
  against a sentinel and, if unchanged, splice the *original stored value* (now
  ciphertext) back in verbatim — `_encrypt_user_secrets` running immediately after is
  safe only because `encrypt_secret` is idempotent on already-encrypted input (see
  §2). This idempotency is a correctness requirement, not a nicety.
- **Fix `_user_to_record`** (lines 48-61): it currently reads `$user->{'gh_token'}`
  and `$user->{'ssh'}` directly off the blessed hash, bypassing accessors. Once
  `$User::USERS` holds ciphertext (per §4), this must instead call `$user->gh_token()`
  and `$user->ssh_decrypted` so that `_sanitise_user_record`'s masking (first4/last4
  for `gh_token`, `<redacted>` for private keys) operates on real plaintext, and so
  `--sensitive` API responses continue to return genuine secrets. This is what keeps
  `test_07_ssh_keypair_private_roundtrip`/`test_08_gh_token_roundtrip` passing
  unmodified.

### 4. Read path — `app/server/lib/User.pm`

Decrypt lazily, at the point of use, **not** in `Data.pm`'s `users.json` loader or in
`User->new` — so the long-lived per-nginx-worker `$User::USERS` global keeps holding
ciphertext, same as it holds the raw record today, shrinking the plaintext-in-memory
window to just the accessor call versus the whole worker lifetime.

- Add `encrypt_secret decrypt_secret` to the existing `use Util qw(...)` (line 10).
  `$CONFIG` is already imported (line 9).
- New helper:
  ```perl
  sub ssh_decrypted ($self) {
     my $ssh = dclone( $self->{'ssh'} // {} );
     for my $kp ( values %{ $ssh->{'keypairs'} // {} } ) {
        $kp->{'private'} = Util::decrypt_secret( $kp->{'private'}, $CONFIG->{'secrets'}{'key'} )
           if defined $kp->{'private'};
     }
     return $ssh;
  }
  ```
  (`dclone` already imported, line 8.)
- `gh_token()` (line 238): `return Util::decrypt_secret( $self->{'gh_token'} // '', $CONFIG->{'secrets'}{'key'} );`
- `keypairs_all()` (line 234): `return $self->ssh_decrypted->{'keypairs'} // {};` — feeds
  `SSH_AGENT_KEYS` at `Reservation.pm:1167`.
- `keypairs($prefix)` (line 228): `return $self->ssh_decrypted->{'keypairs'}{$prefix};`
- No changes needed in `Reservation.pm`'s `exec()` itself for this part — it already
  calls these accessors (`Reservation.pm:1142`, `:1167`); they simply now do the right
  thing transparently for both legacy-plaintext and newly-encrypted records.

### 5. Bundled adjacent fixes

- **`OWNER_DETAILS` leak** — `User.pm`: delete `details_full` (lines 211-213; it has
  exactly one caller in the whole codebase). `Reservation.pm:1080`: change
  `my $user_details = encode_json($user->details_full);` to
  `my $user_details = encode_json($user->details);` — `details()` (lines 207-209)
  already returns exactly `{username, id, name, email}`, which is all
  `create_git_config` in `app/scripts/container/launch.sh:138-153` ever reads via
  `jq`.
- **Unsanitized `docker create` logging** — `Reservation.pm:958` and `:987`: wrap
  both `flog(...)` calls with `sanitize_sensitive_text($cmd)`, matching the pattern
  `run_system` already uses (`Util.pm:283`) and the one call site in `Reservation.pm`
  that already does this correctly (line 1117).
- **File permissions** — covered in §1 (`entrypoint.sh` `chmod 600` for
  `config.json`, `users.json`, `passwd`, on every boot).

## Testing

All integration-suite additions stay within `t/integration/README.md`'s hard rules
(CLI-driven only; no pre-existing/hand-seeded fixtures; no raw file writes as test
setup) — this matters here because, by construction, every write in the new design
encrypts on the way to disk, so the CLI itself can never be used to *produce* a
legacy-plaintext record to migrate from. The properties worth testing therefore
split into what the CLI can exercise and one narrow branch it structurally can't:

- `t/integration/tests/11_admin_api.py`: `test_07_ssh_keypair_private_roundtrip` and
  `test_08_gh_token_roundtrip` must keep passing unmodified — they're the regression
  gate for §3's `_user_to_record` fix (if decryption-for-masking breaks, these fail).
- New test(s) in the same file, all CLI-driven:
  - After setting a known `gh_token`/SSH private key via the CLI, read
    `/data/config/users.json` back (a verification read, not a fixture — the same
    spirit as `09_ssh.py` reading in-container state the CLI produced) and assert
    neither literal secret value appears as a substring in the raw file, and that
    the corresponding fields are `enc:v1:`-prefixed.
  - Same read-only check that `config.json`/`users.json`/`passwd` are mode `0600`.
  - Re-encryption stability: create a user with a `gh_token`/SSH key via the CLI,
    then issue two more `dockside user edit` calls that touch only an unrelated
    field (e.g. `name`) — not the secret. Assert via `--sensitive` after each edit
    that the secret still decrypts to the original value. This exercises exactly
    the "lazy migration" mechanism (`_encrypt_user_secrets` re-running, and
    `encrypt_secret`'s idempotency guard preventing double-wrapping, on every write
    regardless of which field changed) without needing to inject legacy plaintext
    by hand.
  - **Automatable via the opt-out toggle (§2a)**: `config.json` is operator
    configuration with no CLI/API surface by design (confirmed: no route exists to
    edit it remotely), so a harness-level `docker exec` edit of it is not the kind
    of raw-fixture bypass the hard rules exclude — it's the same category of
    low-level, access-gated helper `08_network.py`/`09_ssh.py`/`10_ssh_outbound.py`
    already use for actions with no CLI equivalent, editing a file the product's
    own docs already say operators manage by hand rather than product-managed data
    (`users.json`) the CLI/API exists specifically to own. Full test, local/harness
    mode only (gated like other docker-exec-dependent checks):
    1. Harness-level: flip `secrets.encryption` off in `config.json`.
    2. Via the CLI: set a `gh_token`/SSH key on a test user.
    3. Read `users.json` back; assert the value is genuinely plaintext (not
       `enc:v1:`-prefixed) — this also regression-tests the toggle itself, which
       otherwise has no coverage.
    4. Flip `secrets.encryption` back on in `config.json`.
    5. Via the CLI: edit an unrelated field (e.g. `name`) on the same user,
       triggering a write.
    6. Read `users.json` again; assert the field is now `enc:v1:`-prefixed, and
       confirm via `--sensitive` that it still decrypts to the original value.
    This exercises `decrypt_secret`'s legacy-plaintext tolerance with genuine (not
    synthetic) plaintext, and the lazy-migration-on-next-write path, end to end.
- End-to-end: launch a real devtainer with a profile that uses `ssh`/git-clone and a
  `gh_token` set, confirm `ssh-add`/`gh auth login` still succeed inside the
  container (exercises `Reservation::exec` → decrypted accessors → `launch.sh`,
  covered indirectly by existing `06_git_profile.py`/`09_ssh.py`/`10_ssh_outbound.py`
  but worth a manual run after implementation, per this repo's Perl-change testing
  requirements in CLAUDE.md — restart `nginx`/`docker-event-daemon` services first).
- Run `./test.sh` (Perl compile, ShellCheck for `entrypoint.sh`, JSON checks) after
  each stage.

## Documentation

### ADRs — two, continuing the existing `docs/adr/0001`–`0004` numbering

This work spans two genuinely distinct architectural decisions — container identity
provisioning, and secrets-at-rest encryption — each with its own alternatives and
rejected approaches worth recording, and §0 is explicitly designed to land (and be
useful) independently of §1-§5. One ADR per decision, mirroring the existing
`Context`/`Decision`/`Alternatives considered`/`Consequences` structure (see
`docs/adr/0004-ssh-tunnel-credential-exposure.md`):

- **`docs/adr/0005-dockside-uidgid-provisioning.md`** (§0). *Context*: `/data` is a
  host bind mount; `dockside`'s baked-in uid (`useradd` with no `-u`/`-g`, landing
  on ~1000 on a Debian base) risks colliding with an unrelated real host account,
  exposing every file under `/data` to that account. *Decision*: `entrypoint.sh`-
  driven provisioning — `--uidgid-remap`/`--no-uidgid-remap`/`--uidgid-remap-home`
  flags, a persisted `/data/config/uidgid` file, the resolution order (explicit
  choice → persisted → upgrade-detected → random-generated), and a `65532:65532`
  `Dockerfile` fallback for the disabled/bypassed case. *Alternatives considered and
  rejected* — record all four, they're each informative:
  1. Root-owning a dedicated `secrets.key` file, requiring a `docker-event-daemon`
     privilege-drop rework — rejected because `config.json` itself can't be
     root-owned (nginx workers re-check file readability via `-r` on every request;
     `Data.pm`'s `get_config` silently returns `undef` on EACCES, collapsing
     `$CONFIG`), `docker-event-daemon` never has a root phase to begin with
     (launched via `s6-setuidgid` from its `run` script), a considered re-exec+env-
     var handoff to solve that doesn't work (`/proc/<pid>/environ` is a static
     snapshot at `execve()` time — deleting `$ENV{...}` afterward doesn't remove it),
     and a hand-rolled in-process privilege drop risks silently losing the `docker`
     supplementary group needed for `/var/run/docker.sock` access.
  2. `root:dockside` group-readable `config.json` — rejected: doesn't close the
     read-exposure gap, since a colliding host *group* ID is exactly as arbitrary
     as a colliding *owner* ID; only removes a write-tampering risk, not the
     original one.
  3. Retiring `config.json`'s hot-reload entirely — rejected as disproportionate,
     unrelated scope; contradicts the documented "all config `.json` files
     auto-reload" behavior (`docs/README.md`) and breaks the `secrets.encryption`
     toggle's live-set property for no need.
  4. A single fixed default uid (e.g. always `65532:65532`) for every install —
     rejected as insufficient alone: it protects against colliding with an
     unrelated *human* account, but not against colliding with *other software*
     that adopts the same well-known convention for the same reason. Needs genuine
     per-install randomization for the default (no-explicit-choice) case; the fixed
     value is kept only as the disabled/bypass fallback.
  *Consequences*: the `$HOME` overlay-churn tradeoff and the two flags addressing
  it (`--uidgid-remap-home` vs. relying on already-world-readable build-time
  permissions), upgrade-path behavior (adopt the uid already in use, never a
  surprise re-chown), and the testing requirements from §0's verification list.
- **`docs/adr/0006-user-secrets-encryption-at-rest.md`** (§1-§5). *Context*:
  `gh_token`/`ssh.keypairs.*.private` stored in plaintext in `users.json`.
  *Decision*: key stored in `config.json`, `dockside`-owned — cross-reference
  ADR-0005 explicitly here, since this is only safe *because* ADR-0005 already
  closes the uid-collision risk for the whole `/data` tree; `Crypt::CBC` +
  HMAC-SHA256 envelope (`enc:v1:...`); lazy migration on next write; rotation
  explicitly deferred; a host/container-access-only `secrets.encryption` opt-out.
  *Alternatives considered and rejected*: `CryptX`/AES-GCM (heavier dependency for
  marginal gain here); hand-rolled CBC without `Crypt::CBC` (risk of a
  weak/reused IV, the exact mistake the existing cookie-cipher code already makes
  and this shouldn't repeat); a CLI/API-reachable opt-out (would hand a purely
  network-reachable, app-level `admin` role a capability — disabling at-rest
  protection — it has no business having, independent of host access); an
  explicit bulk-migration command (deferred — an admin can already force
  migration of any user today via a no-op field edit). *Consequences*: the
  bundled adjacent fixes (`OWNER_DETAILS` leak, unsanitized `docker create`
  logging, file permission tightening), and an explicit statement of what this
  does **not** solve — in-container `dockside`-level process compromise — noting
  this is consistent with, and should cite, ADR-0004's existing risk-
  proportionality stance on same-identity compromise.

### `docs/README.md`

- New short subsection (near "Getting Started"/"Setup") on container identity:
  default behavior needs no admin action (a safe uid:gid is auto-provisioned on
  first run), with a pointer to `docs/advanced-launch-options.md` and ADR-0005 for
  the full flag reference — this is the "default launch behaviour" the existing
  Quick Start (`:141-156`) doesn't currently need to change, just be supplemented.
- Update the "Setup" section's `users.json`/`passwd` bullet (`:205`) to note
  `gh_token`/SSH private keys are now encrypted at rest, and that manual edits to
  `users.json` must supply plaintext (auto-encrypted on the next server-mediated
  write, not on the manual edit itself).
- "Security" section (`:228-230`): add a line pointing to ADR-0005/ADR-0006 for
  readers wanting the full design rationale, alongside the existing
  `securing.md` link.

### `docs/advanced-launch-options.md`

- New section, **"Container identity (uid:gid)"**: concrete `docker run`/
  `docker-compose.yml` examples for the explicit-choice case
  (`--uidgid-remap <uid>:<gid>`), the disable case (`--no-uidgid-remap`, and the
  `--uidgid-remap none`/`noremap`/`default` synonyms), and the development-instance
  case (`--uidgid-remap-home`, directly referencing `CLAUDE.md`'s `mountIDE: false`
  own-IDE setups as the motivating scenario).
- New section, **"Common `--config-set` examples"** — this fills a real,
  pre-existing gap: `--config-set` has no documented usage examples anywhere in
  `docs/` today, confirmed by search. Cover at least: setting `globalCookie.secret`
  (an existing, previously-undocumented use case) and the new
  `secrets.encryption` toggle (`--config-set '.secrets.encryption = false'`) as a
  concrete, realistic example tied to this change.

### `docs/setup.md`

- `## config.json` bullet list (`:332-339`): add `secrets.key` (auto-generated,
  not intended for manual editing) and `secrets.encryption` (boolean, default
  `true`, host/container-access-only, cross-referencing ADR-0006) bullets,
  matching the existing `uidCookie`/`globalCookie` bullet style.

### `docs/developing/user-data-model.md`

- Document the `enc:v1:` at-rest envelope as sitting underneath the output-masking
  behavior this doc already documents (masking operates on the decrypted
  plaintext, unchanged); note manual `users.json` edits must supply plaintext,
  auto-encrypted on the next server-mediated write.

### `docs/upgrading.md`

- New short note: upgrading an existing instance preserves its current `dockside`
  uid:gid automatically — no `--uidgid-remap` needed, no disruption; admins who
  want to move to a freshly-generated safe identity can opt in explicitly via
  `--uidgid-remap`. Also note that any existing plaintext secrets in `users.json`
  are migrated automatically and lazily on next write, no action required.

### `docs/securing.md`

- Reviewed, no change — its scope (Docker socket access, devtainer network
  isolation) doesn't overlap with either change here.

## Sequencing (independently reviewable commits)

0. **UID/GID provisioning** (§0) — its own commit, ideally its own short-lived
   branch, landed and verified (fresh install, upgrade, explicit override) *before*
   any of the following. Everything below assumes `dockside` is now a safe identity
   to own `config.json`/`users.json` directly. Include `docs/adr/0005-...md` and
   the `docs/advanced-launch-options.md`/`docs/README.md`/`docs/upgrading.md`
   pieces that document §0 in this same commit, since they're testable together
   with no dependency on anything that follows.
1. Key generation & permissions: `entrypoint.sh` (`init_config` extension, upgrade
   check, `chmod 600`), `Data.pm` (defensive default).
2. Crypto primitives: `Util.pm` (`encrypt_secret`/`decrypt_secret`), `Dockerfile`
   (`libcrypt-cbc-perl`).
3. Write-path integration: `User/Manage.pm` (`_encrypt_user_secrets`, fixed
   `_user_to_record`).
4. Read-path integration: `User.pm` (`ssh_decrypted`, updated accessors).
5. Adjacent fixes: `Reservation.pm` (`details_full`→`details` + deletion,
   `sanitize_sensitive_text` on the two `flog` calls).
6. Tests (`t/integration/tests/11_admin_api.py`) + the remaining documentation
   from the "Documentation" section above: `docs/adr/0006-...md`, `docs/setup.md`,
   `docs/developing/user-data-model.md`, and the secrets-encryption-specific
   pieces of `docs/README.md`/`docs/advanced-launch-options.md`.

### Critical files

- `app/scripts/entrypoint.sh` — §0's uid/gid resolution, `--uidgid-remap`/
  `--no-uidgid-remap`/`--uidgid-remap-home` flag parsing (alongside the existing
  `--run-dockerd`-style flags, `:168-179`), `usermod`/`groupmod` (own commit);
  separately, §1's key generation, upgrade-path check, `chmod 600`
- `Dockerfile` — §0's `useradd -u 65532 -g 65532` fallback default; §2's
  `libcrypt-cbc-perl` dependency; no `$HOME`-permissions change needed (verified
  already world-readable/executable by default, §0)
- `app/server/lib/Util.pm` — `encrypt_secret`/`decrypt_secret`
- `app/server/lib/User/Manage.pm` — `_encrypt_user_secrets` (incl. opt-out check),
  fixed `_user_to_record`, call sites in `createUser`/`updateUser`/`updateSelf`
- `app/server/lib/User.pm` — `ssh_decrypted`, updated `gh_token()`/`keypairs()`/
  `keypairs_all()`, deleted `details_full`
- `app/server/lib/Reservation.pm` — `details_full`→`details` (line 1080),
  `sanitize_sensitive_text` wrapping (lines 958, 987)
- `app/server/lib/Data.pm` — `$CONFIG->{'secrets'}{'key'} //= ''` /
  `$CONFIG->{'secrets'}{'encryption'} //= 1` defaults
- `t/integration/tests/11_admin_api.py` — new tests
- `docs/adr/0005-dockside-uidgid-provisioning.md`,
  `docs/adr/0006-user-secrets-encryption-at-rest.md` — new ADRs (see
  "Documentation" above)
- `docs/README.md`, `docs/advanced-launch-options.md`, `docs/setup.md`,
  `docs/developing/user-data-model.md`, `docs/upgrading.md` — documentation
  updates (see "Documentation" above for the specific change to each)
