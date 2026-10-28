---
name: factory
description: "[EXPERIMENTAL] Software factory for Jira tickets, run from a Mac, for any repo with a .factory/ folder (profiles per product: RDM, Devolutions Console, …): turn a ticket into an agent-ready spec with a red oracle, then run the unattended loop — headless builder in its own worktree that builds and tests in a per-run QEMU VM of the target OS (nothing builds on the Mac), runner verify in that VM, read-only reviewer, and a blind runtime QA stage that drives the verified build in a fresh throwaway VM — with send-backs, caps, a hand-back for the human judge, and Screen Sharing on the VM when a human is needed. Sub-commands: spec, run, qa, status, show, human, judge, stop, vm, setup, profile, layer. Use when the user says factory, factory loop, 'run the loop on <ticket>', 'make <ticket> agent-ready', 'test <ticket> in a VM', 'show me the VM', or asks to judge or check a factory run. Also: set up a repo or a new profile for the factory. Not for a one-off interactive fix (fix-jira) or a QA tester's .app/.deb build (rdm-mac-qa-fix, rdm-linux-qa-fix)."
---

# Software factory

> **Experimental (0.x).** The loop works end to end on Windows guests (RDM, Devolutions Console), but its config format,
> commands and file layout still change between versions, and it spends real budget (up to `LOOP_USD` a ticket) and runs
> unattended VMs. The first time this skill loads in a conversation, tell the user in one line that it is experimental.
> Known gaps: `GAPS.md` at the plugin's root (`<skill dir>/../../GAPS.md`).

```
spec (human-approved) ─► run: worktree ─► builder ─► verify ─► reviewer ─► runtime QA (own VM) ─► hand-back ─► judge
                                              ▲      red     │ send back  │ FAIL (findings + screenshots)  │
                                              └──────────────┴────────────┴────────────────────────────────┘ ≤ ITER_CAP
                              └──── build VM (one per run, shares the worktree) ────┘   └─ fresh clone, launches
                                    builder's `guest build|test`, verify's build + test      the verified binaries
```

Nothing builds or tests on the Mac: the product ships on the guest OS, so it is compiled and tested there. The Mac only
edits, runs git, and drives the VMs.

Everything a station decides is checked by the next one, and the runner (a script) owns every gate: agents never mark
their own work done. The human writes and approves the spec, and judges the hand-back; anything in between that needs a
human is an exception the run asks for (NEEDS-HUMAN), not a step.

`F=<skill dir>/scripts`, where `<skill dir>` is this skill's base directory (an absolute path: the skill is installed as
a plugin, apart from any repo). Run every command from inside the target repo or one of its worktrees: the engine works on
the repo it is run from. The skill is the engine; everything about a project lives in the repo's `.factory/` and is
described in [references/profiles.md](references/profiles.md):
- `.factory/config.sh`: team defaults (models, caps, `DEFAULT_PROFILE`).
- `.factory/profiles/<name>/`: one per product (`rdm`, `console`, …): `profile.sh` (app name, targets, protected paths,
  branch prefix), `reviewer.md` (review standards), `targets/<os>/` (guest image and build/test/launch scripts).
- `.factory/tickets/<KEY>.md` + `.sh` (the `.sh` picks `PROFILE` and `PLATFORM`), on the ticket's own branch.
- Per machine, never in the repo: `~/.factory/config.sh` (VM root, CPUs, RAM, budget overrides).
The reviewer's and the QA agent's system prompts: `agents/factory-reviewer.md`, `agents/factory-qa.md` in this skill.

## Pick the sub-command

| User says | Do |
|---|---|
| "make DEVEX-123 agent-ready", "spec it", a Jira key with no ticket file yet | **spec** |
| "run the loop / factory on DEVEX-123" | **run** (needs an approved spec) |
| "test DEVEX-123 in a VM", "is the runtime check red on base?" | **qa** |
| "how is the run going?", "what happened?" | **status** |
| "show me the VM", "let me see it", "I want to take over" | **show** (+ **human**) |
| "it's fine / it's broken" while a run waits | **judge** |
| "stop it" | **stop** |
| "set up the VM", first QA on this Mac | **setup** |
| "use the factory for <product>", a ticket for a product with no profile | **profile** |

## spec <KEY> (interactive: this is where the human adds the most value)

