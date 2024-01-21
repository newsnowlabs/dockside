<p align="center">
    <img alt="//Dockside" src="https://user-images.githubusercontent.com/354555/145203965-b573f43b-757a-4471-a39c-d2e53b1acb41.png" width="75%"/>
</p>

# Introduction

Dockside is a tool for provisioning lightweight access-controlled IDEs, staging environments and sandboxes - aka _devtainers_ - on local machine, self-hosted on-premises on bare metal or VM, or in the cloud.

By provisioning a devtainer for every fork and branch, Dockside allows collaborative software and product development teams to take lean and iterative development and testing to a highly parallelised extreme.

<h3 align="center">Our sponsors</h3>
<p align="center">
<a title="NewsNow is hiring: work on Dockside and other existing projects" href="https://www.newsnow.co.uk/careers/?utm_source=GitHub&utm_medium=cpc&utm_campaign=2021-10-21-Developer-Roles&utm_content=SponsoredHiringAd" target="_blank"><img alt="Dockside sponsor NewsNow is hiring" src="https://user-images.githubusercontent.com/354555/144637598-5cc14a58-6918-4170-8b47-bbd26cb84062.png"></a>
</p>

## Features

Core features:

- Instantly launch and clone an almost infinite multiplicity of disposable devtainers - one for each task, bug, feature or design iteration.
- Powerful VS Code-compatible IDE.
- HTTPS automatically provisioned for every devtainer.
- SSH server and access automatically provisioned for every devtainer.
- User authentication and access control to running devtainers and their web services.
- Fine-grained user and role-based access control to devtainer functionality and underlying system resources.
- Launch devtainers from stock Docker images, or from your own.
- Root access within devtainers, so developers can upgrade their devtainers and install operating system packages when and how they need.

Benefits for developers:

