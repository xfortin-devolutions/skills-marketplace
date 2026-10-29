---
name: factory
description: "[EXPERIMENTAL] Software factory for Jira tickets, run from a Mac, for a supported repo (projects bundled with the skill, or a repo's own .factory/; profiles per product: RDM, Devolutions Console, …): turn a ticket into an agent-ready spec with a red oracle, then run the unattended loop — headless builder in its own worktree that builds and tests in a per-run QEMU VM of the target OS (nothing builds on the Mac), runner verify in that VM, read-only reviewer, a blind runtime QA stage that drives the verified build in a fresh throwaway VM, then a blind exploratory QA around the change (charter from the diff, findings re-tried on the base) that leaves the judge a guided tour — with send-backs, caps, a hand-back for the human judge, and Screen Sharing on the VM when a human is needed. Sub-commands: spec, run, qa, status, show, human, judge, stop, clean, vm, setup, profile, layer (and which: the profile for a code path). Use when the user says factory, factory loop, 'run the loop on <ticket>', 'make <ticket> agent-ready', 'test <ticket> in a VM', 'show me the VM', or asks to judge or check a factory run. Also: set up a repo or a new profile for the factory. Not for a one-off interactive fix (fix-jira) or a QA tester's .app/.deb build (rdm-mac-qa-fix, rdm-linux-qa-fix)."
---

# Software factory

> **Experimental (0.x).** The loop works end to end on Windows guests (RDM, Devolutions Console), but its config format,
> commands and file layout still change between versions, and it spends real budget (up to `LOOP_USD` a ticket) and runs
> unattended VMs. The first time this skill loads in a conversation, tell the user in one line that it is experimental.
> Known gaps: `GAPS.md` at the plugin's root (`<skill dir>/../../GAPS.md`).

```
spec (human-approved) ─► run: worktree ─► builder ─► verify ─► reviewer ─► runtime QA ─► exploratory QA ─► hand-back ─► judge
                                              ▲      red     │ send back  │ FAIL         │ new blocker (once)
                                              └──────────────┴────────────┴──────────────┴──────────────────┘ ≤ ITER_CAP
                              └──── build VM (one per run, shares the worktree) ────┘   └─ fresh clone, launches
                                    builder's `guest build|test`, verify's build + test      the verified binaries
```

Exploratory QA does what a human would do with a new feature: try it around the edges and show the judge around. It
never touches the acceptance verdict, which is fixed first. A fresh read-only session writes a **charter** from the ticket
and the diff (never the builder's notes, so the builder can't steer it): where to poke and what a user might see go wrong,
in user terms; the runner drops any item naming code. A second **blind** agent restarts the app on the QA VM, follows the
charter and reports a **tour** (steps + screenshots, for the judge) and **findings** (blocker or minor). Each finding is
re-tried on a **build of the base** in its own VM: only a blocker the base doesn't show sends the change back, at most
`EXPLORE_SENDBACKS` times; every other finding is for the judge (hand-back section Exploratory QA).

Nothing builds or tests on the Mac: the product ships on the guest OS, so it is compiled and tested there. The Mac only
edits, runs git, and drives the VMs.

Everything a station decides is checked by the next one, and the runner (a script) owns every gate: agents never mark
their own work done. The human writes and approves the spec, and judges the hand-back; anything in between that needs a
human is an exception the run asks for (NEEDS-HUMAN), not a step.

`F=<skill dir>/scripts`, where `<skill dir>` is this skill's base directory (an absolute path: the skill is installed as
a plugin, apart from any repo). Run every command from inside the target repo or one of its worktrees: the engine works on
the repo it is run from. The skill is the engine; what a repo's products need is its **project**, described in
[references/profiles.md](references/profiles.md). While the factory is experimental, projects ship with the skill:
`projects/<project>/`, picked by `REPO_MATCH` against the repo's `origin`; the supported ones are listed in
[projects/README.md](projects/README.md) (today `devolutions-rdm`: RDM and Devolutions Console, on Windows). A repo's own
`.factory/profiles/` wins, which is how a project moves into its repo later. `factory.sh check` says which one is used.
- `<project>/config.sh`: team defaults (models, caps, `DEFAULT_PROFILE`, `REPO_MATCH`).
- `<project>/profiles/<name>/`: one per product (`rdm`, `console`, …): `profile.sh` (app name, `CODE_PATHS`, targets,
  protected paths, branch prefix), `reviewer.md` (review standards), `targets/<os>/` (guest image and build/test/launch
  scripts).
