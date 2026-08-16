# SSH-only devtainers (no IDE)

By default every devtainer runs a full browser IDE (Theia or OpenVSCode) alongside SSH access.
On resource-constrained hosts — for example some Raspberry Pi boards — running the IDE is the
single biggest RAM/CPU cost Dockside imposes. If you only need SSH access to a devtainer, you can
disable the IDE entirely, globally or per profile, and let developers connect via
[SSH](ssh.md) instead.

## Disabling IDE globally

Dockside enables the IDE by default for all new devcontainers. To disable it globally, set
`"ide": { "default": false }` in `config.json`. To disable it in an individual profile, set
`"ide": false` in the profile. Either way, a profile with the IDE switched off resolves its `IDEs`
list to `["none"]` regardless of whatever real IDE patterns it configured, and no `ide` router is
added — the devtainer never spends any resources launching an IDE.

For maximum resource savings on a constrained host, combine this with SSH access — see
[Integrated SSH server support](ssh.md).

## Offering a choice between IDE and no IDE

A profile can also offer developers a *choice*, rather than forcing IDE off for everyone. Add the
literal string `"none"` to the profile's `IDEs` list alongside real IDE identifiers:

```json
"IDEs": ["theia/latest", "openvscode/latest", "none"]
```

`"none"` is never auto-discovered or implied by `["*"]` — a profile author must list it explicitly.
It is never chosen as an implicit default either: `"none"` is always the last resort in a profile's
resolved `IDEs` list, so a devtainer launched with no `--ide` specified always gets a real IDE if
one is available, never `"none"`, by surprise.

When a profile offers both `"none"` and a real IDE, the devtainer's `ide` router is still created
even for a devtainer launched with `--ide none`. This is deliberate: Dockside cannot add a router to
an existing devtainer's reservation after launch, so the route needs to already exist in case a
developer picks a real IDE later. See "Enabling an IDE later" below.

## Permission model

`"none"` is treated exactly like any other IDE identifier for role/user permission purposes. If a
role or user already has `resources.IDEs: ["*"]` (the default for new users), that grant already
covers `"none"` the moment a profile offers it — no separate configuration is needed. To deny a
specific role or user the ability to choose `"none"` while still allowing real IDEs, deny it
explicitly:

```json
"resources": { "IDEs": { "*": 1, "none": 0 } }
```

"Explicit allow" for `"none"` is enforced at the profile level: an admin must deliberately add
`"none"` to a profile's `IDEs` (or disable `ide` entirely) before any user can select it — it is
never available "by accident."

## Enabling an IDE later

A devtainer launched with `--ide none` can get a real IDE later:

```sh
dockside edit my-devtainer --ide theia/latest
```

This updates the devtainer's stored IDE choice immediately, but — because there is no live
in-place IDE switch — does not start the IDE in an already-running devtainer. Stop and start the
devtainer for the change to take effect:

```sh
dockside stop my-devtainer
dockside start my-devtainer
```

## Command-line usage

```sh
# Launch with no IDE (only valid if the profile, your user, and your role all permit it)
dockside create --profile my-profile --ide none

# Switch back to a real IDE later (see "Enabling an IDE later" above)
dockside edit my-devtainer --ide openvscode/latest
```
