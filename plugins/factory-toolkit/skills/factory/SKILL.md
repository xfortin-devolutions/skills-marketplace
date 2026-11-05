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
                              └── build VM (powered off after verify, shares the worktree) ─┘   └─ fresh clone, launches
                                    builder's `guest build|test`; verify's record:          the verified binaries
                                    negative run, build, accept, listed tests
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
- `<project>/config.sh`: team defaults (models, caps, `DEFAULT_PROFILE`, `REPO_MATCH`, `DASHBOARD_NAME`, `DASHBOARD_PORT`).
- `<project>/profiles/<name>/`: one per product (`rdm`, `console`, …): `profile.sh` (app name, `CODE_PATHS`, targets,
  protected paths, branch prefix), `reviewer.md` (review standards), `targets/<os>/` (guest image and build/test/launch
  scripts).
- Tickets: `<KEY>.md` + `.sh` (the `.sh` picks `PROFILE` and `PLATFORM`) + `<KEY>.assessment.md` (size and test needs),
  and the fixtures its QA needs (`<KEY>.fixtures/<name>/`), in the main checkout's `.claude/worktrees/factory-tickets/`,
  next to the runs: working files, never committed. Each run copies its spec and fixtures, so editing them between runs
  is safe. `factory.sh clean <KEY>` deletes a finished ticket's spec, fixtures, run logs and VM folders.
- Per machine, never in the repo: `~/.factory/config.sh` (VM root, CPUs, RAM, budget overrides, the size table and
  its ceiling), and `~/.factory/provided/<name>/` (resources only a human can provide, for QA).
The agents' system prompts, in this skill's `agents/`: `factory-assessor.md` (size and test needs), `factory-reviewer.md`, `factory-qa.md` (acceptance QA),
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
| "how big is it?", "what will it cost?", "give it more time / budget", "go higher" | **limits** |
| "QA needs a data source / server / account", a run that needs input | **provide** |
| "QA needs this state in the VM" (a file, a setting, a broken configuration), a `fixture:` need | **fixture** |

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
   projects: the guest is Windows for RDM and the Console). Prove it red on the base in the guest: `bash $F/run-loop.sh
   <KEY> --test-only HEAD --expect red` (background) must **fail, for the reason the ticket states**: it ends "red, as
   expected", a success (green on the dashboard); "expected red, got green" means the oracle is wrong. A test that
   passes on buggy code is the most common spec bug: assert on what the user sees.
7. Assess it: `bash $F/factory.sh assess <KEY>` writes `<KEY>.assessment.md` next to the spec: a size class (which sets
   the run's limits) and the test needs (what QA's VM must contain, and how: a fixture, a resource only a human can
   provide, QA's own setup, or nothing). [references/test-needs.md](references/test-needs.md). Read it critically:
   a need the assessor missed, or one QA could create itself, is yours to fix in the file. A `provided:` need: ask the
   user for it now (`factory.sh provide <name>`), they are here; a `fixture:` need: write it for this ticket
   (`factory.sh fixture <KEY> <name>`, from `templates/fixture/`), or change the line to `qa-setup` or `unmet`. A
   fixture is the ticket's own, never the profile's: it lives and dies with the ticket.
8. If there is a Runtime check and a golden VM: `bash $F/run-loop.sh <KEY> --qa-only HEAD --expect red` must come back
   FAIL for the stated reason (it applies the test needs, so do it after step 7). Record both red runs in the ticket.
9. Show the spec to the user and stop: give them its path (`factory.sh spec <KEY>`; `--open` opens it), the red output,
   the assessment (size, what it sets: `factory.sh limits <KEY>`, and the test needs), and the Jira enrichment you'd post. The oracle is already committed (the red runs need it); if they change the spec,
   amend the oracle commit to match (branch commits: no `[TICKET]` prefix, no `CR:`).
10. Offer to post the itemized acceptance and scope back to Jira; never post without a yes.

## run <KEY> [--open-pr] [--qa | --no-qa] [--no-explore] [--keep-vm]

Preconditions: run from the ticket's worktree (`factory.sh start`), with the spec written and the oracle committed: the run
cuts its own branch and worktree from that `HEAD`, and nothing builds in your checkout. It also needs the target's VM image (**setup**). A run holds at most one VM slot, and only while it
uses a VM. The build VM boots with the round's first build or test (the builder's `guest` tool or verify), powers off
after `VM_IDLE_MIN` (10) minutes unused and once verify is green, and boots again when needed: the build output lives
in the worktree, so it builds incrementally. Then the QA clone, for the whole QA stage; then, for findings to re-try,
the base re-check's VM. When every slot (`VM_MAX`) is taken, a VM waits up to `VM_SLOT_WAIT_MIN` for one instead of failing.
The builder also runs the app in its build VM whenever it wants while it works (`guest app launch|shot|click|type|key|
stop`, `guest run '<powershell>'`), to check an assumption or a case as a developer would; headless tests come first
where they can show it. What it sees there is never evidence: the record and the blind QA stay the judge's.
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
- An acceptance test the builder finds contradicts the ticket goes in `disputes.md` as `## accept: <test>`: a red verify
  with one stops the run for a human (notified), and so do the same accept tests failing two verifies in a row. Fix the
  oracle on the ticket branch (or overrule it in the reason), then `--continue` (below).
