# Alternative runtimes

Dockside is runtime-agnostic. By default it uses the standard `runc` runtime supplied by Docker, but it also supports a range of alternative runtimes for specialised use cases. Available runtimes are autodetected from the host's Docker daemon, so adding `["*"]` to the `runtimes` field of a profile is enough to expose all installed runtimes to users.

## Sysbox

[Sysbox](https://github.com/nestybox/sysbox) is an open-source, next-generation OCI runtime that empowers rootless containers to run workloads such as Systemd, Docker, and Kubernetes — just like VMs — without requiring privileged containers.

Dockside supports Sysbox in two different configurations.

### Sysbox 'Docker-in-Dockside' devtainers

It may be useful for developers to be able to run Docker within their devtainers.

Within a closely-knit development team it may be considered acceptable to provide access to the host's `/var/run/docker.sock` within developers' devtainers.

For the more general case, we recommend using Dockside with [Sysbox](https://github.com/nestybox/sysbox), an _open-source, next-generation "runc" that empowers rootless containers to run workloads such as Systemd, Docker, Kubernetes, just like VMs_.

To install Sysbox on your host, please see the [Sysbox User Guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install.md).

Following Sysbox installation, configuring Dockside to use Sysbox should be as easy as modifying your devtainer profiles by:

1. Adding `sysbox-runc` to the `runtimes` section (or using `["*"]` to autodetect all available runtimes, which will include `sysbox-runc` once installed)
2. [Optionally] Adding an anonymous volume mounted at `/var/lib/docker` to the `mounts` section

### Self-contained Docker-in-Dockside

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

## RunCVM

[RunCVM](https://github.com/newsnowlabs/runcvm) is a Dockside-developed OCI runtime shim that runs Docker containers as lightweight KVM virtual machines, while preserving the standard `docker run` / `docker exec` workflow.

**Key use cases:**

- **Full kernel isolation**: each devcontainer runs its own Linux kernel, making it completely isolated from the host kernel and from other devcontainers.
- **KVM workloads on amd64**: run workloads that require `/dev/kvm`, Systemd as PID 1, kernel modules, or low-level networking inside a devcontainer.
- **Stronger security boundary**: hardware virtualisation provides a stronger security boundary than namespace/cgroup-based isolation.

**Requirements:** RunCVM requires an amd64 host with KVM support (`/dev/kvm` available).

To install RunCVM, see the [RunCVM README](https://github.com/newsnowlabs/runcvm). Once installed, add `runcvm` to the `runtimes` section of your Dockside profiles (or use `["*"]` to autodetect).

## gVisor

[gVisor](https://gvisor.dev/) is a Google-developed application kernel written in Go that intercepts and handles system calls in user space, providing a sandboxed environment with a reduced host kernel attack surface.

**Key use cases:**

- **Sandboxed devcontainers**: run untrusted or externally-sourced code in a devcontainer with gVisor's `runsc` runtime to limit exposure to kernel vulnerabilities.
- **AI agent isolation**: pair with Dockside's per-network firewall rules to constrain both system-call surface and network reachability for AI coding agent sessions.

**Requirements:** gVisor (`runsc`) must be installed on the host. See the [gVisor installation guide](https://gvisor.dev/docs/user_guide/install/).

Once installed, the `runsc` runtime will be autodetected by Dockside when using `["*"]` in a profile's `runtimes` field, or you can add it explicitly.

> **Note:** gVisor does not support all Linux system calls; some workloads that depend on uncommon kernel interfaces may not function correctly under `runsc`. Test your devcontainer images under gVisor before rolling out to your team.
