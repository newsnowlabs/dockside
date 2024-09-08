# Security

### Securing profiles

Like Docker, and any service that wraps Docker, Dockside can provide users with superuser access to the host server and filesystem, if configured to do so.

Notably, the default `dockside.json` profile bind-mounts the host's Docker socket (`/var/run/docker.sock`) into Dockside development devtainers. This is necessary to allow Dockside to operate within the default `runc` Docker runtime, but provides users with full access to Docker on the host.

> **N.B.**
>
> 1. **It is the responsibility of the Dockside admin to configure the available profiles, and the profiles that individual users are allowed to launch, such that users are not given unwanted access to host resources.**
> 2. **The _Dockside Sysbox_ profile does not require the host's Docker socket be bind-mounted, but does require [Sysbox](https://github.com/nestybox/sysbox) be pre-installed on the host. Through Sysbox, users can be securely provided with access to Docker-in-Dockside devtainers. Read more about [Dockside and Sysbox](extensions/runtimes/sysbox.md)**

### Securing devtainer services from other devtainers

By default, HTTP(S) or other TCP or UDP services running within a devtainer will be accessible from other devtainers (and those devtainer's developers).

If you would prefer such services be kept private from other devtainers developers, you will need to either ensure all such services listen for connections only on a loopback IP e.g. `127.0.0.1`, or implement a devtainer isolation method.

There exist several main approaches to devtainer isolation:

1. Isolate all devtainers within a network, using a custom Docker network that  blocks inter-container traffic using e.g. `docker network create -o "com.docker.network.bridge.enable_icc=false" -o "com.docker.network.bridge.name=dockside-private" dockside-private`
2. Isolate a set of devtainers from other devtainers by connecting them to a distinct and dedicated Docker network. e.g. Devtainers connected only to `networkA` are not reachable from within `networkB` and vice-versa. Permission to launch (or connect) devtainers to each network may be granted only to the required developers. The Dockside container must be connected to at least one network in common with every devtainer, or it will not be possible to reach the devtainer from within Dockside (so in this example the Dockside container must be connected to both `networkA` and `networkB`). Currently, the Dockside container must be manually connected to additional networks following its launch (as `docker run` supports only one `--network` option). The capability for Dockside to automatically connect itself to additional networks may be provided in a future version.
