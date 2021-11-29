<p align="center">
    <img alt="//Dockside" src="https://user-images.githubusercontent.com/354555/139592306-696d3946-a4dd-4b6a-98d6-90a9ee177566.png" width="75%"/>
</p>

## Introduction

Dockside is a tool for provisioning lightweight access-controlled IDEs, staging environments and sandboxes - aka _devtainers_ - on local machine, self-hosted on-premises on bare metal or VM, or in the cloud.

By provisioning a devtainer for every fork and branch, Dockside allows collaborative software and product development teams to take lean and iterative development and testing to a highly parallelised extreme.

<a title="Click to view video in HD on YouTube" href="https://www.youtube.com/embed/buAefREyngQ" target="_blank"><img src="https://user-images.githubusercontent.com/354555/135777679-67fd1424-f01f-4072-ac3e-ed910c8711af.gif" alt="Dockside Walkthrough Video" width="100%"></a>

Core features:

- Instantly launch and clone an almost infinite multiplicity of disposable devtainers - one for each task, bug, feature or design iteration.
- Powerful VS Code-compatible IDE.
- HTTPS automatically provisioned for every devtainer.
- User authentication and access control to running devtainers and their web services.
- Fine-grained user and role-based access control to devtainer functionality and underlying system resources.
- Launch devtainers from stock Docker images, or from your own.
- Root access within devtainers, so developers can upgrade their devtainers and install operating system packages when and how they need.

Benefits for developers:

- Switch between and hand over tasks instantly. No more laborious branch switching, or committing code before it’s ready. ‘git stash’ will be a thing of the past.
- Work from anywhere. All you need is a browser.
- Unifying on an IDE within a team can deliver great productivity benefits for collaborative teams through improved knowledge-share, better choices and configuration of plugins and other tooling.
- Develop against production databases (or production database clones) when necessary.

Benefits for code reviewers:

- Access your colleagues’ devtainers directly for code review.
- No more staring at code wondering what it does, or time-consuming setup, when their code is already running.
- Annotate their code directly with your comments as to points they should address.
- To save time, when you know best, apply and test your own fixes directly to their code.

Benefits for product managers and senior management:

- High visibility of product development progress. Access always-on application revisions and works-in-progress, wherever you are in the world.
- Devs can be sometimes be fussy about their choice of IDE, but unifying on an IDE can deliver productivity benefits for collaborative teams through improved knowledge-share and tooling.

Advanced features:

