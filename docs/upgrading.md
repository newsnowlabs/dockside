# Upgrading

Upgrading Dockside is a seamless one-step process. Dockside's entrypoint now upgrades the system binaries and IDEs available to new and existing dev containers automatically, assuming Dockside was launched with a named, rather than anonymous, `/opt/dockside` volume-mount.

Some advanced test and upgrade strategies follow.

### Stopping and restarting Dockside

A stop or restart of the Dockside container (`docker compose stop`, `docker compose restart`, `docker compose down`, `docker stop`) lets work already in flight finish before the container is killed: hook runs, and devcontainer creates that have reached Docker. Docker waits for the container's stop grace, then kills it.

The grace must be at least the longest hook run you allow plus a margin for recording its outcome. `docker-compose.yml` sets `stop_grace_period: 360s` for the default hook time limit of 300 s (`hooks.defaultTimeoutSeconds` in `config.json`); the `docker run` form in the [README](README.md#quick-start--launch-locally-with-integrated-ssl-certificate) passes `--stop-timeout 360` for the same reason. If you raise `hooks.defaultTimeoutSeconds`, or run hooks with a longer `--timeout`, raise the grace to match. Without it, Docker's default grace of 10 s kills the container before any hook can complete.

To stop without waiting, pass a shorter grace on the command itself: `docker compose stop -t 5` or `docker stop -t 5`. This kills every process inside the container once the time is up, including any hook run and any devcontainer create in progress; a create interrupted this way is resumed when Dockside restarts, and a hook run's outcome is recovered from Docker when it is next read.

A create that no running worker is driving, whether interrupted by a stop or abandoned mid-pull by a restart, is picked up by the restarted server's first sweep and thereafter every `appServer.reconcileIntervalSeconds` (`config.json`; 60 s by default). The value is read when app-server starts, so a change takes effect on its next restart.

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
