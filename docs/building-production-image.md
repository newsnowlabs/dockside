# Building a Dockside production image

## Dockside production rebuild instructions

We use [Depot](https://depot.dev/) to build multi-architecture images for Dockside, and Docker Hub to store them. The following process requires access to the NewsNow Labs' Depot and Docker Hub accounts (or your own accounts, with the process suitably modified).

1. Set up Depot
   1. Follow the instructions on the Depot website to install the Depot CLI.
   2. From within the root of the Dockside repo, run `depot login` to generate a `depot.json` file, if you do not have one already. You may need to send your authorization URL for approval to somone who is authorized.
2. Build a single platform docker image for each supported platform and resolve any build issues, with the following commands:
   ```sh
   ./build/build.sh --builder depot --tag test --platform linux/amd64
   ./build/build.sh --builder depot --tag test --platform linux/arm64
   ./build/build.sh --builder depot --tag test --platform linux/arm/v7
   ```
   (These commands will each build an image called `newsnowlabs/dockside:test`)
3. Build a multiplatform docker image for testing, pushing it to the image repository. (Please note, this commands executes quickly as it draws upon the cached image layers from the previous build steps.)
   ```sh
   ./build/build.sh --builder depot --tag test --push
   ```
   N.B. `--push` will push your image to Docker Hub.
4. Test your multiplatform image by launching it within Dockside using the 'Dockside (IDE from image)' profile and the `newsnowlabs/dockside:test` image, ideally on our supported range of architectures.
5. Prepare a new GitHub release with a [semantic versioned](https://semver.org/) tag in the form `vA.B.C` and title and text composed from the git log messages of the intervening commits. Publish the release.
6. Pull the new git release tag
   1. Make sure `git status` and `git stash list` is clean
   2. Rebuild the multiplatform docker image with the default production image tag `latest`, pushing it to the image repository; and again with the git release tag used as the image tag.
      ```sh
      ./build/build.sh --builder depot --push
      ./build/build.sh --builder depot --tag vA.B.C --push
      ```
7. Announce the release on the NewsNow Labs `#general` Slack channel, in similar language to that used for the GitHub release.

That completes  the process of building a Dockside image for production.

