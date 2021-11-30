# Roadmap

The roadmap for Dockside currently remains highly flexible. We have a list of candidate features we think would be great to add, and will gradually implement, but we want to hear from you what you would like.

## v1.x.y

### Minor issues

- Remove duplicate nvm chaff appended to `.bashrc`

### Minor improvements

- IDE upgrades:
  - build and store the launch-ide.sh script with the IDE at `/opt/dockside/ide/theia/theia-<version>/bin` (so it can be versioned with the IDE)
  - create a formal script for upgrading the Dockside Theia IDE
- Add profiles for popular Linux distributions
- Add keyboard shortcuts for open Launch form, Launch, Stop, Start, Cancel
- Add option to launch Dockside UI listening on http://localhost/ (i.e. no HTTPS) for purely local usage

### Application Client

- Add devtainer-level menu to select version of Theia IDE (from those available) to launch for a devtainer
- Add UI for managing users, passwords, ssh keys (including deploying keys to devtainers)
- Add UI for monitoring/managing host memory/disk space/images
- Add UI for monitoring/managing container memory/disk space/CPU (via `docker stats`)
- Add UI for viewing devtainer stdout/stderr logs (preferably in integrated terminal)
- Replace Bootstrap with alternative CSS framework more appropriate to a web app

### Service access control

- Implement per-devtainer secret-URL-based auth/access level for services that should be shared only with select public individuals (aka 'devtainerCookie' auth)

### Application Server

- Break out Application Server into standalone FastCGI process to facilitate:
  - reimplement static error pages (for stopped devtainers, and devtainers with stopped services) within the client
- Reimplement all remaining Docker CLI calls with API calls (and remove docker packages from main production build)

### IDE customisation and support

- Build in `ssh-agent` for use with images where none is provided
- Support for other IDEs e.g. VS Code and Cloud9
- Add config and profile options to enable/disable in-devtainer user creation, sudo configuration, and ssh-agent auto-launch

### Launch customisation

- A 'fork'/'clone' button, that launches a devtainer using the same disk image as the selected devtainer
- A 'launch again' button, that launches a devtainer using the same profile and settings as the selected devtainer
- Support for launching a devtainer directly from a git repo using `.devcontainer.json`
- Integrated SSH key management and agent, allowing devtainers to git pull/git checkout specified branches when they launch
- Custom hooks/variables to allow devtainer launch URLs to be crafted that pull/checkout/build specific branches of a repo (depends on integrated SSH agent)

### Other

- Implement per-user quotas for devtainers memory, disk and CPU resources
- Support for Podman

### Scalability

- Docker Swarm and/or Kubernetes support to allow devtainers to be distributed across a cluster

## v2.0.0

Application Server:

- Complete migration of server functionality to Go or Node.js

