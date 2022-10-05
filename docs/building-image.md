# Building a Dockside image

In order to launch a fresh instance of a modified Dockside codebase,
it is first necessary to build a Dockside image.

This is useful to do when you want to test that your modified Dockside
launches and runs as expected, or when you want to launch a modified version of
Dockside in production on another host.

A Dockside image can be built directly from the repo, on any host running Docker - and even within a Dockside devtainer.

For example, to build a new `newsnowlabs/dockside:test` image, run:

```
./build/build.sh --tag test
```

You may now test your newly-built image, by launching a new Dockside devtainer using either the `Dockside` or `Dockside (IDE from image)`
profiles, selecting the `newsnowlabs/dockside:test` image from the Image menu.

## Build options

Here are the build options to `build/build.sh`:

- `--repo <repo>` - build image with name `<repo>` (overriding the default repo, `newsnowlabs/dockside`)
- `--tag <tag>` - tag resulting image with `<tag>` (overriding the default tag, `latest`)
- `--stage <stage>` - build to the stage `<stage>` - `<stage>` must be a valid Dockerfile build stage e.g. `theia-build`, `theia-clean`, `theia` and the resulting image will be additionally tagged with `<stage>`
- `--theia <version>` - build image with Theia version `<version>` - `<version>` must be a valid Theia version and subfolder of `ide/theia`
- `--push` - push resulting image to registry (for buildx and depot builders - requires appropriate permissions for the registry)
- `--load` - load resulting image to local dockerd (for `buildx` and `depot` builders)
- `--no-cache`, `--force-rm`, `--progress-plain` - pass the relevant option to the Docker build process
- `--list` - list all local images for the Dockside repo (default `newsnowlabs/dockside`)
- `--clean` - remove all local images for the Dockside repo (default `newsnowlabs/dockside`)
- `--help` - display all build options
- `--builder <method>` - the choice of builder, 'buildkit', 'buildx' or 'depot' - the default is 'buildkit'
- `--platform <platforms>` - a comma-separated list of platforms (architectures) to build for (subject to the choice of builder) -
  for the 'depot' builder, the default is 'linux/amd64,linux/arm64,linux/arm/v7'; for the 'buildkit' and 'buildx' builders,
  the default is the native hardware platform.

## Examples

To build a new image tagged for a custom repo, e.g. `myrepo:test`:

```
./build/build.sh --repo myrepo --tag test
```

To build a new image with Theia version `1.25.0` with tag `theia-1.25.0`:

```
./build/build.sh --theia 1.25.0 --tag theia-1.25.0
```

To build an image to the `theia-build` stage, for testing the Theia
build stage:

```
./build/build.sh --stage theia-build
```

Theia can then be tested by running this command, then opening
http://localhost:8080/:

```
docker run --rm -it -p 8080:3131 newsnowlabs/dockside:theia-build
```

## Building for foreign or multiple architectures

The above commands all build a Dockside image for the current native architecture platform.
To build for foreign architecture platforms, you may add the `--platforms` option.

However, due to bugs/limitations in the way Docker emulates foreign platforms, your mileage may vary with the `buildx` and `buildkit` builders i.e. you may hit unexpected errors during build.

[Depot](https://depot.dev) is a service for "building Docker images faster and smarter, in the cloud",
that can be used to build Dockside foreign or multiarch images.

To build an image for the native or foreign architecture(s) using the `depot` builder, run:

```
./build/build.sh --tag mytag --builder depot
```

The above command will build a multiarch image for the default set of platforms (see above). To specify individual platform(s), use the `--platforms` option (see above).

In order to use the `depot` builder, you must first install and configure the Depot CLI and register an account. Please refer to the Depot website and docs
at https://depot.dev/ for more information on Depot.

## Dockside development tips

It can be convenient to test a development image by launching it
within Dockside. When doing so, bear in the mind that:

- To test changes to the IDE or to IDE launch code, launch your development image using the `dockside-own-ide.json` profile. This launches the IDE from _within the launched image_.
- To test other changes, launch your development image using the `dockside.json` profile. This uses the IDE embedded in the already-running 'outer' Dockside instance, and saves resources.