- Tickets: `<KEY>.md` + `.sh` (the `.sh` picks `PROFILE` and `PLATFORM`) in the main checkout's
  `.claude/worktrees/factory-tickets/`, next to the runs: working files, never committed. Each run copies its spec, so
  editing it between runs is safe. `factory.sh clean <KEY>` deletes a finished ticket's spec, run logs and VM folders.
- Per machine, never in the repo: `~/.factory/config.sh` (VM root, CPUs, RAM, budget overrides).
The agents' system prompts, in this skill's `agents/`: `factory-reviewer.md`, `factory-qa.md` (acceptance QA),
`factory-charter.md` and `factory-explorer.md` (exploratory QA: explore, and re-check on the base).

## Pick the sub-command

| User says | Do |
|---|---|
| "make DEVEX-123 agent-ready", "spec it", a Jira key with no ticket file yet | **spec** |
| "run the loop / factory on DEVEX-123" | **run** (needs an approved spec) |
| "test DEVEX-123 in a VM", "is the runtime check red on base?" | **qa** |
| "how is the run going?", "what happened?" | **status**, and offer the **dashboard** |
| "show me the dashboard", "where are we at?" | **dashboard** |
| "show me the VM", "let me see it", "I want to take over" | **show** (+ **human**) |
| "it's fine / it's broken" while a run waits | **judge** |
| "stop it" | **stop** |
| "set up the VM", first QA on this Mac | **setup** |
| "use the factory for <product>", a ticket for a product with no profile (`which` says so) | **profile** |
| "the ticket is merged", "clean up DEVEX-123" | **clean** |

## spec <KEY> (interactive: this is where the human adds the most value)

Follow [references/spec-authoring.md](references/spec-authoring.md). In short:
1. Read the ticket: Atlassian MCP `getJiraIssue`, then `acli jira workitem view <KEY>`; never WebFetch Jira.
2. Find the code (root cause or the place to change) and **verify every anchor** you put in the spec.
3. Pick the profile (the product): `bash $F/factory.sh which <the paths you found>`. Starting Claude at the repo root is
   fine: the repo picks the project, the code picks the product.
   - One profile: that one. Say which in one line ("profile: console, the change is under Console/").
   - Several (shared code): the profile is the product whose app shows the change, the one QA launches. Take it from the
     ticket (Jira project, summary); if the ticket doesn't say, ask the user.
   - No profile (e.g. `DVLS/` in the RDM repo): stop the spec. Tell the user the factory doesn't support that product
     yet, and offer to set it up (**profile**, below) before going on. Never borrow another product's profile: its build,
     launch and VM would test the wrong app.
4. Give the ticket its own branch and worktree: `bash $F/factory.sh start <KEY> <profile>`, cut from the latest
   `origin/master` unless the user asks otherwise (`--from <ref>`). The oracle and any prerequisite (generated files,
   tool config) are the ticket's commits, in that worktree, never in the user's checkout; the branch carries product
   commits only, so it becomes the PR as is.
5. Write the spec where `start` said (`.claude/worktrees/factory-tickets/<KEY>.md`, not committed): Context, Acceptance
   (itemized), Acceptance command, Runtime check (when the behaviour shows in the app:
   [references/runtime-checks.md](references/runtime-checks.md)), Scope (Touches / Do not edit), Standards. And
   `<KEY>.sh` (PROFILE, PLATFORM, ACCEPT_TEST, ACCEPT_FILTER, ORACLE_PATHS, SCOPE_REGEX); `factory.sh check` then flags an
   ACCEPT_TEST outside the profile's CODE_PATHS.
6. Write the oracle test **before** any fix, in a test project the target's guest runs (any of the product's test
   projects: the guest is Windows for RDM and the Console). Prove it red on the base in the guest:
   `bash $F/run-loop.sh <KEY> --test-only HEAD` (background) must **fail, for the reason the ticket states**. A test that
   passes on buggy code is the most common spec bug: assert on what the user sees.
7. If there is a Runtime check and a golden VM: `bash $F/run-loop.sh <KEY> --qa-only HEAD` must come back FAIL for the
   stated reason. Record both red runs in the ticket.
8. Show the spec to the user and stop: give them its path (`factory.sh spec <KEY>`; `--open` opens it), the red output,
   and the Jira enrichment you'd post. The oracle is already committed (the red runs need it); if they change the spec,
   amend the oracle commit to match (branch commits: no `[TICKET]` prefix, no `CR:`).
9. Offer to post the itemized acceptance and scope back to Jira; never post without a yes.

## run <KEY> [--open-pr] [--qa | --no-qa] [--no-explore] [--keep-vm]

