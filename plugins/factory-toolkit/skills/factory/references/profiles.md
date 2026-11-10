# Profiles: the contract between a repo and the factory

The engine knows nothing about a product. A repo's **project** says what its products need: a `config.sh` and one
**profile** per product. It lives in the repo's own `.factory/` once the team adopts the factory; while the factory is
experimental, it ships with the skill in `projects/<project>/`, picked by its `REPO_MATCH` against the repo's `origin`
(supported projects and how to move one into its repo: `projects/README.md`). The repo's `.factory/profiles/` wins when
both exist. Tickets are working files, never committed: `.claude/worktrees/factory-tickets/` in the main checkout. Each product
is a **profile**. **Nothing builds or tests on the Mac**: every build and test runs in a VM of the target OS.

A product has two halves. What it is and how its VMs build, test and launch it (`APP_NAME`, `CODE_PATHS`, its guest
**targets** and their scripts, its VM layer) is the **VM toolkit**'s product definition (the `vm-toolkit` plugin, its
`references/products.md`): the repo's `.vm/`, else the one the toolkit bundles for the repo. RDM on Windows, macOS and
Linux is one product with three targets. The profile here is the factory's half on top: review standards, branch
naming, protected paths, and which product it is (`VM_PRODUCT`, default the profile's name).

Start the product definition first when it doesn't exist (`vmt new-product <name>`), then the profile with
`factory.sh new-profile <name> [--skill <project>]` (it copies `templates/profile/` into the repo's
project; a repo with none gets one, in the skill with `--skill`, else in its `.factory/`), fill every `TODO`, then `factory.sh check <name>` until it says OK. `check` validates everything below
that can be checked without running a VM; prove the rest with `run-loop.sh <KEY> --test-only <ref>` and
`--qa-only <ref>` on a commit whose answer you know, with `--expect red|green`.

## Layout

```
<project>/                         <skill>/projects/<project>/ for now, <repo>/.factory/ once adopted
  config.sh                        team defaults: DEFAULT_PROFILE, models and caps, DASHBOARD_NAME/PORT (REPO_MATCH in the skill)
  profiles/<name>/
    profile.sh                     the factory's settings for the product
    reviewer.md                    the reviewer's standards for it
<definitions>/<product>/           the VM toolkit's: <repo>/.vm/, else its bundled projects/<project>/ (references/products.md there)
<main checkout>/.claude/worktrees/factory-tickets/<KEY>.md, <KEY>.sh   a spec and its inputs (spec-authoring.md), not committed
~/.vm-toolkit/config.sh            per machine, never committed: VM_ROOT, VM_CPUS, VM_MEM, VM_MAX, VM_SLOT_WAIT_MIN, VM_IDLE_MIN
~/.factory/config.sh               per machine, never committed: budget overrides (VM settings here still apply, and win)
```

The project's `config.sh` may set `PR_INSTRUCTIONS`: the repo's own PR instructions, repo-relative (RDM:
`.claude/skills/pull-request-rdm/SKILL.md docs/processes/GIT_PULL_REQUEST.md`), which the PR writer (`factory.sh pr`)
reads first and follows; a path missing at run time is logged. Without them it looks for the repo's own, and with none
it fills the engine's `templates/pr-template.md`.

The project's `config.sh` also sets `DOC_PATHS`: repo path prefixes of docs any change may update (for RDM, the root
`.claude/skills/ docs/ CLAUDE.md` plus the DVLS and Console folders' own skills and CLAUDE.md). The builder keeps them
true, verify accepts them whatever the ticket's scope, the reviewer's Docs line checks them, and `factory.sh which`
treats them as shared by every product. Claude Code refuses an unattended session's edits under any `.claude/` folder
(no allow rule or permission mode changes that), so for a `DOC_PATHS` entry under a `.claude/` folder, the root one or
a nested one, the builder writes the new file at `handback/<branch>/docs/<path with that folder's dot dropped>`
(`docs/claude/…`, `docs/DVLS/claude/…`) and the runner copies it into place in its own commit, before verify.

Load order, later wins: engine defaults (`scripts/lib/config.sh`) < the project's `config.sh` < the ticket's `.sh` <
the product's `product.sh` and `target.sh` < `profile.sh` < `~/.vm-toolkit/config.sh` < `~/.factory/config.sh`. All are bash 3.2 (the macOS default): no associative arrays.

## profile.sh

| Variable | Required | Meaning | Example (console) |
|---|---|---|---|
| `VM_PRODUCT` | no | the VM toolkit product it is, when not named like the profile | `console` |
| `REVIEW_STANDARDS` | yes | the reviewer's standards file: absolute, or repo-relative | `$PROFILE_DIR/reviewer.md` |
| `BRANCH_PREFIX` | yes | prefix of the run's branch; `TICKET` is set when it is read | `devex/factory-` |
| `PR_BASE` | yes | the draft PR's target branch | `master` |
| `PROTECTED_EXTRA` | no | paths the builder may never touch, beyond the oracle, `.factory` and `.claude` | `.github` |

No build or test command lives here, nor the app name, code paths or targets: those are the product definition's.
`factory.sh which <path>` maps a path to its product (the toolkit's `CODE_PATHS`), then to the profile using it.

## reviewer.md

What a reviewer from another team would miss on this product: the coding standards documents to apply (with paths), the
product rules and the skills that hold them, and what **Data flows** means for this codebase (UI-thread, async I/O,
persistence, secrets…). Short: the reviewer reads the whole file for every review.

## Targets and layers

The product definition's: the VM toolkit's `references/products.md` (scripts, their inputs, `EXIT CODE` rules, layers).
`factory.sh layer <profile> --test|--build` builds the layer of the profile's product (`vmt layer`).

How the loop uses the targets: one VM per run at a time, and only while in use. The build VM, booted by the first build
or test and powered off after `VM_IDLE_MIN` unused, serves the builder (`guest build|test|info`) and the runner's verify
(`build`, one clean rebuild on red, then the ticket's `test`) and goes down once verify is green; each QA round boots a
fresh clone that runs `launch` on what verify built, without rebuilding.

State one ticket needs belongs in a fixture run inside the throwaway clone, where it costs time, not disk. A fixture is
the ticket's, not the profile's: `<KEY>.fixtures/<name>/` next to its spec (`factory.sh fixture <KEY> <name>`), which
the runner applies in each QA VM before the app starts when the ticket's assessment names it
([test-needs.md](test-needs.md)). A profile has no `fixtures/`. What only a human can provide (a real server, an
account) is not a fixture: it lives on the machine, `factory.sh provide <name>`.

## Tickets

`<KEY>.sh` (next to `<KEY>.md` in `factory-tickets/`) picks `PROFILE` (default `DEFAULT_PROFILE`; pick it with
`factory.sh which`) and `PLATFORM` (default: the product's first target), and sets `ACCEPT_TEST` (a test project),
`ACCEPT_FILTER`, `ORACLE_PATHS` and `SCOPE_REGEX`: references/spec-authoring.md. `factory.sh check` checks the tickets of
each profile too, and warns when `ACCEPT_TEST` is outside the product's `CODE_PATHS`. Each run copies the spec into its
run folder; `factory.sh clean <KEY>` deletes it with the runs once the ticket is done.

## What stays out of a profile

Credentials (NuGet feeds, VM keys, generated passwords), installers, VM images and anything specific to one machine. The
first three live under the VM home, `~/.vm-toolkit/` or `~/.factory/`, never in the repo.
