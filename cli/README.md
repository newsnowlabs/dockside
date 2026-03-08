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
dockside login --server https://my.dockside.example.com

# List devtainers
dockside list

# Create a devtainer and wait for it to start
dockside create --profile myprofile --name my-feature --image ubuntu:22.04 \
    --git-url https://github.com/org/repo --developers alice,role:backend

# Start / stop / remove
dockside start  my-feature
dockside stop   my-feature
dockside remove my-feature --force

# Tail logs
dockside logs my-feature

# Edit metadata
dockside edit my-feature --description "Feature branch X" --viewers carol
```

## CI / GitHub Actions (no stored session)

Pass credentials via flags or environment variables on every invocation:

```sh
DOCKSIDE_SERVER=https://my.dockside.example.com \
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
| `login`   | Authenticate and save session cookie |
| `logout`  | Clear saved session |
| `list`    | List all accessible devtainers |
| `get`     | Show details of a specific devtainer |
| `create`  | Create and launch a new devtainer |
| `start`   | Start a stopped devtainer |
| `stop`    | Stop a running devtainer |
| `edit`    | Edit devtainer metadata |
| `remove`  | Remove a devtainer |
| `logs`    | Retrieve devtainer logs |

## Addressing devtainers

The `DEVTAINER` argument accepts:
- Container **name** (e.g. `my-feature`)
- **Reservation ID** (hex string from `dockside get`)
- **Docker container ID** (full or unambiguous prefix)

## Output formats

```sh
dockside list                  # text table (default)
dockside list -o json          # JSON array
dockside list -o yaml          # YAML
dockside list -o json | jq '.[].name'
```

## Waiting behaviour

By default `create`, `start`, `stop`, and `remove` poll the API until the
requested state is confirmed (or until `--timeout` seconds elapse).

```sh
dockside create --profile ci --name my-pr --no-wait   # fire and forget
dockside stop   my-feature --timeout 60                # custom timeout
```

## Global flags

| Flag | Env var | Description |
|------|---------|-------------|
| `--server URL` | `DOCKSIDE_SERVER` | Dockside server URL |
| `--username USER` | `DOCKSIDE_USER` | Username (one-shot auth) |
| `--password PASS` | `DOCKSIDE_PASSWORD` | Password (one-shot auth) |
| `--output FORMAT` | – | `text` \| `json` \| `yaml` |
| `--no-verify` | – | Skip SSL certificate verification |

## Session storage

```
~/.config/dockside/
  config.json   # server URL and default output format
  cookies.txt   # session cookies (chmod 600)
```

Override with `DOCKSIDE_CONFIG_DIR=/path/to/dir`.

## `create` fields

All fields available in the Dockside web form are supported:

| Flag | API field | Notes |
|------|-----------|-------|
| `--name` | `name` | Lowercase letters, digits, hyphens |
| `--profile` | `profile` | **Required** |
| `--image` | `image` | Docker image (e.g. `ubuntu:22.04`) |
| `--runtime` | `runtime` | e.g. `runc`, `sysbox-runc` |
| `--unixuser` | `unixuser` | Unix user inside the container |
| `--git-url` | `gitURL` | Git repo to clone on launch |
| `--ide` | `IDE` | e.g. `theia/latest`, `openvscode/latest` |
| `--network` | `network` | Docker network name |
| `--description` | `description` | Free-text description |
| `--viewers` | `viewers` | Comma-separated users/roles |
| `--developers` | `developers` | Comma-separated users/roles |
| `--private` | `private` | Hide from other admins |
| `--access JSON` | `access` | e.g. `'{"ssh":"developer","www":"public"}'` |
| `--options JSON` | `options` | Profile-specific options |
| `--from-json FILE` | – | Read all params from JSON file (`-` = stdin) |

## `edit` fields

Only these fields can be changed after launch:

`--network`, `--ide`, `--description`, `--viewers`, `--developers`,
`--private`/`--no-private`, `--access`, `--from-json`
