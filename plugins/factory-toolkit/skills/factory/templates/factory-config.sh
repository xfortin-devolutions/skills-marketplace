# Team defaults for the factory in this repo (sourced by the factory skill's scripts/lib/config.sh; bash 3.2 compatible).
# Machine-specific values (VM root, CPUs, RAM, budget overrides) go in ~/.factory/config.sh, not here.

DEFAULT_PROFILE=@PROFILE@
# Docs a change may always update besides the ticket's scope (repo path prefixes), e.g. ".claude/skills/ docs/ CLAUDE.md".
DOC_PATHS=""

B_MODEL=claude-opus-5-5     B_USD=8    B_MIN=45
R_MODEL=claude-sonnet-5-5   R_USD=2    R_MIN=20
QA_MODEL=claude-opus-5-5    QA_USD=6   QA_MIN=40
# Exploratory QA after a runtime QA PASS: charter (from the diff), explorer (same VM), re-check of findings on the base.
C_MODEL=claude-sonnet-5-5   C_USD=1    C_MIN=10
X_MODEL=claude-opus-5-5     X_USD=5    X_MIN=30    RC_USD=3   RC_MIN=20
EXPLORE=yes                 EXPLORE_SENDBACKS=1
ITER_CAP=3                  LOOP_USD=40
