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

- Currently, IDE functions that internally require an SSH client (like `Git: Push` / `Git: Pull` / the embedded Terminal) are not configured to use keys forwarded by an active `ssh -A` session. So while you can manually run `git push` / `git pull` commands within an SSH terminal using forwarded keys, the IDE cannot access these keys. The IDE instead accesses keys added to the local integrated ssh-agent. This limitation may be addressed in a future release. For now, read on for how to configure the IDE to use keys added to the local integrated `ssh-agent`.

## Local SSH agent support and automatic key provision

To use `git` functionality of the IDE (like `Git: Push` and `Git: Pull`) or other `SSH`-based commands accessible within the IDE UI or terminal, you will first need to have provisioned your devtainer with the required SSH keys.

When a devtainer is launched, Dockside will launch `ssh-agent` in the process context of the IDE. This allows IDE functions requiring SSH (like `Git: Push` and `Git: Pull`) as well as command-line tools run from within the IDE terminal (like `git` and `ssh`) to function as expected. Dockside will use the launched image's `ssh-agent` if it can be found in the `PATH`; failing that it launches its own integrated `ssh-agent`.

On launch of a devtainer, Dockside will load any SSH keys specified in the user's profile into the integrated `ssh-agent`. The user may at any time add additional keys by running `ssh-add <path-to-key>` within a terminal. All such keys are available to the IDE, to VS Code extensions, and to commands run within the IDE terminal.

### Adding SSH keys to a user's profile

Dockside supports two distinct SSH key needs, configured separately in each user's record in `users.json`:

**1. Inbound SSH access (`authorized_keys`) — who can SSH into a devcontainer**

Add the user's SSH public key(s) to their `users.json` record under `ssh.authorized_keys`:

```json
"ssh": {
  "authorized_keys": ["ssh-ed25519 AAAA... alice@example.com"]
}
```

Whenever a devcontainer is started, or its developer list is changed, Dockside writes the public keys of all authorised developers into the devcontainer's `~/.ssh/authorized_keys` — automatically, with no manual step needed.

> **Profile requirement:** For Dockside to write `authorized_keys`, the devcontainer's `~/.ssh` directory must be writable and must not be a persistent volume containing its own `authorized_keys`. The recommended approach (used in the example `10-alpine.json` profile) is to mount `~/.ssh` as a `tmpfs`:
> ```json
> "tmpfs": [
>   { "dst": "/home/{ideUser}/.ssh", "tmpfs-size": "1M" }
> ]
> ```
> This gives Dockside full control of `authorized_keys` on every start. Do not mount a volume or bind-mount over `~/.ssh` (or over `authorized_keys` directly) in profiles where SSH is enabled, or Dockside's automatic key provisioning will not work.

**2. Outbound SSH keypairs (`keypairs`) — authenticating out from a devcontainer to GitHub, GitLab, etc.**

To enable `git push` / `git pull` and other outbound SSH operations from within the IDE or terminal, add the user's keypair to their `users.json` record under `ssh.keypairs`:

```json
"ssh": {
  "authorized_keys": ["ssh-ed25519 AAAA... alice@example.com"],
  "keypairs": {
    "*": {
      "public":  "ssh-ed25519 AAAA... alice@example.com",
      "private": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----\n"
    }
  }
}
```

On devcontainer launch, Dockside automatically loads the keypair into the integrated `ssh-agent`. The key is then available to the IDE (for `Git: Push` / `Git: Pull`), to VS Code extensions, and to any command run in the IDE terminal — without any manual `ssh-add` step.

> **Security note:** The private key stored in `users.json` will be accessible to any admin who can read the config files. Use an SSH key dedicated to Dockside / your development workflow, separate from any personal or production keys. Consider using an encrypted key and relying on `ssh-add` rather than storing it in `users.json` if your threat model requires it.

### Adding SSH keys to a devtainer workspace manually

Manual key provisioning is still possible — SSH public and private key files may be dragged-and-dropped into the IDE file explorer, or uploaded by right-clicking on a folder and selecting `Upload`. Any loaded key can be added to the running agent with `ssh-add <path-to-key>`.

For most teams, configuring `ssh.keypairs` in `users.json` (described above) is simpler and more reliable, since keys are provisioned automatically into every new devcontainer without any manual step.

> N.B.
>
> 1. If you share access to a devtainer IDE, you share access to any unencrypted keys within the container. We recommend __only using encrypted key files__, running `ssh-add` to decrypt them as needed, and running `ssh-add -D` to delete stored unencrypted identities, or `ssh-add -x` to lock the agent, before sharing the IDE with untrusted users.
> 2. It is __not recommended__ to share unencrypted SSH key files between users via shared volume mounts.