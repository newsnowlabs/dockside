# SSH

## Integrated SSH server support

Dockside's SSH server support:

- provisions a dropbear SSH daemon for each devtainer, allowing any authorised developer to SSH in;
- auto-generates a `~/.ssh/authorized_keys` file for the devtainer owner and other developers with whom the devtainer is shared
- one-click SSH to any devtainer directly from the Dockside UI
- wstunnel helper setup instructions integrated in the Dockside UI
- facilitates use of any terminal editor or command line tool including those that benefit from key forwarding, such as `git`
- facilitates seamless [VS Code remote development](https://code.visualstudio.com/docs/remote/ssh) via the [Remote SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension.

Dockside enables SSH by default for all new devtainers. To disable it globally set `"ssh": { "default": false }` in `config.json`. To disable it in an individual profile, set `"ssh": false` in the profile.

To configure autogeneration of devtainer `~/.ssh/authorized_keys` files, add `"ssh": { "authorized_keys": ["<key>"] }` (with a suitable public key substituted for `<key>`) for each developer user in `users.json`.

Whenever a devtainer is started, or the list of developers (with whom a devtainer is shared) is modified, or the devtainer's SSH access mode is changed (from 'Devtainer owner only' to 'Devtainer developers only' or vice-versa) Dockside will populate the devtainer's `~/.ssh/authorized_keys` file with the set of public keys for all authorised developers.

### SSH client setup

Developers must follow the client configuration instructions, by clicking the SSH `Setup` button in the Dockside UI, prior to using SSH.

These instructions will guide them through installing the [wstunnel](https://github.com/erebe/wstunnel) client helper and configuring their `~/.ssh/config` file to provide seamless SSH into their devtainers.

### Notes

- Since `~/.ssh/authorized_keys` can be overwritten by Dockside, SSH support is not compatible with any profiles that mount over this file (or over `~/.ssh` if the mounted filesystem contains an `authorized_keys` file) and you should take care to disable SSH in such profiles. If you make changes manually to this file on a devtainer that has SSH enabled, your changes may be lost.

- Currently, Theia IDE functions that internally require an SSH client (like `Git: Push` / `Git: Pull` / the embedded Terminal) are not configured to use keys forwarded by an active `ssh -A` session. So while you can `git push` / `git pull` within an SSH terminal using forwarded keys, the IDE cannot access these keys. This limitation may be addressed in a future release. For now, read on for how to configure the Theia IDE to use keys added to a local `ssh-agent`.

## Local SSH agent support

To use `git` functionality of the Theia IDE (like `Git: Push` and `Git: Pull`) or other `SSH`-based commands accessible within the Theia IDE UI or terminal, you will first need to have provisioned your devtainer with the required SSH keys.

When a devtainer is launched, if `ssh-agent` can be found in the launched image, then Dockside will launch `ssh-agent` in the context of the Theia IDE. This will allow IDE functions requiring SSH (like `Git: Push` and `Git: Pull`) as well as command-line tools run from within the IDE terminal (like `git` and `ssh`) to function as expected.

On launch of a devtainer, you must load your SSH keys into the running agent, by running `ssh-add <path-to-key>` within a terminal, before any such IDE functions or command-line tools may be used. You only need to do this once after launching, or after stopping and starting, a devtainer.

### Adding SSH keys to devtainer workspace

SSH public and private key files may be dragged-and-dropped into the Theia IDE file explorer, or uploaded by right-clicking on a folder and selecting `Upload`.

However, to automatically provision key files into newly-launched devtainers, configure your profiles to mount a docker volume (or bind-mount a host directory) containing your users' encrypted key files. e.g.

```
   "volume": [
      // Use this to share encrypted ssh keys from the owner's named volume with their devtainers.
      // N.B. Don't overwrite /home/{ideUser}/.ssh if integrated SSH server support is enabled!
      { "src": "myprofile-sshkeys-{user.username}", "dst": "/home/{ideUser}/.ssh/keys" }
   ]
```

(For an example of how this may be done, please see the [`dockside.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/dockside.json) profile.)

> N.B.
> 
> 1. Although this approach means that users of a profile will have access to each others public and private key files, it will not confer access to a user's key _as long as_ the private key file is encrypted.
> 2. It is __not recommended__ to share unencrypted SSH keys files between users in this fashion.
> 3. If you share access to a devtainer IDE, you share access to any unencrypted keys/key files within the container. We recommend __only using encrypted key files__, running `ssh-add` to decrypt them as needed, and running `ssh-add -D` to delete stored unencrypted identities, or `ssh-add -x` to lock the agent, before sharing the IDE with untrusted users.