- The builder commits code and writes its hand-back sections; **the runner writes the verification record**: verify runs
  the negative run (the accept test on the base, kept per base and test, so once), the full build, the accept test and
  the tests the builder lists in `handback/<branch>/tests.txt`, each in the build VM. A test that passes only on a
  re-run (`FLAKY_RERUNS`) is green and listed as flaky for the judge. A listed test red on every run is run on the base too, in a VM
  of its own (once per base): failures the base shows as well are pre-existing, listed for the judge, not a send back. A builder stopped by its time box after its code
  commit is verified like any other (the runner starts a missing hand-back from the template).
- Limits come from the ticket's size class (**limits**, below): `ITER_CAP` builder runs in all, `STALL_CAP` in a row
  that change nothing (code, disputes, listed tests: 2), each station's dollars and minutes, and `LOOP_USD`, the hard
  limit. A run with no assessment starts with the assessor. A builder stopped by its time box or budget before its
  commit keeps its work: the runner commits it as a checkpoint and the next round goes on from it. An accept test that
  passes on the base stops the run: the spec needs a human.
- Test needs: the run checks the fixtures and provided resources the assessment names before it spends anything, and
  puts them in each QA VM before the app starts. A missing one stops the run (`needs input before the run`); one that
  can't be reached at QA, or a QA agent that answers NEEDS-INPUT, pauses it before QA (`needs input for runtime QA`):
  **provide**, then `factory.sh resume <run>`.
- `--open-pr` pushes and opens a **draft** PR when the run is ready: outward-facing, so only when the user asked for it in
  this conversation.
- While it runs, answer progress questions with **status**; when it ends, summarise `loop-handback.md`: status, builder
  runs, spend, the hand-back path, the QA verdict with its screenshots (Read the PNGs and show the decisive ones), and
  the Exploratory QA section: walk the user through the tour with its screenshots, then the findings, new ones first.

## qa <KEY> [<ref>] [--expect red|green] [--explore [--base <ref>]] [--keep-vm]

The QA stage alone, on a commit: `bash $F/run-loop.sh <KEY> --qa-only <ref>` (background). `--expect` names the verdict
the check is for, so the run succeeds on it: `--expect red` on the base (a FAIL is the point), `--expect green` on a
fix; without it, a PASS succeeds and a FAIL means a new round. Use it for red-on-base (spec step 5), to re-test a
branch, or to answer a judge's "does it really work?". It needs no builder and spends only the QA budget. `--explore`
adds the exploratory QA after a PASS, for the change `<base>..<ref>` (`--base`, default the merge-base with `PR_BASE`,
or `<ref>~1` when `<ref>` is already on it); its section is `qa-1/exploratory.md` in the run.

