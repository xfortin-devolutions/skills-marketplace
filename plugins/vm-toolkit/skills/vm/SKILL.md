---
name: vm
description: "[EXPERIMENTAL] Throwaway QEMU VMs of a product's target OS (Windows 11 ARM64 today), run from a Mac: build and test a repo's worktree inside a VM that shares it live, launch the built app in the guest's desktop, take screenshots and drive it with mouse and keyboard, record a demo video with captions, apply test data, and open the VM's screen for a person (TigerVNC with a shared clipboard, else Screen Sharing). Products (RDM, Devolutions Console, …) are defined per repo: the repo's .vm/ folder, else a definition bundled with this skill. Also the one-time golden image, product VM layers (IIS, SQL Server, DVLS…), and setting up a new product. Use when the user says 'test this branch on Windows', 'build it in a VM', 'show me the app in the VM', 'set up the VM image', 'build the console layer', 'add a product to the VMs', or when an agent needs a real target OS to check a change. The same tools are an MCP server (vm_up, vm_build, vm_screenshot, …) for agents in other harnesses. The factory skill runs its loop on these VMs."
---

# VM toolkit

Throwaway VMs of the OS a product ships on, cloned per use from a read-only golden image (copy-on-write: seconds to
boot, nothing kept). The VM shares a worktree from this Mac live as `R:`, so a build in the guest sees every edit and its
output stays in the worktree (incremental across reboots). Nothing about the product is built on the Mac.

`V=<skill dir>/scripts`, where `<skill dir>` is this skill's base directory (an absolute path: installed as a plugin,
apart from any repo). Run `vmt` from inside the repo, or pass `--repo <path>` first.

What a product is, and how its VM builds, tests and launches it, is its **definition**: the repo's `.vm/<product>/`, else
the one this skill bundles for the repo in `projects/<project>/` (today `devolutions-rdm`: `rdm` and `console`, on
Windows). Contract: [references/products.md](references/products.md).

## Pick the job

