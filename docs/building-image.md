# Building a Dockside image

A Dockside image can be built directly from the repo, on any host running Docker - and even within a Dockside devtainer.

To build a new `newsnowlabs/dockside:test` image:

```
./build/build.sh --tag test
```

You may now test your newly-built image, by launching a new Dockside devtainer using either the `Dockside` or `Dockside (IDE from image)`
profiles, selecting the `newsnowlabs/dockside:test` image from the Image menu.

## Build options

- `--repo <repo>` - build image with name `<repo>` (overriding the default repo, `newsnowlabs/dockside`)
- `--tag <tag>` - tag resulting image with `<tag>` (overriding the default tag, `latest`)
- `--stage <stage>` - build to the stage `<stage>` - `<stage>` must be a valid Dockerfile build stage e.g. `theia-build`, `theia-clean`, `theia` and the resulting image will be additionally tagged with `<stage>`
- `--theia <version>` - build image with Theia version `<version>` - `<version>` must be a valid Theia version and subfolder of `ide/theia`
- `--push` - push resulting image to registry (requires appropriate permissions for the registry)
- `--no-cache`, `--force-rm`, `--progress-plain` - pass the relevant option to the Docker build process
- `--list` - list all local images for the Dockside repo (default `newsnowlabs/dockside`)
- `--clean` - remove all local images for the Dockside repo (default `newsnowlabs/dockside`)
- `--help` - display all build options

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

## Dockside development tips

It can be convenient to test a development image by launching it
within Dockside. When doing so, bear in the mind that:

- To test changes to the IDE or to IDE launch code, launch your development image using the `dockside-own-ide.json` profile. This launches the IDE from _within the launched image_.
- To test other changes, launch your development image using the `dockside.json` profile. This uses the IDE embedded in the already-running 'outer' Dockside instance, and saves resources.
