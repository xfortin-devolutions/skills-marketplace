# Hand-back: <ticket ID> <one-line title>
<!-- Rules: fill only your role's section. Replace every <...>; write "unknown" or "none" rather than guess. Do not add or remove fields. Where a field lists values (a | b), start with one of them. 25 words per line at most; details go in PR comments. <base> = the branch's merge-base with the target branch (main in the sandbox). Commit this file when your section is done. Keep the comments. -->

## Change (builder)
- PR: <URL, or "no PR: <branch> @ <short SHA>">
- Ticket: <ID or link: what was asked | none: <one-line goal>>
- Builder: <Claude Code | Codex | Copilot | Cursor>, <model ID>
- Autonomy class: <unattended | attended | not yet, as the group's autonomy policy classes this ticket; "unknown" if no policy>
- What changed: <1 to 3 lines, in the ticket's terms>
- Files: outside the ticket's scope: <none | list; a docs(harness) commit appears as "harness: <file>">. Then one path per line, indented two spaces under this line, from `git diff --name-only <base>..<SHA> -- . ':!handback'`. The paths may include the harness file; Q1 ignores `harness:` entries. The builder lists harness commits already on the branch.
- Undo: <revert the commit | flag off | migration down | other: <how>>
- How we'd see it in production: <log | metric | test>: <which one> | none: <why nothing would show it>

## Tests (builder)
- Run: `<command>` → <passed / failed / skipped counts>
- Added: <test name: what it catches; one per line, or "none">
- Fails without the change: <yes: how you showed it | not checked>
- Criteria: <docs/spec-<ticket>.md: each criterion → the test that covers it | none approved>
- Existing tests changed or deleted: <none | which, and why>
- Verification record: <path> @ <short SHA verified> → <PASS | PARTIAL | FAIL>

## Review (reviewer)
<!-- Read the diff (`git diff <base>..<SHA verified>`) and the verification record. Do not edit code. Harness fix: commit it alone (`docs(harness): ...`), write its SHA below, then commit this section. Harness commits (`docs(harness):`) are listed under outside scope as `harness: <file>` and do not count as outside the ticket for judge Q1. The builder lists harness commits already on the branch; on a first pass the reviewer adds the `harness: <file>` entry to Files, the one exception to "fill only your section". On a re-review, read the previous Open findings first and say whether each is fixed. A (blocking) finding means Recommend: send back. -->
- Reviewer: <tool>, <model ID>; fresh session: <yes | no>; re-ran the Run command: <yes: result | no>
- Design: <OK | finding | n/a>: <one line>
- Dependencies: <OK | finding | n/a>: <one line>
- Schema: <OK | finding | n/a>: <one line>
- Data flows: <OK | finding | n/a>: <one line>
- Duplication: <OK | finding | n/a>: <one line>
- Docs: <OK | finding | n/a>: <one line>
- Open findings: <"none", or one per line, each marked (blocking) or (non-blocking)>
- Written back to the harness: <file (AGENTS.md / CLAUDE.md, a skill, a hook) and commit SHA, this round only | none if nothing new>
- Recommend: <merge | send back>

## Runtime check (QA)
<!-- Written by the runner after the blind QA agent ran the ticket's Runtime check in a throwaway VM. Not filled: the ticket has no Runtime check, or QA was off. -->
- QA: <tool, model, blind; VM; build of <short SHA>>
- Verdict: <PASS | FAIL | NEEDS-HUMAN>: <one line>
- Disputed by the builder: <none | the expectations, and the file with the builder's reasons: the judge decides them>
- Report: <path>; evidence: <screenshots>

## Exploratory QA
<!-- Written by the runner after a runtime QA PASS: a second blind agent explored around the change on the same VM, led by a charter written from the diff by a separate session (never the builder's notes). Each finding was then re-tried on a build of the base commit. A blocker the base doesn't show sends the change back once; every other finding is for the judge. Not filled: no runtime QA PASS, or exploration was off. -->
- Explorer: <tool, model, blind; charter by <model>: <path>>
- Findings: <none | count, then one per line, indented two spaces: F<n> (<blocker | minor>, <new | pre-existing | not rechecked>): <what was seen>>
- Base re-check: <not needed | build of <short SHA>: <path> | could not run: <why>>
- Tour for the judge: <path>; evidence: <screenshots>

## Judge (human)
<!-- Check first: `git log --oneline <SHA verified>..HEAD -- . ':!handback'` prints nothing, or only docs(harness) commits, and `git show --stat <that SHA>` touches only the file named in "Written back to the harness". If not, the record is stale: Q3 = no. Harness entries do not count for Q1. -->
1. Does it do what the ticket asked, and nothing outside it? <yes | no | unknown>
2. Would a test fail if the change were reverted? <yes | no | unknown>
3. Does the verification record show real output, on the PR's last code commit? <yes | no | unknown>
4. Can the open review findings and the exploratory findings ship as they are? <yes | no | unknown>
5. If it is wrong in production, will we see it, and is the undo enough? <yes | no | unknown>

Decision: <merge | merge behind flag: <flag> | send back | reject>: <one-line reason>, <your first and last name>, <YYYY-MM-DD>
<!-- send back = the builder iterates on this branch; reject = abandon the change. Send back when: "unknown" on any of questions 1 to 4; "not checked" on Q2 or Q3; Q5 "no" and no flag available; "unknown" on Q5. With no production yet (sandbox), "test" in "How we'd see it" counts as seen. Write the decision in this file; the lab sheet may mirror it as a PR comment.
After send back: the builder commits the fix, re-runs and overwrites the record (own commit), and updates the Change and Tests sections. The reviewer re-reviews and overwrites the Review section. The judge overwrites the Judge section; the previous decision stays in `git log`.
No hand-back file to write in (the run stopped before it): the judge writes the Decision line alone in `handback/<branch-dir>/judge-note.md` and commits it. The Decision commit that judges the fix run deletes the note (`git rm`), so a stale send back never merges into the target branch. -->
