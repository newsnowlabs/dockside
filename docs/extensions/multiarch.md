# Multi-architecture devtainers

Multi-architecture devtainers can be launched by installing [qemu-user-static](https://github.com/multiarch/qemu-user-static).

On a Debian Dockside host, it can be installed using:

```
sudo apt-get install qemu binfmt-support qemu-user-static
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

> **You can test you have installed qemu-user-static correctly, by launching a devtainer from the Debian profile, and selecting either the `arm32v7/debian`, `arm64v8/debian`, `mips64le/debian`, `ppc64le/debian` or `s390x/debian` image.**
