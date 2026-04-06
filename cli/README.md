# Dockside CLI

A command-line interface for managing [Dockside](https://github.com/newsnowlabs/dockside)
devtainers. It uses the same HTTP API as the Dockside web frontend.

**Zero external dependencies**. Requires only Python 3.6+ and the standard library.

## Installation

### Direct use

```sh
# Run directly from the repo:
python3 cli/dockside_cli.py --help

# Or use the launcher script:
chmod +x cli/dockside
./cli/dockside --help
```

### Install with pip

```sh
pip install ./cli
```

## Quick start

```sh
# Authenticate once for interactive use
dockside login --server https://www.local.dockside.dev --nickname local

# Manage multiple servers
dockside login --server https://www.staging.dockside.example.com --nickname staging
dockside server list
dockside server use local

# Create and inspect a devtainer
dockside create --profile default --name my-feature --image ubuntu:22.04 \
    --git-url https://github.com/org/repo
dockside list
dockside list -o json
dockside get my-feature
dockside get my-feature -o json

# Operate on the devtainer
dockside start my-feature
dockside stop my-feature
dockside edit my-feature --description "Feature branch X" --viewers carol
dockside ssh my-feature
dockside ssh proxy-command my-feature
dockside remove my-feature --force

# Manage users and profiles
dockside user list
dockside profile list
```

## Dev container management

Typical commands:

```sh
dockside list -o json
dockside list --urls
dockside get my-feature -o json
dockside create --profile myprofile --name my-feature --image ubuntu:22.04 \
    --git-url https://github.com/org/repo --developers alice,role:backend
dockside edit my-feature --description "PR #42" --viewers bob
dockside start my-feature
dockside stop my-feature
dockside remove my-feature --force
dockside logs my-feature
dockside logs my-feature --raw
dockside check-url https://www-my-feature.example.com/
dockside ssh my-feature
dockside ssh proxy-command my-feature
```

| Subcommand | Purpose |
|------------|---------|
| `list` (`ls`) | List accessible devtainers |
| `get` | Show one devtainer in detail |
| `create` | Create and launch a devtainer |
| `edit` | Edit mutable devtainer metadata |
| `start` | Start a stopped devtainer |
| `stop` | Stop a running devtainer |
| `remove` (`rm`, `delete`) | Remove a devtainer |
| `logs` | Retrieve devtainer logs |
| `check-url` | Fetch a routed URL using the current session |
| `ssh` | Connect to a devtainer SSH router using the CLI’s resolved transport/auth path |
| `ssh proxy-command` | Print a `wstunnel`-based `ProxyCommand` for a devtainer SSH router |
| `whoami` | Show the authenticated user and effective permissions |

### Addressing devtainers

The `DEVTAINER` argument accepts:

- a container name such as `my-feature`
- a reservation ID
- a Docker container ID, or an unambiguous prefix of one

### `create`

```sh
dockside create --profile default --name my-feature --image ubuntu:22.04
dockside create --profile default --name my-feature --from-json create.json
```

All launch-time fields exposed by the CLI are accepted either as flags, via
`--from-json`, or both. Flags override JSON values.

| Flag | API field | Notes | Editable after launch |
|------|-----------|-------|-----------------------|
| `--name` | `name` | Lowercase letters, digits, hyphens | No |
| `--profile` | `profile` | Required unless supplied in `--from-json` | No |
| `--image` | `image` | e.g. `ubuntu:22.04` | No |
| `--runtime` | `runtime` | e.g. `runc`, `sysbox-runc` | No |
| `--unixuser` | `unixuser` | Unix user inside the container | No |
| `--git-url` | `gitURL` | Git repo to clone on launch | No |
| `--options JSON` | `options` | Profile-specific launch options | No |
| `--network` | `network` | Docker network name | Yes |
| `--ide` | `IDE` | IDE image/tag | Yes |
| `--description` | `description` | Free-text description | Yes |
| `--viewers` | `viewers` | Comma-separated users / `role:NAME` entries | Yes |
| `--developers` | `developers` | Comma-separated users / `role:NAME` entries | Yes |
| `--private` / `--no-private` | `private` | Visibility to other admins | Yes |
| `--access JSON` | `access` | Per-router access map | Yes |
| `--from-json FILE`| `-` | `–` | Read creation params from JSON | N/A |

For the exact flag surface, defaults, and wait options, use:

```sh
dockside create --help
```

### `edit`

```sh
dockside edit my-feature --description "Feature branch X"
dockside edit my-feature --from-json edit.json
```

Editable fields are:

- `--network`
- `--ide`
- `--description`
- `--viewers`
- `--developers`
- `--private` / `--no-private`
- `--access`

Fields fixed at launch time such as `name`, `profile`, `image`, `runtime`,
`unixuser`, and `git-url` cannot be changed after creation.

For the full syntax, use:

```sh
dockside edit --help
```

### Waiting behaviour

By default, `create`, `start`, `stop`, and `remove` poll until the requested
state is observed or the timeout expires.

```sh
dockside create --profile ci --name my-pr --no-wait
dockside stop my-feature --timeout 60
```

### `logs`

`dockside logs` strips ANSI escape sequences and dangerous control characters
by default. Use `--raw` to preserve the original terminal output when you trust
the source.

### SSH routing

```sh
dockside ssh my-feature
dockside ssh my-feature -- echo hello
dockside ssh proxy-command my-feature
dockside ssh proxy-command my-feature -o json
```

`dockside ssh` connects to a devtainer SSH router using the CLI's current
server configuration and authentication path. This lets the CLI resolve the
effective websocket target, cookie header path, and nest level before handing
off to OpenSSH.

`dockside ssh proxy-command` exposes the lower-level `ProxyCommand` string used
by that flow. It is useful for:

- generating an `ssh_config` `ProxyCommand`
- debugging nested or proxied Dockside SSH routing
- inspecting the effective websocket target, cookie header path, and nest level

For structured debugging output, prefer:

```sh
dockside ssh proxy-command my-feature -o json
```

## User and role management

These commands require `manageUsers` permission.

```sh
# Users
dockside user list -o json
dockside user get alice -o json
dockside user create alice --email alice@example.com --role developer --user-password s3cret
dockside user edit alice --set resources.profiles='["myprofile","ci"]'
dockside user remove alice --force

# Roles
dockside role list -o json
dockside role get developer -o json
dockside role create developer --set permissions.createContainerReservation=1
dockside role edit developer --set permissions.stopContainer=1
dockside role remove developer --force
```

| Subcommand | Purpose |
|------------|---------|
| `user list` (`ls`) | List users |
| `user get` | Show one user |
| `user create` | Create a user |
| `user edit` | Edit a user |
| `user remove` (`rm`, `delete`) | Remove a user |
| `role list` (`ls`) | List roles |
| `role get` | Show one role |
| `role create` | Create a role |
| `role edit` | Edit a role |
| `role remove` (`rm`, `delete`) | Remove a role |

### `user create`

Use simple flags for common top-level fields and `--set KEY=VALUE` for nested
properties.

```sh
dockside user create alice \
    --email alice@example.com \
    --role developer \
    --user-password s3cret

dockside user create alice \
    --set resources.profiles='["*"]' \
    --set permissions.createContainerReservation=1
```

Useful flags:

- `--email`
- `--role`
- `--name`
- `--user-password`
- `--gh-token`
- `--permissions JSON`
- `--resources JSON`
- `--ssh JSON`
- `--set KEY=VALUE`
- `--unset KEY`
- `--from-json FILE|-`

### `user edit`

`user edit` supports the same field shapes as `user create`, plus:

- `--sensitive` on `user get` / `user edit` output paths when you need to
  include private keys and `gh_token`

Typical nested edits:

```sh
dockside user edit alice --gh-token github_pat_xxx
dockside user edit alice --set ssh.publicKeys.laptop=@~/.ssh/id_ed25519.pub
dockside user edit alice --set ssh.keypairs.*.public=@~/.ssh/id_ed25519.pub
dockside user edit alice --set ssh.keypairs.*.private=@~/.ssh/id_ed25519
dockside user edit alice --unset ssh.publicKeys.oldkey
```

For full syntax:

```sh
dockside user create --help
dockside user edit --help
```

### `role create`

Roles are typically created either from JSON or with `--set`:

```sh
dockside role create developer \
    --set permissions.createContainerReservation=1 \
    --set resources.profiles='["*"]'
```

Useful flags:

- `--permissions JSON`
- `--resources JSON`
- `--set KEY=VALUE`
- `--unset KEY`
- `--from-json FILE|-`

### `role edit`

```sh
dockside role edit developer --set permissions.stopContainer=1
```

For full syntax:

```sh
dockside role create --help
dockside role edit --help
```

## Profile management

These commands require `manageProfiles` permission.

```sh
dockside profile list -o json
dockside profile get debian-dev -o json
dockside profile create myteam --from-json profile.json
dockside profile edit myteam --set name="My Team"
dockside profile rename myteam myteam-v2
dockside profile remove myteam-v2 --force
```

| Subcommand | Purpose |
|------------|---------|
| `profile list` (`ls`) | List profiles |
| `profile get` | Show one profile record |
| `profile create` | Create a profile |
| `profile edit` | Edit a profile |
| `profile remove` (`rm`, `delete`) | Remove a profile |
| `profile rename` | Rename a profile ID / file-stem |

### `profile create`

Profiles can be created from a full JSON record or assembled with `--set`:

```sh
dockside profile create myteam --from-json profile.json
dockside profile create myteam --set name="My Team" --active
```

Key points:

- `PROFILE` is the unique file-stem ID used in `dockside create --profile ...`
- the JSON `name` display field defaults to the profile ID if omitted
- new profiles are inactive by default unless `--active` is supplied

Useful flags:

- `--active` / `--no-active`
- `--set KEY=VALUE`
- `--unset KEY`
- `--from-json FILE|-`

### `profile edit`

```sh
dockside profile edit myteam --set images='["ubuntu:*"]'
dockside profile edit myteam --no-active
```

For full syntax:

```sh
dockside profile create --help
dockside profile edit --help
```

## CI and scripting

For non-interactive use, pass credentials via flags or environment variables on
every invocation instead of relying on a stored session:

```sh
DOCKSIDE_SERVER=https://www.local.dockside.dev \
DOCKSIDE_USER=ci \
DOCKSIDE_PASSWORD=secret \
dockside create \
    --profile ci \
    --name pr-${{ github.event.pull_request.number }} \
    --image ubuntu:22.04 \
    --no-wait \
    --output json
```

JSON input works well in scripts:

```sh
echo '{"profile":"ci","name":"pr-123","image":"ubuntu:22.04"}' | \
  dockside create --from-json -

dockside edit test --from-json - < <(echo '{"description": "A devtainer for testing Project Beta"}')
```

## Appendix: Server configuration

### Multi-server configuration

The CLI supports multiple Dockside servers. Each server is stored in
`config.json` with an optional nickname.

```sh
dockside login --server https://prod.dockside.io --nickname prod
dockside login --server https://staging.dockside.io --nickname staging

dockside server list
dockside server use staging

dockside list --server prod
dockside get my-devtainer --server https://prod.dockside.io
```

Old single-server configurations are migrated automatically on first read.

### Developing Dockside in Dockside

If you use Dockside to host another Dockside instance, register the inner
server with a `parent` pointing at the outer one:

```sh
dockside login --server https://www.outer.example.com --nickname outer
dockside login --server https://www-inner--outer.example.com \
    --nickname inner \
    --parent outer
```

When a server entry has a `parent`, the CLI merges ancestor session cookies in
memory when talking to the child server. This is the recommended model for
nested Dockside instances; use it instead of sharing one cookie file between
inner and outer servers.

### Login options

Authenticate once for interactive use:

```sh
dockside login --server https://www.local.dockside.dev --nickname local
```

Some servers require extra cookies before login:

```sh
dockside login --server https://www.local.dockside.dev \
    --cookie globalCookie=secret \
    --cookie anotherCookie=value
```

`--cookie-file` can override the per-server target session filename:

```sh
dockside login --server https://inner.dockside.io --cookie-file inner-session
```

For local or nested setups where the canonical hostname is not directly
reachable, `--connect-to` and `--no-verify` are often useful:

```sh
dockside login \
    --server https://www.local.dockside.dev \
    --connect-to 127.0.0.1 \
    --no-verify \
    --nickname local
```

For HTTP service debugging, `dockside check-url URL --debug-http` prints the
resolved URL, effective transport target, and low-level connection failures.

## Appendix: Global flags

Most authenticated commands share these flags:

| Flag | Env var | Purpose |
|------|---------|---------|
| `--server URL_OR_NICKNAME` | `DOCKSIDE_SERVER` | Target server |
| `--username USER` | `DOCKSIDE_USER` | One-shot auth username |
| `--password PASS` | `DOCKSIDE_PASSWORD` | One-shot auth password |
| `--output FORMAT` | – | `text`, `json`, or `yaml` |
| `--no-verify` | – | Skip TLS certificate verification |
| `--host-header HOST` | `DOCKSIDE_HOST_HEADER` | Override the HTTP Host header |
| `--connect-to HOST[:PORT]` | `DOCKSIDE_CONNECT_TO` | Override only the TCP target |
| `--cookie-file PATH` | – | Override the target server’s session cookie file |
| `--cookie-auth MODE` | – | Cookie loading mode (`all` or `ancestors-only`) |
| `--debug-http` | – | Print raw HTTP diagnostics where supported |

For exact availability on a specific command, use:

```sh
dockside <command> --help
```

## Appendix: Output formats

```sh
dockside list
dockside list -o json
dockside list -o yaml
dockside list -o json | jq '.[].name'
```

The default output format may also be stored per server at login time.

## Appendix: Session storage

```text
~/.config/dockside/
  config.json
  cookies/
    <slug>.txt
```

The cookie-file slug is derived from the server nickname or URL hostname unless
overridden by `cookie_file` in `config.json`.

Override the config directory with:

```sh
DOCKSIDE_CONFIG_DIR=/path/to/dir
```

## Appendix: How the integration tests use the CLI

The integration harness drives Dockside almost entirely through the CLI, so the
CLI doubles as both a user-facing tool and the test transport layer.

Current test-harness pattern:

- admin operations usually use a pre-authenticated stored session
- named test-user operations pass explicit `--username` / `--password`
- those same test-user operations also pass a dedicated `--cookie-file` per
  test user so the target-server session is isolated from the normal system
  cookie store
- target-anonymous router checks use `check-url` with an empty dedicated
  `--cookie-file` and no target credentials, so the request is anonymous to the
  target server while still using the normal CLI transport path

This is especially important for nested or outer-proxied Dockside deployments:

- ancestor cookies may still need to flow through the CLI’s normal auth path so
  the request can traverse outer Dockside layers
- a plain no-cookie HTTP probe is often not representative of how a real routed
  request reaches the target instance

`--cookie-auth ancestors-only` still exists in the CLI as an advanced mode, but
the integration tests now prefer isolated `--cookie-file` paths as the normal
way to achieve target-session isolation.

If you are debugging test behavior, the most relevant commands are usually:

```sh
dockside list -o json
dockside get my-devtainer -o json
dockside check-url URL -o json
dockside check-url URL --debug-http
dockside ssh proxy-command my-devtainer -o json
```

## Appendix: Security

- `DOCKSIDE_CONFIG_DIR` is validated to reject empty paths, null bytes, path
  traversal, and symlinks.
- Config and cookie file writes use atomic temp-file + `os.replace()`.
- Cookie filenames supplied via `--cookie-file` are sanitised.
- `http://` server URLs are upgraded to `https://`.
