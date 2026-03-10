# Dockside CLI

A command-line interface for managing [Dockside](https://github.com/newsnowlabs/dockside)
devtainers. Uses the same HTTP API as the Dockside web frontend.

**Zero external dependencies** – requires only Python 3.6+ (standard library only).

## Installation

### Direct use (no install needed)

```sh
# Clone the repo and run directly:
python3 cli/dockside_cli.py --help

# Or use the launcher script after making it executable:
chmod +x cli/dockside
./cli/dockside --help
```

### Install with pip (adds `dockside` to PATH)

```sh
pip install ./cli
# or, to install from the repo root:
pip install dockside-cli   # once published to PyPI
```

## Quick start

```sh
# Authenticate (saves session to ~/.config/dockside/)
dockside login --server https://www.local.dockside.dev --nickname local

# Manage multiple servers
dockside login --server https://www.staging.dockside.example.com --nickname staging
dockside server list
dockside server use local

# List devtainers
dockside list
dockside list --urls          # add per-router URL columns (IDE, SSH, WWW, …)

# Show devtainer details (includes per-router URLs)
dockside get my-feature

# Create a devtainer and wait for it to start
dockside create --profile myprofile --name my-feature --image ubuntu:22.04 \
    --git-url https://github.com/org/repo --developers alice,role:backend

# Start / stop / remove
dockside start  my-feature
dockside stop   my-feature
dockside remove my-feature --force
dockside remove my-feature --force

# View logs (ANSI escape sequences are stripped by default)
dockside logs my-feature
dockside logs my-feature --raw   # preserve raw terminal output

# Edit metadata
dockside edit my-feature --description "Feature branch X" --viewers carol
```

## CI / GitHub Actions (no stored session)

Pass credentials via flags or environment variables on every invocation:

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

Or supply them from a JSON file:

```sh
echo '{"profile":"ci","name":"pr-123","image":"ubuntu:22.04"}' | \
  dockside create --from-json -
```

## Commands

| Command | Description |
|---------|-------------|
| `login`        | Authenticate and save session cookie |
| `logout`       | Clear saved session for the current (or `--server`) server |
| `logout --all` | Clear all saved sessions and remove config |
| `server list`  | List all configured servers |
| `server use`   | Set the current default server |
| `list`         | List all accessible devtainers |
| `get`          | Show details of a specific devtainer |
| `create`       | Create and launch a new devtainer |
| `start`        | Start a stopped devtainer |
| `stop`         | Stop a running devtainer |
| `edit`         | Edit devtainer metadata |
| `remove`       | Remove a devtainer (aliases: `rm`, `delete`) |
| `logs`         | Retrieve devtainer logs |

## Addressing devtainers

The `DEVTAINER` argument accepts:
- Container **name** (e.g. `my-feature`)
- **Reservation ID** (hex string from `dockside get`)
- **Docker container ID** (full or unambiguous prefix)

## Multi-server configuration

The CLI supports multiple Dockside servers. Each server is stored in
`config.json` with an optional nickname.

```sh
# Add servers with nicknames
dockside login --server https://prod.dockside.io --nickname prod
dockside login --server https://staging.dockside.io --nickname staging

# List configured servers
dockside server list

# Switch the active default
dockside server use staging

# Target a specific server on any command (by nickname or URL)
dockside list --server prod
dockside get my-devtainer --server https://prod.dockside.io
```

Old single-server configurations (from CLI v0.1) are migrated transparently
on first read.

## Login options

### Extra cookies (`--cookie`)

Some Dockside servers require a global cookie for access. Use `--cookie`
(repeatable) to inject additional cookies before the login POST:

```sh
dockside login --server https://www.local.dockside.dev \
    --cookie globalCookie=secret \
    --cookie anotherCookie=value
```

### Cookie file override (`--cookie-file`)

By default, each server's session is stored in
`~/.config/dockside/cookies/<slug>.txt` (derived from the nickname or
hostname). Use `--cookie-file` to override the filename:

```sh
dockside login --server https://inner.dockside.io --cookie-file outer-server
```

This is persisted in `config.json` so subsequent commands reuse the same file.
It enables nested Dockside servers to share cookies — the inner server can
reuse the outer server's cookie file by name.

Cookie filenames are validated: only letters, digits, hyphens, underscores,
and dots are allowed; path separators, traversal, null bytes, and names
longer than 128 characters are rejected. A `.txt` suffix is added
automatically if not present.

## Output formats

```sh
dockside list                  # text table (default)
dockside list -o json          # JSON array
dockside list -o yaml          # YAML
dockside list -o json | jq '.[].name'
```

The default output format can be set per-server at login time
(`dockside login --output json`) and is stored in `config.json`.

## Waiting behaviour

By default `create`, `start`, `stop`, and `remove` poll the API until the
requested state is confirmed (or until `--timeout` seconds elapse).

```sh
dockside create --profile ci --name my-pr --no-wait    # fire and forget
dockside stop   my-feature --timeout 60                # custom timeout
```

## Global flags

These flags are available on all authenticated commands (`list`, `get`,
`create`, `start`, `stop`, `edit`, `remove`, `logs`):

| Flag | Env var | Description |
|------|---------|-------------|
| `--server URL_OR_NICKNAME` | `DOCKSIDE_SERVER` | Target server (URL or configured nickname) |
| `--username USER` | `DOCKSIDE_USER` | Username (one-shot auth) |
| `--password PASS` | `DOCKSIDE_PASSWORD` | Password (one-shot auth) |
| `--output FORMAT` | – | `text` \| `json` \| `yaml` |
| `--no-verify` | – | Skip SSL certificate verification |

## Session storage

```
~/.config/dockside/
  config.json          # server list, current server, output format
  cookies/
    <slug>.txt         # per-server session cookies (mode 0600)
```

The slug is derived from the server's nickname or URL hostname. A
`cookie_file` override in `config.json` changes the filename used.

Override the config directory with `DOCKSIDE_CONFIG_DIR=/path/to/dir`.

## `create` fields

All fields available in the Dockside web form are supported:

| Flag | API field | Notes | Editable |
|------|-----------|-------|----------|
| `--name` | `name` | Lowercase letters, digits, hyphens | No |
| `--profile` | `profile` | **Required** | No |
| `--image` | `image` | Docker image (e.g. `ubuntu:22.04`) | No |
| `--runtime` | `runtime` | e.g. `runc`, `sysbox-runc` | No |
| `--unixuser` | `unixuser` | Unix user inside the container | No |
| `--git-url` | `gitURL` | Git repo to clone on launch | No |
| `--ide` | `IDE` | e.g. `theia/latest`, `openvscode/latest` | Yes (effective on reboot) |
| `--network` | `network` | Docker network name | Yes |
| `--description` | `description` | Free-text description | Yes |
| `--viewers` | `viewers` | Comma-separated users/roles | Yes |
| `--developers` | `developers` | Comma-separated users/roles | Yes |
| `--private` | `private` | Hide from other admins | Yes |
| `--access JSON` | `access` | e.g. `'{"ssh":"developer","www":"public"}'` | Yes |
| `--options JSON` | `options` | Profile-specific options | No |
| `--from-json FILE` | – | Read all params from JSON file (`-` = stdin) | N/A |

## `edit` fields

Only these fields can be changed after launch:

`--network`, `--ide`, `--description`, `--viewers`, `--developers`,
`--private`/`--no-private`, `--access`

## `--from-json` editing

```sh
dockside edit test --from-json - < <(echo '{"description": "A devtainer for testing Project Beta"}')
```

## Log sanitisation

`dockside logs` strips ANSI escape sequences (CSI, OSC, two-character ESC)
and dangerous control characters from container output by default. This
prevents terminal injection attacks from untrusted log content. Printable
text, tabs, newlines, and carriage returns are preserved.

Use `--raw` to disable sanitisation when you trust the source and need the
original terminal output.

## Security

- **Config directory validation**: `DOCKSIDE_CONFIG_DIR` rejects empty paths,
  null bytes, path traversal (`..`), and symlinks.
- **Atomic file writes**: all config and cookie file writes use a temp-file +
  `os.replace()` pattern to prevent partial writes.
- **Symlink protection**: config and cookie files are never read from or
  written through symlinks.
- **Cookie filename validation**: user-supplied `--cookie-file` values are
  sanitised to prevent path traversal or injection.
- **HTTPS enforcement**: `http://` URLs are automatically upgraded to
  `https://`.
