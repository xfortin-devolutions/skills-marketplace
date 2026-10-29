# Profiles: the contract between a repo and the factory

The engine knows nothing about a product. A repo's **project** says what its products need: a `config.sh` and one
**profile** per product. It lives in the repo's own `.factory/` once the team adopts the factory; while the factory is
experimental, it ships with the skill in `projects/<project>/`, picked by its `REPO_MATCH` against the repo's `origin`
(supported projects and how to move one into its repo: `projects/README.md`). The repo's `.factory/profiles/` wins when
both exist; tickets always live in the repo's `.factory/tickets/`, on each ticket's own branch. Each product
is a **profile**, and each guest OS the product ships on is a **target** of that profile. RDM on Windows, macOS and
Linux is one profile with three targets, not three profiles: standards, scope rules and branch naming are the same, only
the guest image, build, test and launch differ. **Nothing builds or tests on the Mac**: every build and test runs in a VM
of the target OS, through the target's scripts.

Start one with `factory.sh new-profile <name> [--skill <project>]` (it copies `templates/profile/` into the repo's
project; a repo with none gets one, in the skill with `--skill`, else in its `.factory/`), fill every `TODO`, then `factory.sh check <name>` until it says OK. `check` validates everything below
that can be checked without running a VM; prove the rest with `run-loop.sh <KEY> --test-only <ref>` and
`--qa-only <ref>` on a commit whose answer you know.

## Layout

```
<project>/                         <skill>/projects/<project>/ for now, <repo>/.factory/ once adopted
  config.sh                        team defaults: DEFAULT_PROFILE, models and caps (REPO_MATCH in the skill)
  profiles/<name>/
    profile.sh                     the product
    reviewer.md                    the reviewer's standards for it
    targets/<os>/target.sh         one guest target: image and scripts
    targets/<os>/build.ps1         builds what ships, in the guest
    targets/<os>/test.ps1          runs one test project, in the guest
    targets/<os>/launch.ps1        starts the build in the guest's desktop session
    layer/layer.conf, setup.ps1    optional: the VM layer the targets start from
    layer.md                       optional: notes on how the layer was worked out
<repo>/.factory/tickets/<KEY>.md, <KEY>.sh   a spec and its inputs (references/spec-authoring.md), on the ticket's branch
~/.factory/config.sh               per machine, never committed: FACTORY_VM_ROOT, VM_CPUS, VM_MEM, VM_MAX, budget overrides
```

Load order, later wins: engine defaults (`scripts/lib/config.sh`) < the project's `config.sh` < the ticket's `.sh` <
`profile.sh` < `target.sh` < `~/.factory/config.sh`. All are bash 3.2 (the macOS default): no associative arrays.

## profile.sh

| Variable | Required | Meaning | Example (console) |
|---|---|---|---|
| `APP_NAME` | yes | what the builder and the QA agent are told they work on | `Devolutions Console` |
| `TARGETS` | yes | targets under `targets/`, space-separated; the first is a ticket's default | `windows` |
| `REVIEW_STANDARDS` | yes | the reviewer's standards file: absolute, or repo-relative | `$PROFILE_DIR/reviewer.md` |
| `BRANCH_PREFIX` | yes | prefix of the run's branch; `TICKET` is set when it is read | `devex/factory-` |
| `PR_BASE` | yes | the draft PR's target branch | `master` |
| `PROTECTED_EXTRA` | no | paths the builder may never touch, beyond the oracle, `.factory` and `.claude` | `.github` |

No build or test command lives here: that is the targets' job, in the guest.

## reviewer.md

What a reviewer from another team would miss on this product: the coding standards documents to apply (with paths), the
product rules and the skills that hold them, and what **Data flows** means for this codebase (UI-thread, async I/O,
persistence, secrets…). Short: the reviewer reads the whole file for every review.

## Targets

`target.sh`:

| Variable | Required | Meaning |
|---|---|---|
| `GUEST_OS` | yes | the guest OS folder under `FACTORY_VM_ROOT` (`windows`) |
| `GUEST_DESC` | yes | the guest as the agents are told about it (`Windows 11 ARM64 with IIS, …`) |
| `GOLDEN_IMAGE` | no | the image clones start from: `base.qcow2` (default) or a layer this profile builds (`<LAYER>.qcow2`) |
| `SHARE_CHECK` | yes | a repo-relative file the shared worktree must contain (proves the right repo is shared) |
| `GUEST_BUILD`, `GUEST_TEST`, `GUEST_LAUNCH` | yes | the three scripts, usually `$TARGET_DIR/build.ps1`, … |

The scripts run in the guest with the worktree at `R:` (Windows), sent by `vmssh`, which runs in SSH's session 0 (no
desktop). The runner and the builder call them through `scripts/guest.sh`, which sets their inputs and reads their
verdict:

| Script | Inputs | Must | Ends with |
|---|---|---|---|
| `build` | `$Project` (empty: build what ships) | stop the running app first (it locks its files on the share) | `BUILD EXIT CODE: <n>` |
| `test` | `$Project`, `$Filter` (may be empty) | run that test project only | `TEST EXIT CODE: <n>` |
| `launch` | none | stop any running instance; start the built app in the signed-in desktop session (run again to restart it for the exploratory QA, and on a base build for its re-check) | `LAUNCH OK` once it is starting |

Exit code rules: a non-zero code with restore or SDK errors (`NU…`, `NETSDK…`, `MSB4236`) is a harness error; any other
non-zero code is the change's fault. When the harness is at fault (no `R:`, no SDK), stop **without** printing the
`EXIT CODE` line: the runner then reports ERROR and never sends the change back for it.

How the loop uses them: one build VM per run serves the builder (`guest build|test|info`) and the runner's verify
(`build`, one clean rebuild on red, then the ticket's `test`); each QA round boots a fresh clone that runs `launch` on
what verify built, without rebuilding.

## Layers

One golden image per guest OS (`<FACTORY_VM_ROOT>/<os>/base.qcow2`, references/vm-setup.md), shared by every profile.
Disk is the limit: never an image per scenario or per ticket. Software a product needs on the machine (servers,
databases, services) goes in a **layer**: a qcow2 overlay on `base.qcow2` that stores only its own changes (the
Console's IIS, SQL Server Express, PostgreSQL and four DVLS instances: 6 GB). State one ticket needs belongs in a fixture
run inside the throwaway clone, where it costs time, not disk.

`layer/layer.conf` (bash, read with `FACTORY_VM_HOME` set):

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

`factory.sh layer <profile> --test` rehearses it on a throwaway clone of `base.qcow2`, left up to inspect;
`--build` creates the layer, fills it, removes the setup's files, trims, shuts down and freezes it.

## Tickets

`tickets/<KEY>.sh` picks `PROFILE` (default `DEFAULT_PROFILE`) and `PLATFORM` (default: the profile's first target), and
sets `ACCEPT_TEST` (a test project), `ACCEPT_FILTER`, `ORACLE_PATHS` and `SCOPE_REGEX`: references/spec-authoring.md.
`factory.sh check` checks the tickets of each profile too.

## What stays out of a profile

Credentials (NuGet feeds, VM keys, generated passwords), installers, VM images and anything specific to one machine. The
first three live under the VM home or `~/.factory/`, never in the repo.
