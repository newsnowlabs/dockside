# Building a Dockside image

A Dockside image can be built directly from the repo, on any host running Docker - and even within a Dockside devtainer.

To build a new `dockside:test` image :

```
./build/build.sh --tag test
```

You may now test your newly-built image, by launching a new Dockside devtainer and selecting the `newsnowlabs/dockside:test` image from the devtainer launch menu.

> **N.B.**
> 
> - **To test changes to the IDE or IDE launch code, be sure to launch using the `dockside-own-ide.json` profile.**
> - **To test any other changes, using the stable/production IDE embedded in the 'outer' running Dockside instance, launch using the `dockside.json` profile.**