- Runtime agnostic: use runC (Docker's default), [sysbox](https://github.com/nestybox/sysbox), [gvisor](https://gvisor.dev/), or others.
- Firewall or redirect outgoing devtainer traffic using custom Docker networks.
- Apply Docker system resource limits to devtainers, and communicate available system resources to devtainers using [LXCFS](#lxcfs).
- Support for launching [multi-architecture devtainers](#multi-architecture-devtainers) using [qemu-user-static](https://github.com/multiarch/qemu-user-static).
- Access Dockside devtainers via multiple domain names, when needed to stage or simulate multi-domain web applications.

## Host requirements

Dockside is tested on Debian Linux running [Docker Engine](https://docs.docker.com/engine/install/) (the `docker-ce` package suite) and on MacOS and Windows 10 running [Docker Desktop](https://docs.docker.com/get-docker/), and is expected to run on any host with at least 1GB memory running a modern Linux distribution.

## Getting started

> **Installing Docker**
>
>    Dockside is designed to be installed using [Docker](https://www.docker.com/).
>    To install Docker for your platform, go to [https://www.docker.com/](https://www.docker.com/)

Dockside needs an SSL certificate to run. For temporary/trial usage, Dockside may be launched with a built-in or self-signed SSL certificate.

For production usage on an Internet-connected server, Dockside should be launched on a dedicated public domain name (or sub-domain name) with a genuine _wildcard_ SSL certificate for that domain.

Choose from the following options:

1. [Launch locally with built-in SSL cert](#launch-locally-with-built-in-ssl-cert)
2. [Launch anywhere with self-signed SSL cert](#launch-anywhere-with-self-signed-ssl-cert)
3. [Launch in production with auto-generated LetsEncrypt public SSL certificate](#launch-in-production-with-auto-generated-letsencrypt-public-ssl-certificate)
4. [Launch in production with self-supplied SSL certificate](#launch-in-production-with-self-supplied-ssl-certificate)

### Launch locally with built-in SSL cert

1. Launch Dockside on a local machine, with a temporary and convenient built-in SSL certificate
```sh
mkdir -p ~/.dockside
docker run -it --name dockside \
  -v ~/.dockside:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 \
  newsnowlabs/dockside --ssl-builtin
```

2. In your browser, navigate to the Dockside homescreen at [https://www.local.dockside.dev/](https://www.local.dockside.dev). Sign in with the username `admin` and the password output to the terminal, then follow the instructions displayed on-screen.

(You can now [detach](https://docs.docker.com/engine/reference/commandline/attach/) from the Dockside container running back in your terminal by typing `CTRL+P` `CTRL+Q`. Alternatively you can instead launch with `docker run -d` instead of `docker run -it`; if you do this, run `docker logs dockside` to display the terminal output and admin password).

> WARNING: The default Dockside installation embeds a non-secret SSL certificate, for `*.local.dockside.dev` resolving to 127.0.0.1, which should not be used for production usage.

### Launch anywhere with self-signed SSL cert

1. Launch Dockside on a local machine, on-premises server, VM or cloud instance, with a temporary and convenient self-signed SSL certificate:
```sh
mkdir -p ~/.dockside
docker run -it --name dockside \
  -v ~/.dockside:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 \
  newsnowlabs/dockside --ssl-selfsigned
```

2. In your browser, navigate to the Dockside homescreen at the hostname for your machine/VM in your browser. Sign in with the username `admin` and the password output to the terminal, then follow the instructions displayed on-screen.

(You can now [detach](https://docs.docker.com/engine/reference/commandline/attach/) from the Dockside container running back in your terminal by typing `CTRL+P` `CTRL+Q`. Alternatively you can instead launch with `docker run -d` instead of `docker run -it`; if you do this, run `docker logs dockside` to display the terminal output and admin password).

### Launch in production with auto-generated LetsEncrypt public SSL certificate

In order for Dockside to auto-generate an public SSL certificate using LetsEncrypt, it must be delegated responsibility for handling public internet DNS requests for your chosen domain.

You must therefore ensure the server on which you will run Dockside must be able to accept UDP requests on port 53, and preconfigure your chosen Dockside domain (`<my-domain>`) with the following two domain name records:
- `<my-domain> A <my-server-ip>`
- `<my-domain> NS <my-domain>`

These records are needed to tell the public DNS infrastructure that DNS requests for `<my-domain>` should be forwarded to `<my-server-IP>`.

You may then launch Dockside as follows:

```sh
docker run -d --name dockside \
  -v ~/.dockside:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 -p 53:53/udp \
  newsnowlabs/dockside --ssl-letsencrypt --ssl-zone <my-domain>
```

Assuming you have provisioned <my-domain> correctly, Dockside will use LetsEncrypt to generate a public SSL certificate on startup and to regenerate the certificate periodically to ensure it remains current.

View the launch logs by running:
```sh
docker logs -f dockside
```

#### Launch using Google Cloud Deployment Manager

An implementation of the above procedure within [Google Deployment Manager](https://console.cloud.google.com/dm/deployments) is available [here](/examples/cloud/google-deployment-manager/).

To use it, you must first have a managed zone configured within [Google Cloud DNS](https://console.cloud.google.com/net-services/dns/zones).

Then, sign into Cloud Shell, and run:

```sh
git clone https://github.com/newsnowlabs/dockside.git
cd dockside/examples/cloud/google-deployment-manager/
./launch.sh --managed-zone <managed-zone> --dns-name <managed-zone-fully-qualified-subdomain>
```

For example, if your managed zone is called `myzone`, the zone DNS name is `myzone.org`, and your chosen subdomain is `dockside` then run:

```sh
./launch.sh --managed-zone myzone --dns-name dockside.myzone.org
```

For full `launch.sh` usage, including options for configuring cloud machine type, machine zone, and disk size, run `./launch.sh --help`.

### Launch in production with self-supplied SSL certificate

Before launching Dockside copy your self-supplied `fullchain.pem` and `privkey.pem` files for the wildcard SSL certificate for your domain to inside `~/.dockside/certs/` or bind-mount the directory containing these files by adding `-v <certsdir>:/data/certs` to the `docker run` command line e.g.

```sh
docker run -d --name dockside \
  -v ~/.dockside:/data \
  -v <certsdir>:/data/certs \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 \
  newsnowlabs/dockside --ssl-selfsupplied
```

View the launch logs by running:
```sh
docker logs -f dockside
```

Should you update your certificates in `<certsdir>`, then run `docker exec dockside s6-svc -t /etc/service/nginx`.

## Case-study - Dockside in production at NewsNow

Dockside is used in production for all aspects of web application and back-end development and staging (including acceptance testing) of the websites [https://www.newsnow.co.uk/](https://www.newsnow.co.uk/) and [https://www.newsnow.com/](https://www.newsnow.com/) by a team of around seven developers and seven editorial staff plus managers. Running on a KVM-based VM hosted on bare metal in NewsNow's data centre with 64GB memory, NewsNow's instance of Dockside handles 20-30 devtainers running simultaneously.

The precise number can vary depending on the resource-intensiveness of the application being developed. In the past, the VM required only 32GB memory but the memory requirements of the NewsNow application have grown.

The Dockside Theia IDE itself occupies only ~100MB memory per devtainer, so for a very lightweight application an 8GB server or VM could conceivably handle up to 40 simultaneous running devtainers.

Stopped devtainers (which are stopped Docker containers) occupy disk space but not memory, so the number of stopped devtainers is limited only by available disk space on the VM/server running Dockside.

In order to prevent the risk of runaway devtainers from interfering with other developers' work, NewsNow's Dockside VM has an [XFS](https://en.wikipedia.org/wiki/XFS) filesystem mounted at `/var/lib/docker` and its profiles are configured with memory, storage and pids limits appropriate to the development task using the `dockerArgs` profile option and the `docker run` `--memory`, `--storage-opt` and `--pids-limit` options.

As a 24/7 news platform, the NewsNow application is often best developed and tested with live data. To facilitate this, and in keeping with the Dockside disposable container model, NewsNow operates a number of disposable ZFS-based database clones that can be transparently hooked up to running devtainers (through a system of iptables firewall rules and Docker networks). Developers can safely read and even write to these database clones, which are disposed of and refreshed periodically or when a development task is completed.

## Using the Dockside UI

Dockside UI usage should be reasonably self-explanatory.

Click `Launch` to prepare to launch a devtainer. Choose a Profile to indicate the kind of devtainer you wish to launch, then customise the devtainer according to your needs, optionally selecting (depending on the profile):

- choice of docker runtime
- devtainer docker image
- docker network
- the auth/access level for each service preconfigured within the profile
- a list of users allowed to view the devtainer i.e. acccess the devtainer and links to devtainer services displayed on Dockside
- a list of users allowed to develop the devtainer i.e. access the Dockside Theia IDE (which implies rights to view the devtainer too)
- a checkbox for keeping the devtainer private from other admin users (only available to admin users)

When ready, click the green `Launch` button. If errors are encountered launching the devtainer, these will be displayed onscreen.

To edit the developer and users lists, change the connected network, change the auth/access levels for the devtainer's services, or change its privacy setting, click `Edit`, make changes, then `Save`.

To open a preconfigured devtainer service, click the `Open` button adjoining the service.

> To create and customise a Profile before launching devtainers, see [Profiles](#profiles).

## Using the Dockside IDE

Dockside runs a version of the amazing open-source [Theia IDE](https://theia-ide.org/), an Eclipse Foundation project, a version of which is also used as the [Google Cloud IDE](https://ide.cloud.google.com).

Theia aims to be a fully VSCode-compatible IDE, provides an experience highly familiar to VSCode developers, and today seamlessly runs many VSCode extensions, which can be preinstalled or installed on demand via the Extensions tab.

When a devtainer is launched, if `ssh-agent` can be found in the launched image, then Dockside will launch `ssh-agent` in the context of the Theia IDE to allow IDE functions requiring SSH (like `Git: Push` and `Git: Pull`) as well as command-line tools (like `git` and `ssh`) to function. ([Read more about using SSH from within devtainers](#using-ssh-from-within-devtainers))

> **On initial launch of a new devtainer, you must currently add your SSH key to the agent, by running `ssh-add <path-to-key>` within a terminal, before such IDE functions may be used.**

## Configuring and administering Dockside

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

### Security model

Dockside aims to secure host resources such that they may only be used by registered Dockside users as permitted by the user's User record, the Role record corresponding to their role, and by the specification of the Profiles they are permitted to deploy.

As such, registered users are only able to:
1. deploy devtainers if specifically permitted to do so;
2. deploy devtainers from profiles they have been granted access to;
3. deploy or use resources explicitly specified within the profile;
4. deploy or use resources explicitly specified (and not barred by) by their user record or by the role record corresponding to their role.

Read on, to learn about [Profiles](#profiles), [Users](#users) and [Roles](#roles).

> **N.B. For avoidance of doubt, non-registered users may not access the Dockside UI, and may not deploy or configure devtainers. But, non-registered 'users' may access a non-IDE service running within a devtainer if the router auth/access level has been set to `public`.**

### Profiles

Profile `.json` files specify the broad types of devtainer that may be launched within Dockside, and each profile specifies the precise nature of the devtainer and the range of parameters which a user is allowed to customise.

A team admin is expected to add, remove and customise the profiles to meet the needs of their development team.

A profiles today allow the specification of the available user choices for the following Docker container properties: images, bind-mounts, volume-mounts and tmpfs-mounts, networks, runtimes, launch commands.

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
| runtimes | allowed docker runtimes | optional | `["runc"]` | `["runc", "sysbox-runc"]`
| images | allowed docker images (a wildcard may be used to allow the user to specify an arbitrary element of the image string) | mandatory | N/A | `["alpine:latest","i386/alpine:latest"]` |
| unixusers | array of the unix user account for which to run the IDE | optional | `["dockside"]` | `["john","jim"]`
| mounts | tmpfs, bind and/or volume mounts | optional | `{}` | `{"tmpfs": [{ "dst": "/tmp","tmpfs-size": "1G"}], "volume": [{"src": "ssh-keys", "dst":"/home/mycompany/.ssh"}]}`
| runDockerInit | if true, run an init process inside the devtainer | optional | `true` | `true` |
| dockerArgs | arguments to pass verbatim to docker | optional | `[]` | `["--memory", "2G", "--storage-opt", "size=1.2G","--pids-limit", "4000"]` |
| lxcfs | whether to mount [lxcfs](#lxcfs) | optional | as specified in `config.json` | `true` |
| command | [array] command to run on devtainer launch | mandatory if image does not specify a long-running entrypoint or command | `[]` | `["/bin/sh", "-c", "[ -x \"$(which sudo)\" ] || (apk update && apk add sudo;); sleep infinity"]`
| entrypoint | command with which to override image entrypoint | optional | `[]` | `["/my-entrypoint.sh"]` |
| mountIDE | disable mounting the Dockside IDE volume (strictly for use with images, such as the Dockside image, that embed their own IDE volume) | optional | `false` | `true` |

#### Profile routers

A profile may specify zero or more routers. Each router consists of:

- `name`: uniquely identifies the router within the profile (any unique string will do)
- `prefixes`: an array of one or more domain name prefixes that when requested, in conjunction with a correct domain, will select the router (or, the `"*"` wildcard value may otherwise be used)
- `domains`: an array of one or more domain names that when requested, in conjunction with a correct prefix, will select the router (or, the `"*"` wildcard value should otherwise be used)
- `https` (optional): an object specifying, for incoming public https requests selecting the router, the protocol and port within the devtainer to which the request should be forwarded
- `http` (optional): an object specifying, for incoming public http requests selecting the router, the protocol and port within the devtainer to which the request should be forwarded
- `auth`: an array of permitted auth/access levels that may be set on a devtainer for this router (see [auth/access levels](#auth-access-levels))

#### Router auth/access levels

The available router auth/access levels are, from most to least restrictive, are:

- Devtainer owner only (`owner`): router may be accessed only by the devtainer owner (the user who launched the devtainer)
- Devtainer developers only (`developer`): router may be accessed only by users named as developers of the devtainer
- Devtainer developers and viewers only (`viewer`): router may be accessed only by users named as developers or viewers of the devtainer
- Dockside users (`user`): i.e. router may be accessed by any authenticated Dockside user
- Public (`public`): router may be accessed by anyone with the URL, without access-control restrictions

Planned but as-yet not-fully-implemented router auth/access levels, are:
- Devtainer cookie (`containerCookie`) i.e. a secret cookie unique to the devtainer must be presented to access this router

### Users

The `users.json` file describes registered Dockside users. An 'admin' user is the only user specified in the file by default. It is recommended to modify the admin user record with a dedicated username for at least one team admin.

A user record specifies:

- `id`: a unique numeric id, not currently used
- `email`: user's email address, used today to configure `.gitconfig` for the user and potentially in future for automated emails
- `name`: user's display name, used today to configure `.gitconfig` for the user
- `role`: user's role, as configured in `roles.json`
- `permissions`: specific permissions that should be enabled or disabled, in customisation of those conferred from the user's role
- `resources`: host and Dockside resources to which the user should or should not have access
  - `profiles`: profiles the user is permitted to deploy
  - `networks`: docker networks the user's devtainers are permitted to join (subject also to the profile)
  - `images`: docker images the user is permitted to launch (subject also to the profile)
  - `runtimes`: docker runtimes the user is permitted to use using (subject also to the profile)
  - `auth`: the auth/access levels the user is permitted to specify for a devtainer's router (subject also to the devtainer's profile)

You should add one record to `users.json` for each registered user in your team.

The `passwd` file is a text file (in largely standard Unix format) containing one row per user. It should contain a row for each registered user specified in `users.json` that is not disabled, of the form `<username>:<encrypted-password>`. Password may currently be added, changed, or checked, from the host (or any dockside container with access to the host docker socket) using the following command:

```sh
docker exec -it dockside passwd [--check] <username>
```

#### Revoking a user's access to Dockside

> **After deleting a user, or modifying `users.json`, `roles.json` or `passwd` in such a way that a user's access to a running devtainer should be revoked, it is necessary to [restart the Dockside Server](#dockside-server) to ensure any open HTTP(S) or websocket connections made by that user are closed and the user's access completely revoked.**

#### Resources syntax and semantics

Any resource - profiles, networks, images, runtimes, auth - may be set to:

- an array of permitted values
- an array consisting of the wildcard value `"*"` (which indicates all values are allowed, subject to other constraints)
- an object of name-value pairs, where names are resource types and values are `true`/`false` (or `1`/`0`), indicating the use of the resource is  permitted (in the `true` or `1` case) or not permitted (in the `false` or `0` case); the wildcard name `"*"` may also be given with a corresponding value indicating whether use of all other resources are permitted or denied.

All resources specified for a user are computed in addition to (or subtraction from) those already conferred by the user's role, and are _always_ subject to the resource constraints specified within a [profile](#profiles).

### Roles

The syntax for `roles.json` mirrors that for `users.json`.

### config.json

The `config.json` file contains global config for the Dockside instance. Not all properties are user-editable, but those which are include:

- `uidCookie`: an object specifying a unique name and salt for the Dockside authentication cookie; this must be different for every nested instance of Dockside;
- `globalCookie`: for an extra layer of security for the security-conscious, you may specify a name, domain and secret value for a global cookie which must be present before any part of Dockside, including the UI will respond to a web request; use this if you are uncomfortable with either the Dockside UI login screen, or devtainer services that may be set to 'public' to be exposed publicly;
- `lxcfs`: [LXCFS](#lxcfs) is a fuse filesystem that allows processes running with docker containers to measure their own cpu, memory, and disk usage. As not all Docker hosts will have lxcfs installed, it is disabled in Dockside by default, but may be enabled by setting `available: true`. After this, lxcfs may be by default enabled or disabled for all profiles (by setting `enabled` in `config.json` accordingly), however this default may be overriden by the lxcfs setting in any individual profile.

## Security

### Securing profiles

Like Docker, and any service that wraps Docker, Dockside can provide users with superuser access to the host server and filesystem, if configured to do so.

Notably, the default `dockside.json` profile bind-mounts the host's Docker socket (`/var/run/docker.sock`) into Dockside development devtainers. This is necessary to allow Dockside to operate within the default `runc` Docker runtime, but provides users with full access to Docker on the host.

> **N.B.**
>
> 1. **It is the responsibility of the Dockside admin to configure the available profiles, and the profiles that individual users are allowed to launch, such that users are not given unwanted access to host resources.**
> 2. **The _Dockside Sysbox_ profile does not require the host's Docker socket be bind-mounted, but does require [Sysbox](https://github.com/nestybox/sysbox) be pre-installed on the host. Through Sysbox, users can be securely provided with access to [Docker-in-Dockside](#docker-in-dockside) devtainers.**

### Using SSH from within devtainers

To use `git` functionality of the Theia IDE, the `git` command (or other `ssh`-based commands) within the Theia IDE terminal, you will need to provision your devtainer with the reuqired SSH keys.

Dockside runs an instance of `ssh-agent` (currently only where installed in the launched devtainer image) within the context of the Theia IDE.

To provide the Theia IDE with access to the keys, load them into the running `ssh-agent` by running `ssh-add <keyfile>` from a terminal. You only need to do this once after launching (or after stopping and starting) each devtainer.

To automatically provision developers' SSH key files into newly-launched devtainers, configure the relevant profile to mount a docker volume (or bind-mount a host directory) containing your users' encrypted key files. e.g.

```
   "volume": [
      // Use this to share encrypted ssh keys in the named volume among team members.
      { "src": "myprofile-ssh-keys", "dst": "/home/newsnow/.ssh" }
   ]
```

(For an example of how this may be done, please see the [`dockside.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/dockside.json) profile.)

> **N.B.**
> 
> 1. **Although this approach means that users of a profile will have access to each others public and private key files, it will not confer access to a user's key _as long as_ the private key file is encrypted.**
> 2. **It is __not recommended__ to share unencrypted SSH keys files between users in this fashion.**
> 3. **If you share access to a devtainer IDE, you share access to any unencrypted keys/key files within the container. We recommend __only using encrypted key files__, running `ssh-add` to decrypt them as needed, and running `ssh-add -D` to delete stored unencrypted identities, or `ssh-add -x` to lock the agent, before sharing the IDE with untrusted users.**

### Root access within Devtainers

Upon launch of a devtainer, Dockside configures `sudo` within the devtainer to allow the IDE user (the `unixuser`) to `sudo <command>` (without password) for any command.

Dockside currently provides all devtainer developers with root access within devtainers where `sudo` is available.

> **N.B.**
> 
> 1. **Sudo functionality will only be available in devtainers: (a) launched from images with `sudo` pre-installed; or, (b) where a profile launch `command` is provided that installs the `sudo` package into the running container e.g. the [`alpine.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/alpine.json) profile.**
> 2. **An option to disable `sudo` functionality may be provided in a future Dockside version.**
> 3. **An option to preconfigure the devtainer root password (to enable `su` functionality) may be provided in a future Dockside version.**

### Securing devtainer services from other devtainers

By default, HTTP(S) or other TCP or UDP services running within a devtainer will be accessible from other devtainers (and those devtainer's developers).

If you would prefer such services be kept private from other devtainers developers, you will need to either ensure all such services listen for connections only on a loopback IP e.g. `127.0.0.1`, or implement a devtainer isolation method.

There exist several main approaches to devtainer isolation:

1. Isolate all devtainers within a network, using a custom Docker network that  blocks inter-container traffic using e.g. `docker network create -o "com.docker.network.bridge.enable_icc=false" -o "com.docker.network.bridge.name=dockside-private" dockside-private`
2. Isolate a set of devtainers from other devtainers by connecting them to a distinct and dedicated Docker network. e.g. Devtainers connected only to `networkA` are not reachable from within `networkB` and vice-versa. Permission to launch (or connect) devtainers to each network may be granted only to the required developers. The Dockside container must be connected to at least one network in common with every devtainer, or it will not be possible to reach the devtainer from within Dockside (so in this example the Dockside container must be connected to both `networkA` and `networkB`). Currently, the Dockside container must be manually connected to additional networks following its launch (as `docker run` supports only one `--network` option). The capability for Dockside to automatically connect itself to additional networks may be provided in a future version.

## Upgrading

There are several strategies available for upgrading Dockside, or Dockside components such as the Dockside Theia IDE.

### 1. Replacing the running Dockside container

This is the simplest and most general method of upgrading the Dockside system and client/server app, but it will not upgrade the version of the Theia IDE running within _existing_ devtainers, only new ones.

Always backup your `/data` directory (i.e. the host directory you have bind-mounted at `/data`) before proceeding.

It is often a good idea to test a new version of Dockside:

1. Stop - but do not remove - your running Dockside container.
2. Launch and test the new Dockside container. As long as the previous Dockside container is stopped, the new one can bind to the correct ports.
3. If everything works fine, remove the old Dockside container. If not, remove the new container, restore the backed-up `/data` folder, and restart the old container.

> **N.B. It is best to ensure Dockside users know not to launch new devtainers during testing, in case it proves necessary to roll back. Newly-launched devtainers may not be guaranteed to be backwards-compatible with an older version of Dockside.**

As variations on this theme, you can test the new version of Dockside with a backup of the original `/data` directory bind-mounted. You can also test the new version of Dockside without having to stop your running Dockside container, by modifying the `docker run` command line to listen on alternative ports e.g. `-p 444:443 -p 81:80`.

> **N.B. Ensure your Dockside /data directory is bind-mounted from the host or mounted from a Docker volume, otherwise its contents will be lost when the Dockside container is removed!**

### 2. Upgrading Dockside codebase within running Dockside container

This method will upgrade the version of the client/server app and daemons within the running dockside container. To do this from the host, obtain a terminal on the dockside container using `docker exec -it <dockside-container-name>` and then run:

```sh
cd ~/dockside
git pull
cd app/client && . ~/.nvm/nvm.sh && npm run build
sudo s6-svc -t /etc/service/nginx
sudo s6-svc -t /etc/service/docker-event-daemon
```

### 3. Upgrading the IDE running within running Dockside devtainers

This method will install an upgraded version of the Dockside IDE within running (and new) devtainers. It is useful to combine this method with method #1 to upgrade the IDE running within already-launched devtainers launched, before upgrading the Dockside container.

Procedures for this are yet to be fully documented or automated but, roughly put, involve: launching or creating a new Dockside container from latest image; copying the `/opt/dockside/ide/theia/theia-<version>` folder from the new container to the old Dockside container's `/opt/dockside/ide/theia` folder. This can be done within the running Dockside container, using `docker container create --name dockside-new newsnowlabs/dockside:latest && sudo docker cp dockside-new:/opt/dockside/ide/theia/<theia-path>/ /opt/dockside/ide/theia/ && docker rm dockside-new` then pruning the redundant volume. It could also be implemented by launching the new Dockside container with the old Dockside container's `/opt/dockside` bind-mounted at a known location and specific command line arguments that tell it to copy its `/opt/dockside/ide/theia/` contents to this bind-mounted location.

## Backups

Restic, or other backup tools, may be run on the host to take periodic devtainers backups.

> **N.B. Scripts for using `restic` to take incremental devtainers backups may be provided in a future release.**

## Extensions

### LXCFS

[LXCFS](https://linuxcontainers.org/lxcfs/introduction/) is a simple userspace filesystem that allows processes running with docker containers to measure their own cpu, memory, and disk usage.

On a Debian Dockside host, it can be installed using:

```
sudo apt install lxcfs
```

### Multi-architecture devtainers

Multi-architecture devtainers can be launched by installing [qemu-user-static](https://github.com/multiarch/qemu-user-static).

On a Debian Dockside host, it can be installed using:

```
sudo apt-get install qemu binfmt-support qemu-user-static
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

> **You can test you have installed qemu-user-static correctly, by launching a devtainer from the Debian profile, and selecting either the `arm32v7/debian`, `arm64v8/debian`, `mips64le/debian`, `ppc64le/debian` or `s390x/debian` image.**

### Docker-in-Dockside devtainers

It may be useful for developers to be able to run Docker within their devtainers.

Within a closely-knit development team it may be considered acceptable to provide access to the host's `/var/run/docker.sock` within developers' devtainers.

For the more general case, we recommend using Dockside with [Sysbox](https://github.com/nestybox/sysbox), an _open-source, next-generation "runc" that empowers rootless containers to run workloads such as Systemd, Docker, Kubernetes, just like VMs_.

To install Sysbox on your host, please see the [Sysbox User Guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install.md).

Following Sysbox installation, configuring Dockside to use Sysbox should be as easy as modifying your devtainer profiles by:

1. Adding `sysbox-runc` to the `runtimes` section
2. [Optionally] Adding an anonymous volume mounted at `/var/lib/docker` to the `mounts` section

### Self-contained Docker-in-Dockside

As an alternative to using [Sysbox](https://github.com/nestybox/sysbox) as the runtime for launching devtainers (described above), Dockside may instead itself be
launched within the Sysbox runtime and without bind-mounting `/var/run/docker.sock` from the host.

When Dockside detects it is not launched within the `runc` runtime, or when Dockside is launched with `--run-dockerd`, Dockside
will attempt to launch its own `dockerd` within the Dockside container.

Thereafter, when Dockside launches a devtainer using the standard `runc` runtime, it will be launched within the Docker context of the
'parent' Dockside Sysbox container and will have no relationship or access to the Docker daemon running on the host.

The benefits of this use of Sysbox are different to [Docker-in-Dockside devtainers](#docker-in-dockside-devtainers):

| [Docker-in-Dockside devtainers](#docker-in-dockside-devtainers) | [Self-contained Docker-in-Dockside](#self-contained-docker-in-dockside) |
| - | - |
| Launch Dockside using `runc` | Launch Dockside using `sysbox` |
| Host's `/var/run/docker.sock` must be bind-mounted | Host's `/var/run/docker.sock` must not be bind-mounted |
| Dockside uses host's Docker daemon | Dockside benefits from increased isolation from host, and launches and uses its own dedicated Docker daemon, running independently of the host's Docker daemon (and its image and container storage) |
| Devtainers may be launched using `runc` or `sysbox` | Devtainers must be launched using `runc` |
| Devtainers launched using `runc` and bind-mounting `/var/run/docker.sock` share and use the host's Docker daemon (and its image and container storage) | Devtainers bind-mounting `/var/run/docker.sock` share and use Dockside's own dedicated Docker daemon (and its image and container storage), running independently of the host's Docker daemon (and its image and container storage) |
| Devtainers launched using `sysbox` benefit from increased isolation from host and may each run their own Docker daemon independently of each other and of the host (each with their own image and container storage), providing developers with their own independent Docker installation | Devtainers may not be launched using `sysbox` |
| **Use when**: you want to give developers fully-isolated devtainers, optionally with their own fully-independent Docker installation | **Use when:** you want to keep Dockside and its devtainers entirely isolated from your host, and do not need devtainers to run Docker or do not mind shared access to the Dockside Docker daemon |

## Developing Dockside

The simplest way to develop Dockside is within Dockside!

Dockside can also be developed and built within Dockside within Dockside, or indeed {within Dockside}^N for any reasonable N >= 1.

Simply:

1. Launch a devtainer from the _Dockside_ profile.
2. Open the devtainer IDE
3. `git pull` the latest main branch from the Github repo
4. Modify the code, rebuilding [the dockside client](#dockside-client) and restarting the [server](#dockside-server) and [event daemon](#dockside-event-daemon) as necessary.
5. Test, by clicking `Open` on the devtainer `dockside` router. Admin login credentials can be obtained by running `docker logs <devtainer-name>` within the IDE terminal.
6. Build a test Dockside image, and launch within a new Dockside devtainer.

### Dockside application components

The main components of the Dockside application are:

1. The Request Proxy, written in Perl and embedded in NGINX using mod-http-perl 
2. The [Dockside Server](#dockside-server), currently written in Perl and also embedded in NGINX using mod-http-perl
3. The [Dockside Client](#dockside-client), written in Vue (HTML/CSS/JavaScript)
4. The [Dockside Event Daemon](#dockside-event-daemon), written in Perl

Additional optionally-enabled components are:

1. A Dehydrated service, which generates and maintains LetsEncrypt SSL certificates using [dehydrated](https://github.com/dehydrated-io/dehydrated)
2. A Bind9 service, which is needed to support the generation of LetsEncrypt wildcard SSL certificates
3. A Logrotate service, which rotates Dockside and NGINX logs.

### Dockside client

To rebuild the client, run:

```sh
cd ~/dockside/app/client && . ~/.nvm/nvm.sh && npm run build
```

To watch continuously for changes to client code, run:

```sh
cd ~/dockside/app/client && . ~/.nvm/nvm.sh && npm run start
```

### Dockside server

To restart the Dockside server, run:

```sh
sudo s6-svc -t /etc/service/nginx
```

### Dockside event daemon

To restart the Dockside server, run:

```sh
sudo s6-svc -t /etc/service/docker-event-daemon
```

### Documentation

To rebuild the documentation html, run:

```sh
~/.local/bin/mkdocs build
```

## Building

A Dockside image can be built directly from the repo, on any host running Docker - and even within a Dockside devtainer.

To build a new `dockside:test` image :

```
./build/build.sh --tag test
```

You may now test your newly-built image, by launching a new Dockside devtainer and selecting the `newsnowlabs/dockside:test` image from the devtainer launch menu.

> **N.B.**
> 
> - **To test changes to the IDE or IDE launch code, be sure to launch using the `dockside.json` profile.**
> - **To test any other changes, using the stable/production IDE embedded in the 'outer' running Dockside instance, launch using the `dockside-failsafe.json` profile.**

## Bugs, issues and support

If you are experiencing an issue or believe you have found a bug, please [raise an issue](https://github.com/newsnowlabs/dockside/issues) or contact via on the [NewsNow Labs Slack Workspace](https://join.slack.com/t/newsnowlabs/shared_invite/zt-wp54l05w-0DTxuc_n8uISJRtks3Xw3A).

## Contributing

If you would like to contribute a bugfix, patch or feature, we'd be delighted.

Please just [raise an issue](https://github.com/newsnowlabs/dockside/issues/new) or contact us on our [NewsNow Labs Slack Workspace](https://join.slack.com/t/newsnowlabs/shared_invite/zt-wp54l05w-0DTxuc_n8uISJRtks3Xw3A).

If you would like to assist with an item from the [roadmap](#roadmap), please read on.

## Contact

Github: [Raise an issue](https://github.com/newsnowlabs/dockside/issues/new)

Slack: [NewsNow Labs Slack Workspace](https://join.slack.com/t/newsnowlabs/shared_invite/zt-wp54l05w-0DTxuc_n8uISJRtks3Xw3A)

Email: [dockside@NewsNow.co.uk](mailto:dockside@NewsNow.co.uk)

We are typically available Monday-Friday, 9am-5pm London time.

## Roadmap

Where are we taking Dockside? As Dockside today satisfactorily serves the needs of the NewsNow development team, its roadmap currently remains highly flexible. We have a list of features we think could be great to add, but we now want to hear from you what you would most value to see added to Dockside.

For our current ideas/plans, see our [draft roadmap](roadmap.md).

## Thank you

Thank you _very much_ for using and/or contributing and/or spreading the word about Dockside. We hope you find it helps your team be more and more productive.

## Credits

Thanks to [Struan Bartlett](https://github.com/struanb) for conceiving the model of iterative web development through the use of ready-built, stageable and disposable development environments running web-based IDEs, and for leading the development of Dockside.

Thanks also to other members of the NewsNow development team for contributing the Dockside Vue client, design and architectural ideas, support and advice, code and code-reviews; for coining the term _devtainers_; and for the Dockside logo concept.

Thanks also to the entire design and development, editorial and testing teams at [NewsNow](https://www.newsnow.co.uk/about/) for so enthusiastically adopting containerised development working practices and for subjecting Dockside to so many years of robust use (and abuse) during the course of their daily iterative development, evaluation and testing of the [NewsNow](https://www.newsnow.co.uk/) platform - and proving the value of this development model.

Thanks last but not least to [NewsNow](https://www.newsnow.co.uk/about/), _The Independent News Discovery Platform_, for sponsoring the development of Dockside.

## Licence and legals

This project (known as "Dockside"), comprising the files in this Git repository,
is copyright 2017-2021 NewsNow Publishing Limited and contributors.

Dockside is an open-source project licensed under the Apache License, Version 2.0 (the "License");
you may not use Dockside or its constituent files except in compliance with the License.

You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0).

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

> N.B. In order to run, Dockside relies upon other third-party open-source software dependencies that are separate to and
independent from Dockside and published under their own independent licences.
>
> Dockside Docker images made available at [https://hub.docker.com/repository/docker/newsnowlabs/dockside](https://hub.docker.com/repository/docker/newsnowlabs/dockside) are distributions
> designed to run Dockside that comprise: (a) the Dockside project source and/or object code; and
> (b) third-party dependencies that Dockside needs to run; and which are each distributed under the terms
> of their respective licences.

### Trade marks

Dockside and devtainer are trade marks of NewsNow Publishing Limited. All rights reserved.