Follow [references/spec-authoring.md](references/spec-authoring.md). In short:
0. Give the ticket its own branch and worktree: `bash $F/factory.sh start <KEY> [profile]`, cut from the latest
   `origin/master` unless the user asks otherwise (`--from <ref>`; while the factory itself lives on a branch, that
   branch). Everything below happens in that worktree, never on the factory branch or the user's checkout: the
   spec, the oracle and any prerequisite (generated files, tool config) are the ticket's commits. Keep the product's
   commits (oracle, prerequisites) apart from the factory's (`.factory/tickets/`), so the PR branch can be rebuilt from
   `master` with the product's commits only.
1. Read the ticket: Atlassian MCP `getJiraIssue`, then `acli jira workitem view <KEY>`; never WebFetch Jira.
2. Find the code (root cause or the place to change) and **verify every anchor** you put in the spec.
3. Pick the profile (product) and platform. Write `.factory/tickets/<KEY>.md`: Context, Acceptance (itemized),
   Acceptance command, Runtime check (when the behaviour shows in the app:
   [references/runtime-checks.md](references/runtime-checks.md)), Scope (Touches / Do not edit), Standards. Write `tickets/<KEY>.sh` (PROFILE, PLATFORM, ACCEPT_TEST, ACCEPT_FILTER, ORACLE_PATHS, SCOPE_REGEX).
4. Write the oracle test **before** any fix, in a test project the target's guest runs (any of the product's test
   projects: the guest is Windows for RDM and the Console). Prove it red on the base in the guest:
   `bash $F/run-loop.sh <KEY> --test-only HEAD` (background) must **fail, for the reason the ticket states**. A test that
   passes on buggy code is the most common spec bug: assert on what the user sees.
5. If there is a Runtime check and a golden VM: `bash $F/run-loop.sh <KEY> --qa-only HEAD` must come back FAIL for the
   stated reason. Record both red runs in the ticket.
6. Show the spec to the user and stop. Commit only once they approve (branch commits: no `[TICKET]` prefix, no `CR:`).
7. Offer to post the itemized acceptance and scope back to Jira; never post without a yes.

## run <KEY> [--open-pr] [--qa | --no-qa] [--keep-vm]

Preconditions: run from the ticket's worktree (`factory.sh start`), with the ticket files and oracle committed: the run
cuts its own branch and worktree from that `HEAD`, and nothing builds in your checkout. It also needs the target's VM image (**setup**). The run holds two VM slots while QA runs: the build VM
and the QA clone.
```
bash $F/run-loop.sh <KEY>            # Bash tool with run_in_background; the loop takes minutes to an hour
```
- QA runs by default when the ticket has a `## Runtime check` and a golden image exists; `--no-qa` skips it, `--qa`
  makes a missing image an error. `--keep-vm` leaves the last QA VM running, whatever the verdict, for **show**;
  `factory.sh down <run>` removes it.
- A builder that finds a QA expectation wrong (intended behaviour, or outside the scope) disputes it in
  `handback/<branch>/disputes.md` instead of changing code: the next QA round gets only the intended behaviour (never the
  reasons), reports the item as disputed, and the hand-back lists it for the judge. A send back that changes no code and
  disputes nothing stops the run for a human.
- `--open-pr` pushes and opens a **draft** PR when the run is ready: outward-facing, so only when the user asked for it in
  this conversation.
- While it runs, answer progress questions with **status**; when it ends, summarise `loop-handback.md`: status, builder
  runs, spend, the hand-back path, and the QA verdict with its screenshots (Read the PNGs and show the decisive ones).

## qa <KEY> [<ref>] [--keep-vm]

The QA stage alone, on a commit: `bash $F/run-loop.sh <KEY> --qa-only <ref>` (background). Use it for red-on-base
(spec step 5), to re-test a branch, or to answer a judge's "does it really work?". It needs no builder and spends only
the QA budget.

## status [run] · show [run] · human [run] · judge [run] pass|fail <why> · stop [run] · down [run]

`bash $F/factory.sh <sub-command> …` ([run] = run id or prefix; default the newest run).
- **show** opens the run's live VM in macOS Screen Sharing (VNC on localhost, per-run password): the QA clone during a
  QA stage, else the build VM, which lives as long as the run. With `--keep-vm` the last QA VM stays until **down**.
- **human** makes the run's next QA wait for a human verdict (the agent still runs and reports first). When a run waits
  (`WAITING FOR A HUMAN` in status), it has already notified and opened Screen Sharing; the user looks, then **judge**.