## limits <KEY> · assess <KEY>

`bash $F/factory.sh limits <KEY>` prints every limit a run would use and where it comes from; `assess <KEY>` (re)writes
the assessment (the previous one stays as `.prev`). To overrule the assessor, when the user (or you, with a reason)
wants more or less, in order of reach:
- the ticket, every run: `SIZE=XL` and/or any limit (`B_MIN=240`, `LOOP_USD=300`) in `<KEY>.sh`, with `SIZE_WHY="…"`;
  or edit the Size line of `<KEY>.assessment.md`;
- one run: `run-loop.sh <KEY> --size XL --set LOOP_USD=300`;
- a run that stopped at a limit (`stopped: loop budget`, `reject: iteration cap`, a round cut by its time box):
  `factory.sh resume <run> --set LOOP_USD=120 --set ITER_CAP=8` goes on from where it stopped.
The size table and `SIZE_CEILING` are in the project's `config.sh` (team) and `~/.factory/config.sh` (this machine). The
ceiling only caps the assessor's own suggestion: a value someone set on purpose may go above it, and the run log says so.
Say in one line which limits you raised and why; never raise them on your own to finish a run the user didn't ask to
push.

## fixture <KEY> <name>

State a script can put in QA's VM before the app starts (a file, a setting, a broken or seeded configuration), for one
ticket: `bash $F/factory.sh fixture <KEY> <name>` starts `<KEY>.fixtures/<name>/` next to the spec. Fill `fixture.md`
(What, Use: in user terms, no secrets) and `apply.ps1` (idempotent, throws on failure), name it in the assessment
(`| fixture: <name>`), then prove it on the base with `run-loop.sh <KEY> --qa-only <base> --expect red`. Fixtures are
never committed and never go in a profile; `clean <KEY>` deletes them with the ticket.

## provide <name> · provided

A test need only a human can meet (a real data source with a working Dashboard entry, a server, an account):
`bash $F/factory.sh provide <name>` starts `~/.factory/provided/<name>/`; walk the user through `provided.md` (What, Use,
Access read-only or scratch, Shared) and the files the guest needs. Never read, print or copy those files yourself: they
may be credentials; only the runner copies them into QA VMs. `factory.sh provided` lists what is on the machine, and the
needs tickets name that aren't.

## dashboard

`bash $F/factory.sh dashboard` (Bash tool with `run_in_background`: it serves until stopped) opens the repo's live page
in the browser, at `http://<DASHBOARD_NAME>.factory.localhost:<DASHBOARD_PORT>/` (RDM:
`http://rdm.factory.localhost:8765/`; one per repo: when it already runs, the command opens it and exits; a port someone
else holds is an error, not the next free one): every run with its state and spend, coloured by what the runner decided
comes next (its `results.log`: green goes on as planned, red means a new round or a check to run again, orange needs a
human, grey was stopped; a run from before 0.7.10 by the verdict its outcome starts with), filtered by age and by state
(a finished run by how it ended; a builder's dispute is a `disputed` badge beside that, the judge's to decide, not a
colour); a Bin a finished run goes to in one click, and back (a `BINNED` marker in the run folder, the page's only
write); per run, a pipeline of its stations round by round (builder, verify, reviewer, charter, runtime QA, exploratory
QA, re-check), each with its outcome, time and cost; a station's details on click: the agent's live steps (what it
reads, runs, edits), the builder's changes in its worktree, the QA report and screenshots (live, as the agent takes
them), the answer, the prompt and stderr. Nothing leaves the Mac. Offer it when a run starts, and whenever the user asks
how things are going. `--port N`, `--no-open`.

## status [run] · show [run] · human [run] · judge [run] pass|fail <why> · stop · pause · resume [run] · down [run]

`bash $F/factory.sh <sub-command> …` ([run] = run id or prefix; default the newest run).
- **show** opens the run's live VM in macOS Screen Sharing (VNC on localhost, per-run password): the QA clone during a
  QA stage, else the build VM while the builder or verify works. With `--keep-vm` the last QA VM stays until **down**.
