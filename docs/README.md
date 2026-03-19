<p align="center">
    <img alt="//Dockside" src="https://user-images.githubusercontent.com/354555/145203965-b573f43b-757a-4471-a39c-d2e53b1acb41.png" width="75%"/>
</p>

<p align="center">
  <a href="https://github.com/newsnowlabs/dockside"><img alt="GitHub stars" src="https://img.shields.io/github/stars/newsnowlabs/dockside?style=flat-square&logo=github"></a>
  <a href="https://hub.docker.com/r/newsnowlabs/dockside"><img alt="Docker Pulls" src="https://img.shields.io/docker/pulls/newsnowlabs/dockside?style=flat-square&logo=docker"></a>
  <a href="https://github.com/newsnowlabs/dockside/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/badge/licence-Apache%202.0-blue?style=flat-square"></a>
  <img alt="AI-ready" src="https://img.shields.io/badge/AI--ready-Claude%20%7C%20Codex%20%7C%20Copilot-8A2BE2?style=flat-square">
</p>

# Introduction

Dockside is a self-hosted platform for teams who want a devcontainer for every branch — isolated, browser-accessible, HTTPS-secured, and ready in seconds, on your own infrastructure.

Each devcontainer (or _devtainer_, as we call them) is automatically provisioned with a browser IDE, SSH access, and a dedicated HTTPS reverse proxy with per-service subdomains. No per-project configuration required. Spin one up per branch, per task, per developer — or per AI agent session.

> **Note on terminology:** Dockside's _devtainers_ are development containers in the general sense. They predate and differ from the [VS Code devcontainer spec](https://containers.dev/) (`.devcontainer/devcontainer.json`), though they serve the same core purpose: a reproducible, isolated environment for each piece of work.

