# Alternative runtimes

Dockside is runtime-agnostic. It can launch devcontainers in a variety of runtimes, and Dockside itself can be launched in a variety of runtimes.

There are two distinct ways an alternative runtime can be used:

- **Launching devcontainers in an alternative runtime** gives each developer's devcontainer the capabilities of that runtime — for example, an isolated Docker daemon via Sysbox, hardware-virtualised kernel isolation via RunCVM, or a sandboxed system-call surface via gVisor.
- **Launching Dockside itself in an alternative runtime** (Sysbox or RunCVM) goes further: Dockside runs inside an isolated container with its own `dockerd`, entirely independent of the host's Docker daemon, its image store, and its container storage.

Both modes are supported by Sysbox and RunCVM; gVisor is supported as a devcontainer runtime only.

Available runtimes are autodetected from the host's Docker daemon. Adding `["*"]` to the `runtimes` field of a profile exposes all installed runtimes to users at launch time, with no profile changes needed when new runtimes are added.

## Sysbox

[Sysbox](https://github.com/nestybox/sysbox) is an open-source, next-generation OCI runtime that empowers rootless containers to run workloads such as Systemd, Docker, and Kubernetes — just like VMs — without requiring privileged containers.

To install Sysbox on your host, see the [Sysbox User Guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install.md).

### Running devcontainers with Sysbox

Running devcontainers under Sysbox allows each developer to have a fully isolated Docker installation within their devcontainer — able to run Systemd, Docker, Kubernetes and other workloads that require a fuller kernel environment.

Within a closely-knit development team it may be considered acceptable to provide access to the host's `/var/run/docker.sock` within developers' devtainers. For the more general case, Sysbox provides isolated Docker-in-devcontainer without that risk.

Configuring Dockside to use Sysbox for devcontainers is as simple as modifying your profiles:

1. Add `sysbox-runc` to the `runtimes` section (or use `["*"]` to autodetect all available runtimes, which will include `sysbox-runc` once installed).
2. Optionally add an anonymous volume mounted at `/var/lib/docker` to the `mounts` section to give each devcontainer its own persistent Docker storage.

### Running Dockside itself with Sysbox

As an alternative to using Sysbox only for devcontainers, Dockside may itself be launched within the Sysbox runtime (and without bind-mounting `/var/run/docker.sock` from the host). In this configuration Dockside runs its own `dockerd` entirely independently of the host.

When Dockside detects it is not running under the `runc` runtime, or when launched with `--run-dockerd`, it will start its own `dockerd` inside the Dockside container. Devcontainers launched thereafter are managed by that dedicated daemon and have no relationship to the host's Docker daemon.

The trade-offs between the two Sysbox configurations are:

| | Devcontainers run under Sysbox | Dockside itself runs under Sysbox |
| - | - | - |
| **Launch Dockside using** | `runc` | `sysbox` |
| **Host `/var/run/docker.sock`** | Must be bind-mounted | Must not be bind-mounted |
| **Dockside's Docker daemon** | Host's daemon | Dockside's own dedicated daemon |
| **Devtainer runtimes available** | `runc` or `sysbox` | `runc` only |
| **Devtainers with `/var/run/docker.sock`** | Share the host daemon | Share Dockside's dedicated daemon |
| **Sysbox devcontainers** | Each gets its own isolated Docker daemon | Not supported |
| **Use when** | You want developers to have fully-isolated devcontainers, optionally each with their own independent Docker installation | You want to keep Dockside and all its devcontainers entirely isolated from your host |

## RunCVM

[RunCVM](https://github.com/newsnowlabs/runcvm) is a Dockside-developed OCI runtime shim that runs Docker containers as lightweight KVM virtual machines, while preserving the standard `docker run` / `docker exec` workflow.

**Requirements:** RunCVM requires an amd64 host with KVM support (`/dev/kvm` available). To install RunCVM, see the [RunCVM README](https://github.com/newsnowlabs/runcvm).

Once installed, add `runcvm` to the `runtimes` section of your Dockside profiles (or use `["*"]` to autodetect).

### Running devcontainers with RunCVM

Each devcontainer launched under RunCVM runs as a KVM virtual machine with its own Linux kernel. Key use cases:

- **Full kernel isolation**: each devcontainer is completely isolated from the host kernel and from other devcontainers — a much stronger boundary than namespace/cgroup isolation.
- **KVM workloads**: run workloads that require `/dev/kvm`, Systemd as PID 1, kernel modules, or low-level networking.
- **Stronger security for AI agents**: hardware virtualisation limits the blast radius of a compromised or runaway AI coding session.

### Running Dockside itself with RunCVM

Just as with Sysbox, Dockside can itself be launched as a RunCVM devcontainer. This gives Dockside a fully isolated environment: Dockside runs its own `dockerd` (via `--run-dockerd`) inside a KVM VM, with no access to the host's Docker daemon. See the example [`92-dockside-runcvm.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/92-dockside-runcvm.json) profile for a working configuration.

## gVisor

[gVisor](https://gvisor.dev/) is a Google-developed application kernel written in Go that intercepts and handles system calls in user space, providing a sandboxed environment with a reduced host kernel attack surface.

**Requirements:** gVisor (`runsc`) must be installed on the host. See the [gVisor installation guide](https://gvisor.dev/docs/user_guide/install/). Once installed, `runsc` will be autodetected when using `["*"]` in a profile's `runtimes` field.

**Key use cases:**

- **Sandboxed devcontainers**: run untrusted or externally-sourced code with gVisor's `runsc` runtime to limit exposure to host kernel vulnerabilities.
- **AI agent isolation**: pair with Dockside's per-network outbound firewall rules to constrain both the system-call surface and network reachability of AI coding agent sessions.

> **Note:** gVisor does not support all Linux system calls. Some workloads that depend on uncommon kernel interfaces may not function correctly under `runsc`. Test your devcontainer images under gVisor before rolling out to your team.
