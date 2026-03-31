# User and profile data model: key conventions

This document captures the architectural distinctions that are easy to
conflate when working on the admin UI, account self-service, or any code
that reads or writes user/profile state. Getting these wrong causes
security bugs, stale identity, and broken API routing.

---

## 1. Two distinct data shapes for user records

The same underlying user record is represented in two different shapes
depending on who is reading it and why.

### Admin / CRUD shape (verbatim stored record)

Returned by `GET /users/:name`, `GET /users`, and all mutation responses
(`POST /users/create`, `POST /users/:name/update`).

```json
{
  "username": "alice",
  "role": "developer",
  "permissions": { "createContainerReservation": "1", "viewAllContainers": "0" },
  "resources":   { "profiles": ["*"], "runtimes": ["runc"], "IDEs": ["*"] },
  "name":        "Alice Example",
  "email":       "alice@example.com",
  "gh_token":    "ghp_****cdef",
  "ssh": {
    "authorized_keys": [],
    "keypairs": { "my-key": { "public": "ssh-ed25519 AAAA...", "private": "<redacted>" } }
  }
}
```

- `permissions` values are **strings** `"1"` / `"0"`, not booleans.
- `permissions` contains only the **explicit overrides** stored for this
  user — it does not reflect role-inherited permissions.
- `resources` contains the user's specific resource constraints (may be
  empty `{}` meaning "inherit from role").
- `gh_token` and SSH private keys are **masked by default**. The raw
  values are only returned when the caller passes `sensitive=1` as a
  query parameter — this is intentional for the CLI, which needs the
  real values for operations like cloning with SSH. The web UI does not
  (and should not) pass `sensitive=1`.

### Session / bootstrap shape (derived record)

Returned by `GET /me` (`getSelf`) and injected at page load as
`window.dockside.user`.

```json
{
  "username":     "alice",
  "role":         "developer",
  "role_as_meta": "role:developer",
  "permissions":  { "actions": { "createContainerReservation": true, "viewAllContainers": false, ... } },
  "resources":    { "profiles": ["*"], "runtimes": ["runc"], "IDEs": ["*"] },
  "name":         "Alice Example",
  "email":        "alice@example.com",
  "gh_token":     "ghp_****cdef"
}
```

- `permissions` is nested under an `actions` key and values are **booleans**.
- `permissions.actions` reflects **fully derived** effective permissions:
  role permissions merged with user overrides, then resolved to true/false.
- `role_as_meta` is derived from `role` as `"role:" + role` — used for
  container sharing filters.
- `gh_token` and SSH private keys are **always masked** — `getSelf` and
  `updateSelf` never accept or honour the `sensitive` flag.
- Consumers of this shape must never assume it matches the CRUD shape.

### Why they differ

`getSelf` calls `_user_to_record` + `_sanitise_user_record` (CRUD shape),
then **overrides** `permissions` and adds `role_as_meta`:

```perl
my $record = _sanitise_user_record(_user_to_record($user));
$record->{'role_as_meta'} = $user->role_as_meta;
$record->{'permissions'}  = { 'actions' => $user->permissions() };
```

`$user->permissions()` returns derived booleans by merging the role's
`permissions` hash with the user's override hash, then evaluating each
key to true/false. This derivation happens server-side; the client must
never reimplement it.

---

## 2. Two independent server API surfaces

### Admin API — requires `manageUsers` or `manageProfiles`

| Method | Route | Returns |
|--------|-------|---------|
| GET    | `/users`                    | All users, verbatim CRUD shape |
| GET    | `/users/:name`              | One user, verbatim CRUD shape |
| POST   | `/users/create`             | Create user, verbatim CRUD shape |
| POST   | `/users/:name/update`       | Update user, verbatim CRUD shape |
| GET    | `/users/:name/remove`       | Remove user (see note on GET mutations below) |
| GET    | `/roles`                    | All roles, verbatim |
| GET    | `/roles/:name`              | One role, verbatim |
| POST   | `/roles/create`             | Create role, verbatim |
| POST   | `/roles/:name/update`       | Update role, verbatim |
| GET    | `/roles/:name/remove`       | Remove role |
| GET    | `/profiles`                 | All profiles, verbatim |
| GET    | `/profiles/:name`           | One profile, verbatim |
| POST   | `/profiles/create`          | Create profile, verbatim |
| POST   | `/profiles/:name/update`    | Update profile, verbatim |
| GET    | `/profiles/:name/remove`    | Remove profile |
| GET    | `/profiles/:name/rename`    | Rename profile |
| GET    | `/resources`                | Host runtimes, networks, IDEs, auth modes, verbatim |

**Note on GET for remove/rename:** These endpoints are currently
implemented as GETs for historical simplicity. This violates HTTP
semantics — mutations should use POST (or DELETE). They should be
migrated to POST when the opportunity arises; until then, callers must
not assume they are idempotent or cacheable.

### Self-service account API — any authenticated user

| Method | Route | Returns |
|--------|-------|---------|
| GET    | `/me`             | Session user, derived/bootstrap shape |
| POST   | `/me/update`      | Session user after update, derived/bootstrap shape |
| GET    | `/me/profiles`    | Profiles accessible to session user (launch cache) |

