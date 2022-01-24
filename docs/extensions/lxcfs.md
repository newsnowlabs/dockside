# LXCFS

[LXCFS](https://linuxcontainers.org/lxcfs/introduction/) is a simple FUSE filesystem that allows processes running with docker containers to measure their own cpu, memory, and disk usage.

On a Debian or Ubuntu Dockside host, it can be installed using:

```
sudo apt install lxcfs
```

As Dockside hosts will not generally have LXCFS pre-installed, Dockside has LXCFS support disabled in by default. 

So after installing LXCFS, Dockside support for it must be enabled by setting `available: true` in the `lxcfs` property in `config.json`.

Henceforth, LXCFS in devtainers may by default be enabled (or disabled) for all profiles by setting `default: true` (or `default: false`) respectively. However, this default setting may be overriden for specific profiles by specifying `lxcfs: true` or `lxcfs: false` within the specific profile.