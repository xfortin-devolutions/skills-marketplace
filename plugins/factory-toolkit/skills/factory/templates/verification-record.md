# Verification record
<!-- Written by the factory runner (run-loop.sh) after each builder session, never by an agent: the runner runs every command below itself, in the run's build VM, on the Commit, and pastes their exit codes and output. Kept as the reference for its format; a human filling one in by hand follows the same fields. Verdict: PASS only when every command passed (the negative run fails, as expected) and "Not verified" is "nothing"; a test that passed only on a re-run is listed under Flaky. -->

- Change: <ticket ID, or "none">, <one line: what changed>
- Commit: <branch> @ <short SHA of the code commit you verified>
- Timestamp: <UTC, ISO 8601, when the last command finished: `date -u +%Y-%m-%dT%H:%M:%SZ` or `(Get-Date).ToUniversalTime().ToString('o')`>
- Tool: <Claude Code | Codex | Copilot | Cursor> <version from `--version`, or the IDE extension version>
- Model: <model ID as the tool reports it (an agent may read it from its own session context). Claude Code: `/status`, or the key under "modelUsage" in `claude -p --output-format json`. Codex: `/status`, or the `-m` / `config.toml` value (it is not in the `--json` events)>
- Environment: <OS>; <shell>; <runtime versions from `node --version`, `dotnet --version` or `pwsh --version`, whichever your stack uses, e.g. node 22.11 / dotnet 8.0 / pwsh 7.4; write `unknown` for any that is refused (rule 6; not a Not verified item)>

| # | Command (exactly as run) | Exit code | Result |
|---|---|---|---|
| 1 | <command> | <code> | <e.g. 54 passed, 0 failed, 0 skipped> |

Output 1:
```text
<excerpt>
```

- Flaky: <none | each test command that failed and then passed on a re-run, with how many runs failed>
- Not verified: <what you did not check, and why; or "nothing">
- Verdict: <PASS: all passed (expected-fail rows excepted), "Not verified" is "nothing" | PARTIAL: all run passed, something not verified | FAIL>
