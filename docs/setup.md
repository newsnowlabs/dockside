# Setup, configuration and administration

Dockside configuration (config), database (db), cache, and SSL certificates (certs) are stored in /data in the dockside container, and at corresponding locations within any /data-bind-mounted host directory, such as `~/.dockside/`.

Here is the `config/` subfolder hierarchy:

```
config/
  config.json
  users.json
  roles.json
  passwd
  profiles/
    alpine.json
    debian.json
    dockside.json
    nginx.json
    ...
```

Dockside automatically checks for and reloads all configuration `.json` files when it finds they have changed. If errors are found within any file, the file will be ignored, and any preexisting file contents retaining in memory will be used, until such time as the file errors are fixed.

Dockside `.json` files are allowed to contain JavaScript-style `//` comments.

## Security model

Dockside aims to secure host resources such that they may only be used by registered Dockside users as permitted by the user's User record, the Role record corresponding to their role, and by the specification of the Profiles they are permitted to deploy.

As such, registered users are only able to:
1. deploy devtainers if specifically permitted to do so;
2. deploy devtainers from profiles they have been granted access to;
3. deploy or use resources explicitly specified within the profile;
4. deploy or use resources explicitly specified (and not barred by) by their user record or by the role record corresponding to their role.

Read on, to learn about [Profiles](#profiles), [Users](#users) and [Roles](#roles).

> **N.B. For avoidance of doubt, non-registered users may not access the Dockside UI, and may not deploy or configure devtainers. But, non-registered 'users' may access a non-IDE service running within a devtainer if the router auth/access level has been set to `public`.**

## Profiles

Profile `.json` files specify the broad types of devtainer that may be launched within Dockside, and each profile specifies the precise nature of the devtainer and the range of parameters which a user is allowed to customise.

A team admin is expected to preconfigure the available profiles to meet the needs of their development team.

A profile allows the specification of the available user choices for the following Docker container properties: images, bind-mounts, volume-mounts and tmpfs-mounts, networks, runtimes, launch commands.

> N.B. The available choices when a user launches/creates/edits a devtainer are always subject to the choices allowed that user in their user record. The available operations are always subject to the permissions granted to that user in their user record.

A profile also allow the specification of Dockside _routers_, which dictate how external HTTP(S) requests are mapped to internal HTTP(S) requests to devtainer services launched from the profile, and what access level(s) a user (who may or may not be a Dockside user) must have in order to access the service.

For insight into the profile object structure, examine the example profiles provided withing `config/profiles/`. To modify the available profiles, simply modify or add to the `.json` files within `config/profiles/`.

The currently-supported root properties within a profile are:

| property | description | optional/mandatory | default | example |
| - | - | - | - | - |
| version | version of the profile object schema used | mandatory | N/A | `2` |
| name | displayed name within the UI | mandatory | N/A | `Dockside`
| description | currently for informational use only, may be displayed within UI at later date | optional | `""` | `"Dockside devtainer with built-in IDE"`
| active | must be set to `true` or the profile will be ignored | mandatory | `false` | `true` |
| [routers](#profile-routers) | [array] preconfigured services | optional | `[]` | `[{"name": "dockside", "prefixes": [ "www" ], "domains": [ "*" ], "auth": [ "developer", "owner", "viewer", "user", "public" ], "https": { "protocol": "https", "port": 443 } }]`
| networks | allowed docker networks | optional | `["*"]` (allow any networks connected to the Dockside container) | `["bridge"]` or `["*"]`
| runtimes | allowed docker runtimes | optional | `["*"]` (allow any runtimes available on the host's Docker daemon) | `["runc", "sysbox-runc", "io.containerd.runc.v2", "runcvm"]` or `["*"]`
| images | allowed docker images (a wildcard may be used to allow the user to specify an arbitrary element of the image string) | mandatory | N/A | `["alpine:latest","i386/alpine:latest"]` |
| unixusers | array of the unix user account for which to run the IDE | optional | `["dockside"]` | `["john","jim"]`
| mounts | tmpfs, bind and/or volume mounts | optional | `{}` | `{ "tmpfs": [{ "dst": "/tmp","tmpfs-size": "1G"}], "volume": [{"src": "ssh-keys", "dst":"/home/mycompany/.ssh"}], "bind": [{"src": "/source/path", "dst": "/dest/path", "readonly": true}] }`
| gitURLs | allowed git repository URLs that may be cloned on launch; use `["*"]` to allow any URL | optional | `[]` | `["https://github.com/myorg/*"]` or `["*"]`
| IDEs | allowed IDE installations for the devtainer; use `["*"]` to allow all IDEs available in the Dockside image (under `/opt/dockside/ide/`) | optional | `["*"]` | `["theia/latest", "openvscode/latest"]`
| options | dynamic user-input fields displayed in the launch form; each entry has `name`, `label`, `type`, `default`, and `placeholder` sub-fields; values are injected into the container as `DOCKSIDE_OPTION_<NAME>` environment variables or via `entrypoint` or `command` placeholders of form `{option.<NAME>}` | optional | `[]` | `[{"name": "branch", "label": "Branch", "type": "text", "default": "", "placeholder": "e.g. main"}]`
| runDockerInit | if true, run an init process inside the devtainer | optional | `true` | `true` |
| dockerArgs | arguments to pass verbatim to docker | optional | `[]` | `["--memory", "2G", "--storage-opt", "size=1.2G","--pids-limit", "4000"]` |
| lxcfs | whether to mount [lxcfs](extensions/lxcfs.md) | optional | as specified in `config.json` | `true` |
| security | `docker run` security options | optional | as specified in `config.json` | `{ "apparmor": "unconfined", "seccomp": "unconfined" }` |
| command | [array] command to run on devtainer launch | mandatory if image does not specify a long-running entrypoint or command | `[]` | `["/bin/sh", "-c", "[ -x \"$(which sudo)\" ] \|\| (apk update && apk add sudo;); sleep infinity"]`
| entrypoint | [array] command with which to override image entrypoint | optional | `[]` | `["/my-entrypoint.sh"]` |
| mountIDE | mount the Dockside IDE volume (disable this only for images that either (a) embed their own IDE volume, such as the Dockside image itself, or (b) do not need an IDE or any Dockside configuration) | optional | `true` | `false` |
| ssh | whether to enable ssh access | optional | as specified in `config.json` | `true` |

#### Autodetection of networks, runtimes and IDEs

Profiles using `["*"]` for `networks`, `runtimes`, or `IDEs` will present only those values actually available on the host at launch time:

- **Networks** are discovered by inspecting the Docker networks currently connected to the Dockside container.
- **Runtimes** are discovered by querying the host's Docker daemon.
- **IDEs** are discovered by scanning the `/opt/dockside/ide/` directory for installed IDE versions (e.g. `theia/latest`, `openvscode/latest`).

This means profiles using `["*"]` require no updates when new runtimes, networks, or IDEs become available (subject always to the resources the user is granted access to in `users.json` and `roles.json`).

#### Network name format

Docker network names may contain letters, digits, hyphens, underscores (`_`), and dots (`.`).

#### Git URL format

Values in `gitURLs`, and the `gitURL` field supplied at launch, may optionally end with `.git` (e.g. `https://github.com/org/repo.git` is equivalent to `https://github.com/org/repo`). Both HTTPS (e.g. `https://github.com/newsnowlabs/dockside.git`) and SSH (e.g. `git@github.com:newsnowlabs/dockside.git`) URLs are supported.

### Profile routers

A profile may specify zero or more routers. Each router consists of:

- `name`: uniquely identifies the router within the profile (any unique string will do)
- `prefixes`: an array of one or more domain name prefixes that when requested, in conjunction with a correct domain, will select the router (or, the `"*"` wildcard value may otherwise be used)
- `domains`: an array of one or more domain names that when requested, in conjunction with a correct prefix, will select the router (or, the `"*"` wildcard value should otherwise be used)
- `https` (optional): an object specifying, for incoming public https requests selecting the router, the protocol and port within the devtainer to which the request should be forwarded
- `http` (optional): an object specifying, for incoming public http requests selecting the router, the protocol and port within the devtainer to which the request should be forwarded
- `auth`: an array of permitted auth/access levels that may be set on a devtainer for this router (see [auth/access levels](#router-auth%2Faccess-levels))

### Router auth/access levels

The available router auth/access levels, from most to least restrictive, are:

- Devtainer owner only (`owner`): router may be accessed only by the devtainer owner (the user who launched the devtainer)
- Devtainer developers only (`developer`): router may be accessed only by users named as developers of the devtainer
- Devtainer developers and viewers only (`viewer`): router may be accessed only by users named as developers or viewers of the devtainer
- Dockside users (`user`): i.e. router may be accessed by any authenticated Dockside user
- Public (`public`): router may be accessed by anyone with the URL, without access-control restrictions

Planned but as-yet not-fully-implemented router auth/access levels, are:
- Devtainer cookie (`containerCookie`) i.e. a secret cookie unique to the devtainer must be presented to access this router

## Access Control Model

This section explains how the two access-control concepts work together at runtime.

### Profile `auth` array vs active access mode

The profile's `auth` array defines the **selectable range** of access modes the owner may choose for each router. It does not dictate what mode is currently active.

The **active access mode** per router is stored in `meta.access.{routerName}` on the devtainer record. It defaults to the first element of the profile's `auth` array and can be changed by the owner or a named developer via the Edit UI or CLI `--access` flag.

### Who can access a service

| Active mode | Who can access |
|---|---|
| `public` | Everyone (unauthenticated visitors and all Dockside users) |
| `user` | Any authenticated Dockside user |
| `viewer` | Devtainer owner + named developers + named viewers |
| `developer` | Devtainer owner + named developers only |
| `owner` | Devtainer owner only |

### Viewer vs Developer roles on a devtainer

A devtainer can be shared with other users by listing them in the Viewers list or Developers list.

**Named developers**:
- Can view the devtainer in the UI (or list the devtainer via the CLI)
- Can access the IDE and SSH router (subject to the router's active mode being `developer` or `owner`)
- Can access routers whose active mode is `developer` (Devtainer developers only), `viewer` (Devtainer developers and viewers only), `user` (Dockside users), or `public` (unauthenticated users)
- Can edit: description, viewers list, developers list, IDE, access modes, and network

**Named viewers**:
- Can view and list the devtainer 
- Can access routers whose active mode is `viewer`, `user`, or `public`
- **Cannot** access the IDE or SSH router — these are always restricted to `owner`/`developer`
- **Cannot** edit any container properties (description, viewers, developers, access mode, network, IDE)

**Other users**:
- Cannot view or list the devtainer
- Can access routers whose active mode is `user`, or `public` only
- **Cannot** access anything else

**Admin users** (role with `viewAllContainers` permission, or the `admin` role):
- Can see all containers regardless of sharing
- The `admin` role is special: a user with the `admin` role is auto-granted all permissions and access to all available resources, unless explicitly denied

### Router visibility in list and get responses

When listing devtainers or fetching details of a specific devtainers, Dockside filters each devtainer's routers to only those the requesting user can access at the current access setting. For example, a viewer will see an empty routers list for a container whose routers are all set to `developer` mode.

### IDE and SSH routers

The IDE and SSH routers are always restricted to `owner` or `developer` access. They cannot be set to `viewer`, `user`, or `public` mode. Only named developers (and the owner) receive an entry in the devtainer's `~/.ssh/authorized_keys` file.

## Users

The `users.json` file describes registered Dockside users. An 'admin' user is the only user specified in the file by default. It is recommended to modify the admin user record with a dedicated username for at least one team admin.

A user record specifies:

- `id`: a unique numeric id, not currently used (number)
- `email`: user's email address, used today to configure `.gitconfig` for the user and potentially in future for automated emails (string)
- `name`: user's display name, used today to configure `.gitconfig` for the user (string)
- `role`: user's role, as configured in `roles.json` (string)
- `permissions`: specific [permissions](#permissions) that should be enabled or disabled, in customisation of those conferred from the user's role (object)
- `resources`: host and Dockside [resources](#resources) to which the user should or should not have access, of the following types:
    - `profiles`: profiles the user is permitted to deploy (object or array)
    - `networks`: Docker networks the user's devtainers are permitted to join, subject also to the profile (object or array) and detected networks connected to the Dockside container; defaults to `["*"]`
    - `runtimes`: Docker runtimes the user is permitted to use using, subject also to the profile (object or array) and detected runtimes available on the Docker daemon; defaults to `["*"]`
    - `IDEs`: IDE installations the user is permitted to select (e.g. `["theia/latest"]`, `["*"]`); defaults to `["*"]` (all available IDEs) for all users (object or array)
    - `images`: Docker images the user is permitted to launch, subject also to the profile (object or array)
    - `auth`: the auth/access levels the user is permitted to specify for a devtainer's router, subject also to the devtainer's profile (object or array)
- `ssh`:
    - `publicKeys`: a map of named ssh public key strings (e.g. `{ "laptop": "ssh-rsa ..." }`) that will be automatically written to devtainers' `~/.ssh/authorized_keys` files for devtainers owned by, or shared with, the user (as 'developer'); individual keys can be added/removed via the CLI with `--set ssh.publicKeys.keyname="ssh-rsa ..."` and `--set ssh.publicKeys.keyname=`
    - `keypairs`: an object representing named keypair objects; currently only one keypair per user, with the name `*`, is supported; the keypair object must have two properties, named `public` and `private` with appropriate values (e.g. `{"*": {{"public": "ssh-rsa AAAAAskjha... myname@myteam.com", "private": "-----BEGIN OPENSSH PRIVATE KEY-----\nhsgjhga...\n-----END OPENSSH PRIVATE KEY-----\n"}}}`)
- `gh_token`: an optional GitHub Personal Access Token (string); when set, the token is passed as the `GH_TOKEN` environment variable into every container launched by or shared with the user, enabling the bundled `gh` CLI to authenticate automatically (e.g. for `gh pr checkout`)

You should add one record to `users.json`, and one record to [`passwd`](#passwords), for each registered user in your team.

### Permissions

Generic permissions are:

- `createContainerReservation`: permission to launch a devtainer
- `viewAllContainers`: permission to view all devtainers (except ones marked private)
- `viewAllPrivateContainers`: permission to view all devtainers including private devtainers
- `developContainers`: permission to develop devtainers that one owns or is a named developer on
- `developAllContainers`: permission to develop all devtainers irrespective of ownership or named developers

Devtainer permissions are:

- `setContainerViewers`: permit owner or named developers to edit the list of viewers
- `setContainerDevelopers`: permit owner or named developers to edit the list of developers
- `setContainerPrivacy`: permit owner to edit the private flag
- `startContainer`: permission to start a devtainer
- `stopContainer`: permission to stop a devtainer
- `removeContainer`: permission to remove a devtainer
- `getContainerLogs`: permission to retrieve devtainer logs

#### Permission syntax

In the `permissions` object, properties are permission names and their values are `true`/`false` (or `1`/`0`), indicating whether the permission is allowed (in the `true` or `1` case) or not allowed (in the `false` or `0` case).

> N.B. All permissions specified for a user are computed in addition to (or subtracted from) those already conferred by the user's role.

### Resources

Available resource names are:

- `profiles`: specify allowed profile filenames
- `networks`: specify allowed Docker networks
- `runtimes`: specify allowed Docker runtimes
- `IDEs`: specify allowed IDE installations (e.g. `theia/latest`, `openvscode/latest`, or `openvscode/1.109.5`)
- `images`: specify allowed Docker images
- `auth`: specify allowed [auth/access levels](#router-auth%2Faccess-levels)

#### Resources syntax

Any resource type - `profiles`, `networks`, `images`, `runtimes`, `auth` - may be set to:

- an array of permitted resource names
- an array consisting of the wildcard value `"*"` (which indicates all names are allowed, subject to other constraints)
- an object, where properties are resource names and their values are `true`/`false` (or `1`/`0`), indicating the use of the resource is  permitted (in the `true` or `1` case) or not permitted (in the `false` or `0` case); the wildcard name `"*"` may also be given with a corresponding value indicating whether use of all other resources are permitted or denied.

> N.B. All resource names specified for a user are computed in addition to (or subtracted from) those already conferred by the user's role, and are _always_ subject to the resource constraints specified within a [profile](#profiles).

Examples:

- `"networks": { "*": 1 }` - permit use of any network
- `"networks": { "*": 1, "customnet": 0 }` - permit use of any network _except_ `customnet`
- `"networks": { "*": 0, "customnet": 1 }` - permit use of _only_ `customnet` network
- `"networks": [ "customnet" ]` - permit use of _only_ `customnet` network

### Passwords

The `passwd` file is a text file (in essentially standard Unix format) containing one row per user. It should contain a row for each registered user specified in `users.json` that is not disabled, of the form `<username>:<encrypted-password>`. Passwords may currently be added, changed, or checked, from the host (or any dockside container with access to the host docker socket) using the following command:

```sh
docker exec -it dockside password [--check] <username>
```

### Revoking a user's access to Dockside

> **After deleting a user, or modifying `users.json`, `roles.json` or `passwd` in such a way that a user's access to a running devtainer should be revoked, it is necessary to [restart the Dockside Server](#dockside-server) to ensure any open HTTP(S) or websocket connections made by that user are closed and the user's access completely revoked.**

## Roles

The syntax for `roles.json` mirrors that for `users.json`, except top-level object properties declare arbitrarily-named roles representing useful collections of permissions and resources that may be assigned to multiple users via the user's `role` property.

N.B. The `admin` role is special: a user with the `admin` role is granted all permissions and access to all available resources, unless explicitly denied either in the `admin` role definition, or in the user's record.

## config.json

The `config.json` file contains global config for the Dockside instance. Not all properties are user-editable, but those which are include:

- `uidCookie`: an object specifying a unique name and salt for the Dockside authentication cookie; this must be different for every nested instance of Dockside
- `globalCookie`: for an extra layer of security for the security-conscious, you may specify a name, domain and secret value for a global cookie which must be present before any part of Dockside, including the UI will respond to a web request; use this if you are uncomfortable with either the Dockside UI login screen, or devtainer services that may be set to 'public' to be exposed publicly
- `lxcfs`:  is a fuse filesystem that allows processes running with docker containers to measure their own cpu, memory, and disk usage; refer to [LXCFS](extensions/lxcfs.md) for details of the LXCFS extension
- `docker.security`: the default `apparmor` and `seccomp` security profiles (may be overriden within Dockside profiles)
- `ssh`:
    - `default`: a boolean indicating whether devtainers launched from profiles that do not contain an `ssh` property should have ssh access enabled (default true)