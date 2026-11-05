# Sizing and test needs

Before its first builder run, a ticket gets an **assessment**: `<KEY>.assessment.md`, next to its spec in
`.claude/worktrees/factory-tickets/`. A read-only session (the assessor, `agents/factory-assessor.md`) writes it from the
spec and the code. Get it during the spec, `factory.sh assess <KEY>`, and show it to the user with the spec; a run
without one starts by writing one (`ASSESS=no` skips it). It is a working file like the spec: edit it to overrule.

```
Size: L
Why: three projects, a new setting and its migration
Rounds: 3
Split: no
Needs:
- N1: an RDP entry with a linked credential | fixture: rdp-linked-credential
- N2: a DVLS data source with a Dashboard entry | provided: lab-dvls: a DVLS 2026.3 data source with one Dashboard entry
- N3: a second folder of entries | qa-setup: create a folder "B" and move two entries into it
- N4: a Hyper-V host to connect to | unmet: no Hyper-V in the guest
```

## Size: the run's limits

A size class sets limits from a table (`SIZE_<class>` in the project's `config.sh`, which the machine's
`~/.factory/config.sh` may override): the builder's dollars and minutes a round, the rounds, the reviewer's and QA's
limits, the run's budget. A class lists only what it changes; `SIZE_M=""` keeps the defaults.

Where each limit comes from, later wins (`factory.sh limits <KEY>` prints the result, with the source of each):

| # | Source | Example | Ceiling |
|---|---|---|---|
| 1 | the config layers (engine, project, profile, target, machine) | `B_MIN=75` | n/a |
| 2 | the size class: `--size`, else `SIZE` in `<KEY>.sh`, else the assessment's Size line, else `SIZE_DEFAULT` | `SIZE=XL` | caps the assessor's class only |
| 3 | a limit the ticket sets on purpose, in `<KEY>.sh` | `B_MIN=240`, with `SIZE_WHY="…"` | no |
| 4 | `--set NAME=VALUE` on `run-loop.sh` or `factory.sh resume`, this run only | `--set LOOP_USD=300` | no |

`SIZE_CEILING` (e.g. `LOOP_USD=150 B_MIN=180`) caps what the assessor's suggestion can buy. A size or a limit that a
human or an agent set (rows 2 from `--size` or the ticket, 3, 4) may go above it: the run log says "above the ceiling",
with `SIZE_WHY`. So "go higher" is one line in `<KEY>.sh`, or `--set` on the resume of a run that stopped at its limit.

Measured, on top: the reviewer's limits grow with the diff (`R_SCALE_LINES` changed lines a share) and QA's with the
Runtime check's steps and expectations (`QA_SCALE_ITEMS`), up to `SCALE_MAX` times, unless set on purpose.

A builder stopped by its time box or budget before its commit doesn't lose its work: the runner commits it as a
checkpoint, and the next round goes on from it.

Each finished loop run adds a line to `factory-runs/.calibration.tsv` (size, where it came from, rounds, spent, minutes,
longest builder round, status): what the table is tuned on. The dashboard shows it.

## Test needs: what QA must find in the VM

A QA VM starts with the app freshly installed. Each need is one way to get what the Runtime check needs, the first that
works:

| How | What it is | Where | When it is missing |
|---|---|---|---|
| `fixture: <name>` | state a script puts in the VM before the app starts, written for this ticket | `<KEY>.fixtures/<name>/` next to the spec (`factory.sh fixture <KEY> <name>`): `fixture.md` (What, Use), `apply.ps1`, data files; never committed | the run stops before it spends anything |
| `provided: <name>` | what only a human has: a real server or data source, an account, a license | `~/.factory/provided/<name>/` on this machine, never in a repo | the run stops before it spends anything; unreachable at QA (its `check.ps1` fails): the run pauses for input |
| `qa-setup: <how>` | QA creates it in the app, as setup steps | the assessment line | n/a |
| `unmet: <why>` | nothing provides it | the assessment line | what needs it goes untested; the hand-back says so |

In every QA, exploration and base re-check VM, after the build and before the app starts, the runner copies each
fixture's folder to `C:\factory\fixtures\<name>` and each provided resource's to `C:\factory\provided\<name>`, then runs
its `check.ps1` (provided only) and `apply.ps1` with `$Dir` set to that folder. QA, the charter and the explorer get a
**Test setup** section: what is in place and how to reach it (the Use line), what they must create, what is not available.
The hand-back's **Test needs** section tells the judge how each need was met.

### Fixtures

A fixture belongs to its ticket, like the spec and the assessment: written while specifying it, carried for the
ticket's duration, deleted by `factory.sh clean <KEY>`. There is no catalog in the profiles: a state worth reusing
across tickets belongs in the profile's VM layer, not in a fixture. `factory.sh fixture <KEY> <name>` starts one in
`<KEY>.fixtures/<name>/` from `templates/fixture/`; each run takes a copy at its start, as it does the spec. `apply.ps1`
runs over SSH as the desktop user (same profile, no desktop), must be idempotent, and throws on failure (the QA round is
then a harness error, not the change's fault). The assessor sees the ticket's fixtures and proposes the ones it lacks
(`fixture: <name>: <what it puts in place>`); `factory.sh check` checks them. Prove a new one with
`run-loop.sh <KEY> --qa-only <base> --expect red` before any builder run.

### Resources a human provides

`factory.sh provide <name>` starts one from `templates/provided/`:
- `provided.md`: What, Use, Access (`read-only`: QA looks and uses, never changes, deletes or adds; `scratch`: QA may
  change it), Shared (`no`: one run at a time; the others wait for it, up to `VM_SLOT_WAIT_MIN`). Agents read this file:
  no secrets in it.
- The files the guest needs (a data source file, credentials). They reach the QA VM and nothing else: never a prompt,
  the repo, or a log. A QA agent can read the guest's disk, so an `apply.ps1` that sets the app up with a secret then
  deletes the raw file.
- `check.ps1` (optional): throws when the resource can't be used from the VM, with a line that says why.

A resource the assessor names that isn't on the machine stops the run before it starts ("needs input before the run:
provided lab-dvls (…): factory.sh provide lab-dvls"). A QA agent that finds it can't go on without something from
outside the VM answers `NEEDS-INPUT` with what it needs: the run pauses before QA (`factory.sh resume <run>` once it is
provided), never a FAIL that would send the builder back for nothing. What needs a person at the screen (an
interactive sign-in, MFA) is `factory.sh human`, as before. `factory.sh provided` lists the resources on this machine
and the ones tickets need that are missing.