| User says | Do |
|---|---|
| "test / build this branch in a VM", "does it build on Windows" | **use a VM** below |
| "show me the VM", "let me see the app" | `bash $V/vmt show <vm dir>` (TigerVNC with the clipboard shared both ways, else Screen Sharing; this Mac only) |
| "set up the VMs", no image yet (`vmt products` says "not on this machine") | **setup** |
| "build / update the console layer" | **layer** |
| "add DVLS to the VMs", a path with no product (`vmt which` says "no product") | **new product** |
| "what VMs are running", a slot stuck | `bash $V/vmt list`, `bash $V/vmt gc` (frees dead VMs' slots) |
| "keep this sign-in / setup for the next VMs", "start QA from the dev's VM" | **checkpoints** |
| "which checkpoints are there", "clean up the checkpoints" | `bash $V/vmt checkpoint list`, `… rm <name>...` |
| "record a demo", "make a video of it" | **use a VM**, step 5 |

## Use a VM

1. `bash $V/vmt products` (and `vmt which <changed paths>` when the repo has several): the product, its target, its
   image, and whether the image is on this machine.
2. Pick a VM folder outside the repo, one per worktree, e.g. `$(bash $V/vmt root)/mcp/<name>`: the MCP server uses
   that folder too, so either can pick the VM up.
   `bash $V/vmt init <vm dir> <worktree> --product <p>`.
3. `bash $V/vmt guest <vm dir> build [<project>] [--clean]`, `… test [--no-build] <project> [<filter>]`: the first
   guest command boots the VM (waiting for a free slot), and it powers off after `VM_IDLE_MIN` (10) idle minutes; the
   next command boots it again. `vmt up <vm dir> --keep` instead keeps it up until `vmt down`, for a person looking at
   it. Exit 0 green, 1 red (the change), 3 harness error (the VM, the share, a restore: not the change; retry or say so).
   The summary prints the errors and the log's path (`<vm dir>/build.log`, `test.log`).
4. The app: `vmt guest <vm dir> app launch`, then `app wait <s>`, `app shot` (prints the PNG's path: read it),
   `app click <x> <y> [right|double]`, `app type <text>`, `app key ctrl-n tab ret`, `app scroll <x> <y> <n>`,
   `app stop`. Coordinates are screenshot pixels. One PowerShell command in the guest: `vmt guest <vm dir> run '<ps>'`.
5. A demo video: `app record start [<max min>]` (default 10), drive the app as in step 4, then `app record stop`
   (prints the MP4's path: `<vm dir>/app/video-N.mp4`, 15 fps, 1 to 2 MB a minute). Clicks are circled in it; `app caption
   '<text>' [<s>]` shows a caption from then on, until the next one (or for `<s>` seconds; `''` clears it): say what
   is being done or what to look at, one short sentence. A recording ends at its limit or with the VM; `stop` then
   still reports it. Needs ffmpeg (`brew install ffmpeg`) and a VM started by 0.3.0 or later (else down and up).
6. Test data or a resource the app reads at startup: `vmt apply <vm dir> <folder> [<guest folder>]` before launching
   (copies it, runs its `check.ps1`, then `apply.ps1`, with `$Dir` set).
7. `bash $V/vmt down <vm dir>` when done. The folder stays; `vmt up` boots a fresh clone from it.

A screenshot is evidence of what the app does; a build log is evidence of what compiles. Say which you have.

## checkpoints

A VM's disk goes when it powers off, and with it what was done in the guest: a person's sign-in to an SSO tool,
installed tools, test data. A **checkpoint** keeps that state for the VMs that come after (a ticket's QA after its dev):

1. In the VM, set up what the work needs; for a sign-in, `vmt show` it and ask the person.
2. `bash $V/vmt checkpoint <vm dir> <name> [--note '<what was set up>'] [--resume]`: the guest shuts down cleanly
   (apps write their settings), then its disk becomes the read-only image `<VM root>/<os>/checkpoints/<name>.qcow2`
   (~1 min, ~1 GB). The VM starts from it from then on; `--resume` boots it again right away. Name it after the
   branch or ticket (`devex-610`; `devex-610-2` for a later one, which is built on the first). The note is for the
   VMs that start from it: never secrets.
3. Other VMs: `vmt init <vm dir> <worktree> --product <p> --checkpoint <name>`, then use them as usual. Each is its
   own throwaway copy: what one does never reaches another, or the checkpoint.

What the checkpoint holds is the guest's disk, not the worktree: an app that keeps its settings next to its exe (RDM's
Debug build, in `bin/` on `R:`) keeps them on the Mac, and a VM sharing another worktree doesn't see them.
Nothing deletes a checkpoint but a person: `vmt checkpoint list` (size, age, branch, users; `vmt list` counts them),
`vmt checkpoint show <name>` (and its note), `vmt checkpoint rm <name>...`, refused while a running VM or another
checkpoint is built on it. Agents never delete one: say which can go and let the person run `rm`. The golden image
can't be compacted while checkpoints exist.

## Other agents: the MCP server

The plugin declares an MCP server, `vm` (`mcp/server.py`, Python standard library only), with the same jobs as tools:
`vm_products`, `vm_up` (`from_checkpoint`), `vm_build`, `vm_test`, `vm_run`, `vm_app_launch`, `vm_app_stop`,
`vm_screenshot` (returns the image and its path), `vm_click`, `vm_type`, `vm_key`, `vm_scroll`, `vm_record_start`,
`vm_caption`, `vm_record_stop` (a demo video's path), `vm_apply`, `vm_show`,
`vm_checkpoint`, `vm_checkpoints` (list, or one's note), `vm_list`, `vm_down`; none deletes a checkpoint. A named VM's
folder is `<VM root>/mcp/<name>`. Claude Code gets it with the plugin; another harness (Codex, Cursor, a FleetView agent
on another provider) adds `python3 -I <plugin dir>/mcp/server.py` as a stdio MCP server. It runs on the machine with
the images: a client elsewhere gets screenshots, but `vm_show` opens the screen (TigerVNC, else Screen Sharing) on that
machine only. A build can take many minutes: give the client a long tool timeout.

## setup

The one-time golden image: walk the user through [references/vm-setup.md](references/vm-setup.md). It needs their
Windows 11 ARM64 ISO, their Artifactory `NuGet.Config` and one keypress, and takes about an hour. One image per guest OS
(`<VM root>/<os>/base.qcow2`), never one per scenario.

## layer <product>

Software a product needs in the guest beyond the golden image (a database, IIS, a server) is a **layer**: a qcow2
overlay on the base, built from the product's `layer/setup.ps1` and `layer/layer.conf` (contract: products.md, Layers).
`bash $V/vmt layer <product> --test` rehearses on a throwaway clone left up to inspect; `--build` creates and freezes
the image (ask first: it writes a VM image). The `console` product's `layer.md` is a worked example and a list of traps.

## new product

A product with no definition: `bash $V/vmt new-product <name>` from the repo creates `.vm/<name>/` (or adds to the
definitions the repo already uses). While the repo shouldn't carry it, put it in this skill's bundled project for the
repo instead (copy `templates/product/` there, commit it to the marketplace repo). Fill every `TODO` with the user,
reading the repo first: `product.sh` (app name, `CODE_PATHS`, targets), per target `target.sh` (guest OS, image, share
check) and the three scripts (`build.ps1` builds what ships, `test.ps1` one test project with a filter, `launch.ps1`
starts the build in the desktop session and prints `LAUNCH OK`). `bash $V/vmt check <name>` until OK, then prove the
scripts on a VM (**use a VM**). The `rdm` and `console` definitions in `projects/devolutions-rdm/` are worked examples.

## Where things are

| What | Where |
|---|---|
| Golden image, layers, guest SSH key, installers | `<VM root>/<os>/` (`vmt root`; default `~/VMs/factory`) |
| A VM's clone disk, logs, screenshots, videos, settings (`guest.conf`) | its VM folder (`<VM root>/mcp/<name>/` for the MCP server's) |
| Machine settings: VM root, CPUs, RAM, slots, idle minutes | `~/.vm-toolkit/config.sh` (`~/.factory/config.sh` is read first, for older setups) |
| Product definitions | the repo's `.vm/`, else `projects/<project>/` in this skill |
| What is still missing | `GAPS.md` at the plugin's root |

Credits: the `rdm-windows-vm-test` setup (QEMU Windows 11 ARM64, QMP driving, SMB share), changed to clone one VM per
use from a read-only golden image; extracted from the factory skill, which runs its loop on it.
