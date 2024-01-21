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
| networks | allowed docker networks | mandatory | N/A | `["bridge"]`
| runtimes | allowed docker runtimes | optional | `["runc"]` | `["runc", "sysbox-runc", "runcvm"]`
| images | allowed docker images (a wildcard may be used to allow the user to specify an arbitrary element of the image string) | mandatory | N/A | `["alpine:latest","i386/alpine:latest"]` |
| unixusers | array of the unix user account for which to run the IDE | optional | `["dockside"]` | `["john","jim"]`
| mounts | tmpfs, bind and/or volume mounts | optional | `{}` | `{"tmpfs": [{ "dst": "/tmp","tmpfs-size": "1G"}], "volume": [{"src": "ssh-keys", "dst":"/home/mycompany/.ssh"}]}`
| runDockerInit | if true, run an init process inside the devtainer | optional | `true` | `true` |
| dockerArgs | arguments to pass verbatim to docker | optional | `[]` | `["--memory", "2G", "--storage-opt", "size=1.2G","--pids-limit", "4000"]` |
| lxcfs | whether to mount [lxcfs](extensions/lxcfs.md) | optional | as specified in `config.json` | `true` |
| security | `docker run` security options | optional | as specified in `config.json` | `{ "apparmor": "unconfined", "seccomp": "unconfined" }` |
| command | [array] command to run on devtainer launch | mandatory if image does not specify a long-running entrypoint or command | `[]` | `["/bin/sh", "-c", "[ -x \"$(which sudo)\" ] || (apk update && apk add sudo;); sleep infinity"]`
| entrypoint | command with which to override image entrypoint | optional | `[]` | `["/my-entrypoint.sh"]` |
| mountIDE | disable mounting the Dockside IDE volume (strictly for use with images, such as the Dockside image, that embed their own IDE volume) | optional | `false` | `true` |
| ssh | whether to enable ssh access | optional | as specified in `config.json` | `true` |

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
    - `networks`: Docker networks the user's devtainers are permitted to join, subject also to the profile (object or array)
    - `images`: Docker images the user is permitted to launch, subject also to the profile (object or array)
    - `runtimes`: Docker runtimes the user is permitted to use using, subject also to the profile (object or array)
    - `auth`: the auth/access levels the user is permitted to specify for a devtainer's router, subject also to the devtainer's profile (object or array)
- `ssh`:
    - `authorized_keys`: an array of standard ssh authorized keys strings that will be automatically written to devtainers' `~/.ssh/authorized_keys` files for devtainers owned by, or shared with, the user (as 'developer')

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

- `profiles`: choose from available profile filenames
- `networks`: choose from available Docker networks
- `images`: choose from available Docker images
- `runtimes`: choose from available Docker runtimes
- `auth`: choose from the hardcoded [auth/access levels](#router-auth%2Faccess-levels)

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