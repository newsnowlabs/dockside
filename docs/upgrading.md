# Upgrading

Upgrading Dockside is usually a two-step process:

1. Upgrading the version of the Dockside IDE available to existing devtainers
2. Upgrading the Dockside application (which includes the version of the Dockside IDE launched within any subsequently-launched devtainers)

## Step 1: Upgrade the IDE within running Dockside devtainers

This step will backport any new version(s) of the Dockside IDE that may be embedded within any new Dockside image, to the running Dockside container. Doing this means the new IDE version(s) may be used within existing devtainers after they are next started or restarted. It is generally useful to perform this step before upgrading the Dockside container (as per Step 2 below), to allow the users of existing devtainers to benefit from newer versions of the IDE.

To copy the new IDE from the latest Dockside image (i.e. from `newsnowlabs/dockside:latest`) into the currently running Dockside container, simply run:
```
docker exec <dockside-container> upgrade
```

Alternatively, to copy the new IDE from a test or development Dockside image, where `<image>` is the name of the image, simply run:
```
docker exec <dockside-container> upgrade --image <image>
```

> N.B. You may skip this step if you have no existing devtainers, or if you are not bothered about upgrading the version of the Dockside IDE available within existing devtainers.

## Step 2. Replacing the running Dockside container

This step will upgrade the version of the Dockside client/server app that is running, as well as the version of the IDE embedded within any subsequently-launched devtainers.

### Testing a new Dockside version

It can be a good idea to test a new version of Dockside like this:

1. Stop - but do not remove - your running Dockside container, by running: `docker stop <old-dockside-container>`
2. Backup the directory you have bind-mounted at `/data` (e.g. `~/.dockside`)
3. Launch a new Dockside container by [following the usual instructions](README.md#getting-started). As long as the previous Dockside container is stopped, the new container will be able to bind to the usual ports.
4. If the new Dockside passes testing, clean up by removing the old Dockside container. If it doesn't, then remove the new Dockside container, restore the backed-up `/data` folder, and start the old Dockside container.

> **N.B. It is best to ensure Dockside users know not to launch new devtainers during testing, in case it proves necessary to roll back. Newly-launched devtainers may not be guaranteed to be backwards-compatible with an older version of Dockside.**

### Testing a new Dockside version in parallel

You can test a new version of Dockside without having to disrupt your running Dockside container, by launching Dockside in the usual manner but referencing a copy of the directory currently bind-mounted at `/data`, and listening on alternative ports.

e.g. Assuming you originally launched Dockside with `-v ~/.dockside:/data` then run:

```
cp -a ~/.dockside ~/.dockside.tmp
docker run -it --name dockside \
  -v ~/.dockside.tmp:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 444:443 -p 81:80 \
  newsnowlabs/dockside <ssl-opts>
```

> **Make sure your firewall allows incoming TCP connections on ports 444 and 81.**

If the new Dockside container passes testing, remove it and relaunch it referencing the original `/data` directory and ports. If it doesn't, then just remove the new Dockside container.