- **judge** writes the human verdict; the loop resumes: `pass` = PASS, `fail` = send back with the reason.
- A send back on a **finished** run (the judge looked at the hand-back or the app): first update the spec on the ticket
  branch for what the judge asked (commit it), then `run-loop.sh <KEY> --resume <run branch> "<the judge's reason>"` from the
  ticket worktree. It merges the ticket branch into the run branch, writes the Decision line, and the loop goes on there.
  When the runner itself stopped for a human (NEEDS-HUMAN, a stop that was wrong) and the human sends it on: `--continue`
  with the same arguments, which writes no Decision line.

The final merge decision is the Judge section of the hand-back, which the human fills in; don't fill it for them.

## vm up|env|show|down|list|gc · setup

`$F/vm/vmctl.sh …` manages per-run VMs (normally only the runner calls it). `list` and `gc` are the useful manual ones
(gc frees slots of dead VMs). **setup** = the one-time golden image: walk the user through
[references/vm-setup.md](references/vm-setup.md); it needs their Windows ISO, Artifactory NuGet config and one keypress.
One golden image per guest OS (`<VM root>/<os>/base.qcow2`); never one per scenario: per-run state belongs in fixtures.

## profile <name> (set up a product, or a repo that has no `.factory/`)

[references/profiles.md](references/profiles.md) is the contract: read it first. One profile per product, one target per
guest OS it ships on (RDM on Windows and Linux is one profile with two targets). A new OS for an existing product is a
new `targets/<os>/`, not a new profile.
1. `bash $F/factory.sh new-profile <name>` from the repo: copies `templates/profile/` to `.factory/profiles/<name>/`,
   and creates `.factory/config.sh` when the repo has none.
2. Fill every `TODO` with the user, reading the repo for the answers before asking: `profile.sh` (app name, targets,
   branch prefix, protected paths, review standards), `reviewer.md` (the product's standards docs and what Data flows
   covers), and per target `target.sh` (image, guest OS), `build.ps1` (builds what ships, in the guest), `test.ps1` (one
   test project, with a filter), `launch.ps1` (starts the build in the guest's desktop session, prints `LAUNCH OK`).
   The `rdm` and `console` profiles in the RDM repo are worked examples.
3. `bash $F/factory.sh check <name>` until it says OK.
4. When the product needs software in the guest beyond the golden image (a database, a server), write `layer/setup.ps1`
   and `layer/layer.conf`, rehearse with `factory.sh layer <name> --test`, then `--build` (ask first: it writes a VM
   image), and point the target's `GOLDEN_IMAGE` at the layer.
5. Prove the target before any builder run, with a probe ticket whose answer you know: `run-loop.sh <KEY> --test-only
   <ref>` (the build and test scripts) and `--qa-only <ref>` (launch and QA). Both red for the stated reason on the base,
   green on a fixed commit.
6. Commit `.factory/` to the repo through its normal review: profiles are the team's, the engine is not.

## Rules for every agent the runner spawns
- No AskUserQuestion, no waiting for a human inside a session: decide and record; the runner owns human hand-offs.
- Builder: only the ticket's scope; never edit the oracle or the factory (denied anyway). One code commit, then record,
  then hand-back. Reviewer: read-only. QA: blind (no source), never "Send error report".
- Nothing is pushed, no PR, no Jira write, unless the user asked for it in this conversation.

## Where things are
| What | Where |
|---|---|
| Run log, prompts, JSON of every session, verify logs, QA evidence | `.claude/worktrees/factory-runs/<run>/` |
| Builder branch / worktree | `<BRANCH_PREFIX><key>-build-<stamp>`, `.claude/worktrees/<key>-build-<stamp>/` (main checkout) |
| Hand-back (builder, reviewer, QA sections + Judge) | `<worktree>/handback/<branch-dir>/hand-back.md`, QA screenshots in `qa-<n>/` |
| VM disks (overlays) and the QA agent's folder | `~/VMs/factory/<os>/runs/<run>/` (golden image: `~/VMs/factory/<os>/base.qcow2`) |
| Project config, profiles, tickets | `.factory/` |
| What is still missing | `GAPS.md` at the plugin's root |

Credits: the VM layer is the `rdm-windows-vm-test` setup (QEMU Windows 11 ARM64, QMP driving, SMB share), vendored and
changed to clone one VM per run from a read-only golden image.
