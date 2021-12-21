<p align="center">
    <img title="//Dockside" alt="//Dockside" src="https://user-images.githubusercontent.com/354555/145203965-b573f43b-757a-4471-a39c-d2e53b1acb41.png" width="75%"/>
</p>

## Features

Core features:

- Instantly launch and clone an almost infinite multiplicity of disposable devtainers - one for each task, bug, feature or design iteration.
- Powerful VS Code-compatible IDE.
- HTTPS automatically provisioned for every devtainer.
- User authentication and access control to running devtainers and their web services.
- Fine-grained user and role-based access control to devtainer functionality and underlying system resources.
- Launch devtainers from stock Docker images, or from your own.
- Root access within devtainers, so developers can upgrade their devtainers and install operating system packages when and how they need.

Benefits for developers:

- Code in a clone of your production environment, avoiding troublesome deploy-time errors and bugfixing.
- Switch between and hand over tasks instantly. No more laborious branch switching, or committing code before it’s ready. ‘git stash’ will be a thing of the past.
- Work from anywhere. All you need is a browser.
- Unifying on an IDE within a team can deliver great productivity benefits for collaborative teams through improved knowledge-share, better choices and configuration of plugins and other tooling.
- Develop against production databases (or production database clones) when necessary.

Benefits for code reviewers:

- Access your colleagues’ devtainers directly for code review.
- No more staring at code wondering what it does, or time-consuming setup, when their code is already running.
- Annotate their code directly with your comments as to points they should address.
- To save time, when you know best, apply and test your own fixes directly to their code.

Benefits for product managers and senior management:

- High visibility of product development progress. Access always-on application revisions and works-in-progress, wherever you are in the world.
- Devs can be sometimes be fussy about their choice of IDE, but unifying on an IDE can deliver productivity benefits for collaborative teams through improved knowledge-share and tooling.

Advanced features:

- Runtime agnostic: use runC (Docker's default), [sysbox](https://github.com/nestybox/sysbox), [gvisor](https://gvisor.dev/), or others.
- Apply Docker system resource limits to devtainers, and communicate available system resources to devtainers using [LXCFS](extensions/lxcfs.md).
- Support for launching [multi-architecture devtainers](extensions/multiarch.md) using [qemu-user-static](https://github.com/multiarch/qemu-user-static).
- Firewall or redirect outgoing devtainer traffic using custom Docker networks.
- Access Dockside devtainers via multiple domain names, when needed to stage or simulate multi-domain web applications.

## Video walkthrough

<p align="center">
<a title="Click to view video in HD on YouTube" href="https://www.youtube.com/embed/buAefREyngQ" target="_blank"><img src="https://user-images.githubusercontent.com/354555/135777679-67fd1424-f01f-4072-ac3e-ed910c8711af.gif" alt="Dockside Walkthrough Video" width="70%"></a>
</p>

## Host requirements

Dockside is tested on Debian Linux running [Docker Engine](https://docs.docker.com/engine/install/) (the `docker-ce` package suite) and on MacOS and Windows 10 running [Docker Desktop](https://docs.docker.com/get-docker/), and is expected to run on any host with at least 1GB memory running a modern Linux distribution.

## Getting started

View [Dockside on GitHub](https://github.com/newsnowlabs/dockside#getting-started) for how to quickly install on local machine, on-premises or in the cloud, and for full documentation.

## Licence

This project (known as "Dockside"), comprising the files in the [Dockside Git repository](https://github.com/newsnowlabs/dockside),
is copyright 2017-2021 NewsNow Publishing Limited and contributors.

Dockside is an open-source project licensed under the Apache License, Version 2.0 (the "License");
you may not use Dockside or its constituent files except in compliance with the License.

You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0).

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

N.B. In order to run, Dockside relies upon other third-party open-source software dependencies that are separate to and independent from Dockside and published under their own independent licences. Dockside Docker images made available at https://hub.docker.com/repository/docker/newsnowlabs/dockside are distributions designed to run Dockside that comprise: (a) the Dockside project source and/or object code; and (b) third-party dependencies that Dockside needs to run; and which are each distributed under the terms of their respective licences.

### Trade marks

Dockside and devtainer are trade marks of NewsNow Publishing Limited. All rights reserved.
