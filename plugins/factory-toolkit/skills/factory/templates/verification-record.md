# Verification record
<!-- Rules for the agent filling this in. Keep this comment in the file.
1. Order: the code change is already committed. Verify that commit, then commit this file on its own. Commit field = the code commit you verified. After a send back, overwrite this file for the new code commit.
2. Commands come from the lab sheet; if it names none, run the project's test command. Run each one yourself now.
3. Run each command on its own: no pipe, no `;` or `&&`, no redirect, no `$?` or `$LASTEXITCODE`, no environment-variable prefix. Headless allow-lists can refuse those forms. The exit code is the one your shell tool reports; no error reported means 0. That exit code is the evidence. If your tool never shows exit codes, write "unknown" (rule 6) and list that command under Not verified. If a form you tried (pipe, chain, redirect, prefix) is refused, run the bare command instead; that refusal is not a Not verified item. A lab-sheet command that is refused as the sheet writes it is a Not verified item. A cmdlet such as Invoke-Pester sets no exit code: run the lab sheet's command, which wraps it in `pwsh -NoProfile -File <script>` or `-Command` and exits with the failure count. `FailedCount` alone misses test files that fail to load, so the sandbox wrapper also counts blocks and containers. In the table, write the command exactly as run. The excerpt quotes the relevant lines of the output your tool shows (rule 4). If output is not in English, the person who launched you applies the README's `locale` value (Fixture map) before starting the agent; do not prefix commands. Paste the output as it is.
4. Paste real output, 15 lines at most per command. Mark cuts with [...]; lines you pick from the output are fine; a separate `grep -n` command row keeps its prefixes. Redact tokens, user names and home paths.
5. A deliberate negative run (new test, change removed) is its own row with Result "expected fail: ..."; it does not make the Verdict FAIL. Restore the change afterwards; then `git status --short -- . ':!handback'` must print nothing before you commit this file.
6. A value you cannot read from a tool: write "unknown". Never guess.
7. Verdict: PASS only if "Not verified" is "nothing"; anything listed there makes it PARTIAL. -->

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

- Not verified: <what you did not check, and why; or "nothing">
- Verdict: <PASS: all passed (expected-fail rows excepted), "Not verified" is "nothing" | PARTIAL: all run passed, something not verified | FAIL>
