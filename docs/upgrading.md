# Upgrading

Upgrading Dockside is a seamless one-step process. Dockside's entrypoint now upgrades the system binaries and IDEs available to new and existing dev containers automatically, assuming Dockside was launched with a named, rather than anonymous, `/opt/dockside` volume-mount.

Some advanced test and upgrade strategies follow.

### Testing a new Dockside version while old version stopped

It can be a good idea to test a new version of Dockside like this:

1. Stop - but do not remove - your running Dockside container, by running: `docker stop <old-dockside-container>` or `docker compose down`.
2. Backup the directory you have bind-mounted at `/data` (e.g. `~/.dockside`)
3. Launch a new Dockside container by [following the usual instructions](README.md#getting-started). As long as the previous Dockside container is stopped, the new container will be able to bind to the usual ports.
4. If the new Dockside passes testing, clean up by removing the old Dockside container. If it doesn't, then remove the new Dockside container, restore the backed-up `/data` folder, and start the old Dockside container.

> **N.B. It is best to ensure Dockside users know not to launch new devtainers during testing, in case it proves necessary to roll back. Newly-launched devtainers may not be guaranteed to be backwards-compatible with an older version of Dockside.**

### Testing a new Dockside version in parallel

You can test a new version of Dockside without having to disrupt your running Dockside container, by launching Dockside in the usual manner but referencing a copy of the directory currently bind-mounted at `/data`, and listening on alternative ports (e.g. 444 and 81, instead of the standard 443 and 80, respectively).

e.g. Assuming you originally launched Dockside with `docker run -v ~/.dockside:/data` then run:

```sh
mkdir -p ~/.dockside.tmp && \
docker run -it --name dockside \
  -v ~/.dockside.tmp:/data \
  --mount=type=volume,src=dockside_ide,dst=/opt/dockside \
  --mount=type=volume,src=dockside_hostkeys,dst=/opt/dockside/host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 444:443 -p 81:80 \
  --security-opt=apparmor=unconfined \
  newsnowlabs/dockside <arguments>
```

> **Note:**
> - If you launch with Docker Compose, create a modified `docker-compose.yml` accordingly.
> - Configure your firewall to *allow incoming TCP connections on ports 444 and 81*.

If the new Dockside container passes testing, remove it and relaunch it referencing the original `/data` directory and ports. If it doesn't, then just remove the new Dockside container.