- **human** makes the run's next QA wait for a human verdict (the agent still runs and reports first). When a run waits
  (`WAITING FOR A HUMAN` in status), it has already notified and opened Screen Sharing; the user looks, then **judge**.
- **judge** writes the human verdict; the loop resumes: `pass` = PASS, `fail` = send back with the reason.
- **pause** stops the run before its next station and powers its VMs off (a weekend, a reboot, a closing session: a
  runner started from a Claude session dies with it). **resume** goes on from the station it saved (`state.sh`), in the
  same run folder and worktree: after a pause, a **stop**, or a runner that crashed or was killed. Run it in the
  background like the loop. No reason to write, no new run.
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
One golden image per guest OS (`<VM root>/<os>/base.qcow2`); never one per scenario: per-ticket state belongs in the ticket's fixtures.

## clean <KEY>

Once a ticket is merged or dropped: `bash $F/factory.sh clean <KEY> --dry-run`, show the user what it would delete and
how much, then the same without `--dry-run` on their yes. It deletes the spec, the assessment, the fixtures, the run
logs (prompts, JSON, QA screenshots) and the VM folders, never a run that is live or waiting for a human. It lists the ticket's worktrees and
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
   <ref>` (the build and test scripts) and `--qa-only <ref>` (launch and QA). Both red for the stated reason on the base
   (`--expect red`), green on a fixed commit (`--expect green`).
6. A project in the skill: commit it to the skill's marketplace repo. In the repo's `.factory/`: commit it through the
   repo's normal review. Moving one from the skill to its repo: `projects/README.md`.

## Rules for every agent the runner spawns
- No AskUserQuestion, no waiting for a human inside a session: decide and record; the runner owns human hand-offs.
- Builder: only the ticket's scope, plus the docs the change makes wrong (`DOC_PATHS`: skills, docs, CLAUDE.md), in
  the same commit; never the oracle, the factory, or `.claude/` settings and hooks (denied anyway). Claude Code refuses a
  headless session's edits under `.claude/`, so the builder stages a skill update in `handback/<branch>/docs/claude/…`
  and the runner commits it into place. One code commit, then hand-back; the record is the runner's. The reviewer checks the docs (its Docs line). Reviewer and charter: read-only. QA and explorer: blind (no source), never "Send error report".
- Nothing is pushed, no PR, no Jira write, unless the user asked for it in this conversation.

## Where things are
| What | Where |
|---|---|
| Run log, prompts, JSON of every session, verify logs, QA evidence | `.claude/worktrees/factory-runs/<run>/` |
| Builder branch / worktree | `<BRANCH_PREFIX><key>-build-<stamp>`, `.claude/worktrees/<key>-build-<stamp>/` (main checkout) |
| Hand-back (builder, reviewer, QA, exploratory QA sections + Judge) | `<worktree>/handback/<branch-dir>/hand-back.md`, QA screenshots in `qa-<n>/`, the charter, tour and re-check in `qa-<n>/charter.md`, `explore/`, `recheck/` |
| VM disks (overlays) and the QA agent's folder | `~/VMs/factory/<os>/runs/<run>/` (golden image: `~/VMs/factory/<os>/base.qcow2`) |
| Project config and profiles | `projects/<project>/` in this skill (or the repo's `.factory/`, which wins) |
| Tickets (specs, assessments and fixtures, never committed) | `.claude/worktrees/factory-tickets/` in the main checkout; `factory.sh clean <KEY>` when done |
| Limits a run used, and where each came from | `<run>/limits.txt`; every finished run: `factory-runs/.calibration.tsv` |
| Fixtures / resources a human provides | `factory-tickets/<KEY>.fixtures/<name>/` / `~/.factory/provided/<name>/` |
| What is still missing | `GAPS.md` at the plugin's root |

Credits: the VM layer is the `rdm-windows-vm-test` setup (QEMU Windows 11 ARM64, QMP driving, SMB share), vendored and
changed to clone one VM per run from a read-only golden image.
