# Updating Theia

Here is the procedure to follow to update Dockside to run the latest version of Theia.

1. Find the latest version of Theia e.g. `1.35.0` via the Eclipse Theia GitHub website (https://github.com/eclipse-theia/theia).
2. Inside a clone of [the Dockside repo](https://github.com/newsnowlabs/dockside), duplicate the latest Theia folder inside `ide/theia` and rename it to the new Theia version i.e. `1.35.0`
3. Inside the `build` subdirectory of `1.35.0`
   1. Delete `yarn.lock`.
   2. Inside the `patches` directory, rename each file, changing references to the old Theia version to the new Theia version.
   3. In `package.json`:
      - Update references to the old Theia version to the new version.
      - Audit the list of dependencies to ensure that every dependency referenced in the upstream new Theia version (at e.g. https://github.com/eclipse-theia/theia/blob/release/1.35.0/examples/browser/package.json) is referenced in your `package.json` with the exception of:
         - @theia/api-samples
         - @theia/memory-inspector
4. Update `Dockerfile` to reference the new Theia version for supported platforms.
5. Build a test image locally (see below):
   1. Resolve any build issues. e.g. You may need to upgrade the version of Node specified in the `Dockerfile`, or re-implement the patches.
   2. Test the image to ensure all patched functionality is working correctly 
6. Finally, when everything is tested and working, copy `yarn.lock` from the test image to the same Theia `build` subdirectory as contains the new `package.json` (i.e. `ide/theia/1.35.0/build`).
7. Don't forget to update the `README` file to describe the patches, should any patch files have been deleted or added.

## Building a test image, reimplementing patches and obtaining `yarn.lock`

The process for reimplementing Theia patches involves launching Theia, developing the necessary code changes to reimplement the desired functionality, and then regenerating the patches.

1. Build a Theia image using:
   ```sh
   ./build/build.sh --builder buildkit --platform linux/amd64 --stage theia-build
   ```
   (N.B. If you are developing on another platform architecture, adjust the command accordingly.)
2. Launch Theia using:
   ```sh
   docker run --name=my-theia-build -it -p 80:3131 newsnowlabs/dockside:theia-build
   ```
3. Open Theia at http://localhost/ and begin debugging and development:
   1. Modify Theia _javascript_ files (_not_ typescript, though it can be useful to look at the typescript files to understand the javascript files).
   2. Rebuild the Theia javascript bundle using:
      ```sh
      PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 && NODE_OPTIONS="--max_old_space_size=4096" && yarn config set network-timeout 600000 -g && yarn
      ```
   3. Reload Theia in your browser (assuming client-side code patches only) and/or stop/start the Theia backend by stopping and starting `my-theia-build` (assuming server-side code has been touched).
   4. Test your changes to ensure they deliver the desired functionality (see below).
   5. Lastly, regenerate `patch-package` patch files, replacing `<package>` with the name of the relevant Theia package (e.g. `@theia/core`, `@theia/application-manager` or `@theia/plugin-ext`) using:
      ```sh
      apk add git; yarn patch-package <package>
      ```
4. Finally, the `yarn.lock` file you need is the one present in the `my-theia-build` container home directory. You can copy it to the `ide/theia/<version>/build` directory of your repo, assuming you are already in that directory, using:
   ```sh
   docker cp my-theia-build:/opt/dockside/theia/theia/yarn.lock .
   ```

## Testing for desired functionality of Theia patches

In order to test that the Dockside Theia patches exhibit the desired functionality, you'll need to launch a test instance of Dockside, from a test image. See [Building a Dockside image](building-image.md) or [Building a Dockside production image](building-production-image.md).

### Testing patch to fix invalid cspSource

Perform the following steps within the IDE of a devtainer launched from a test Dockside image using the `Dockside (IDE from image)` profile:

1. Install the Git Graph extension
   - View > Extensions
   - Search for 'Git Graph'
   - Click 'Install'
2. Run command `Git Graph: Add Git Repository`, select the `dockside` folder and click `Open`.
3. Run command `Git Graph: View Git Graph (git log)`.
4. Confirm that the Git Graph git log display opens up.

### Testing patch to modify browser title to incorporate devtainer name

Perform the following steps within Theia running inside the `my-theia-build` test image:

1. Confirm that the title of the browser window is of the form `[devtainer] - theia - Theia for Dockside from NewsNow Labs`.

Perform the following steps within the IDE of a devtainer launched from a test Dockside image using the `Dockside (IDE from image)` profile:

1. Launch the test image, log in and launch a test devtainer from any profile.
2. Confirm that the title of the brown's a window is of the form `<devtainer name> - <open file> - <workspace> - Theia for Dockside from NewsNow Labs`.