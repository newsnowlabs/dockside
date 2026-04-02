# Usage

## Using the Dockside UI

Dockside UI usage should be reasonably self-explanatory.

### Launching a devtainer

Click `Launch` to prepare to launch a devtainer. Choose a Profile to indicate the kind of devtainer you wish to launch, then customise the devtainer according to your needs, optionally selecting (depending on the profile):

- choice of docker runtime
- devtainer docker image
- docker network
- choice of IDE (e.g. Theia or OpenVSCode) if multiple IDEs are available
- profile-specific option fields (e.g. git branch or pull-request number) if the profile defines `options` entries
- the auth/access level for each service preconfigured within the profile
- a list of users, and/or roles of users, allowed to view the devtainer i.e. access the devtainer and display links to devtainer services displayed on Dockside
- a list of users, and/or roles of users, allowed to develop the devtainer i.e. access the Dockside IDE (which implies rights to view the devtainer too)
- a checkbox for keeping the devtainer private from other admin users (only available to admin users)

When ready, click the green `Launch` button. If errors are encountered launching the devtainer, these will be displayed onscreen.

To edit the developer and users lists, change the connected network, change the auth/access levels for the devtainer's services, or change its privacy setting, click `Edit`, make changes, then `Save`.

To open a preconfigured devtainer service, click the `Open` button adjoining the service.

Where SSH has been enabled, you can open an SSH terminal to a devtainer by clicking the `Open` button adjoining the SSH service. SSH support requires setup; see [Integrated SSH server support](extensions/ssh.md#integrated-ssh-server-support).

> To create and customise a Profile before launching devtainers, see [Profiles](setup.md#profiles).

## Using the Dockside IDE

Dockside supports two open-source web IDEs:

- **[Theia](https://theia-ide.org/)** — an Eclipse Foundation project that aims to be a fully VS Code-compatible IDE, providing an experience highly familiar to VS Code developers; supports many VS Code extensions, which can be preinstalled or installed on demand via the Extensions tab.
- **[OpenVSCode](https://github.com/gitpod-io/openvscode-server)** — the upstream open-source VS Code server, providing direct VS Code compatibility and broader extension support.

The IDE is selected at launch time from those available on the host. The active IDE can also be changed for a running devtainer via `Edit` (takes effect on IDE restart).

To use `git` functionality within the IDE (like `Git: Push` and `Git: Pull`) or other `SSH`-based commands accessible within the IDE UI or terminal, you will first need to have provisioned your devtainer with the required SSH keys. See [SSH: Local ssh-agent support](extensions/ssh.md#local-ssh-agent-support).

The bundled `gh` (GitHub CLI) is available in all devtainer terminals. When a `gh_token` is configured for your user in `users.json`, `gh` authenticates automatically, enabling commands such as `gh pr checkout` without any additional login steps.

## Using the Dockside CLI

The `dockside` CLI is a zero-dependency Python 3.6+ command-line tool that provides the same functionality as the web UI, making it suitable for scripting, automation, and CI/CD pipelines.

```sh
# Authenticate
dockside login --server https://www.local.dockside.dev --nickname local

# List, create, and manage devtainers
dockside list
dockside create --profile myprofile --name my-feature --image ubuntu:22.04
dockside stop my-feature
dockside remove my-feature --force
```

See the [Dockside CLI README](../cli/README.md) for installation instructions, all available commands, multi-server configuration, and CI/CD usage examples.

### Root access within Devtainers

Upon launch of a devtainer, Dockside configures `sudo` within the devtainer to allow the IDE user (the `unixuser`) to `sudo <command>` (without password) for any command.

Dockside currently provides all devtainer developers with root access within devtainers where `sudo` is available.

> N.B.
> 
> 1. Sudo functionality will only be available in devtainers: (a) launched from images with `sudo` pre-installed; or, (b) where a profile launch `command` is provided that installs the `sudo` package into the running container e.g. the [`alpine.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/alpine.json) profile.
> 2. An option to disable `sudo` functionality may be provided in a future Dockside version.
> 3. An option to preconfigure the devtainer root password (to enable `su` functionality) may be provided in a future Dockside version.