- Code in a clone of your production environment, avoiding troublesome deploy-time errors and bugfixing.
- Switch between and hand over tasks instantly. No more laborious branch switching, or committing code before it’s ready. ‘git stash’ will be a thing of the past.
- Work from anywhere. All you need is a browser.
- Unifying on an IDE within a team can deliver great productivity benefits for collaborative teams through improved knowledge-share, better choices and configuration of plugins and other tooling.
- SSH access facilitates use of any terminal editor or command line tool and seamless [VS Code remote development](https://code.visualstudio.com/docs/remote/ssh) via the [Remote SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension.
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

Dockside is supported on Intel (amd64/x86), Apple M1/M2 (arm64) and Raspberry Pi (arm/v7) hardware platforms, via a multiarch Docker image
that contains native binary implementations of Dockside for all three architectures.

Dockside is tested on:
- Intel (amd64/x86) platforms running Debian Linux and [Docker Engine](https://docs.docker.com/engine/install/) (via the `docker-ce` package suite)
- MacOS (amd64/x86 and Apple Mac M1) running [Docker Desktop](https://docs.docker.com/get-docker/)
- Intel Windows 10 running [Docker Desktop](https://docs.docker.com/get-docker/)
- Raspberry Pi (arm/v7) running Raspbian Linux and [Docker Engine](https://docs.docker.com/engine/install/) (via the `docker-ce` package suite)

Dockside requires a host with a minimum of 1GB memory.

## Getting started

> **Installing Docker**
>
>    Dockside is designed to be installed using [Docker](https://www.docker.com/).
>    To install Docker for your platform, go to [https://www.docker.com/](https://www.docker.com/)

Dockside needs an SSL certificate to run. For temporary/trial usage, Dockside may be launched with a built-in or self-signed SSL certificate.

For production usage on an Internet-connected server, Dockside should be launched on a dedicated public domain name (or sub-domain name) with a genuine _wildcard_ SSL certificate for that domain.

Choose from the following options:

1. [Launch locally with built-in SSL cert](#launch-locally-with-built-in-ssl-cert)
2. [Launch anywhere with self-signed SSL cert](#launch-anywhere-with-self-signed-ssl-cert)
3. [Launch in production with self-supplied SSL certificate](#launch-in-production-with-self-supplied-ssl-certificate)
4. [Launch in production with auto-generated LetsEncrypt public SSL certificate](#launch-in-production-with-auto-generated-letsencrypt-public-ssl-certificate)

### Launch locally with built-in SSL cert

1. Launch Dockside on a local machine, with a temporary and convenient built-in SSL certificate
```sh
mkdir -p ~/.dockside && \
docker run -it --name dockside \
  -v ~/.dockside:/data \
  --mount=type=volume,src=dockside-ssh-hostkeys,dst=/opt/dockside/host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 \
  --security-opt=apparmor=unconfined \
  newsnowlabs/dockside --ssl-builtin
```

2. In your browser, navigate to the Dockside homescreen at [https://www.local.dockside.dev/](https://www.local.dockside.dev). Sign in with the username `admin` and the auto-generated password output to the terminal, then follow the instructions displayed on-screen.

3. You can now [detach](https://docs.docker.com/engine/reference/commandline/attach/) from the Dockside container running back in your terminal by typing `CTRL+P` `CTRL+Q`. Alternatively you can instead launch with `docker run -d` instead of `docker run -it`; if you do this, run `docker logs dockside` to display the terminal output and auto-generated admin password.

> WARNING: The default Dockside installation embeds a non-secret SSL certificate, for `*.local.dockside.dev` resolving to 127.0.0.1, which should not be used for production usage.

### Launch anywhere with self-signed SSL cert

1. Launch Dockside on a local machine, on-premises server, VM or cloud instance, with a temporary and convenient self-signed SSL certificate, where `<my-domain>` is the domain name:
```sh
mkdir -p ~/.dockside && \
docker run -it --name dockside \
  -v ~/.dockside:/data \
  --mount=type=volume,src=dockside-ssh-hostkeys,dst=/opt/dockside/host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 \
  --security-opt=apparmor=unconfined \
  newsnowlabs/dockside --ssl-selfsigned --ssl-zone <my-domain>
```

2. In your browser, navigate to the Dockside homescreen at the hostname for your machine/VM in your browser. This must be `https://www.<my-domain>/` so you must configure your DNS or `/etc/hosts` file accordingly. Sign in with the username `admin` and the auto-generated password output to the terminal, then follow the instructions displayed on-screen.
 
3. You can now [detach](https://docs.docker.com/engine/reference/commandline/attach/) from the Dockside container running back in your terminal by typing `CTRL+P` `CTRL+Q`. Alternatively you can instead launch with `docker run -d` instead of `docker run -it`; if you do this, run `docker logs dockside` to display the terminal output and auto-generated admin password.

### Launch in production with self-supplied SSL certificate

1. Assuming your self-supplied `fullchain.pem` and `privkey.pem` files for the wildcard SSL certificate for your domain `<my-domain>` are located in `<certsdir>` then launch Dockside as follows:
```sh
mkdir -p ~/.dockside && \
docker run -d --name dockside \
  -v ~/.dockside:/data \
  --mount=type=volume,src=dockside-ssh-hostkeys,dst=/opt/dockside/host \
  -v <certsdir>:/data/certs \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 \
  --security-opt=apparmor=unconfined \
  newsnowlabs/dockside --ssl-selfsupplied
```

2. In your browser, navigate to the Dockside homescreen at `https://www.<my-domain>/`. To view the launch logs and obtain the auto-generated `admin` user password, run `docker logs dockside`. Sign in with the username `admin` and the displayed password, then follow the instructions displayed on-screen.

> N.B. Should you update your certificates run `docker exec dockside s6-svc -t /etc/service/nginx` to tell Dockside to reload them.

### Launch in production with auto-generated LetsEncrypt public SSL certificate

In order for Dockside to auto-generate a public SSL certificate using LetsEncrypt, it must first be delegated responsibility for handling public internet DNS requests for your chosen domain and you must also configure the server (or VM or instance) on which you will run Dockside to accept UDP requests on port 53. So:

1. Delegate the domain to the server running Dockside by installing the following two domain name records for `<my-domain>`:
```
<my-domain> A <my-server-ip>
<my-domain> NS <my-domain>
```
These records are needed to tell the public DNS infrastructure that DNS requests for `<my-domain>` should be forwarded to `<my-server-IP>`.

2. Launch Dockside as follows:
```sh
mkdir -p ~/.dockside && \
docker run -d --name dockside \
  -v ~/.dockside:/data \
  --mount=type=volume,src=dockside-ssh-hostkeys,dst=/opt/dockside/host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 -p 53:53/udp \
  --security-opt=apparmor=unconfined \
  newsnowlabs/dockside --ssl-letsencrypt --ssl-zone <my-domain>
```
Assuming you have provisioned <my-domain> correctly, Dockside will use LetsEncrypt to generate a public SSL certificate on startup and to regenerate the certificate periodically to ensure it remains current.

3. In your browser, navigate to the Dockside homescreen at `https://www.<my-domain>/`. To view the launch logs and obtain the auto-generated `admin` user password, run `docker logs dockside`. Sign in with the username `admin` and the displayed password, then follow the instructions displayed on-screen.

> **Launch using Google Cloud Deployment Manager**
>
> An implementation of the above procedure within [Google Deployment Manager](https://console.cloud.google.com/dm/deployments) is available [here](/examples/cloud/google-deployment-manager/). To use it, you must first configure a managed zone within [Google Cloud DNS](https://console.cloud.google.com/net-services/dns/zones).
>
> Then sign into Cloud Shell, and run:
> ```sh
> git clone https://github.com/newsnowlabs/dockside.git
> cd dockside/examples/cloud/google-deployment-manager/
> ./launch.sh --managed-zone <managed-zone> --dns-name <managed-zone-fully-qualified-subdomain>
> ```
> For example, if your managed zone is called `myzone`, the zone DNS name is `myzone.org`, and your chosen subdomain is `dockside` then run `./launch.sh --managed-zone myzone --dns-name dockside.myzone.org`.
>
> For full `launch.sh` usage, including options for configuring cloud machine type, machine zone, and disk size, run `./launch.sh --help`.

## Usage

Refer to [Usage](usage.md) for how to use the Dockside UI and IDE.

## Setup

See [Configuring and administering Dockside](setup.md)

## Upgrading

See [Upgrading Dockside](upgrading.md) for strategies for upgrading Dockside, or Dockside components such as the Dockside Theia IDE.

## Security

See [Securing profiles and devtainers](securing.md)

## Extensions

- [LXCFS](extensions/lxcfs.md) -- allows processes within devtainers to correctly report their own cpu, memory, and disk available resources and usage
- [Multi-architecture devtainers](extensions/multiarch.md) -- support for devtainers running non-amd64 processor architectures
- [Docker-in-Dockside devtainers](extensions/runtimes/sysbox.md#sysbox-docker-in-dockside-devtainers) -- support for running devtainers using the sysbox runtime
- [Self-contained Docker-in-Dockside](extensions/runtimes/sysbox.md#self-contained-docker-in-dockside) -- support for running Dockside using the sysbox runtime
- [Backups](extensions/backups.md) -- strategies for backing up devtainers
- [Integrated SSH server support](extensions/ssh.md#integrated-ssh-server-support) -- allows one-click SSH into any devtainer and auto-generated provision of `~/.ssh/authorized_keys` files
- [Local ssh-agent support](extensions/ssh.md#local-ssh-agent-support) -- to allow use of `git` functionality of the Theia IDE (like `Git: Push` and `Git: Pull`) or other `SSH`-based commands accessible within the Theia IDE UI or terminal

## Case-study: Dockside in production at NewsNow

Read the [case study of how Dockside is used in production](case-studies/NewsNow.md) for all aspects of web application and back-end development and staging (including acceptance testing) of the websites [https://www.newsnow.co.uk/](https://www.newsnow.co.uk/) and [https://www.newsnow.com/](https://www.newsnow.com/).

## Roadmap

Where are we taking Dockside? As Dockside today satisfactorily serves the needs of the NewsNow development team, its roadmap currently remains highly flexible. We have a list of features we think could be great to add, but we now want to hear from you what you would most value to see added to Dockside.

For our current ideas/plans, see our [draft roadmap](roadmap.md).

## Developing

See [Developing Dockside](developing/developing.md) to learn more about how to go about developing Dockside within Dockside, the Dockside application components and building Dockside images.

## Bugs, issues and support

If you are experiencing an issue or believe you may have found a bug, please [raise an issue](https://github.com/newsnowlabs/dockside/issues) or contact via on the [NewsNow Labs Slack Workspace](https://join.slack.com/t/newsnowlabs/shared_invite/zt-wp54l05w-0DTxuc_n8uISJRtks3Xw3A).

## Contributing

If you would like to contribute a bugfix, patch or feature, we'd be delighted.

Please just [raise an issue](https://github.com/newsnowlabs/dockside/issues/new) or contact us on our [NewsNow Labs Slack Workspace](https://join.slack.com/t/newsnowlabs/shared_invite/zt-wp54l05w-0DTxuc_n8uISJRtks3Xw3A).


## Contact

Github: [Raise an issue](https://github.com/newsnowlabs/dockside/issues/new)

Slack: [NewsNow Labs Slack Workspace](https://join.slack.com/t/newsnowlabs/shared_invite/zt-wp54l05w-0DTxuc_n8uISJRtks3Xw3A)

Email: [dockside@NewsNow.co.uk](mailto:dockside@NewsNow.co.uk)

We are typically available Monday-Friday, 9am-5pm London time.

## Thank you

Thank you _very much_ for using and/or contributing and/or spreading the word about Dockside. We hope you find it helps your team be more and more productive.

## Credits

Thanks to [Struan Bartlett](https://github.com/struanb) for conceiving the model of iterative web development through the use of ready-built, stageable and disposable development environments running web-based IDEs, and for leading the development of Dockside.

Thanks also to other members of the NewsNow development team for contributing the Dockside Vue client, design and architectural ideas, support and advice, code and code-reviews; for coining the term _devtainers_; and for the Dockside logo concept.

Thanks also to the entire design and development, editorial and testing teams at [NewsNow](https://www.newsnow.co.uk/about/) for so enthusiastically adopting containerised development working practices and for subjecting Dockside to so many years of robust use (and abuse) during the course of their daily iterative development, evaluation and testing of the [NewsNow](https://www.newsnow.co.uk/) platform - and proving the value of this development model.

Thanks last but not least to [NewsNow](https://www.newsnow.co.uk/about/), _The Independent News Discovery Platform_, for sponsoring the development of Dockside.

## More credits

The Dockside multiarch build is built thanks to [Depot](https://depot.dev) and we're grateful for their support.

## Licence and legals

This project (known as "Dockside"), comprising the files in this Git repository,
is copyright 2017-2021 NewsNow Publishing Limited and contributors.

Dockside is an open-source project licensed under the Apache License, Version 2.0 (the "License");
you may not use Dockside or its constituent files except in compliance with the License.

You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0).

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

> N.B. In order to run, Dockside relies upon other third-party open-source software dependencies that are separate to and
independent from Dockside and published under their own independent licences.
>
> Dockside Docker images made available at [https://hub.docker.com/repository/docker/newsnowlabs/dockside](https://hub.docker.com/repository/docker/newsnowlabs/dockside) are distributions
> designed to run Dockside that comprise: (a) the Dockside project source and/or object code; and
> (b) third-party dependencies that Dockside needs to run; and which are each distributed under the terms
> of their respective licences.

### Trade marks

Dockside and devtainer are trade marks of NewsNow Publishing Limited. All rights reserved.
