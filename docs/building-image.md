# Building a Dockside image

A Dockside image can be built directly from the repo, on any host running Docker - and even within a Dockside devtainer.

To build a new `newsnowlabs/dockside:test` image :

```
./build/build.sh --tag test
```

You may now test your newly-built image, by launching a new Dockside devtainer using either the `Dockside` or `Dockside (IDE from image)`
profiles, selecting the `newsnowlabs/dockside:test` image from the Image menu.

To build a new image tagged for a custom repo, e.g. `myrepo:test` :

```
./build/build.sh --repo myrepo --tag test
```

> **N.B.**
> 
> - **To test changes to the IDE or IDE launch code, be sure to launch using the `dockside-own-ide.json` profile.**
> - **To test any other changes, using the stable/production IDE embedded in the 'outer' running Dockside instance, launch using the `dockside.json` profile.**
