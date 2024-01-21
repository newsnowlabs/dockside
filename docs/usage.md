# Usage

## Using the Dockside UI

Dockside UI usage should be reasonably self-explanatory.

### Launching a devtainer

Click `Launch` to prepare to launch a devtainer. Choose a Profile to indicate the kind of devtainer you wish to launch, then customise the devtainer according to your needs, optionally selecting (depending on the profile):

- choice of docker runtime
- devtainer docker image
- docker network
- the auth/access level for each service preconfigured within the profile
- a list of users, and/or roles of users, allowed to view the devtainer i.e. access the devtainer and display links to devtainer services displayed on Dockside
- a list of users, and/or roles of users, allowed to develop the devtainer i.e. access the Dockside Theia IDE (which implies rights to view the devtainer too)
- a checkbox for keeping the devtainer private from other admin users (only available to admin users)

When ready, click the green `Launch` button. If errors are encountered launching the devtainer, these will be displayed onscreen.

To edit the developer and users lists, change the connected network, change the auth/access levels for the devtainer's services, or change its privacy setting, click `Edit`, make changes, then `Save`.

To open a preconfigured devtainer service, click the `Open` button adjoining the service.

Where SSH has been enabled, you can open an SSH terminal to a devtainer by clicking the `Open` button adjoining the SSH service. SSH support requires setup; see [Integrated SSH server support](extensions/ssh.md#integrated-ssh-server-support).

> To create and customise a Profile before launching devtainers, see [Profiles](../setup/#profiles).

## Using the Dockside IDE

Dockside runs a version of the amazing open-source [Theia IDE](https://theia-ide.org/), an Eclipse Foundation project, a version of which is also used as the [Google Cloud IDE](https://ide.cloud.google.com).

Theia aims to be a fully VSCode-compatible IDE, provides an experience highly familiar to VSCode developers, and today seamlessly runs many VSCode extensions, which can be preinstalled or installed on demand via the Extensions tab.

To use `git` functionality of the Theia IDE (like `Git: Push` and `Git: Pull`) or other `SSH`-based commands accessible within the Theia IDE UI or terminal, you will first need to have provisioned your devtainer with the required SSH keys. See [SSH: Local ssh-agent support](extensions/ssh.md#local-ssh-agent-support).

### Root access within Devtainers

Upon launch of a devtainer, Dockside configures `sudo` within the devtainer to allow the IDE user (the `unixuser`) to `sudo <command>` (without password) for any command.

Dockside currently provides all devtainer developers with root access within devtainers where `sudo` is available.

> N.B.
> 
> 1. Sudo functionality will only be available in devtainers: (a) launched from images with `sudo` pre-installed; or, (b) where a profile launch `command` is provided that installs the `sudo` package into the running container e.g. the [`alpine.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/alpine.json) profile.
> 2. An option to disable `sudo` functionality may be provided in a future Dockside version.
> 3. An option to preconfigure the devtainer root password (to enable `su` functionality) may be provided in a future Dockside version.