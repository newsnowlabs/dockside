# Dockside in production at NewsNow

Dockside is used in production for all aspects of web application and back-end development and staging (including acceptance testing) of the websites [https://www.newsnow.co.uk/](https://www.newsnow.co.uk/) and [https://www.newsnow.com/](https://www.newsnow.com/) by a team of around seven developers and seven editorial staff plus managers. Running on a KVM-based VM hosted on bare metal in NewsNow's data centre with 64GB memory, NewsNow's instance of Dockside handles 20-30 devtainers running simultaneously.

The precise number can vary depending on the resource-intensiveness of the application being developed. In the past, the VM required only 32GB memory but the memory requirements of the NewsNow application have grown.

The Dockside Theia IDE itself occupies only ~100MB memory per devtainer, so for a very lightweight application an 8GB server or VM could conceivably handle up to 40 simultaneous running devtainers.

Stopped devtainers (which are stopped Docker containers) occupy disk space but not memory, so the number of stopped devtainers is limited only by available disk space on the VM/server running Dockside.

In order to prevent the risk of runaway devtainers from interfering with other developers' work, NewsNow's Dockside VM has an [XFS](https://en.wikipedia.org/wiki/XFS) filesystem mounted at `/var/lib/docker` and its profiles are configured with memory, storage and pids limits appropriate to the development task using the `dockerArgs` profile option and the `docker run` `--memory`, `--storage-opt` and `--pids-limit` options.

As a 24/7 news platform, the NewsNow application is often best developed and tested with live data. To facilitate this, and in keeping with the Dockside disposable container model, NewsNow operates a number of disposable ZFS-based database clones that can be transparently hooked up to running devtainers (through a system of iptables firewall rules and Docker networks). Developers can safely read and even write to these database clones, which are disposed of and refreshed periodically or when a development task is completed.
