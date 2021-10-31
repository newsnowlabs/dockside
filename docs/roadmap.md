# Roadmap

The roadmap for Dockside currently remains highly flexible. We have a list of candidate features we think would be great to add, and will gradually implement, but we want to hear from you what you would like.

## v1.x.y

### Minor issues

- Remove duplicate nvm chaff appended to `.bashrc`
- fix devtainer launch logs not updating periodically in client

### Minor improvements

- IDE upgrades:
  - build and store the launch-ide.sh script with the IDE at `/opt/dockside/ide/theia/theia-<version>/bin` (so it can be versioned with the IDE)
  - create a formal script for upgrading the Dockside Theia IDE

### Application Client

- Add devtainer-level menu to select version of Theia IDE (from those available) to launch for a devtainer
- Add admin view for managing users, passwords, ssh keys (including deploying keys to devtainers)
- Add admin view for monitoring/managing host memory/disk space
- Add option for viewing devtainer launch logs (preferably in integrated terminal)
- Replace Bootstrap with alternative CSS framework more appropriate to a web app

### Service access control

- Implement per-devtainer secret-URL-based auth/access level for services that should be shared only with select public individuals (aka 'devtainerCookie' auth)

### Application Server

- Break out Application Server into standalone FastCGI process to facilitate:
  - reimplement static error pages (for stopped devtainers, and devtainers with stopped services) within the client
  - (re)implementing API in separate Go or Node.js process
- Add config and profile options to enable/disable user creation, sudo configuration, and ssh-agent auto-launch
- Build in ssh-agent for use with images where none is provided

### Other

- Custom hooks/variables to allow users to craft devtainer launch URLs that check out and build your app for specific repo branches
- Docker Swarm and/or Kubernetes support to allow devtainers to be distributed across a cluster
- Per-user quotas for devtainers, and for memory and disk resources

## v2.0.0

Application Server:

- Complete migration of server functionality to Go or Node.js

