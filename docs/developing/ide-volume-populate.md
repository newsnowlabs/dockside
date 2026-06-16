# IDE volume populate — runtime permutations and design alternatives

`entrypoint.sh` populates `/opt/dockside` from `/opt/dockside.img` at container start.
The image layout (set up by the Dockerfile) is:

- `/opt/dockside.img/` — full IDE/system/bin content baked into the image layer.
- `/opt/dockside/` — **empty directory** in the image layer.
- `VOLUME /opt/dockside` — Docker creates an anonymous volume here on container start.

Dockside supports two OCI runtimes: **runc** (standard containers) and **sysbox-runc**
(system containers that run their own dockerd). Both are used under Docker and both
honour `VOLUME` declarations, so `/opt/dockside` is always a real mountpoint on the
Dockside container itself.

At start, `entrypoint.sh` classifies the mount and sets `OPT_PATH_STATE`:

```sh
if ! mountpoint -q "$OPT_PATH"; then
  OPT_PATH_STATE=symlinked          # not a mountpoint — see note below
elif (> $OPT_PATH/.writeable ...); then
  OPT_PATH_STATE=writeable
else
  OPT_PATH_STATE=readonly
fi
```

## Permutation table

Rows A–F are Dockside container startups (entrypoint.sh runs and classifies the mount).
Rows G–H are devtainer startups (Dockside's entrypoint does **not** run; `/opt/dockside`
arrives via a mount wired by `Reservation::Launch::cmdline_ide_mount()`).

| | Scenario | OCI runtime | `/opt/dockside` mount | `mountpoint` | Writeable? | `OPT_PATH_STATE` | Populate | Correct? |
|---|---|---|---|---|---|---|---|---|
| **A** | Standalone Dockside, first start | runc | Anonymous Docker volume (rw, empty) | ✓ | ✓ | writeable | Full populate | ✓ |
| **B** | Standalone Dockside, upgrade | runc | Named Docker volume (rw, existing content) | ✓ | ✓ | writeable | Incremental — new versions added, existing preserved | ✓ |
| **C** | Dockside container, own IDE volume (`mountIDE: false`) | runc / sysbox-runc | Own rw Docker volume | ✓ | ✓ | writeable | Full or incremental populate | ✓ |
| **D** | Dockside container, outer IDE volume (`mountIDE: true`) | runc / sysbox-runc | Outer Dockside's `/opt/dockside` bind-mounted ro | ✓ | ✗ | readonly | Skipped — outer volume already populated | ✓ |
| **E** | Dev/CI, rw bind mount from host | runc | Host bind mount (rw) | ✓ | ✓ | writeable | Populate | ✓ |
| **F** | Dev/CI, ro bind mount from host | runc | Host bind mount (ro) | ✓ | ✗ | readonly | Skipped | ✓ |
| **G** | Devtainer, normal dockerd path (`should_mount_ide`, `$HOSTNAME` set) | runc | Named Docker volume passed through from Dockside container inspect, ro | ✓ | ✗ | — ¹ | — ¹ | ✓ |
| **H** | Devtainer, inner dockerd path (`should_mount_ide`, `$INNER_DOCKERD` set) — sysbox / DinD / RunCVM / Podman | runc | Bind mount of Dockside container's `/opt/dockside`, ro | ✓ | ✗ | — ¹ | — ¹ | ✓ |

¹ Dockside's `entrypoint.sh` does not run in devtainers; they run the user's container image entrypoint.

## Notes

**A–C (own rw volume):** The production and dev path. Populate installs `launch.sh`
last as a readiness sentinel: its absence during populate causes `docker exec` from
the daemon to fail with exit 127 (ENOENT), which the daemon retries every 5 s for
up to 60 s.

**D (outer IDE volume, ro):** Standard devtainer-inside-Dockside. The outer Dockside's
volume is already populated; the inner container must not overwrite it.

**E–F (bind mount):** Operator/developer-managed. A ro bind mount typically means the
operator has pre-populated the path externally.

**G (named volume via host dockerd):** `Reservation::Launch::cmdline_ide_mount()`
resolves the Dockside container's `ideVolume` from the container inspect and passes it
through as a ro named volume mount. The devtainer sees the same volume content as the
Dockside container's `/opt/dockside`.

**H (bind mount via inner dockerd):** When `$INNER_DOCKERD` is set, there is no Dockside
container accessible to the inner dockerd, so `cmdline_ide_mount()` falls back to a
ro bind mount of `$idePath` (i.e. `/opt/dockside`) from the Dockside container's own
filesystem. This works because the populate step (row C) has already filled
`/opt/dockside` by the time devtainers are launched. The devtainer's `/opt/dockside`
is effectively a read-only snapshot of the Dockside container's populate output.

**Symlinked state:** `OPT_PATH_STATE=symlinked` (not a mountpoint) cannot be reached
under runc or sysbox-runc because Docker always honours `VOLUME`. It is a historical
artefact from a layout where bootstrap symlinks existed at `$OPT_PATH`; the current
Dockerfile places an empty directory there instead.

## Design alternatives for the inner dockerd path (row H)

The current H path requires the Dockside container to populate `/opt/dockside` before
any devtainer launches, purely so that content can be bind-mounted into devtainers.
Two alternatives could eliminate or reshape that dependency.

### Alt 1 — bind-mount `/opt/dockside.img` directly

Change `cmdline_ide_mount()` to pass `$idePath . '.img'` instead of `$idePath` when
`$INNER_DOCKERD` is set. Devtainers would receive a ro bind mount of
`/opt/dockside.img` (the baked image-layer directory) rather than the populated
`/opt/dockside`.

**Pro:** No populate step needed in the inner dockerd case; `/opt/dockside.img` is
always present from the image layer; removes the sentinel race entirely for this path.

**Con:** Devtainers get the exact image-build-time content with no upgrade semantics
(though this is probably acceptable — the Dockside container image is what gets
upgraded, not the volume). Requires knowing the `.img` path is stable, which it is
(`$OPT_PATH.img` is set by the Dockerfile).

**Assessment:** Low-risk improvement worth implementing when the inner dockerd path
is next touched. Does not interact with the current branch's populate logic changes.

### Alt 2 — Docker volume managed by the inner dockerd

When Dockside starts the inner dockerd, create a named Docker volume (under that
dockerd) and pre-populate it from `/opt/dockside.img`. `cmdline_ide_mount()` would
resolve this volume name (discovered by the Dockside server or docker-event-daemon)
and pass it to devtainers as a named ro volume mount — the same pattern as row G.

**Pro:** Devtainers under inner dockerd would use the same named-volume path as those
under the host dockerd; upgrade semantics would be available.

**Con:** Significantly more complex: Dockside must manage volume lifecycle under a
secondary dockerd, and the server/docker-event-daemon must discover and track the
volume name. Volume population timing must be guaranteed before the first devtainer
launch. Benefit over Alt 1 is unclear given that upgrades are handled at the Dockside
container level anyway.

**Assessment:** Higher complexity without a clear advantage over Alt 1. Not recommended
unless named-volume semantics for inner devtainers become a specific requirement.