`POST /me/update` accepts only the user's **own editable fields**: `name`,
`email`, `gh_token`, `ssh`. It does not accept `role`, `permissions`, or
`resources` — those are admin-only writes via `/users/:name/update`. The
response is in the derived/bootstrap shape: `permissions.actions` reflects
the user's effective permissions after the edit, but the editable fields
themselves are not derived — only the response _format_ matches the
bootstrap shape.

`GET /me` returns the same shape as `window.dockside.user`. After any
self-edit, always re-read identity via `GET /me`, never from the admin
CRUD response — they have different shapes and the admin response does
not include derived permissions.

### URL routing note

App.pm serves the SPA HTML for routes matching `^/(container|admin|account)(/|$)`.
**Do not place JSON API routes under `/account/`, `/admin/`, or `/container/`** —
they will be shadowed by the HTML handler and return HTML 200 instead of
JSON. The self-service API lives under `/me/` precisely to avoid this.

---

## 3. Client Vuex store structure

```
store (root)          — containers, UI selection, filter state only
├── account/          — session user identity and launch profiles
│   ├── currentUser   — derived/bootstrap shape (mirrors window.dockside.user)
│   ├── launchProfiles— accessible launch profiles (from GET /me/profiles)
│   └── accountError  — surfaced on /account page only
└── admin/            — management state, requires admin permissions
    ├── users         — verbatim CRUD shape (from GET /users)
    ├── roles         — verbatim role records
    ├── profiles      — verbatim profile records (from GET /profiles)
    └── error         — surfaced on /admin/* pages only
```

`account.currentUser` is the **single source of truth** for live identity
checks (permissions, role, display name). The bootstrap global
`window.dockside.user` is only read once, at store initialisation.

`admin.users` and `account.currentUser` **can coexist** for the same
person but hold different shapes. Never read identity from `admin.users`.

---

## 4. Cross-refresh triggers

When a mutation in one domain affects state in the other, the store
action must trigger a refresh:

| Triggering action | Must also dispatch |
|-------------------|--------------------|
| `admin/updateUser` (editing self) | `account/fetchSelf` — derived identity may have changed |
| `admin/createProfile`, `updateProfile`, `removeProfile`, `renameProfile` | `account/fetchLaunchProfiles` — accessible profiles may have changed |
| `account/updateSelf` (if user has `manageUsers`) | `admin/fetchUsers` — admin list is now stale |

Dispatching into a sibling module uses `{ root: true }`:
```js
dispatch('account/fetchSelf', null, { root: true });
```

Without `{ root: true }`, Vuex resolves the name within the current
module's namespace.

---

## 5. `role_as_meta` must never go stale

Container sharing filters in `mixins/index.js` match against
`container.meta.developers` and `container.meta.viewers` using both
`username` and `role_as_meta` (e.g. `"role:developer"`). If a user's
role is edited and `role_as_meta` is not updated in the store, the
shared-container view silently shows wrong results.

`role_as_meta` is derived in the `setCurrentUser` mutation:
```js
if (patch.role !== undefined) {
  merged.role_as_meta = patch.role ? ('role:' + patch.role) : undefined;
}
```

Any code path that updates `account.currentUser` must go through
`setCurrentUser`, not a direct state assignment.

---

## 6. New user / role form defaults

The new-user form must initialise `resources: {}` and `permissions: {}`.

- `resources: {}` means "no user-specific constraints; inherit from role".
  Pre-filling with `['*']` wildcards sends them to the server on create
  and grants the new user unrestricted access to all resource types,
  overriding the server's safe `{}` default.
- `permissions: {}` means "no user-specific overrides; inherit from role".
  This is correct: the role defines baseline capabilities.

If an admin wants to grant specific users more or less than their role
provides, they do so by editing the user record explicitly — the form
blank-slate should never grant anything implicitly.

---

## 7. Sensitive data must never appear in URLs

User mutations (create, update) can include passwords, `gh_token`, and
SSH private keys. These must be sent as POST bodies, not query-string
parameters. Query strings appear in:

- Server access logs
- Browser history
- Proxy logs
- Shell history (when using curl/CLI)

All mutation endpoints (`/users/create`, `/users/:name/update`,
`/profiles/create`, `/profiles/:name/update`) accept
`application/x-www-form-urlencoded` POST bodies via
`get_args($r, $querystring)`. The CLI uses `_do_post()` for all mutation
calls; the web client uses `axios.post()`.

---

## 8. Reserved identifiers

`"new"` is the current UI sentinel for the create-form route
(`/admin/users/new`, `/admin/profiles/new`, etc.). The server rejects
creation of any user, role, or profile with that exact identifier,
otherwise clicking the real record in the sidebar opens the create form
instead.

Reserved at server level:
- Users: `createUser` rejects `username eq 'new'`
- Roles: `createRole` rejects `name eq 'new'`
- Profiles: `%RESERVED_NAMES` includes `'new'`

**Recommendation:** Consider replacing `"new"` with a sentinel that
contains a character not permitted in entity names, such as `:new`. A
leading colon is valid in a URL path segment but would never appear in a
legitimate username, role name, or profile name under any reasonable
naming convention. This would eliminate the need to reserve a common
English word server-side, and future entity names like `"news"` or
`"newuser"` would not risk confusion (they are already fine — only the
exact string `"new"` is reserved — but the principle still applies as
the set of reserved words grows). A non-alphanumeric sentinel removes the
ambiguity entirely.