**Running AI coding tools?** Dockside devcontainers are natural sandboxes for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [OpenAI Codex](https://openai.com/codex), GitHub Copilot and similar. The Claude and Codex CLIs — and their VS Code extensions — run natively inside Dockside's integrated IDEs. Each AI session is isolated in its own container. And coming soon: built-in network firewall management to define exactly what AI agents can reach, reproducing purpose-built AI devcontainer security without elevated capabilities or weakened isolation.

<h3 align="center">Our sponsors</h3>
<p align="center">
<a title="NewsNow is hiring: work on Dockside and other existing projects" href="https://www.newsnow.co.uk/careers/?utm_source=GitHub&utm_medium=cpc&utm_campaign=2021-10-21-Developer-Roles&utm_content=SponsoredHiringAd" target="_blank"><img alt="Dockside sponsor NewsNow is hiring" src="https://user-images.githubusercontent.com/354555/144637598-5cc14a58-6918-4170-8b47-bbd26cb84062.png"></a>
</p>

## AI-assisted development

AI coding tools work best when they have their own isolated environment to operate in — somewhere they can install dependencies, run tests, edit files, and make mistakes, without affecting anything else. Dockside devcontainers are a natural fit.

- **Claude Code and OpenAI Codex CLIs** run natively inside Dockside's integrated IDEs (OpenVSCode Server and Theia), as do their VS Code extensions. Point an AI agent at a fresh devcontainer, let it work, then review the result — all contained.
- **Per-session isolation**: each AI coding session gets its own devcontainer. Unintended side-effects — runaway processes, unexpected file changes, dependency conflicts — stay within that container's blast radius and don't touch your host or other devcontainers.
- **Network firewall management** _(coming soon)_: configurable outbound firewall rules per Docker custom network, letting you define exactly what AI agents can and cannot reach. Assign a devcontainer to a restricted network and Dockside enforces the rules — without requiring elevated container capabilities or weakening isolation.

## Why Dockside?

| | Dockside | GitHub Codespaces | Gitpod | Coder |
|---|---|---|---|---|
| **Self-hosted / private cloud** | ✅ | ❌ | Partial | ✅ |
| **No per-seat cloud fees** | ✅ | ❌ | ❌ | ✅ |
| **Your data stays on your infra** | ✅ | ❌ | ❌ | ✅ |
| **Full root in containers** | ✅ | ❌ | ❌ | Partial |
| **AI CLI tools run natively in IDE** | ✅ | Partial | Partial | Partial |
| **Per-network outbound firewall for AI** | ✅ soon | ❌ | ❌ | ❌ |
| **Browser IDE + SSH + JetBrains** | ✅ | ✅ | ✅ | ✅ |
| **Works on your laptop** | ✅ | ❌ | ❌ | ❌ |
| **Open source** | ✅ Apache 2.0 | ❌ | Partial | ✅ AGPL |

Dockside's sweet spot: teams that want **Codespaces-style devcontainers without the cloud lock-in**, and teams that want to run AI coding agents **safely and privately** on their own infrastructure.

## Features

Core features:

- Instantly launch disposable devcontainers: one per task, bug, feature, design iteration, or AI agent session.
- Powerful IDE bundle including [OpenVSCode Server](https://github.com/gitpod-io/openvscode-server) and [Theia](https://theia-ide.org/), plus first-class SSH and support for [VS Code Remote Development using SSH](https://code.visualstudio.com/docs/remote/ssh) or [JetBrains development over SSH](https://www.jetbrains.com/remote-development/).
- AI-ready devcontainers: Claude Code, OpenAI Codex, GitHub Copilot and other AI tools and CLIs run natively inside every devcontainer's integrated IDE. Isolate each AI agent session in its own container for safe, auditable agentic development.
- An access-controlled HTTPS reverse proxy automatically provisioned for every devcontainer, with separately configurable domain name prefixes for each subservice.
- SSH server with automated `authorized_keys` provision for every devcontainer.
- User authentication and access control to running devcontainers and their web services.
- Fine-grained user and role-based access control to devcontainer functionality and underlying system resources.
- Launch devcontainers from stock Docker images, or from your own.
- Root access within devcontainers, so developers can upgrade their environment and install operating system packages when and how they need.
- Bundled GitHub CLI (`gh`) with per-user token support for seamless `gh pr checkout` and other GitHub operations.

Benefits for developers:

- Code in a clone of your production environment, avoiding troublesome deploy-time errors and bugfixing.
- Switch between and hand over tasks instantly. No more laborious branch switching, or committing code before it’s ready. `git stash` will be a thing of the past.
- Work from anywhere. All you need is a browser. Or connect with VS Code, JetBrains, or any other IDE capable of remote development over SSH. Or SSH in directly and use your favourite terminal editor or toolchain. You choose.
- Run AI coding agents — Claude Code, Codex, GitHub Copilot — safely inside isolated devcontainers. Each agent session is self-contained, and coming-soon firewall controls let you define exactly what AI tools can reach on the network.
- Unifying on an IDE within a team can deliver great productivity benefits through improved knowledge-share and better choices of plugins and tooling.
- SSH access facilitates use of any terminal editor or command line tool and seamless [VS Code remote development](https://code.visualstudio.com/docs/remote/ssh) via the [Remote SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension.
- Develop against production databases (or production database clones) when necessary.

Benefits for code reviewers:

- Access your colleagues’ devcontainers directly for code review.
- No more staring at code wondering what it does, or time-consuming setup, when their code is already running.
- Annotate their code directly with your comments as to points they should address.
- To save time, when you know best, apply and test your own fixes directly to their code.

Benefits for product managers and senior management:

- High visibility of product development progress. Access always-on application revisions and works-in-progress, wherever you are in the world.
- Every feature branch can have its own running environment — share a link with stakeholders to review work in progress without waiting for a dedicated staging deployment.

Advanced features:

- Runtime agnostic: use runC (Docker's default), [Sysbox](https://github.com/nestybox/sysbox) (for Docker-in-Dockside devtainers), [gVisor](https://gvisor.dev/) (for sandboxed kernel isolation), or [RunCVM](https://github.com/newsnowlabs/runcvm) (for full KVM VMs on amd64); see [Alternative runtimes](extensions/runtimes.md).
- Apply Docker system resource limits to devtainers, and communicate available system resources to devtainers using [LXCFS](extensions/lxcfs.md).
- Support for launching [multi-architecture devtainers](extensions/multiarch.md) using [qemu-user-static](https://github.com/multiarch/qemu-user-static).
- Firewall or redirect outgoing devcontainer traffic using custom Docker networks — useful for isolating AI agent network access or mirroring production network topologies.
- Access Dockside devtainers via multiple domain names, when needed to stage or simulate multi-domain web applications.
- Command-line interface (`dockside` CLI) for scripting, automation, and CI/CD integration.
- Autodetection of available runtimes, networks and IDEs from the host environment.

## Video walkthrough

<p align="center">
<a title="Click to view video in HD on YouTube" href="https://www.youtube.com/embed/buAefREyngQ" target="_blank"><img src="https://user-images.githubusercontent.com/354555/135777679-67fd1424-f01f-4072-ac3e-ed910c8711af.gif" alt="Dockside Walkthrough Video" width="70%"></a>
</p>

> _Recorded in 2021 — the core workflow remains the same, though the UI has evolved since then._

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

### Quick Start — Launch locally

The fastest way to get started with Dockside is to run it on your local machine. This is ideal for solo developers and teams working on multiple web projects simultaneously — spin up a devcontainer per branch, per project, per experiment, or per AI agent session, all accessible from your browser.

1. Launch Dockside using its built-in SSL certificate:
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

2. In your browser, navigate to [https://www.local.dockside.dev/](https://www.local.dockside.dev). Sign in with the username `admin` and the auto-generated password output to the terminal, then follow the instructions displayed on-screen.

3. You can now [detach](https://docs.docker.com/engine/reference/commandline/attach/) from the Dockside container running back in your terminal by typing `CTRL+P` `CTRL+Q`. Alternatively, launch with `docker run -d` instead of `docker run -it`; if you do this, run `docker logs dockside` to display the terminal output and auto-generated admin password.

> **Note:** The built-in SSL certificate covers `*.local.dockside.dev` which resolves to 127.0.0.1. It is intended for local use only.

**Once Dockside is running:**

4. Open the Dockside UI, click **Launch**, and pick an example profile (e.g. `Alpine` or `Debian`) to launch your first trial devcontainer — this confirms everything is working.
5. Next, register your team members and configure profiles to tailor the available devcontainer types for your projects. See [**Setup**](#setup) below for a guided overview and [**read full details of the config files here**](setup.md).

### Launch on a public domain with auto-generated SSL

To share devtainers with your team — or access them from anywhere — deploy Dockside on an internet-connected server with a public domain name and a LetsEncrypt wildcard SSL certificate generated automatically on startup.

In order for Dockside to auto-generate a public SSL certificate using LetsEncrypt, the server must be delegated responsibility for handling public internet DNS requests for your chosen domain, and must accept UDP requests on port 53. So:

1. Delegate the domain to the server running Dockside by installing the following two DNS records for `<my-domain>`:
```
<my-domain> A <my-server-ip>
<my-domain> NS <my-domain>
```
These records tell the public DNS infrastructure that DNS requests for `<my-domain>` should be forwarded to `<my-server-ip>`.

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
Assuming you have provisioned `<my-domain>` correctly, Dockside will use LetsEncrypt to generate a public SSL certificate on startup and to regenerate the certificate periodically to ensure it remains current.

3. In your browser, navigate to `https://www.<my-domain>/`. To view the launch logs and obtain the auto-generated `admin` user password, run `docker logs dockside`. Sign in with the username `admin` and the displayed password, then follow the instructions displayed on-screen.

### Advanced Launch Options

For self-signed, self-supplied SSL, Google Cloud Deployment Manager, and Terraform launch configurations, see [Advanced Launch Options](advanced-launch-options.md).

## Setup

Dockside configuration lives under `~/.dockside/config/` on the host (mounted at `/data/config/` inside the container). Config files are plain JSON (with `//` comments allowed) and are auto-reloaded on change — most settings take effect immediately without restarting Dockside.

Getting set up involves three main steps:

- **[Profiles](setup.md#profiles)**: define the types of devcontainer your team can launch — which Docker images, networks, runtimes, and IDE options are available. Dockside ships several example profiles (`alpine.json`, `debian.json`, `dockside.json`, and others) to get you started. Edit them or add new ones to match your own projects and images.
- **[Users and Roles](setup.md#users)**: register each team member in `users.json` and `passwd`. Assign a role (`admin` or a custom role from `roles.json`) to control what each user can do and which profiles they can deploy.
- **[SSH keys](extensions/ssh.md)**: add each user's SSH public key to their `users.json` record so Dockside auto-populates `~/.ssh/authorized_keys` in every devcontainer they own or are shared on. Users then follow the one-click **SSH Setup** instructions in the Dockside UI to configure their `~/.ssh/config` and install the [wstunnel](https://github.com/erebe/wstunnel) helper. After that, SSHing into any devcontainer — and using VS Code Remote SSH or JetBrains Remote Development — works seamlessly with no extra steps.

For the full configuration reference see [Configuring and administering Dockside](setup.md), including [config.json](setup.md#configjson), [Roles](setup.md#roles), [Profile routers](setup.md#profile-routers) and [Access control](setup.md#access-control-model).

## Usage

The Dockside UI is intentionally simple: click **Launch** to create a new devcontainer from a profile, configure it, and you're running in seconds. The rest of the workflow — opening an IDE, starting an SSH session, sharing a devcontainer with a colleague, setting access modes on its exposed services — is a click or two away.

Key workflow points:

- **[Launching a devcontainer](usage.md#launching-a-devtainer)**: choose a profile, select a Docker image, set your network and runtime, optionally specify a git branch or other profile options, then click **Launch**.
- **[Using the IDE](usage.md#using-the-dockside-ide)**: open Theia or OpenVSCode Server directly in your browser. AI coding tools (Claude Code, Codex, Copilot) run natively inside the IDE. The bundled `gh` CLI authenticates automatically when you have a `gh_token` configured in your user profile.
- **[SSH access](extensions/ssh.md#integrated-ssh-server-support)**: one-click SSH from the Dockside UI, or SSH in directly from any terminal. Works with VS Code Remote SSH and JetBrains Remote Development out of the box once SSH client setup is complete.
- **[Outbound SSH for git operations](extensions/ssh.md#adding-ssh-keys-to-a-users-profile)**: add a user's keypair to their `users.json` record and Dockside automatically loads it into the integrated `ssh-agent` on every devcontainer launch — enabling `git push` / `git pull` to GitHub, GitLab, or any SSH remote from the IDE or terminal, with no manual `ssh-add` required.
- **[Sharing and access control](setup.md#router-authaccess-levels)**: share a devcontainer with teammates as developers or viewers, and set per-service access levels (owner-only, team, or public URL).

For the full UI and CLI reference see [Usage](usage.md).

## CLI

The `dockside` CLI is a zero-dependency Python 3.6+ command-line interface for managing devtainers programmatically, suitable for scripting and CI/CD pipelines. See the [Dockside CLI README](../cli/README.md) for full documentation.

## Security

See [Securing profiles and devtainers](securing.md)

## Upgrading

See [Upgrading Dockside](upgrading.md) for strategies for upgrading Dockside, or Dockside components such as the Dockside IDE bundle.

## Extensions

- [LXCFS](extensions/lxcfs.md) -- allows processes within devtainers to correctly report their own cpu, memory, and disk available resources and usage
- [Multi-architecture devtainers](extensions/multiarch.md) -- support for devtainers running non-amd64 processor architectures
- [Alternative runtimes](extensions/runtimes.md) -- Sysbox (Docker-in-Dockside devtainers), RunCVM (KVM VMs on amd64), gVisor (sandboxed kernel isolation)
- [Backups](extensions/backups.md) -- strategies for backing up devtainers
- [Integrated SSH server support](extensions/ssh.md#integrated-ssh-server-support) -- allows seamless one-click SSH access to devtainers from the command line and accessing devtainers using VS Code
- [Local ssh-agent support](extensions/ssh.md#local-ssh-agent-support) -- to allow use of `git` functionality across Dockside IDEs (like `Git: Push` and `Git: Pull`) or other `SSH`-based commands accessible within their UIs or terminals

## Case study: Dockside in production at NewsNow

Dockside was built at [NewsNow](https://www.newsnow.co.uk/about/) and has been the daily development platform for the entire NewsNow engineering team for years. Read [how it's used in production](case-studies/NewsNow.md) across all aspects of web application and back-end development, staging, and acceptance testing for [newsnow.co.uk](https://www.newsnow.co.uk/) and [newsnow.com](https://www.newsnow.com/) — a real-world, high-traffic platform built and maintained entirely inside Dockside devcontainers.

## Roadmap

Near-term priorities include:

- **Network firewall management**: per-Docker-network configurable outbound firewall rules, enabling safe AI agent sandboxing without elevated container capabilities — assign a devcontainer to a restricted network to define exactly what AI tools can reach.
- **Terraform launch support**: first-class infrastructure-as-code deployment for teams managing Dockside at scale.

Beyond that, the roadmap is shaped by what our users most need. We'd love to hear from you — tell us what would be most valuable to add next.

For the full picture, see our [draft roadmap](roadmap.md).

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
is copyright 2017-2026 NewsNow Publishing Limited and contributors.

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