Preconditions: run from the ticket's worktree (`factory.sh start`), with the spec written and the oracle committed: the run
cuts its own branch and worktree from that `HEAD`, and nothing builds in your checkout. It also needs the target's VM image (**setup**). The run holds two VM slots while QA runs: the build VM
and the QA clone. A base re-check (findings to re-try) powers the build VM off for its own VM, and the loop boots it
again if a send back follows.
```
bash $F/run-loop.sh <KEY>            # Bash tool with run_in_background; the loop takes minutes to an hour
```
- QA runs by default when the ticket has a `## Runtime check` and a golden image exists; `--no-qa` skips it, `--qa`
  makes a missing image an error. `--keep-vm` leaves the last QA VM running, whatever the verdict, for **show**;
  `factory.sh down <run>` removes it.
- Exploratory QA follows every runtime QA PASS (`EXPLORE=yes`); `--no-explore` skips it. It costs a charter (`C_USD`), an
  explorer (`X_USD`), and when there are findings a base build plus a re-check (`RC_USD`).
- A builder that finds a QA expectation wrong (intended behaviour, or outside the scope) disputes it in
  `handback/<branch>/disputes.md` instead of changing code: the next QA round gets only the intended behaviour (never the
  reasons), reports the item as disputed, and the hand-back lists it for the judge. A send back that changes no code and
  disputes nothing stops the run for a human.
- `--open-pr` pushes and opens a **draft** PR when the run is ready: outward-facing, so only when the user asked for it in
  this conversation.
- While it runs, answer progress questions with **status**; when it ends, summarise `loop-handback.md`: status, builder
  runs, spend, the hand-back path, the QA verdict with its screenshots (Read the PNGs and show the decisive ones), and
  the Exploratory QA section: walk the user through the tour with its screenshots, then the findings, new ones first.

## qa <KEY> [<ref>] [--explore [--base <ref>]] [--keep-vm]

The QA stage alone, on a commit: `bash $F/run-loop.sh <KEY> --qa-only <ref>` (background). Use it for red-on-base
(spec step 5), to re-test a branch, or to answer a judge's "does it really work?". It needs no builder and spends only
the QA budget. `--explore` adds the exploratory QA after a PASS, for the change `<base>..<ref>` (`--base`, default the
merge-base with `PR_BASE`, or `<ref>~1` when `<ref>` is already on it); its section is `qa-1/exploratory.md` in the run.

## dashboard

`bash $F/factory.sh dashboard` (Bash tool with `run_in_background`: it serves until stopped) opens a live, read-only page
on `127.0.0.1` in the browser: every run with its state and spend; per run, a pipeline of its stations round by round
(builder, verify, reviewer, charter, runtime QA, exploratory QA, re-check), each with its outcome, time and cost; a
station's details on click: the agent's live steps (what it reads, runs, edits), the builder's changes in its worktree,
the QA report and screenshots (live, as the agent takes them), the answer, the prompt and stderr. Nothing leaves the Mac.
Offer it when a run starts, and whenever the user asks how things are going. `--port N`, `--no-open`.

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

## clean <KEY>

Once a ticket is merged or dropped: `bash $F/factory.sh clean <KEY> --dry-run`, show the user what it would delete and
how much, then the same without `--dry-run` on their yes. It deletes the spec, the run logs (prompts, JSON, QA
screenshots) and the VM folders, never a run that is live or waiting for a human. It lists the ticket's worktrees and
branches but removes none: those may hold work, so ask, and remove them only on a yes.

## profile <name> (set up a product, or a repo with no project yet)

[references/profiles.md](references/profiles.md) is the contract: read it first. It comes up two ways: the user asks
for a product, or a spec found code no profile covers (`factory.sh which` says "no profile", e.g. DVLS in the RDM
repo). A product of a supported repo joins that repo's project (`new-profile <name>` adds it there); a repo with no
project gets one in the skill (`--skill <project>`) while the factory is experimental.
Setting up a product is real work, not a form: plan on a session with the user, and on the product's own build docs.
What to work out, in this order (the questions are the same for any product; a server product like DVLS is the
hardest case):
- **What ships and where its code is:** the solution or project that builds the app, and `CODE_PATHS` (`DVLS/`).
- **The guest:** which OS it ships on (the target), and what the golden image lacks: a database, IIS, a runtime, Node
  for a web front end. That goes in a VM layer; reuse one when it fits (the `console` layer already has IIS, SQL Server
  Express and DVLS instances: a DVLS profile can start from it, or from its recipe).
