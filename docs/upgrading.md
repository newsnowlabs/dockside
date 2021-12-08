# Upgrade strategies

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

