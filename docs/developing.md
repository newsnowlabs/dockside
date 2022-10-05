# Developing and building Dockside

The simplest way to develop Dockside is within Dockside!

Dockside can also be developed and built within Dockside within Dockside, or indeed {within Dockside}^N for any reasonable N >= 1.

Simply:

1. Launch a devtainer from the _Dockside_ profile.
2. Open the devtainer IDE
3. `git pull` the latest main branch from the Github repo
4. Modify the code, rebuilding [the dockside client](#dockside-client) and restarting the [server](#dockside-server) and [event daemon](#dockside-event-daemon) as necessary.
5. Test, by clicking `Open` on the devtainer `dockside` router. Admin login credentials can be obtained by running `docker logs <devtainer-name>` within the IDE terminal.
6. Build a test Dockside image, and launch within a new Dockside devtainer.

## Dockside application components

The main components of the Dockside application are:

1. The Request Proxy, written in Perl and embedded in NGINX using mod-http-perl 
2. The [Dockside Server](#dockside-server), currently written in Perl and also embedded in NGINX using mod-http-perl
3. The [Dockside Client](#dockside-client), written in Vue (HTML/CSS/JavaScript)
4. The [Dockside Event Daemon](#dockside-event-daemon), written in Perl

Additional optionally-enabled components are:

1. A Dehydrated service, which generates and maintains LetsEncrypt SSL certificates using [dehydrated](https://github.com/dehydrated-io/dehydrated)
2. A Bind9 service, which is needed to support the generation of LetsEncrypt wildcard SSL certificates
3. A Logrotate service, which rotates Dockside and NGINX logs.

Whether these components are enabled depends on the command-line options given when Dockside is launched.

## Dockside client

To rebuild the client, run:

```sh
cd ~/dockside/app/client && npm run build
```

To watch continuously for changes to client code, run:

```sh
cd ~/dockside/app/client && npm run start
```

## Dockside server

To restart the Dockside server, run:

```sh
sudo s6-svc -t /etc/service/nginx
```

## Dockside event daemon

To restart the Dockside server, run:

```sh
sudo s6-svc -t /etc/service/docker-event-daemon
```

## Rebuilding documentation

To rebuild the documentation html, run:

```sh
~/.local/bin/mkdocs build
```

## Building a Dockside image

To launch a fresh instance of a modified Dockside codebase, it is necessary to build a Dockside image.

This is useful to do when you want to test that your modified Dockside
launches as expected, or when you want to launch a modified version of
Dockside in production on another host.

For instructions, see [Building the Dockside image](building-image.md).
