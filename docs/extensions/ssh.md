# SSH

Dockside provides two complementary types of SSH support: [integrated SSH server support](#integrated-ssh-server-support) for SSHing *into* devcontainers from your local machine or the Dockside UI, and [local SSH agent support](#local-ssh-agent-support-and-automatic-key-provision) for SSHing *out of* devcontainers — for example, to push to or pull from GitHub or GitLab.

## Integrated SSH server support

Dockside's integrated SSH server support:

- provisions a Dropbear SSH daemon for each devcontainer, allowing any authorised developer to SSH in
- manages each devcontainer's `~/.ssh/authorized_keys` file, ensuring it is correctly populated with the public keys of the devcontainer owner and any developers with whom the devcontainer is shared
- provides one-click SSH to any devcontainer directly from the Dockside UI
- integrates wstunnel helper setup instructions in the Dockside UI
- facilitates use of any terminal editor or command-line tool, including those that benefit from key forwarding such as `git`
- facilitates seamless [VS Code remote development](https://code.visualstudio.com/docs/remote/ssh) via the [Remote SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension

Dockside enables SSH by default for all new devcontainers. To disable it globally, set `"ssh": { "default": false }` in `config.json`. To disable it in an individual profile, set `"ssh": false` in the profile.

### Configuring user public keys

To control which developers can SSH into a devcontainer, add each developer's SSH public key to their record in `users.json` under `ssh.authorized_keys`:

```json
"ssh": {
  "authorized_keys": ["ssh-ed25519 AAAA... alice@example.com"]
}
```

Whenever a devcontainer is started, its developer list is changed, or its SSH access mode is switched (between 'Devcontainer owner only' and 'Devcontainer developers only'), Dockside automatically writes the correct set of public keys to `~/.ssh/authorized_keys` inside the devcontainer. No manual step is needed.

> **Profile requirement:** For Dockside to write `authorized_keys`, the devcontainer's `~/.ssh` directory must be writable and must not already contain a persistent `authorized_keys` file. The recommended approach — used in the example `10-alpine.json` profile — is to mount `~/.ssh` as a `tmpfs`:
> ```json
> "tmpfs": [
>   { "dst": "/home/{ideUser}/.ssh", "tmpfs-size": "1M" }
> ]
> ```
> A `tmpfs` mount is empty on every start, giving Dockside full control of `authorized_keys`. Do not mount a Docker volume or bind-mount over `~/.ssh` (or over `authorized_keys` directly) in profiles where SSH is enabled, or automatic key provisioning will not work correctly.

### SSH client setup

Developers must follow the client configuration instructions — accessible via the SSH `Setup` button in the Dockside UI — before using SSH for the first time.

These instructions guide them through installing the [wstunnel](https://github.com/erebe/wstunnel) client helper and configuring their `~/.ssh/config` file for seamless SSH access to their devcontainers.

### Notes

- Since Dockside manages `~/.ssh/authorized_keys` automatically, any manual changes you make to this file inside a devcontainer with SSH enabled may be overwritten on the next start or developer-list change. To add a key persistently, add it to the user's `users.json` record instead.

- IDE functions that internally require an SSH client (such as `Git: Push` and `Git: Pull`) cannot use keys forwarded by an active `ssh -A` session. You can still use forwarded keys when running `git` commands manually in an SSH terminal, but the IDE itself cannot access them. Instead, the IDE reads keys from the local integrated `ssh-agent` — see [Local SSH agent support](#local-ssh-agent-support-and-automatic-key-provision) below.

## Local SSH agent support and automatic key provision

Dockside launches and manages an `ssh-agent` in each devcontainer, providing secure SSH key access when using the IDE and its integrated terminal.

The agent runs in the process context of the IDE, which means IDE functions requiring SSH (like `Git: Push` and `Git: Pull`) and command-line tools run from the IDE terminal (like `git` and `ssh`) can all use it automatically. Dockside uses the `ssh-agent` binary found in the devcontainer image's `PATH`; if none is found it falls back to its own built-in `ssh-agent`.

Keys held in the agent are available to the IDE, to VS Code extensions, and to any command run in the IDE terminal. Additional keys can be added at any time by running `ssh-add <path-to-key>` in a terminal.

### Configuring keypairs for outbound SSH

To authenticate outbound SSH connections from within the IDE or terminal — for example, `git push` / `git pull` to GitHub or GitLab — add the user's keypair to their `users.json` record under `ssh.keypairs`:

```json
"ssh": {
  "keypairs": {
    "*": {
      "public":  "ssh-ed25519 AAAA... alice@example.com",
      "private": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----\n"
    }
  }
}
```

On devcontainer launch, Dockside automatically loads the keypair into the `ssh-agent`. The key is then immediately available to the IDE (for `Git: Push` / `Git: Pull`), to VS Code extensions, and to any terminal command — without any manual `ssh-add` step.

> **Security note:** Private keys stored in `users.json` are readable by any administrator with access to the config files. Use an SSH key dedicated to your Dockside / development workflow, separate from personal or production keys. If your security requirements demand it, omit the private key from `users.json` and instead run `ssh-add <path-to-key>` manually each session.

### Adding SSH keys to a devcontainer manually

SSH key files can also be added to a devcontainer directly — by dragging and dropping them into the IDE file explorer, or by right-clicking a folder and selecting `Upload`. Once present in the container, load a key into the agent with `ssh-add <path-to-key>`.

For most teams, configuring `ssh.keypairs` in `users.json` is simpler and more reliable, since keys are provisioned automatically into every new devcontainer with no manual steps required.

> **Note:** If you share your devcontainer IDE with another user, they will have access to any unencrypted key files present in the container and to any keys currently loaded in the agent. Before sharing with an untrusted user, run `ssh-add -D` to remove all unencrypted identities from the agent (or `ssh-add -x` to lock it), and ensure any key files on disk are encrypted.