- **Build and test in the guest:** `build.ps1` builds what ships (all of it: back end and front end), `test.ps1` runs
  one test project with a filter. Ask which test projects run headless.
- **Launch:** for a desktop app, start it in the signed-in session. For a server or web app, deploy or start the build
  (an IIS site, a Kestrel process), wait until it answers, then open the browser at its URL in the desktop session:
  QA drives the browser like a user. `LAUNCH OK` only once the page answers.
- **Review standards:** the product's own docs (`DVLS/CLAUDE.md` for DVLS: different standards from RDM). One profile per product, one target per
guest OS it ships on (RDM on Windows and Linux is one profile with two targets). A new OS for an existing product is a
new `targets/<os>/`, not a new profile.
1. `bash $F/factory.sh new-profile <name>` from the repo: copies `templates/profile/` into the repo's project. A repo
   with no project gets one: in the skill with `--skill <project>` (the default while the factory is experimental: the
   product repo stays untouched; add a row to `projects/README.md`), else in the repo's `.factory/`.
2. Fill every `TODO` with the user, reading the repo for the answers before asking: `profile.sh` (app name, targets,
   branch prefix, protected paths, review standards), `reviewer.md` (the product's standards docs and what Data flows
   covers), and per target `target.sh` (image, guest OS), `build.ps1` (builds what ships, in the guest), `test.ps1` (one
   test project, with a filter), `launch.ps1` (stops a running instance, starts the build in the guest's desktop
   session, prints `LAUNCH OK`; exploratory QA runs it again to restart the app).
   The `rdm` and `console` profiles in `projects/devolutions-rdm/` are worked examples. Add the product's row to
   `projects/README.md`.
3. `bash $F/factory.sh check <name>` until it says OK.
4. When the product needs software in the guest beyond the golden image (a database, a server), write `layer/setup.ps1`
   and `layer/layer.conf`, rehearse with `factory.sh layer <name> --test`, then `--build` (ask first: it writes a VM
   image), and point the target's `GOLDEN_IMAGE` at the layer.
5. Prove the target before any builder run, with a probe ticket whose answer you know: `run-loop.sh <KEY> --test-only
   <ref>` (the build and test scripts) and `--qa-only <ref>` (launch and QA). Both red for the stated reason on the base,
   green on a fixed commit.
6. A project in the skill: commit it to the skill's marketplace repo. In the repo's `.factory/`: commit it through the
   repo's normal review. Moving one from the skill to its repo: `projects/README.md`.

## Rules for every agent the runner spawns
- No AskUserQuestion, no waiting for a human inside a session: decide and record; the runner owns human hand-offs.
- Builder: only the ticket's scope, plus the docs the change makes wrong (`DOC_PATHS`: skills, docs, CLAUDE.md), in
  the same commit; never the oracle, the factory, or `.claude/` settings and hooks (denied anyway). Claude Code refuses a
  headless session's edits under `.claude/`, so the builder stages a skill update in `handback/<branch>/docs/claude/…`
  and the runner commits it into place. One code commit, then record, then hand-back. The reviewer checks the docs (its Docs line). Reviewer and charter: read-only. QA and explorer: blind (no source), never "Send error report".
- Nothing is pushed, no PR, no Jira write, unless the user asked for it in this conversation.

## Where things are
| What | Where |
|---|---|
| Run log, prompts, JSON of every session, verify logs, QA evidence | `.claude/worktrees/factory-runs/<run>/` |
| Builder branch / worktree | `<BRANCH_PREFIX><key>-build-<stamp>`, `.claude/worktrees/<key>-build-<stamp>/` (main checkout) |
| Hand-back (builder, reviewer, QA, exploratory QA sections + Judge) | `<worktree>/handback/<branch-dir>/hand-back.md`, QA screenshots in `qa-<n>/`, the charter, tour and re-check in `qa-<n>/charter.md`, `explore/`, `recheck/` |
| VM disks (overlays) and the QA agent's folder | `~/VMs/factory/<os>/runs/<run>/` (golden image: `~/VMs/factory/<os>/base.qcow2`) |
| Project config and profiles | `projects/<project>/` in this skill (or the repo's `.factory/`, which wins) |
| Tickets (specs, never committed) | `.claude/worktrees/factory-tickets/` in the main checkout; `factory.sh clean <KEY>` when done |
| What is still missing | `GAPS.md` at the plugin's root |

Credits: the VM layer is the `rdm-windows-vm-test` setup (QEMU Windows 11 ARM64, QMP driving, SMB share), vendored and
changed to clone one VM per run from a read-only golden image.
