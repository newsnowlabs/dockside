# Extensions for advanced usage

A variety of extensions are available to facilitate advanced usage:

- [LXCFS](extensions/lxcfs.md) -- allows processes within devtainers to correctly report their own cpu, memory, and disk available resources and usage
- [Multi-architecture devtainers](extensions/multiarch.md) -- support for devtainers running non-amd64 processor architectures
- [Sysbox runtime](extensions/runtimes/sysbox.md) extensions
    - for running devtainers using the Sysbox runtime
    - for running Dockside using the Sysbox runtime
- [Integrated SSH server support](extensions/ssh.md) -- allows seamless SSH access to devtainers from the command line and accessing devtainers using VS Code
- Firewall or redirect outgoing devtainer traffic using custom Docker networks.
- Access Dockside devtainers via multiple domain names, when needed to stage or simulate multi-domain web applications