# Sysbox runtime

[Sysbox](https://github.com/nestybox/sysbox) is an open-source, next-generation runtime ("runc") that empowers rootless containers to run workloads such as Systemd, Docker, Kubernetes, just like VMs.

Dockside supports Sysbox in two different configurations.

## Sysbox 'Docker-in-Dockside' devtainers

It may be useful for developers to be able to run Docker within their devtainers.

Within a closely-knit development team it may be considered acceptable to provide access to the host's `/var/run/docker.sock` within developers' devtainers.

For the more general case, we recommend using Dockside with [Sysbox](https://github.com/nestybox/sysbox), an _open-source, next-generation "runc" that empowers rootless containers to run workloads such as Systemd, Docker, Kubernetes, just like VMs_.

To install Sysbox on your host, please see the [Sysbox User Guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install.md).

Following Sysbox installation, configuring Dockside to use Sysbox should be as easy as modifying your devtainer profiles by:

1. Adding `sysbox-runc` to the `runtimes` section
2. [Optionally] Adding an anonymous volume mounted at `/var/lib/docker` to the `mounts` section

## Self-contained Docker-in-Dockside

As an alternative to using [Sysbox](https://github.com/nestybox/sysbox) as the runtime for launching devtainers (described above), Dockside may instead itself be
launched within the Sysbox runtime and without bind-mounting `/var/run/docker.sock` from the host.

When Dockside detects it is not launched within the `runc` runtime, or when Dockside is launched with `--run-dockerd`, Dockside
will attempt to launch its own `dockerd` within the Dockside container.

Thereafter, when Dockside launches a devtainer using the standard `runc` runtime, it will be launched within the Docker context of the
'parent' Dockside Sysbox container and will have no relationship or access to the Docker daemon running on the host.

The benefits of this use of Sysbox are different to Docker-in-Dockside devtainers:

| Docker-in-Dockside devtainers | Self-contained Docker-in-Dockside |
| - | - |
| Launch Dockside using `runc` | Launch Dockside using `sysbox` |
| Host's `/var/run/docker.sock` must be bind-mounted | Host's `/var/run/docker.sock` must not be bind-mounted |
| Dockside uses host's Docker daemon | Dockside benefits from increased isolation from host, and launches and uses its own dedicated Docker daemon, running independently of the host's Docker daemon (and its image and container storage) |
| Devtainers may be launched using `runc` or `sysbox` | Devtainers must be launched using `runc` |
| Devtainers launched using `runc` and bind-mounting `/var/run/docker.sock` share and use the host's Docker daemon (and its image and container storage) | Devtainers bind-mounting `/var/run/docker.sock` share and use Dockside's own dedicated Docker daemon (and its image and container storage), running independently of the host's Docker daemon (and its image and container storage) |
| Devtainers launched using `sysbox` benefit from increased isolation from host and may each run their own Docker daemon independently of each other and of the host (each with their own image and container storage), providing developers with their own independent Docker installation | Devtainers may not be launched using `sysbox` |
| **Use when**: you want to give developers fully-isolated devtainers, optionally with their own fully-independent Docker installation | **Use when:** you want to keep Dockside and its devtainers entirely isolated from your host, and do not need devtainers to run Docker or do not mind shared access to the Dockside Docker daemon |

