# Writing a Runtime check

The `## Runtime check` section of `tickets/<KEY>.md` is what the blind QA agent receives, verbatim, and nothing else: it
never sees the code, the diff or the rest of the ticket. Write it for a careful tester who has never seen the app's source.

```
## Runtime check

Platform: windows · Needs human: no | <exactly what a human must confirm>

Launch: <how to reach the screen from the app's main window; name menus and fallbacks; what to do with first-run dialogs>

Steps:
1. <action with exact inputs> ...

Expectations:
- E1: <what must be visible on screen, observable without the code>
- E2: ...

Red on base: <which expectation fails on the base commit, and how>   (confirmed with run-loop.sh --qa-only <base>)
```

## Rules
- **Observable.** "The row appears in the grid" is checkable; "the source is rebuilt" is not. Counters, titles, rows,
  dialogs, colours, a value in a field.
- **Self-contained data.** The VM has no data source, no network shares and no accounts. Use what is in the guest
  (`127.0.0.1`, its open ports, its files) or have a step create it (a new entry with host 127.0.0.1).
- **Timing.** Say when to look ("while the scan runs", "after 10 s") and what "still running" looks like.
- **Side effects too.** Add an expectation for what must *not* change (selection, scroll, focus, no error dialog): the
  reviewer of DEVEX-528 missed exactly that.
- **Red on base first.** Run the QA stage alone on the base commit; if it passes, the check can't tell fixed from
  broken. Rewrite it before any builder run.
- **Needs human** only for what a screenshot can't judge (smoothness, sound, a real remote session); be precise, the run
  pauses on it.

## What the QA stage does with it
The runner builds the branch head in a fresh VM (a guest build failure is already a FAIL), launches the app, and gives this
section to the QA agent. Its verdict goes into the hand-back's Runtime check section with the screenshots; FAIL goes back
to the builder with the report.

After a PASS, the exploratory QA gets this section too, without its Red on base line, so it can find the feature; it
doesn't repeat it, and its findings never change this verdict. So keep the Runtime check to what the ticket asks: what
the change might break around it is the charter's job, not more expectations here.
