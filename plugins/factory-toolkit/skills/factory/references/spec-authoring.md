# Making a ticket agent-ready

The loop is only as good as its oracle (GAPS.md R1, I3). A spec is ready when an agent that never talks to anyone can
finish it, and a script can tell whether it did.

## <KEY>.md

Specs live in the main checkout's `.claude/worktrees/factory-tickets/` (`factory.sh start` prints the path), never in
git: the ticket branch carries only product commits (the oracle and its prerequisites).

| Section | Contents |
|---|---|
| `# <KEY> — <title>` | first line; also the draft PR title |
| Context | what the user sees, where (screen, menu), root cause with **verified** `file` anchors |
| Acceptance | itemized, testable; include non-goals and "keeps working" items |
| Acceptance command | the test project and filter that pass when done (run in the guest); today's red result from `--test-only` (how many fail, why) |
| Runtime check | when the bug shows in the app: [runtime-checks.md](runtime-checks.md) |
| Scope | Touches (globs) and Do not edit (oracle, factory, `.github/`, `.resx`/`.axaml` unless needed). Docs under the project's `DOC_PATHS` (skills, `docs/`, CLAUDE.md) are always in scope: the builder updates the ones the change makes wrong |
| Standards | CLAUDE.md, CODING_STANDARDS.md, the skills the builder must invoke |

## <KEY>.sh
```
ACCEPT_TEST=<test project the Acceptance command runs, repo-relative, no spaces>
ACCEPT_FILTER=<optional test filter, no spaces>
ORACLE_PATHS="<test file(s) and test csproj the builder must not edit>"
SCOPE_REGEX='<the Touches line as an extended regex over repo paths>'
```

## <KEY>.assessment.md
Written by `factory.sh assess <KEY>` once the spec is: the size class (the run's limits) and the test needs (what QA's
VM must contain, and how each is met). Edit it to overrule; `SIZE` or any limit in `<KEY>.sh` beats its Size line.
[test-needs.md](test-needs.md). Write the Runtime check's steps as if their data were there, and make sure each thing
they need is a need line: a fixture, a resource the user provides, a `qa-setup` step, or `unmet` (then QA can't check
it, and the hand-back says so).

## <KEY>.fixtures/<name>/
A fixture the assessment names: the ticket's own, written with the spec (`factory.sh fixture <KEY> <name>`), never
committed, deleted by `factory.sh clean <KEY>`. [test-needs.md](test-needs.md).

## The oracle
- Runs in the target's guest (the target's `test.ps1`), like every build and test: any test project of the product,
  Windows-only ones included. Avalonia headless for controls.
- Red on base **for the stated reason**, in the guest: `run-loop.sh <KEY> --test-only HEAD`.
- A new feature's oracle doesn't compile until the feature exists: that is its red ("type not found"). The Runtime
  check's red-on-base then runs on the commit before the oracle (`--qa-only <oracle commit>~1`), since the target's
  build includes the test project (GAPS V32). Read the failure messages, not just the count. Assert on what the user sees
  (DEVEX-528: `source.Rows`, not the lazy `source.Items`, which passed on the buggy code). For a control, drive it
  the way the screen does: shown in a window (Avalonia headless), not only its view model or collection (DEVEX-531: the
  oracle passed on a fix the shown grid ignored, and only runtime QA caught it, a round later).
  Drive the user's input, not the method it ends in: a header click goes through the control's own state before it calls
  `SortBy` (DEVEX-531 round 2: a click from ascending did nothing, and a test that called `SortBy` passed). When the test
  project can't render the control (no theme, no templates: RDM's Core.Tests), say so in the spec and put the input in
  the Runtime check as its own expectation ("each single click flips the order").
- Covers each Acceptance item; keeps a couple of "already works" tests as regression guards.
- Committed before the run (the builder's worktree is cut from `HEAD`) and protected (ORACLE_PATHS).

## Hand-off
Show the user the ticket file, the red output, and the Jira enrichment you'd post. They approve, then **run**.
