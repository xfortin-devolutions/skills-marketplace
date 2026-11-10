# Product definitions: the contract between a repo and its VMs

The toolkit knows nothing about a product. A **product definition** says what the product is, where its code is, and
how a VM of each OS it ships on builds, tests and launches it. Each guest OS is a **target** of the product: RDM on
Windows, macOS and Linux is one product with three targets. Every build and test runs in a VM of the target OS, through
the target's scripts; the host only edits and drives the VMs.

A repo's definitions live in its own `.vm/` folder. Until a repo carries them, the toolkit bundles them in
`projects/<project>/`, picked by `REPO_MATCH` in its `project.sh` against the repo's `origin` remote. The repo's `.vm/`
wins when both exist; moving a bundled project into its repo is copying its product folders to `<repo>/.vm/`.
`vmt products` says which definitions a repo uses; `vmt check [<product>]` checks them and this machine's images.

Start one with `vmt new-product <name>` (copies `templates/product/` into the repo's definitions), fill every `TODO`,
then `vmt check <name>` until it says OK. Prove the scripts on a VM: `vmt init <dir> <worktree> --product <name>`, then
`vmt guest <dir> build`, `vmt guest <dir> test <project>`, `vmt guest <dir> app launch` and `app shot`.

## Layout

```
<definitions>/                     <repo>/.vm/, or the toolkit's projects/<project>/ (with a project.sh: REPO_MATCH)
  <product>/
    product.sh                     the product
    targets/<os>/target.sh         one guest target: image and scripts
    targets/<os>/build.ps1         builds what ships, in the guest
    targets/<os>/test.ps1          runs one test project, in the guest
    targets/<os>/launch.ps1        starts the build in the guest's desktop session
    layer/layer.conf, setup.ps1    optional: the VM layer the targets start from
    layer.md                       optional: notes on how the layer was worked out
~/.vm-toolkit/config.sh            per machine, never committed: VM_ROOT, VM_CPUS, VM_MEM, VM_MAX, VM_SLOT_WAIT_MIN, VM_IDLE_MIN
```

All are bash 3.2 (the macOS default): no associative arrays. A caller with settings of its own (the factory's profiles)
names a product and adds its settings on top; nothing here is about who calls.

## product.sh

| Variable | Required | Meaning | Example (console) |
|---|---|---|---|
| `APP_NAME` | yes | what agents are told they work on | `Devolutions Console` |
| `CODE_PATHS` | yes | where the product's code is: repo paths, space-separated; `vmt which <path>` picks the product with the longest match | `Console/` |
| `TARGETS` | yes | targets under `targets/`, space-separated; the first is the default | `windows` |

No build or test command lives here: that is the targets' job, in the guest.

## Targets

`target.sh` (read with `TARGET_DIR` set):

| Variable | Required | Meaning |
|---|---|---|
| `GUEST_OS` | yes | the guest OS folder under the VM root (`windows`) |
| `GUEST_DESC` | yes | the guest as agents are told about it (`Windows 11 ARM64 with IIS, …`) |
| `GOLDEN_IMAGE` | no | the image clones start from: `base.qcow2` (default) or a layer this product builds (`<LAYER>.qcow2`) |
| `SHARE_CHECK` | yes | a repo-relative file the shared worktree must contain (proves the right repo is shared) |
| `GUEST_BUILD`, `GUEST_TEST`, `GUEST_LAUNCH` | yes | the three scripts, usually `$TARGET_DIR/build.ps1`, … |

The scripts run in the guest with the worktree at `R:` (Windows), sent by `vmssh`, which runs in SSH's session 0 (no
desktop). Callers run them through `scripts/guest.sh` (`vmt guest`, the MCP server's `vm_build`, `vm_test`,
`vm_app_launch`), which sets their inputs and reads their verdict:

| Script | Inputs | Must | Ends with |
|---|---|---|---|
| `build` | `$Project` (empty: build what ships) | stop the running app first (it locks its files on the share) | `BUILD EXIT CODE: <n>` |
| `test` | `$Project`, `$Filter` (may be empty), `$NoBuild` | run that test project only; with `$NoBuild`, on what the last whole build left (`dotnet test --no-build`) | `TEST EXIT CODE: <n>` |
| `launch` | none | stop any running instance; start the built app in the signed-in desktop session (run again to restart it). A server or web app: deploy or start it, wait until it answers, then open the browser at its URL in the desktop session | `LAUNCH OK` once it is starting (a server: once its page answers) |

Exit code rules: a non-zero code with restore or SDK errors (`NU…`, `NETSDK…`, `MSB4236`) is a harness error; any other
non-zero code is the change's fault. When the harness is at fault (no `R:`, no SDK), stop **without** printing the
`EXIT CODE` line: `guest.sh` then exits 3 (harness error), which a caller must never blame on the change.

## Layers

One golden image per guest OS (`<VM root>/<os>/base.qcow2`, [vm-setup.md](vm-setup.md)), shared by every product.
Disk is the limit: never an image per scenario or per ticket. Software a product needs on the machine (servers,
databases, services) goes in a **layer**: a qcow2 overlay on `base.qcow2` that stores only its own changes (the
Console's IIS, SQL Server Express, PostgreSQL and four DVLS instances: 6 GB). State one test needs belongs in a setup
folder applied inside the throwaway clone (`vmt apply`, `scripts/apply.sh`), where it costs time, not disk.

`layer/layer.conf` (bash, read with `VM_HOME` set, and `FACTORY_VM_HOME` for older ones):

| Variable | Required | Meaning |
|---|---|---|
| `LAYER` | yes | the image name: `<LAYER>.qcow2`, which a target names in `GOLDEN_IMAGE` |
| `LAYER_FILES` | no | host files copied to the guest's `C:\factory\layer\` (installers without a public URL live in `<VM home>/installers/`, never in the repo) |
| `LAYER_DIRS` | no | `<guest folder>=<host folder>` pairs, copied to `C:\factory\layer\<guest folder>\` |

It may print why it can't build on this machine and `return 1` (a missing installer).

`layer/setup.ps1` runs in the guest, elevated, in the desktop session (installers such as PostgreSQL's fail from SSH).
Every step checks whether it is already done and skips it, so a failed run is started again rather than from scratch
(the template's `Step` helper). It logs to `C:\factory\layer\setup.log` and ends it with `LAYER SETUP OK` or
`LAYER SETUP FAILED: <why>`. Generated credentials go to `C:\factory\secrets\` (administrators only), never to the log.

`vmt layer <product> --test` rehearses it on a throwaway clone of `base.qcow2`, left up to inspect; `--build` creates
the layer, fills it, removes the setup's files, trims, shuts down and freezes it.

## What stays out of a definition

Credentials (NuGet feeds, VM keys, generated passwords), installers, VM images and anything specific to one machine.
They live under the VM home or `~/.vm-toolkit/`, never in a repo.
