# Devtainer backup strategies

There exist various strategies for backing up devtainers, with varying trade-offs. For example:

1. Configure profiles to run a backup agent within every devtainer
2. Configure a backup agent to periodically backup the whole of `/var/lib/docker` on the host
3. Configure a backup agent to periodically commit devtainers to images, and push the images to a private image registry
4. Configure a backup agent to periodically backup the 'upper dir' for each devtainer
5. Configure a backup agent to periodically backup each devtainer base image to a registry, and take incremental backups of the 'upper dir'

> **A proof-of-concept implementation of (5), using Restic, complete with a restore feature, may be provided in a future release.**