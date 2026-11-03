# The fake agents' defaults and helpers (sourced by fakes/bin/claude, then the scenario overrides them).
hb_dir() { echo "handback/$(git symbolic-ref --short HEAD | tr / -)"; }
commit_code() { mkdir -p src && echo "$1" > src/feature.txt && git add src && git commit -qm "DEMO-1: Changed the feature ($1)"; }
write_handback() {
  local d; d=$(hb_dir); mkdir -p "$d"
  [ -f "$d/hand-back.md" ] || cp "$FAKE_SKILL/templates/hand-back.md" "$d/hand-back.md"
  git add handback && { git diff --cached --quiet || git commit -qm "handback: DEMO-1 builder sections"; }
}
run_dir() { ls -1dt "$FAKE_RUNS"/demo-1-*/ | head -1; }
builder() { commit_code done; write_handback; }
reviewer() {
  cat <<R
- Reviewer: Claude Code, fake; fresh session: yes; re-ran the Run command: no: the runner's record
- Design: OK: fine; files: src/feature.txt
- Dependencies: n/a: none
- Schema: n/a: none
- Data flows: n/a: none
- Duplication: OK: none
- Docs: n/a: none
- Open findings: none
- Recommend: ${REVIEW:-merge}
R
}
qa() { printf 'Verdict: PASS\nSummary: the feature works\nSteps:\n1. looked\nHuman: none\n'; }
charter() { printf '1. Use the feature twice in a row.\n2. Look at it in OtherWindow.cs\n'; }
explorer() { printf 'Tour:\n1. used it\nFindings:\n'; }
recheck() { echo "- F1: same: also on the base"; }
assessor() { printf 'Size: M\nWhy: one file, fake\nRounds: 1\nSplit: no\nNeeds: none\n'; }
unknown() { echo "unknown prompt"; }
